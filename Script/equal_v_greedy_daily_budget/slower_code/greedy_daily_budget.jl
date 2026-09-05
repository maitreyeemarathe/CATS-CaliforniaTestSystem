function run_greedy_daily_budget(system, selected_gen_names, selected_hydro_details, main_start_time, solver_xpress, equal_results_directory, greedy_results_directory)

    # Make a variable for total plant-wise revenue/profit 
    revenue_by_plant = Dict{String, Float64}()
    # Make a variable for hydro dispatch across all timesteps
    hydro_dispatch_accumulated = DataFrame()
    # Make a variable for hydro budget usage across all timesteps
    hydro_budget_usage_accumulated = DataFrame()

    # Make a list of the components that are selected hydro units
    selected_hydro_comps = [comp for comp in get_components(HydroDispatch, system) if get_name(comp) in selected_gen_names]
    # Build one DataFrame with hourly budget for all selected hydro generators.
    # Columns: DateTime + one column per selected generator (MW budget per hour).
    selected_hydro_budget_df = DataFrame()
    for (plant_name, (csv_file, gen_names)) in selected_hydro_details
        budget_df = CSV.read(csv_file, DataFrame)
        @assert all(col -> col in propertynames(budget_df), (:datetime, :budget_hour)) "Budget CSV must contain datetime and budget_hour columns"
        println("plant_name: $plant_name, gen_names: $gen_names, budget_df size: $(size(budget_df))")
        dt = DateTime.(String.(budget_df[!, :datetime]), dateformat"yyyy-mm-dd HH:MM:SS")
        if !(:DateTime in names(selected_hydro_budget_df))
            selected_hydro_budget_df[!, :DateTime] = dt
        else
            @assert selected_hydro_budget_df.DateTime == dt "Budget datetime mismatch across plant CSV files"
        end
        total_max_active_power = sum(
            get_max_active_power(c) for c in get_components(HydroDispatch, system) if get_name(c) in gen_names
        )
        for gen_name in gen_names
            if !(gen_name in selected_gen_names)
                continue
            end
            comp = get_component(HydroDispatch, system, gen_name)
            unit_share = get_max_active_power(comp) / total_max_active_power
            selected_hydro_budget_df[!, Symbol(gen_name)] = Float64.(budget_df[!, :budget_hour]) .* unit_share
        end
    end

    for week_i in 1:Int(1)
        horizon_hours_int = Int(24)
        horizon_hours = Hour(horizon_hours_int)
        model_interval = Hour(24)
        sim_steps = Int(7)  
        start_time = main_start_time + (week_i-1)*7*horizon_hours
        system_copy = deepcopy(system)

        week_budget_df = filter(
            row -> row.DateTime >= start_time && row.DateTime < start_time + 7*horizon_hours,
            selected_hydro_budget_df,
        )

        # Get the price forecast for the week starting at start_time
        price_forecast_file = joinpath(equal_results_directory, "shadow_prices.csv")
            price_forecast_df = read_price_forecast(price_forecast_file, start_time)
            price_forecast_df = filter(
                row -> row.DateTime >= start_time && row.DateTime < start_time + 7*horizon_hours,
                price_forecast_df,
            ) 
        sort!(price_forecast_df, :DateTime)
        
        for comp in get_components(HydroDispatch, system_copy)
            if get_name(comp) in selected_gen_names 
                comp_name = get_name(comp)
                ts_max = get_time_series(SingleTimeSeries, comp, "max_active_power")
                max_mw_vals = get_time_series_values(comp, ts_max; start_time = start_time, len = 7*horizon_hours_int)
                ts_min = get_time_series(SingleTimeSeries, comp, "min_active_power")
                min_mw_vals = get_time_series_values(comp, ts_min; start_time = start_time, len = 7*horizon_hours_int)

                week_budget_for_comp = sum(week_budget_df[!, Symbol(comp_name)])
                budget_normalized = calculate_budget(week_budget_for_comp, start_time, max_mw_vals, min_mw_vals, price_forecast_df.value)/get_max_active_power(comp)
                # Pad to full-year length using hourly index offsets.
                ts_times = timestamp(get_data(ts_max))
                start_idx = findfirst(==(start_time), ts_times)::Int
                pre_len = start_idx - 1
                post_len = length(ts_times) - pre_len - length(budget_normalized)
                budget_normalized = vcat(zeros(pre_len), budget_normalized, zeros(post_len))
                @assert length(budget_normalized) == length(ts_times) == 8760 "Padded budget length must be 8760"

                budget_ts = SingleTimeSeries(;
                    name = "hydro_budget",
                    data = TimeArray(timestamp(get_data(ts_max)), budget_normalized),
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
            add_time_series!(system_copy, comp, budget_ts)
        end

        transform_single_time_series!(
            system_copy,
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
        #set_device_model!(template, Source, ImportExportSourceModel)

        
        #solver_highs = JuMP.optimizer_with_attributes(HiGHS.Optimizer) 
        #solver_xpress = JuMP.optimizer_with_attributes(Xpress.Optimizer)
        solver_xpress = JuMP.optimizer_with_attributes(Xpress.Optimizer, 
            "RANDOMSEED" => 123,  # Lock the random seed to a fixed integer
            "THREADS"    => 1,   # Limit solver to a single thread to prevent multi-threading
            "MIPRELSTOP" => 0.001,
            "DETERMINISTIC" => 1,  # Enable deterministic mode for reproducibility
        )

        problem = DecisionModel(
            template,
            system_copy;
            optimizer=solver_xpress,
            optimizer_solve_log_print=false,
            calculate_conflict=false,
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
            simulation_folder = greedy_results_directory,
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

        #=
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
        =#

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

        # Write price per timestep to a CSV file
        price_usd_per_mwh_df = copy(price_df)
        price_usd_per_mwh_df.value ./= get_base_power(system_copy)  # convert from $/100 MWh to $/MWh
        
        hydro_ed_prices_path = joinpath(greedy_results_directory, "hydro_ed_prices.csv")
        if week_i == 1
            CSV.write(hydro_ed_prices_path, price_usd_per_mwh_df)
        else
            CSV.write(hydro_ed_prices_path, price_usd_per_mwh_df; append = true, writeheader = false)
        end

        # Marginal generator at each timestep for this week
        all_dispatch_week = vcat(
            [vcat([copy(df) for df in values(sd)]...) for sd in [dispatch_hydro, dispatch_thermal, dispatch_renewable]]...
        )
        demand_param_dict = read_parameter(ed_results, "ActivePowerTimeSeriesParameter__PowerLoad")
        demand_df_week = vcat([copy(df) for df in values(demand_param_dict)]...)
        week_marginal_dir = joinpath(greedy_results_directory, "week_$(week_i)")
        mkpath(week_marginal_dir)
        write_marginal_generators(all_dispatch_week, price_usd_per_mwh_df, demand_df_week, system_copy, week_marginal_dir)

    end

    # Write selected hydro dispatch once after collecting all iterations.
    CSV.write(joinpath(greedy_results_directory, "selected_hydro_dispatch_wide.csv"), hydro_dispatch_accumulated)

    # Write selected hydro budget usage once after collecting all iterations.
    #CSV.write(joinpath(greedy_results_directory, "hydro_budget_usage_pct.csv"), hydro_budget_usage_accumulated)

    # Write total revenue by plant over all timesteps to a CSV file
    # Note:This is ordered as Mammoth, Shasta, Devil Canyon
    CSV.write(joinpath(greedy_results_directory, "hydro_ed_total_revenue_by_plant.csv"), DataFrame(plant=collect(keys(revenue_by_plant)), revenue=collect(values(revenue_by_plant))))

end
