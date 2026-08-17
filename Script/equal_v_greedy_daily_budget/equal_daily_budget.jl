function run_equal_daily_budget(template, system, solver_xpress, start_time,results_directory, selected_gen_names, selected_hydro_details)

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
            # Assign a unity hydro_budget for non-selected hydro units (they are not constrained by a budget).
            budget_ts = SingleTimeSeries(;
                name = "hydro_budget",
                data = TimeArray(timestamp(get_data(get_time_series(SingleTimeSeries, comp, "max_active_power"))), ones(length(timestamp(get_data(get_time_series(SingleTimeSeries, comp, "max_active_power")))))),
                scaling_factor_multiplier = get_max_active_power,
            )   
        end
        add_time_series!(system, comp, budget_ts)
    end

    horizon_hours_int = Int(24)
    horizon_hours = Hour(horizon_hours_int)
    model_interval = Hour(24)
    sim_steps = Int(7)  

    transform_single_time_series!(
        system,
        horizon_hours,  # horizon
        model_interval,   # interval (daily rolling windows)
    );

    problem = DecisionModel(
        template,
        system;
        optimizer=solver_xpress,
        check_numerical_bounds=false,
        initialize_model = false,
        optimizer_solve_log_print=true,
        horizon = horizon_hours,
        interval = model_interval,
        initial_time = start_time,
        calculate_conflict=false,
        store_variable_names = false,
        name="equal_daily_budget",
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
        simulation_folder = results_directory,
        initial_time=start_time
    )
    build!(sim)
    execute!(sim)
    results = SimulationResults(sim)

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

    problem_results = get_decision_problem_results(results, "equal_daily_budget")

    # Compute revenue/profit for selected hydro units in ED
    problem_variables = read_variables(problem_results)
    problem_duals = read_duals(problem_results)

    # Write dispatch of all generators to XLSX for external analysis. Make a new sheet for each timestep
    dispatch_hydro = read_variable(problem_results, "ActivePowerVariable__HydroDispatch")
    dispatch_thermal = read_variable(problem_results, "ActivePowerVariable__ThermalStandard")
    dispatch_renewable = read_variable(problem_results, "ActivePowerVariable__RenewableDispatch")
    dispatch_tables = [dispatch_hydro, dispatch_thermal, dispatch_renewable]

    dispatch_xlsx_path = joinpath(results_directory, "ed_dispatch_all_generators_by_timestep.xlsx")
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
        joinpath(results_directory, "selected_hydro_dispatch_wide.csv"),
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
        joinpath(results_directory, "hydro_budget_usage_pct.csv"),
        budget_usage_df,
    )


    # Find ED hydro dispatch and ED energy price tables
    hydro_key = only([k for k in keys(problem_variables) if occursin("ActivePowerVariable", String(k)) && occursin("HydroDispatch", String(k))])
    price_key = only([k for k in keys(problem_duals) if occursin("CopperPlateBalanceConstraint", String(k))])


    hydro_sd = problem_variables[hydro_key]   # SortedDict{DateTime, DataFrame}
    price_sd = problem_duals[price_key]   # SortedDict{DateTime, DataFrame}

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

    println("\n=== Selected Hydro Revenue by Generator ===")
    show(by_gen, allrows=true, allcols=true); println()

    println("\n=== Selected Hydro Revenue by Plant ===")
    show(by_plant, allrows=true, allcols=true); println()

    println("\nTotal selected hydro revenue = \$$(round(sum(by_plant.revenue), digits=2))")
    println("Total selected hydro profit  = \$$(round(sum(by_plant.profit), digits=2))")

    # Write revenue/profit summaries to CSV
    CSV.write(joinpath(results_directory, "hydro_revenue_by_generator.csv"), by_gen)
    CSV.write(joinpath(results_directory, "hydro_revenue_by_plant.csv"), by_plant) 


    # Write price per timestep to a CSV file
    price_usd_per_mwh_df = copy(price_df)
    price_usd_per_mwh_df.value ./= get_base_power(system)  # convert from $/100 MWh to $/MWh
    CSV.write(joinpath(results_directory, "shadow_prices.csv"), price_usd_per_mwh_df)  # convert from $/100 MWh to $/MWh


    # Get maximum dispatch bounds for hydro plants
    hydro_max_param_dict = read_parameter(problem_results, "ActivePowerTimeSeriesParameter__HydroDispatch")
    hydro_min_param_dict = read_parameter(problem_results, "MinActivePowerTimeSeriesParameter__HydroDispatch")

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
    savefig(fig, joinpath(results_directory, "hydro_dispatch_price_combined.png"))

end