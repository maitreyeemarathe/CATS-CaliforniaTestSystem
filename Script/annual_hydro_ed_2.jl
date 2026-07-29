
using PowerSystems
using PowerSimulations
using HydroPowerSimulations
using PowerSystemCaseBuilder
using PowerFlows
#using Xpress
using HiGHS
using Dates
using JuMP
using PowerFlows
import PowerNetworkMatrices: VirtualPTDF
using TimeSeries
using XLSX
using Plots



#if isempty(Xpress.libxprs)
#    error("Xpress loaded with empty lib path. Restart Julia and rerun after setting XPRESSDIR/XPRESS_JL_LIBRARY.")
#end

BASE_DIR = joinpath(@__DIR__, "..")
HYDRO_DATA_DIR = "$BASE_DIR/hydro_data/"
RESULTS_DIR = "$BASE_DIR/results/annual_ed_2/"
CATS_DIR = "$BASE_DIR/Sienna/"

include(joinpath(CATS_DIR, "build_CATS_modified.jl"))
include(joinpath(dirname(@__FILE__), "annual_greedy_dispatch_ed_2.jl"))


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

# Budget assignment
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
        budget_hourly = convert(Vector{Float64}, collect(budget_df[!, :budget_hour]))
        total_max_active_power = sum(
            get_max_active_power(c) for c in get_components(HydroDispatch, system) if get_name(c) in gen_names
        )
        max_ts = get_time_series(SingleTimeSeries, comp, "max_active_power")
        max_ta = get_data(max_ts)
        @assert length(timestamp(max_ta)) == length(budget_hourly) "Shasta hydro budget series length does not match max_active_power timestamps"
        unit_max = get_max_active_power(comp)
        unit_share = unit_max / total_max_active_power
        unit_budget_hourly = budget_hourly .* unit_share
        unit_budget_normalized = unit_budget_hourly ./ unit_max
        budget_ts = SingleTimeSeries(;
            name = "hydro_budget",
            data = TimeArray(timestamp(max_ta), unit_budget_normalized),
            scaling_factor_multiplier = get_max_active_power,
        )
    else
        # Assign a unity hydro_budget for non-selected hydro units 
        # Since they are not constrained by budget, they can operate up to their max_active_power at all times.
        budget_ts = SingleTimeSeries(;
            name = "hydro_budget",
            data = TimeArray(timestamp(get_data(get_time_series(SingleTimeSeries, comp, "max_active_power"))), ones(length(timestamp(get_data(get_time_series(SingleTimeSeries, comp, "max_active_power")))))),
            scaling_factor_multiplier = get_max_active_power,
        )   
    end
    add_time_series!(system, comp, budget_ts)
    
end


# Selected hydro units use market bids so we can attach hourly offer-curve time series.
for comp in get_components(HydroDispatch, system)
    if get_name(comp) in selected_gen_names
        set_operation_cost!(
            comp,
            MarketBidCost(
                ;
                no_load_cost = 0.0,
                start_up = (hot = 0.0, warm = 0.0, cold = 0.0),
                shut_down = 0.0,
            ),
        )
    end
end





# Choose the week to solve.
# Example: week starting Monday 2019-07-01 00:00.
horizon_hours_int = Int(24)
horizon_hours = Hour(horizon_hours_int)
model_interval = Hour(24)
sim_steps = Int(1)  

# Make a variable for total plant-wise revenue/profit 
revenue_by_plant = Dict{String, Float64}()
# Make a variable for hydro dispatch across all timesteps
hydro_dispatch_accumulated = DataFrame()
# Make a variable for hydro budget usage across all timesteps
hydro_budget_usage_accumulated = DataFrame()


# Make a deepcopy of the system and solve for multiple timesteps
for i in 1:Int(52*7)
    start_time = DateTime("2019-01-01T00:00:00") + (i-1)*horizon_hours
    system_copy = deepcopy(system)

    println("Day $(i)")
    # Calculate total budget for each selected hydro unit by summing the hourly budget values over the horizon starting at start_time.
    total_budget_mwh_by_name = Dict{String, Float64}()
    for comp in get_components(HydroDispatch, system_copy)
        if get_name(comp) in selected_gen_names
            budget_ts = get_time_series(SingleTimeSeries, comp, "hydro_budget")
            budget_vals = get_time_series_values(
                comp,
                budget_ts;
                start_time = start_time,
                len = sim_steps*horizon_hours_int,
            )
            total_budget_mwh = sum(budget_vals)
            #println("Total budget for hydro unit $(get_name(comp)) over the horizon starting at $(start_time): $(total_budget_mwh) MWh")
            total_budget_mwh_by_name[get_name(comp)] = total_budget_mwh
        end
    end

    # Find if there is any hydro unit such that the sum of min_active_power over the horizon starting at start_time exceeds the total budget. If so, print a warning.
    for comp in get_components(HydroDispatch, system_copy)
        if get_name(comp) in selected_gen_names
            min_ts = get_time_series(SingleTimeSeries, comp, "min_active_power")
            min_vals = get_time_series_values(
                comp,
                min_ts;
                start_time = start_time,
                len = sim_steps*horizon_hours_int,
            )
            total_min_mwh = sum(min_vals)
            if total_min_mwh > total_budget_mwh_by_name[get_name(comp)]
                println("Warning: Hydro unit ", get_name(comp), " has minimum generation (", total_min_mwh, " MWh) exceeding its total budget (", total_budget_mwh_by_name[get_name(comp)], " MWh).")
            end
        end
    end

    offer_curve_by_name = Dict{String, SingleTimeSeries}()
    for comp in get_components(HydroDispatch, system_copy)
        if get_name(comp) in selected_gen_names 
            offer_curves = generate_offer_curve(
                    comp,
                    start_time,
                    Hour(sim_steps*horizon_hours_int);
                    leftover_budget_by_name = total_budget_mwh_by_name,
                    forecast_perfect = false,
                    day = i
                )
            offer_curve_by_name[get_name(comp)] = offer_curves
            set_variable_cost!(system_copy, comp, offer_curves, UnitSystem.NATURAL_UNITS)
            ts_max = get_time_series(SingleTimeSeries, comp, "max_active_power")
            max_ta = get_data(ts_max)
            initial_input_ts = SingleTimeSeries(
                ;
                name = "incremental_initial_input",
                data = TimeArray(timestamp(max_ta), zeros(Float64, length(timestamp(max_ta)))),
            )
            set_incremental_initial_input!(system_copy, comp, initial_input_ts)
        end   
    end

    transform_single_time_series!(
            system_copy,
            horizon_hours,  # horizon
            model_interval,   # interval (daily rolling windows)
        );

    template = ProblemTemplate(NetworkModel(CopperPlatePowerModel; use_slacks=false, duals=[CopperPlateBalanceConstraint]))

    set_device_model!(template, ThermalStandard, ThermalBasicDispatch)
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, HydroDispatch, HydroDispatchRunOfRiver)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, Line, StaticBranch)
    set_device_model!(template, Transformer2W, StaticBranch)
 
    solver_highs = JuMP.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false,) 

    problem = DecisionModel(
        template,
        system_copy;
        optimizer=solver_highs,
        optimizer_solve_log_print=false,
        calculate_conflict=false,
        #rebuild_model = true,
        horizon = horizon_hours,
        interval = model_interval,
        initial_time = start_time,
        name="ED",
        store_variable_names = true
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
    #dispatch_thermal = read_variable(ed_results, "ActivePowerVariable__ThermalStandard")
    #dispatch_renewable = read_variable(ed_results, "ActivePowerVariable__RenewableDispatch")
    #dispatch_tables = [dispatch_hydro, dispatch_thermal, dispatch_renewable]

    # Write the dispatch of all selected hydro units to a CSV file for external analysis.
    #hydro_dispatch_timesteps = sort(unique(vcat([DateTime.(df[!, :DateTime]) for df in values(dispatch_hydro)]...)))

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

    # Accumulate dispatch across iterations and write once after the loop.
    append!(hydro_dispatch_accumulated, hydro_dispatch_wide; cols = :union, promote = true)

    budget_usage_df = DataFrame(name = String[], budget_used_pct = Float64[])
    for gen_name in sort(collect(selected_gen_names))
        total_dispatch_mwh = sum(hydro_dispatch_wide[!, gen_name])
        total_budget_mwh = total_budget_mwh_by_name[gen_name]
        budget_used_pct = total_budget_mwh > 0 ? 100 * total_dispatch_mwh / total_budget_mwh : NaN
        #println(
        #    "Total budget used for hydro unit ",
        #    gen_name,
        #    ": ",
        #    budget_used_pct,
        #    "% (",
        #    total_dispatch_mwh,
        #    " MWh / ",
        #    total_budget_mwh,
        #    " MWh)",
        #)
        push!(budget_usage_df, (name = gen_name, budget_used_pct = budget_used_pct))
    end

    append!(hydro_budget_usage_accumulated, budget_usage_df; cols = :union, promote = true)
 

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

            
    for row in eachrow(by_plant)
        plant = String(row.plant)
        revenue_by_plant[plant] = get(revenue_by_plant, plant, 0.0) + Float64(row.revenue)
    end

    # Write revenue/profit summaries to CSV
    #hydro_ed_revenue_by_generator_path = joinpath(RESULTS_DIR, "hydro_ed_revenue_by_generator.csv")
    #hydro_ed_revenue_by_plant_path = joinpath(RESULTS_DIR, "hydro_ed_revenue_by_plant.csv")
    #if i == 1
    #    CSV.write(hydro_ed_revenue_by_generator_path, by_gen)
    #    CSV.write(hydro_ed_revenue_by_plant_path, by_plant)
    #else
    #    CSV.write(hydro_ed_revenue_by_generator_path, by_gen; append = true, writeheader = false)
    #    CSV.write(hydro_ed_revenue_by_plant_path, by_plant; append = true, writeheader = false)
    #end


    # Write price per timestep to a CSV file
    price_usd_per_mwh_df = copy(price_df)
    price_usd_per_mwh_df.value ./= get_base_power(system)  # convert from $/100 MWh to $/MWh
    
    hydro_ed_prices_path = joinpath(RESULTS_DIR, "hydro_ed_prices.csv")
    if i == 1
        CSV.write(hydro_ed_prices_path, price_usd_per_mwh_df)
    else
        CSV.write(hydro_ed_prices_path, price_usd_per_mwh_df; append = true, writeheader = false)
    end


end

# Write selected hydro dispatch once after collecting all iterations.
CSV.write(joinpath(RESULTS_DIR, "selected_hydro_dispatch_wide.csv"), hydro_dispatch_accumulated)

# Write selected hydro budget usage once after collecting all iterations.
CSV.write(joinpath(RESULTS_DIR, "hydro_budget_usage_pct.csv"), hydro_budget_usage_accumulated)

# Write price per timestep once after collecting all iterations.
CSV.write(joinpath(RESULTS_DIR, "hydro_ed_prices.csv"), price_accumulated)

# Write total revenue by plant over all timesteps to a CSV file
# Note:This is ordered as Mammoth, Shasta, Devil Canyon
CSV.write(joinpath(RESULTS_DIR, "hydro_ed_total_revenue_by_plant.csv"), DataFrame(plant=collect(keys(revenue_by_plant)), revenue=collect(values(revenue_by_plant))))



#=  
build!(problem, output_dir=mktempdir())
solve!(problem)


results = OptimizationProblemResults(problem)
# Read dual variables
dual_balance_constraint = read_dual(results, "CopperPlateBalanceConstraint__System")
println("Dual variables for CopperPlateBalanceConstraint__System:", dual_balance_constraint)
CSV.write(joinpath(RESULTS_DIR, "dual_copper_plate.csv"), dual_balance_constraint)

dispatch_results = read_variable(results, "ActivePowerVariable__HydroDispatch")
CSV.write(joinpath(RESULTS_DIR, "hydro_dispatch.csv"), dispatch_results)

# Hourly diagnostics: dispatch, active tranche, balance dual, and local hydro dual terms.
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

function _get_coords(psd, candidates::Vector{Symbol})
    for c in candidates
        if c in fieldnames(typeof(psd))
            return collect(Float64.(getfield(psd, c)))
        end
    end
    error("Could not find coordinates on $(typeof(psd)). Fields = $(fieldnames(typeof(psd)))")
end

function _active_tranche(p_mw::Float64, x::Vector{Float64})
    tol = 1e-6
    n = length(x)
    if n < 2
        return 1
    end
    if p_mw <= x[1] + tol
        return 1
    end
    for j in 1:(n - 1)
        if p_mw <= x[j + 1] + tol
            return j
        end
    end
    return n - 1
end

function _clean_key_name(s::String)
    cleaned = replace(s, r"[^A-Za-z0-9]+" => "_")
    return Symbol(lowercase(cleaned))
end

function _pick_col(df::DataFrame, candidates::Vector{Symbol}, label::String)
    cols = Symbol.(propertynames(df))
    for c in candidates
        if c in cols
            return c
        end
    end
    error("Could not find $(label) column. Tried $(candidates). Available: $(cols)")
end

week_end_time = start_time + horizon_hours
dispatch_comp_col = _pick_col(dispatch_results, [:name, :component_name, :asset], "dispatch component")

dispatch_diag = filter(
    row -> row[dispatch_comp_col] in selected_gen_names && row[:DateTime] >= start_time && row[:DateTime] < week_end_time,
    dispatch_results,
)
balance_diag = filter(
    row -> row[:DateTime] >= start_time && row[:DateTime] < week_end_time,
    dual_balance_constraint,
)

diag = innerjoin(
    select(dispatch_diag, :DateTime, dispatch_comp_col => :gen_name, :value => :dispatch_mw),
    select(balance_diag, :DateTime, :value => :balance_dual),
    on = :DateTime,
)

diag.abs_balance_dual = abs.(diag.balance_dual)
diag.active_tranche = zeros(Int, nrow(diag))
diag.tranche_price = fill(NaN, nrow(diag))
diag.p_star = fill(NaN, nrow(diag))
diag.offer_x = fill("", nrow(diag))
diag.offer_y = fill("", nrow(diag))

for r in eachrow(diag)
    g = r.gen_name
    offer_ts = offer_curve_by_name[g]
    ta = get_data(offer_ts)
    ts = timestamp(ta)
    vals = TimeSeries.values(ta)
    i0 = findfirst(==(r.DateTime), ts)
    @assert i0 !== nothing "Timestamp $(r.DateTime) not found in offer curve for $(g)"
    psd = ndims(vals) == 1 ? vals[i0] : vals[i0, 1]
    x = _get_coords(psd, [:x_coords, :x])
    y = _get_coords(psd, [:y_coords, :y])
    tr = _active_tranche(Float64(r.dispatch_mw), x)
    r.active_tranche = tr
    r.tranche_price = y[min(tr, length(y))]
    r.p_star = length(x) >= 2 ? x[2] : NaN
    r.offer_x = string(x)
    r.offer_y = string(y)
end

diag.offer_minus_abs_balance = diag.tranche_price .- diag.abs_balance_dual

# Pull available local hydro active-power dual tables and join as extra columns.
local_dual_table_count = 0
try
    all_duals = read_duals(results)
    for (k, v) in all_duals
        key_s = String(k)
        if occursin("HydroDispatch", key_s) && occursin("ActivePower", key_s)
            dfk = _to_df(v)
            if :DateTime ∉ names(dfk) || :value ∉ names(dfk)
                continue
            end
            dcol = :name in names(dfk) ? :name : (:component_name in names(dfk) ? :component_name : nothing)
            if isnothing(dcol)
                continue
            end
            renamed_val = Symbol("dual_" * String(_clean_key_name(key_s)))
            dfk2 = select(dfk, :DateTime, dcol => :gen_name, :value => renamed_val)
            diag = leftjoin(diag, dfk2, on = [:DateTime, :gen_name])
            local_dual_table_count += 1
        end
    end
catch err
    @warn "Could not read all dual tables for local-dual diagnostics" err
end

CSV.write(joinpath(RESULTS_DIR, "hydro_dual_gap_diagnostics.csv"), diag)
println("Wrote hydro dual-gap diagnostics with $(nrow(diag)) rows and $(local_dual_table_count) local dual tables")

# Merit order export (all generator types): one worksheet per timestamp.
all_var_tables = DataFrame[]
all_var_keys = String[]
try
    for (k, v) in read_variables(results)
        key_s = String(k)
        push!(all_var_keys, key_s)
        if !occursin("ActivePowerVariable", key_s)
            continue
        end
        dfk = _to_df(v)
        tcol = try
            _pick_col(dfk, [:DateTime, :datetime, :timestamp, :time], "timestamp")
        catch
            nothing
        end
        vcol = try
            _pick_col(dfk, [:value, :Value], "value")
        catch
            nothing
        end
        if tcol === nothing || vcol === nothing
            continue
        end
        dcol = try
            _pick_col(dfk, [:name, :component_name, :asset], "dispatch component")
        catch
            nothing
        end
        if dcol === nothing
            continue
        end
        tdf = select(dfk, tcol => :DateTime, dcol => :gen_name, vcol => :dispatch_mw)
        insertcols!(tdf, :variable_table => fill(key_s, nrow(tdf)))
        push!(all_var_tables, tdf)
    end
catch err
    @warn "read_variables(results) failed while collecting all generator dispatch tables" err
end

# Fallback: directly try common active-power table names by device type.
if isempty(all_var_tables)
    fallback_tables = [
        "ActivePowerVariable__ThermalStandard",
        "ActivePowerVariable__ThermalMultiStart",
        "ActivePowerVariable__RenewableDispatch",
        "ActivePowerVariable__HydroDispatch",
        "ActivePowerVariable__Source",
        "ActivePowerVariable__EnergyReservoirStorage",
        "ActivePowerVariable__HydroEnergyReservoir",
        "ActivePowerVariable__HydroTurbine",
        "ActivePowerVariable__HydroPumpTurbine",
    ]
    for tbl in fallback_tables
        try
            dfk = read_variable(results, tbl)
            tcol = try
                _pick_col(dfk, [:DateTime, :datetime, :timestamp, :time], "timestamp")
            catch
                nothing
            end
            vcol = try
                _pick_col(dfk, [:value, :Value], "value")
            catch
                nothing
            end
            if tcol === nothing || vcol === nothing
                continue
            end
            dcol = try
                _pick_col(dfk, [:name, :component_name, :asset], "dispatch component")
            catch
                nothing
            end
            if dcol === nothing
                continue
            end
            tdf = select(dfk, tcol => :DateTime, dcol => :gen_name, vcol => :dispatch_mw)
            insertcols!(tdf, :variable_table => fill(tbl, nrow(tdf)))
            push!(all_var_tables, tdf)
        catch
            # Ignore missing tables for device types not present in this case.
        end
    end
end

@assert !isempty(all_var_tables) "No ActivePowerVariable tables found in results. read_variables keys seen: $(all_var_keys)"
all_dispatch = vcat(all_var_tables...)
all_dispatch = filter(row -> row.DateTime >= start_time && row.DateTime < week_end_time, all_dispatch)

function _max_available_at_time(comp::Generator, dt::DateTime)
    try
        ts = get_time_series(SingleTimeSeries, comp, "max_active_power")
        vals = get_time_series_values(comp, ts; start_time = dt, len = 1)
        return Float64(first(vals))
    catch
        return Float64(get_max_active_power(comp))
    end
end


scarcity_time = DateTime("2019-03-21T15:00:00")
hour_dispatch = filter(row -> row.DateTime == scarcity_time, all_dispatch)
dispatch_by_name = Dict{String, Float64}()
for row in eachrow(hour_dispatch)
    name = String(row.gen_name)
    dispatch_by_name[name] = get(dispatch_by_name, name, 0.0) + Float64(row.dispatch_mw)
end

total_non_shasta_dispatch_mw = sum(
    Float64(row.dispatch_mw) for row in eachrow(hour_dispatch) if !(String(row.gen_name) in shasta_gen_names)
)
actual_shasta_dispatch_mw = sum(
    Float64(row.dispatch_mw) for row in eachrow(hour_dispatch) if String(row.gen_name) in shasta_gen_names
)

remaining_non_shasta_headroom_mw = sum(
    max(0.0, _max_available_at_time(comp, scarcity_time) - get(dispatch_by_name, get_name(comp), 0.0))
    for comp in get_components(Generator, system)
    if !(get_name(comp) in shasta_gen_names)
)

load_param = read_parameter(results, "ActivePowerTimeSeriesParameter__PowerLoad")
load_tcol = _pick_col(load_param, [:DateTime, :datetime, :timestamp, :time], "load timestamp")
load_vcol = _pick_col(load_param, [:value, :Value], "load value")
total_load_mw = - sum(
    load_param[load_param[!, load_tcol] .== scarcity_time, load_vcol]
)
required_shasta_output_mw = total_load_mw - total_non_shasta_dispatch_mw

println("\n=== Scarcity Check @ $(scarcity_time) ===")
println("1. Total load (MW): ", total_load_mw)
println("2. Total non-Shasta dispatch (MW): ", total_non_shasta_dispatch_mw)
println("3. Remaining non-Shasta headroom (MW): ", remaining_non_shasta_headroom_mw)
println("4. Required Shasta output from balance (MW) = load - non-Shasta dispatch: ", required_shasta_output_mw)
println("5. Actual Shasta dispatch (MW): ", actual_shasta_dispatch_mw)

all_diag = innerjoin(
    all_dispatch,
    select(balance_diag, :DateTime, :value => :balance_dual),
    on = :DateTime,
)
all_diag.abs_balance_dual = abs.(all_diag.balance_dual)

# Attach hydro-specific tranche diagnostics where available.
hydro_cols = select(
    diag,
    :DateTime,
    :gen_name,
    :active_tranche,
    :tranche_price,
    :p_star,
    :offer_minus_abs_balance,
    :offer_x,
    :offer_y,
)
all_diag = leftjoin(all_diag, hydro_cols, on = [:DateTime, :gen_name])
if :active_tranche in names(all_diag)
    all_diag.active_tranche = coalesce.(all_diag.active_tranche, -1)
end

# Merit price logic:
# - Selected hydro generators: use active tranche price from diagnostics.
# - All other generators: use marginal cost from operation cost curve at dispatch.
name_to_comp = Dict(get_name(comp) => comp for comp in get_components(Generator, system))

function _marginal_from_fd(fd, p::Float64)
    if fd isa LinearFunctionData
        return get_proportional_term(fd)
    elseif fd isa QuadraticFunctionData
        return 2.0 * get_quadratic_term(fd) * p + get_proportional_term(fd)
    elseif fd isa PiecewiseStepData
        x = get_x_coords(fd)
        y = get_y_coords(fd)
        tr = _active_tranche(p, collect(Float64.(x)))
        return y[min(tr, length(y))]
    elseif fd isa PiecewiseLinearData
        x = collect(Float64.(get_x_coords(fd)))
        s = get_slopes(fd)
        tr = _active_tranche(p, x)
        return s[min(tr, length(s))]
    else
        return NaN
    end
end

function _component_marginal_cost(comp::Generator, p::Float64)
    cost = get_operation_cost(comp)
    isnothing(cost) && return NaN

    # MarketBidCost is only expected for selected hydro in this workflow.
    if cost isa MarketBidCost
        return NaN
    end

    if cost isa ImportExportCost
        var = get_import_offer_curves(cost)
    elseif cost isa StorageCost
        var = get_charge_variable(cost)
    else
        var = get_variable(cost)
    end
    isnothing(var) && return NaN

    vc = get_value_curve(var)
    fd = get_function_data(vc)
    return _marginal_from_fd(fd, p)
end

all_diag.merit_price = fill(NaN, nrow(all_diag))
for r in eachrow(all_diag)
    g = r.gen_name
    p = Float64(r.dispatch_mw)
    if (g in selected_gen_names) && !ismissing(r.tranche_price)
        r.merit_price = Float64(r.tranche_price)
        continue
    end
    comp = get(name_to_comp, g, nothing)
    if comp === nothing
        r.merit_price = NaN
        continue
    end
    r.merit_price = _component_marginal_cost(comp, p)
end

merit_order_path = joinpath(RESULTS_DIR, "all_generators_merit_order_by_timestep.xlsx")
timesteps = sort(unique(all_diag.DateTime))

XLSX.openxlsx(merit_order_path, mode = "w") do xf
    for (i, dt) in enumerate(timesteps)
        sdf = filter(row -> row.DateTime == dt, all_diag)
        sdf.sort_merit_price = coalesce.(sdf.merit_price, Inf)
        sort!(sdf, [:sort_merit_price, :dispatch_mw], rev = [false, true])
        sdf.rank = collect(1:nrow(sdf))

        merit_df = select(
            sdf,
            :rank,
            :gen_name,
            :variable_table,
            :dispatch_mw,
            :merit_price,
            :balance_dual,
            :abs_balance_dual,
            :active_tranche,
            :tranche_price,
            :p_star,
            :offer_minus_abs_balance,
            :offer_x,
            :offer_y,
        )

        sheet_name = "t" * lpad(string(i), 3, '0') * "_" * Dates.format(dt, "yyyymmdd_HHMM")
        sheet = if i == 1
            XLSX.renamesheet!(xf[1], sheet_name)
            xf[1]
        else
            XLSX.addsheet!(xf, sheet_name)
        end

        columns = [merit_df[!, c] for c in names(merit_df)]
        XLSX.writetable!(sheet, columns, String.(names(merit_df)); write_columnnames = true)
    end
end

println("Wrote all-generator merit-order workbook: $(merit_order_path)")

# Calculate total revenue for each selected hydro unit over the week starting at start_time.
# Revenue per time step = dispatch (MW) * dual price ($/MWh), with 1-hour resolution.
total_revenue_df = DataFrame(name=String[], total_revenue=Float64[])
week_end_time = start_time + horizon_hours

for comp in get_components(HydroDispatch, system)
    unit_name = get_name(comp)
    if unit_name in selected_gen_names
        dispatch_df = filter(
            row -> row[dispatch_comp_col] == unit_name && row[:DateTime] >= start_time && row[:DateTime] < week_end_time,
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

CSV.write(joinpath(RESULTS_DIR, "hydro_total_revenue.csv"), total_revenue_df)

# Calculate the percentage of the weekly budget used for each selected hydro unit over the week starting at start_time.
budget_usage_df = DataFrame(name=String[], budget_used_pct=Float64[])
for comp in get_components(HydroDispatch, system)
    unit_name = get_name(comp)
    if unit_name in selected_gen_names
        dispatch_df = filter(
            row -> row[dispatch_comp_col] == unit_name && row[:DateTime] >= start_time && row[:DateTime] < week_end_time,
            dispatch_results,
        )
        total_dispatch_mwh = sum(dispatch_df[!, :value])
        println(total_dispatch_mwh, " MWh dispatched for hydro unit ", unit_name, " over the week starting at ", start_time)
        total_budget_mwh = weekly_budget_mwh_by_name[unit_name]
        println(total_budget_mwh, " MWh budget for hydro unit ", unit_name, " over the week starting at ", start_time)
        budget_used_pct = total_budget_mwh > 0 ? 100 * total_dispatch_mwh / total_budget_mwh : NaN
        push!(budget_usage_df, (name=unit_name, budget_used_pct=budget_used_pct))
    end
end
# Write the budget usage percentages to a CSV file.
CSV.write(joinpath(RESULTS_DIR, "hydro_budget_usage_pct.csv"), budget_usage_df)
=#


#=
# Read dual variables
dual_balance_constraint = read_dual(results, "CopperPlateBalanceConstraint__System")
println("Dual variables for CopperPlateBalanceConstraint__System:", dual_balance_constraint)
CSV.write(joinpath(RESULTS_DIR, "dual_copper_plate.csv"),dual_balance_constraint)


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


dispatch_results = read_variable(results, "ActivePowerVariable__HydroDispatch")
CSV.write(joinpath(RESULTS_DIR, "hydro_dispatch.csv"), dispatch_results)
# Read only Shasta hydro dispatch results
selected_dispatch_results = filter(row -> row[:name] in selected_gen_names, dispatch_results)
CSV.write(joinpath(RESULTS_DIR, "selected_dispatch_results.csv"), selected_dispatch_results)
#load_parameters = read_parameter(results,"ActivePowerTimeSeriesParameter__PowerLoad");
#CSV.write(joinpath(RESULTS_DIR, "load_parameters.csv"), load_parameters)
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
