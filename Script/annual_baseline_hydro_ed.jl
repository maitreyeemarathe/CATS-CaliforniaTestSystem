
#ENV["XPRESSDIR"] = "$(homedir())/Documents/Xpress"

# if environmnent isn't set up, see top of Script/uc_ed_with_ac_pf.jl for setup instructions
using PowerSystems
using PowerSimulations
using HydroPowerSimulations
using PowerSystemCaseBuilder
using PowerFlows
#using Ipopt
#using Xpress
using HiGHS
using Dates
using JuMP
using PowerFlows
import PowerNetworkMatrices: VirtualPTDF
using TimeSeries
using XLSX
using Plots


BASE_DIR = joinpath(@__DIR__, "..")
HYDRO_DATA_DIR = "$BASE_DIR/hydro_data/"
RESULTS_DIR = "$BASE_DIR/results/annual_baseline/"
CATS_DIR = "$BASE_DIR/Sienna/"

include(joinpath(CATS_DIR, "baseline_build_CATS_modified.jl"))

# Find selected hydro units and assign budget
gen_csv = CSV.read("$BASE_DIR/GIS/CATS_gens.csv", DataFrame)
shasta_csv = joinpath(HYDRO_DATA_DIR, "shasta_hourly.csv")
devilcanyon_csv = joinpath(HYDRO_DATA_DIR, "devilcanyon_hourly.csv")
mammoth_csv = joinpath(HYDRO_DATA_DIR, "mammoth_hourly.csv")
shasta_gen_names = get_hydro_gen_names(gen_csv; plant_code=445, bus=1498, gen_ids=["1", "2", "3", "4", "5"], expected_count=5)
devilcanyon_gen_names = get_hydro_gen_names(gen_csv; plant_code=436, bus=1005, gen_ids=["1", "2", "3", "4"], expected_count=4) 
mammoth_gen_names = get_hydro_gen_names(gen_csv; plant_code=344, bus=1636, gen_ids=["1", "2"], expected_count=2)  
selected_hydro_details = Dict(
    "Shasta" => (shasta_csv, shasta_gen_names),
    "Devil Canyon" => (devilcanyon_csv, devilcanyon_gen_names),
    "Mammoth" => (mammoth_csv, mammoth_gen_names)
)
selected_gen_names = union(shasta_gen_names, devilcanyon_gen_names, mammoth_gen_names)

for comp in get_components(HydroDispatch, system)
    if get_name(comp) in selected_gen_names
        # find the csv file for the hydro plant this unit belongs to and assign the corresponding budget series
        match = nothing
        for (plant_name, (csv_file, gen_names)) in selected_hydro_details
            if get_name(comp) in gen_names
                match = (plant_name, csv_file, gen_names)
                break
            end
        end
        @assert match !== nothing "Could not find CSV file for hydro unit $(get_name(comp))"
        plant_name, filename, gen_names = match
        budget_df = CSV.read(filename, DataFrame)
        @assert all(col -> col in propertynames(budget_df), (:datetime, :budget_hour)) "Budget CSV must contain datetime and budget_hour columns" 
        budget_hourly_mw = convert(Vector{Float64}, collect(budget_df[!, :budget_hour]))
        total_max_active_power = sum(
            get_max_active_power(c) for c in get_components(HydroDispatch, system) if get_name(c) in gen_names
        )
        max_ts = get_time_series(SingleTimeSeries, comp, "max_active_power")
        max_ta = get_data(max_ts)
        @assert length(timestamp(max_ta)) == length(budget_hourly_mw) "hydro budget series length does not match max_active_power timestamps"
        unit_max = get_max_active_power(comp)
        unit_share = unit_max / total_max_active_power
        unit_budget_hourly_mw = budget_hourly_mw .* unit_share
        unit_budget_normalized = unit_budget_hourly_mw ./ unit_max
        budget_ts = SingleTimeSeries(;
            name = "hydro_budget",
            data = TimeArray(timestamp(max_ta), unit_budget_normalized),
            scaling_factor_multiplier = get_max_active_power,
        )
    else
        # Assign a unity hydro_budget for non-Shasta hydro units (they are not constrained by Shasta budget).
        budget_ts = SingleTimeSeries(;
            name = "hydro_budget",
            data = TimeArray(timestamp(get_data(get_time_series(SingleTimeSeries, comp, "max_active_power"))), ones(length(timestamp(get_data(get_time_series(SingleTimeSeries, comp, "max_active_power")))))),
            scaling_factor_multiplier = get_max_active_power,
        )   
    end
    add_time_series!(system, comp, budget_ts)
    # add hydro_budget_interval = 168 hours for all hydro units

    
end

# Choose the week to solve.
# Example: week starting Monday 2019-07-01 00:00.
start_time = DateTime("2019-01-01T00:00:00")
horizon_hours_int = Int(24)
horizon_hours = Hour(horizon_hours_int)
model_interval = Hour(24)
sim_steps = Int(7*52)  

# Calculate total budget for each selected hydro unit by summing the hourly budget values over the horizon starting at start_time.
total_budget_mwh_by_name = Dict{String, Float64}()
for comp in get_components(HydroDispatch, system)
    if get_name(comp) in selected_gen_names
        budget_ts = get_time_series(SingleTimeSeries, comp, "hydro_budget")
        budget_vals = get_time_series_values(
            comp,
            budget_ts;
            start_time = start_time,
            len = sim_steps*horizon_hours_int,
        )
        total_budget_mwh = sum(budget_vals)
        println("Total budget for hydro unit $(get_name(comp)) over the horizon starting at $(start_time): $(total_budget_mwh) MWh")
        total_budget_mwh_by_name[get_name(comp)] = total_budget_mwh
    end
end

transform_single_time_series!(
    system,
    horizon_hours,  # horizon
    model_interval,   # interval (daily rolling windows)
);

template = ProblemTemplate(NetworkModel(CopperPlatePowerModel; use_slacks=false, duals=[CopperPlateBalanceConstraint]))

set_device_model!(template, ThermalStandard, ThermalBasicDispatch)
set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
set_device_model!(template, HydroDispatch, HydroDispatchRunOfRiverBudget)
set_device_model!(template, PowerLoad, StaticPowerLoad)
set_device_model!(template, Line, StaticBranch)
set_device_model!(template, Transformer2W, StaticBranch)
 
solver_highs = JuMP.optimizer_with_attributes(HiGHS.Optimizer) 

problem = DecisionModel(
    template,
    system;
    optimizer=solver_highs,
    optimizer_solve_log_print=true,
    calculate_conflict=true,
    horizon = horizon_hours,
    interval = model_interval,
    initial_time = start_time,
    name="ED"
)



model = SimulationModels(;decision_models = problem)
sequence = SimulationSequence(;
    models = model,
    ini_cond_chronology = InterProblemChronology(),
)
sim = Simulation(;
    name = "cats_hydro_ed",
    steps = sim_steps,
    models = model,
    sequence = sequence,
    simulation_folder = RESULTS_DIR,
    #joinpath(".", "cats_hydro_ed_simulation"),
    initial_time=start_time
)
build!(sim)
execute!(sim)
results = SimulationResults(sim)

ed_results = get_decision_problem_results(results, "ED")

# Compute revenue/profit for selected hydro units in ED
ved = read_variables(ed_results)
ded = read_duals(ed_results)

# Write dispatch of all generators to XLSX for external analysis. Make a new sheet for each timestep
dispatch_hydro = read_variable(ed_results, "ActivePowerVariable__HydroDispatch")
dispatch_thermal = read_variable(ed_results, "ActivePowerVariable__ThermalStandard")
dispatch_renewable = read_variable(ed_results, "ActivePowerVariable__RenewableDispatch")
dispatch_tables = [dispatch_hydro, dispatch_thermal, dispatch_renewable]

#=
dispatch_xlsx_path = joinpath(RESULTS_DIR, "ed_dispatch_all_generators_by_timestep.xlsx")
dispatch_timesteps = sort(unique(vcat([collect(keys(sd)) for sd in dispatch_tables]...)))

XLSX.openxlsx(dispatch_xlsx_path, mode = "w") do xf
    for (i, dt) in enumerate(dispatch_timesteps)
        dfs = DataFrame[]
        for sd in dispatch_tables
            if haskey(sd, dt)
                push!(dfs, copy(sd[dt]))
            end
        end
        sdf = isempty(dfs) ? DataFrame() : vcat(dfs...)
        if :DateTime ∉ names(sdf)
            sdf.DateTime = fill(dt, nrow(sdf))
        end
        if :value in names(sdf)
            sort!(sdf, :value, rev = true)
        end

        sheet_name = "t" * lpad(string(i), 3, '0') * "_" * Dates.format(dt, "yyyymmdd_HHMM")
        sheet = if i == 1
            XLSX.renamesheet!(xf[1], sheet_name)
            xf[1]
        else
            XLSX.addsheet!(xf, sheet_name)
        end

        columns = [sdf[!, c] for c in names(sdf)]
        XLSX.writetable!(sheet, columns, String.(names(sdf)); write_columnnames = true)
    end
end

println("Wrote all-generator dispatch workbook: $(dispatch_xlsx_path)")
=#

# Write the dispatch of all selected hydro units to a CSV file for external analysis.
hydro_dispatch_timesteps = sort(unique(vcat([DateTime.(df[!, :DateTime]) for df in values(dispatch_hydro)]...)))

# Name column used to identify generators in dispatch tables.
hydro_name_col = :name

# 1) Build one long table from all simulation-step DataFrames.
# Each DataFrame already contains row-level DateTime values.
hydro_long = vcat([copy(df) for df in values(dispatch_hydro)]...)

# 2) Keep only generators we care about.
hydro_long = filter(row -> row[hydro_name_col] in selected_gen_names, hydro_long)

# 3) Pivot to wide format:
#    rows   -> DateTime
#    cols   -> generator name
#    values -> dispatch MW
hydro_dispatch_wide = unstack(
    hydro_long,
    :DateTime,
    hydro_name_col,
    :value;
    combine = first,  # safe if a (DateTime, gen) appears once
)

# 4) Sort by time so output is chronological.
sort!(hydro_dispatch_wide, :DateTime)

# 5) Ensure every selected generator has a column, and replace missing with NaN.
ordered_gens = sort(collect(selected_gen_names))
for gen_name in ordered_gens
    if !(gen_name in names(hydro_dispatch_wide))
        hydro_dispatch_wide[!, gen_name] = fill(NaN, nrow(hydro_dispatch_wide))
    else
        hydro_dispatch_wide[!, gen_name] = coalesce.(hydro_dispatch_wide[!, gen_name], NaN)
    end
end

# 6) Keep columns in a clean order: DateTime first, then sorted generator names.
select!(hydro_dispatch_wide, Cols(:DateTime, ordered_gens...))

CSV.write(
    joinpath(RESULTS_DIR, "selected_hydro_dispatch_wide.csv"),
    hydro_dispatch_wide,
)

budget_usage_df = DataFrame(name = String[], budget_used_pct = Float64[])
for gen_name in sort(collect(selected_gen_names))
    total_dispatch_mwh = sum(hydro_dispatch_wide[!, gen_name])
    total_budget_mwh = total_budget_mwh_by_name[gen_name]
    budget_used_pct = total_budget_mwh > 0 ? 100 * total_dispatch_mwh / total_budget_mwh : NaN
    println(
        "Total budget used for hydro unit ",
        gen_name,
        ": ",
        budget_used_pct,
        "% (",
        total_dispatch_mwh,
        " MWh / ",
        total_budget_mwh,
        " MWh)",
    )
    push!(budget_usage_df, (name = gen_name, budget_used_pct = budget_used_pct))
end

CSV.write(
    joinpath(RESULTS_DIR, "hydro_budget_usage_pct.csv"),
    budget_usage_df,
)



# Find ED hydro dispatch and ED energy price tables
hydro_key = only([k for k in keys(ved) if occursin("ActivePowerVariable", String(k)) && occursin("HydroDispatch", String(k))])
price_key = only([k for k in keys(ded) if occursin("CopperPlateBalanceConstraint", String(k))])


hydro_sd = ved[hydro_key]   # SortedDict{DateTime, DataFrame}
price_sd = ded[price_key]   # SortedDict{DateTime, DataFrame}

# Flatten SortedDict -> one DataFrame (attach DateTime if missing)
to_df(sd) = vcat([
    begin
        x = copy(df)
        #if :DateTime ∉ names(x)
        #    x.DateTime = fill(dt, nrow(x))
        #end
        x
    end
    for (dt, df) in pairs(sd)
]...)

hydro_df = to_df(hydro_sd)
price_df = to_df(price_sd)

comp_col = :component_name in names(hydro_df) ? :component_name : :name

# Keep only selected hydro generators
hydro_df = filter(row -> row[comp_col] in selected_gen_names, hydro_df)

# Join dispatch with price
rev_df = innerjoin(
    select(hydro_df, :DateTime, comp_col, :value),
    select(price_df, :DateTime, :value),
    on = :DateTime,
    makeunique = true,
)

DataFrames.rename!(rev_df, comp_col => :gen_name, :value => :mw, :value_1 => :price)


# 1-hour ED resolution => MWh = MW
rev_df.energy_mwh = rev_df.mw
rev_df.revenue = rev_df.energy_mwh .* rev_df.price/100 # price is in $ per 100 MWh, so divide by 100 to get $ per MWh
rev_df.production_cost = zeros(nrow(rev_df))   # or: fill(0.0, nrow(rev_df))
rev_df.profit = rev_df.revenue .- rev_df.production_cost


# Map generator -> plant
gen_to_plant = Dict(g => plant for (plant, (_, gens)) in selected_hydro_details for g in gens)
rev_df.plant = [get(gen_to_plant, g, "UNKNOWN") for g in rev_df.gen_name]

# Summaries
by_gen = combine(groupby(rev_df, :gen_name),
    :energy_mwh => sum => :energy_mwh,
    :revenue => sum => :revenue,
    :profit => sum => :profit,
)

by_plant = combine(groupby(rev_df, :plant),
    :energy_mwh => sum => :energy_mwh,
    :revenue => sum => :revenue,
    :profit => sum => :profit,
)

println("\n=== Selected Hydro ED Revenue by Generator ===")
show(by_gen, allrows=true, allcols=true); println()

println("\n=== Selected Hydro ED Revenue by Plant ===")
show(by_plant, allrows=true, allcols=true); println()

println("\nTotal selected hydro ED revenue = \$$(round(sum(by_plant.revenue), digits=2))")
println("Total selected hydro ED profit  = \$$(round(sum(by_plant.profit), digits=2))")

# Write revenue/profit summaries to CSV
CSV.write(joinpath(RESULTS_DIR, "hydro_ed_revenue_by_generator.csv"), by_gen)
CSV.write(joinpath(RESULTS_DIR, "hydro_ed_revenue_by_plant.csv"), by_plant) 


# Write price per timestep to a CSV file
price_usd_per_mwh_df = copy(price_df)
price_usd_per_mwh_df.value ./= get_base_power(system)  # convert from $/100 MWh to $/MWh
CSV.write(joinpath(RESULTS_DIR, "hydro_ed_prices.csv"), price_usd_per_mwh_df)  # convert from $/100 MWh to $/MWh

# Get maximum dispatch bounds for hydro plants
hydro_max_param_dict = read_parameter(ed_results, "ActivePowerTimeSeriesParameter__HydroDispatch")
hydro_min_param_dict = read_parameter(ed_results, "MinActivePowerTimeSeriesParameter__HydroDispatch")

# Convert SortedDict to DataFrame
hydro_max_param = vcat([
    begin
        x = copy(df)
        #if :DateTime ∉ names(x)
        #    println("Adding DateTime column to hydro_max_param for dt = $(dt)")
        #    x.DateTime = fill(dt, nrow(x))
        #end
        x
    end
    for (dt, df) in pairs(hydro_max_param_dict)
]...)
hydro_min_param = vcat([
    begin
        x = copy(df)
        x
    end
    for (dt, df) in pairs(hydro_min_param_dict)
]...)

# Plot system price and dispatch for each plant in a single figure
system_price = combine(groupby(rev_df, :DateTime), :price => first => :price)  # Price is identical per DateTime
p_price = plot(system_price.DateTime, (system_price.price)/100; label="System Price (USD/MWh)", color=:red, xlabel="", ylabel="USD/MWh", title="System Energy Price", legend=:topright)

# Create plant dispatch plots
plant_plots = []
for (plant, (_, gens)) in selected_hydro_details
    plant_df = filter(row -> row.gen_name in gens, rev_df)
    plant_dispatch = combine(groupby(plant_df, :DateTime), :mw => sum => :total_mw)
    
    # Aggregate max bounds by plant
    plant_max = filter(row -> row[:name] in gens, hydro_max_param)
    plant_max_agg = combine(groupby(plant_max, :DateTime), :value => sum => :max_mw)
    # Aggregate min bounds by plant
    plant_min = filter(row -> row[:name] in gens, hydro_min_param)
    plant_min_agg = combine(groupby(plant_min, :DateTime), :value => sum => :min_mw)
    # Create plot with dispatch and bounds
    p = plot(plant_dispatch.DateTime, plant_dispatch.total_mw; label="Dispatch (MW)", color=:blue, lw=2, xlabel="", ylabel="MW", title="Dispatch for $(plant)", legend=:topright)
    plot!(p, plant_max_agg.DateTime, plant_max_agg.max_mw; label="Maximum (MW)", color=:red, ls=:dash, lw=1.5)
    plot!(p, plant_min_agg.DateTime, plant_min_agg.min_mw; label="Minimum (MW)", color=:green, ls=:dash, lw=1.5)
    push!(plant_plots, p)
end

# Combine all plots into a single figure
fig = plot(p_price, plant_plots...; layout=(5, 1), link=:x, size=(1500, 1500), dpi=150,
    left_margin=8Plots.mm, bottom_margin=10Plots.mm, right_margin=8Plots.mm)
display(fig)
savefig(fig, joinpath(RESULTS_DIR, "hydro_dispatch_price_combined.png"))

#model = SimulationModels(;decision_model = problem)

#=
build!(problem, output_dir=mktempdir()) 
solve!(problem)
 
results = OptimizationProblemResults(problem)
# Read dual variables
dual_balance_constraint = read_dual(results, "CopperPlateBalanceConstraint__System")
println("Dual variables for CopperPlateBalanceConstraint__System:", dual_balance_constraint)
CSV.write(joinpath(RESULTS_DIR, "dual_copper_plate.csv"), dual_balance_constraint)

# Dual of the energy budget constraint per hydro unit (shadow price of ∑p ≤ ∑budget).
# Workaround: extract directly from JuMP constraints to avoid PSI dual-container shape mismatch.

container = PowerSimulations.get_optimization_container(problem)
budget_key = PowerSimulations.ConstraintKey(EnergyBudgetConstraint, HydroDispatch)
selected_budget_duals = DataFrame(name = String[], t = Any[], dual = Float64[])

try
    budget_cons = PowerSimulations.get_constraint(container, budget_key)
    selected_names = collect(selected_gen_names)
    if ndims(budget_cons) == 1
        model_names = collect(axes(budget_cons, 1))
        for g in intersect(model_names, selected_names)
            push!(selected_budget_duals, (name = g, t = 1, dual = JuMP.dual(budget_cons[g])))
        end
    elseif ndims(budget_cons) == 2
        model_names = collect(axes(budget_cons, 1))
        time_axis = collect(axes(budget_cons, 2))
        for g in intersect(model_names, selected_names), t in time_axis
            push!(selected_budget_duals, (name = g, t = t, dual = JuMP.dual(budget_cons[g, t])))
        end
    else
        @warn "Unsupported EnergyBudgetConstraint dimensions" ndims(budget_cons)
    end
catch err
    @warn "Could not retrieve EnergyBudgetConstraint container" err
end

#println("Energy budget duals for selected hydro generators:")
#println(selected_budget_duals)
#CSV.write("selected_budget_duals.csv", selected_budget_duals)
#aux_variables = read_aux_variables(results)

#dispatch_results = read_variable(results, "ActivePowerVariable__HydroDispatch")
#CSV.write("hydro_dispatch.csv", dispatch_results)
# Read only Shasta hydro dispatch results
#selected_dispatch_results = filter(row -> row[:name] in selected_gen_names, dispatch_results)
#CSV.write("selected_dispatch_results.csv", selected_dispatch_results)
#load_parameters = read_parameter(results,"ActivePowerTimeSeriesParameter__PowerLoad");
#CSV.write("load_parameters.csv", load_parameters)

dispatch_results = read_variable(results, "ActivePowerVariable__HydroDispatch")
CSV.write(joinpath(RESULTS_DIR, "baseline_hydro_dispatch.csv"), dispatch_results)

# Calculate total revenue for each selected hydro unit over the week starting at start_time.
# Revenue per time step = dispatch (MW) * dual price ($/MWh), with 1-hour resolution.
total_revenue_df = DataFrame(name=String[], total_revenue=Float64[])
week_end_time = start_time + horizon_hours


for comp in get_components(HydroDispatch, system)
    unit_name = get_name(comp)
    if unit_name in selected_gen_names
        dispatch_df = filter(
            row -> row[:name] == unit_name && row[:DateTime] >= start_time && row[:DateTime] < week_end_time,
            dispatch_results,
        )
        dual_df = filter(
            row -> row[:DateTime] >= start_time && row[:DateTime] < week_end_time,
            dual_balance_constraint,
        )

        dispatch_aligned = select(dispatch_df, :DateTime, :value => :dispatch_mw)
        dual_aligned = select(dual_df, :DateTime, :value => :dual_price)
        joined = innerjoin(dispatch_aligned, dual_aligned, on=:DateTime)

        @assert nrow(joined) == nrow(dispatch_df) "Dispatch and dual timestamps are not fully aligned for hydro unit $(unit_name)"
        total_revenue = sum(joined[!, :dispatch_mw] .* joined[!, :dual_price]./100)

        push!(total_revenue_df, (name=unit_name, total_revenue=total_revenue))
    end
end

CSV.write(joinpath(RESULTS_DIR, "baseline_hydro_total_revenue.csv"), total_revenue_df)
=#

#=
# Print the merit order of generators at the first time step
function _to_df(sd)
    if sd isa DataFrame
        return sd
    end
    return vcat([
        begin
            x = copy(df)
            if :DateTime ∉ names(x)
                x.DateTime = fill(dt, nrow(x))
            end
            x
        end
        for (dt, df) in pairs(sd)
    ]...)
end

function _pick_col(df::DataFrame, candidates::Vector{Symbol})
    cols = Symbol.(propertynames(df))
    for c in candidates
        if c in cols
            return c
        end
    end
    error("Could not find expected column. Tried $(candidates). Available: $(cols)")
end

function _active_tranche(p_mw::Float64, x::Vector{Float64})
    for j in 1:(length(x) - 1)
        if p_mw <= x[j + 1] + 1e-6
            return j
        end
    end
    return max(1, length(x) - 1)
end

function _marginal_from_fd(fd, p::Float64)
    if fd isa LinearFunctionData
        return get_proportional_term(fd)
    elseif fd isa QuadraticFunctionData
        return 2.0 * get_quadratic_term(fd) * p + get_proportional_term(fd)
    elseif fd isa PiecewiseStepData
        x = collect(Float64.(get_x_coords(fd)))
        y = get_y_coords(fd)
        return y[min(_active_tranche(p, x), length(y))]
    elseif fd isa PiecewiseLinearData
        x = collect(Float64.(get_x_coords(fd)))
        s = get_slopes(fd)
        return s[min(_active_tranche(p, x), length(s))]
    else
        return NaN
    end
end

function _component_marginal_cost(comp::Generator, p::Float64)
    cost = get_operation_cost(comp)
    isnothing(cost) && return NaN

    var = if cost isa ImportExportCost
        get_import_offer_curves(cost)
    elseif cost isa StorageCost
        get_charge_variable(cost)
    else
        get_variable(cost)
    end
    isnothing(var) && return NaN

    return _marginal_from_fd(get_function_data(get_value_curve(var)), p)
end

all_var_tables = DataFrame[]
for (k, v) in read_variables(results)
    key_s = String(k)
    if !occursin("ActivePowerVariable", key_s)
        continue
    end
    dfk = _to_df(v)
    tcol = _pick_col(dfk, [:DateTime, :datetime, :timestamp, :time])
    vcol = _pick_col(dfk, [:value, :Value])
    dcol = _pick_col(dfk, [:name, :component_name, :asset])
    tdf = select(dfk, tcol => :DateTime, dcol => :gen_name, vcol => :dispatch_mw)
    insertcols!(tdf, :variable_table => fill(key_s, nrow(tdf)))
    push!(all_var_tables, tdf)
end

all_dispatch = vcat(all_var_tables...)
first_dt = minimum(all_dispatch.DateTime)
first_dispatch = filter(row -> row.DateTime == first_dt, all_dispatch)
name_to_comp = Dict(get_name(comp) => comp for comp in get_components(Generator, system))

merit_df = DataFrame(
    gen_name = String[],
    variable_table = String[],
    dispatch_mw = Float64[],
    merit_price = Float64[],
)

for row in eachrow(first_dispatch)
    g = String(row.gen_name)
    comp = get(name_to_comp, g, nothing)
    if comp === nothing
        continue
    end
    p = Float64(row.dispatch_mw)
    push!(merit_df, (
        gen_name = g,
        variable_table = String(row.variable_table),
        dispatch_mw = p,
        merit_price = _component_marginal_cost(comp, p),
    ))
end

merit_df.sort_merit_price = coalesce.(merit_df.merit_price, Inf)
sort!(merit_df, [:sort_merit_price, :dispatch_mw], rev = [false, true])
merit_df.rank = collect(1:nrow(merit_df))
select!(merit_df, :rank, :gen_name, :variable_table, :dispatch_mw, :merit_price)

merit_order_path = joinpath(RESULTS_DIR, "baseline_generators_merit_order_first_timestep.xlsx")
XLSX.openxlsx(merit_order_path, mode = "w") do xf
    sheet = xf[1]
    XLSX.renamesheet!(sheet, "merit_order")
    columns = [merit_df[!, c] for c in names(merit_df)]
    XLSX.writetable!(sheet, columns, String.(names(merit_df)); write_columnnames = true)
end
println("Wrote first-timestep merit order workbook: $(merit_order_path)")

=#



# ══════════════════════════════════════════════════════════════════════════════
# Plotting
# ══════════════════════════════════════════════════════════════════════════════
#=
using Plots
using Statistics

base_power = get_base_power(system)   # 100 MW for CATS

# ── 1. System shadow prices ───────────────────────────────────────────────────
# Duals are in $/base_power per hour; divide by base_power to get $/MW.
balance_df = sort(dual_balance_constraint, :DateTime)
balance_times = balance_df[!, :DateTime]
balance_duals_mw = balance_df[!, :value] ./ base_power

# ── 2. Budget duals per plant (check consistency, convert to $/MW) ────────────
function plant_budget_dual_mw(budget_df, gen_names, base_pwr)
    sub = filter(row -> row[:name] in gen_names, budget_df)
    isempty(sub) && return NaN
    dvals = sub[!, :dual]
    if !all(isapprox.(dvals, dvals[1]; atol=1e-3))
        @warn "Budget duals differ within plant — using mean" sub
    else
        println("  ✓ Budget duals are identical within plant ($(round(dvals[1]; sigdigits=5)))")
    end
    return mean(dvals) / base_pwr
end

println("Budget dual consistency check:")
shasta_λ      = plant_budget_dual_mw(selected_budget_duals, shasta_gen_names,      base_power)
devilcanyon_λ = plant_budget_dual_mw(selected_budget_duals, devilcanyon_gen_names,  base_power)
mammoth_λ     = plant_budget_dual_mw(selected_budget_duals, mammoth_gen_names,      base_power)
println("Shasta budget dual:      $(round(shasta_λ;      sigdigits=5)) \$/MW")
println("Devil Canyon budget dual: $(round(devilcanyon_λ; sigdigits=5)) \$/MW")
println("Mammoth budget dual:     $(round(mammoth_λ;     sigdigits=5)) \$/MW")

# ── 3. Hydro dispatch and power bounds per plant ──────────────────────────────
hydro_max_param = read_parameter(results, "ActivePowerTimeSeriesParameter__HydroDispatch")
hydro_min_param = try
    read_parameter(results, "MinActivePowerTimeSeriesParameter__HydroDispatch")
catch e
    @warn "MinActivePowerTimeSeriesParameter not available; plotting zeros for min" e
    nothing
end

# Aggregate values for a set of generators by summing over time
function plant_total_series(df, gen_names)
    sub = filter(row -> row[:name] in gen_names, df)
    totals = combine(groupby(sub, :DateTime), :value => sum => :total)
    return sort(totals, :DateTime)
end

dispatch_times = sort(unique(selected_dispatch_results[!, :DateTime]))

shasta_disp_df      = plant_total_series(selected_dispatch_results, shasta_gen_names)
devilcanyon_disp_df = plant_total_series(selected_dispatch_results, devilcanyon_gen_names)
mammoth_disp_df     = plant_total_series(selected_dispatch_results, mammoth_gen_names)

shasta_max_df      = plant_total_series(hydro_max_param, shasta_gen_names)
devilcanyon_max_df = plant_total_series(hydro_max_param, devilcanyon_gen_names)
mammoth_max_df     = plant_total_series(hydro_max_param, mammoth_gen_names)

if !isnothing(hydro_min_param)
    shasta_min_df      = plant_total_series(hydro_min_param, shasta_gen_names)
    devilcanyon_min_df = plant_total_series(hydro_min_param, devilcanyon_gen_names)
    mammoth_min_df     = plant_total_series(hydro_min_param, mammoth_gen_names)
else
    n = length(dispatch_times)
    shasta_min_df      = DataFrame(DateTime=dispatch_times, total=zeros(n))
    devilcanyon_min_df = DataFrame(DateTime=dispatch_times, total=zeros(n))
    mammoth_min_df     = DataFrame(DateTime=dispatch_times, total=zeros(n))
end

# ── 3B. Weekly hydro budget utilization by plant (%) ─────────────────────────
function _to_datetime_vec(v)
    if eltype(v) <: DateTime
        return collect(v)
    else
        svec = strip.(string.(v))
        out = Vector{DateTime}(undef, length(svec))
        for i in eachindex(svec)
            s = svec[i]
            out[i] = try
                # ISO-like form, e.g. 2019-01-01T00:00:00
                DateTime(s)
            catch
                try
                    # CSV form in this project, e.g. 2019-01-01 00:00:00
                    DateTime(s, dateformat"yyyy-mm-dd HH:MM:SS")
                catch
                    # Variant with fractional seconds
                    DateTime(s, dateformat"yyyy-mm-dd HH:MM:SS.s")
                end
            end
        end
        return out
    end
end

function plant_budget_usage_pct(dispatch_df, csv_file, start_time, horizon)
    # Dispatch is MW at 1h resolution, so sum(values) is weekly MWh.
    dispatch_energy = sum(dispatch_df[!, :total])

    budget_df = CSV.read(csv_file, DataFrame)
    @assert :datetime in propertynames(budget_df) && :budget_hour in propertynames(budget_df) "Budget CSV must contain datetime and budget_hour columns"
    dt = _to_datetime_vec(budget_df[!, :datetime])
    t_end = start_time + horizon
    mask = (dt .>= start_time) .& (dt .< t_end)
    budget_energy = sum(budget_df[mask, :budget_hour])

    return budget_energy > 0 ? 100 * dispatch_energy / budget_energy : NaN
end

shasta_usage_pct = plant_budget_usage_pct(shasta_disp_df, shasta_csv, start_time, horizon_hours)
devilcanyon_usage_pct = plant_budget_usage_pct(devilcanyon_disp_df, devilcanyon_csv, start_time, horizon_hours)
mammoth_usage_pct = plant_budget_usage_pct(mammoth_disp_df, mammoth_csv, start_time, horizon_hours)

# ── 4. Build subplots ─────────────────────────────────────────────────────────
dt_fmt = x -> Dates.format(x, "mm/dd HH:MM")
xtick_vals = balance_times[1:24:end]          # one label per day
xtick_lbls = dt_fmt.(xtick_vals)

p1 = plot(balance_times, balance_duals_mw;
    label="System LMP", color=:black, lw=2,
    xlabel="", ylabel="\$/MW", title="Shadow prices",
    xticks=(xtick_vals, xtick_lbls), xrotation=30, legend=:best)
hline!(p1, -[shasta_λ];      label="Shasta budget dual",       color=:steelblue,   ls=:dash,    lw=1.5)
hline!(p1, -[devilcanyon_λ]; label="Devil Canyon budget dual", color=:darkorange,  ls=:dot,     lw=1.5)
hline!(p1, -[mammoth_λ];     label="Mammoth budget dual",      color=:forestgreen, ls=:dashdot, lw=1.5)

function dispatch_subplot(title_str, disp_df, max_df, min_df, xtick_vals, xtick_lbls)
    p = plot(disp_df[!, :DateTime], disp_df[!, :total];
        label="Dispatch", color=:steelblue, lw=2,
        xlabel="", ylabel="MW", title=title_str,
        xticks=(xtick_vals, xtick_lbls), xrotation=30, legend=:best)
    plot!(p, max_df[!, :DateTime], max_df[!, :total]; label="Max", color=:red,       ls=:dash, lw=1.5)
    plot!(p, min_df[!, :DateTime], min_df[!, :total]; label="Min", color=:darkgreen, ls=:dot,  lw=1.5)
    return p
end

p2 = dispatch_subplot("Shasta",      shasta_disp_df,      shasta_max_df,      shasta_min_df,      xtick_vals, xtick_lbls)
p3 = dispatch_subplot("Devil Canyon", devilcanyon_disp_df, devilcanyon_max_df, devilcanyon_min_df, xtick_vals, xtick_lbls)
p4 = dispatch_subplot("Mammoth",     mammoth_disp_df,     mammoth_max_df,     mammoth_min_df,     xtick_vals, xtick_lbls)

# Add right-side usage text on each plant subplot.
annot_x = maximum(balance_times) + Hour(6)
#xlims!(p2, minimum(balance_times), maximum(balance_times) + Hour(18))
#xlims!(p3, minimum(balance_times), maximum(balance_times) + Hour(18))
#xlims!(p4, minimum(balance_times), maximum(balance_times) + Hour(18))
annotate!(p2, annot_x, maximum(shasta_max_df[!, :total]) * 0.9,
    text("Budget used: $(round(shasta_usage_pct; sigdigits=4))%", 10, :black, :left))
annotate!(p3, annot_x, maximum(devilcanyon_max_df[!, :total]) * 0.9,
    text("Budget used: $(round(devilcanyon_usage_pct; sigdigits=4))%", 10, :black, :left))
annotate!(p4, annot_x, maximum(mammoth_max_df[!, :total]) * 0.9,
    text("Budget used: $(round(mammoth_usage_pct; sigdigits=4))%", 10, :black, :left))

xlabel!(p4, "Time")

fig = plot(p1, p2, p3, p4;
    layout=(4, 1), link=:x, size=(1500, 1300), dpi=150,
    left_margin=8Plots.mm, bottom_margin=10Plots.mm, right_margin=40Plots.mm)

plot_path = joinpath(dirname(@__FILE__), "hydro_dispatch_plot.png")
savefig(fig, plot_path)
println("Plot saved: ", plot_path)

=#
