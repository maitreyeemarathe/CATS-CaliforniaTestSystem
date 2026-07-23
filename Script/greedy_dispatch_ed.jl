function read_price_forecast(file_name, start_time::DateTime)
    # Read the CSV file into a DataFrame
    df = CSV.read(file_name, DataFrame)
    # The data frame has the following columns: :DateTime, :name, :value. Create a new data frame
    # with only the :DateTime and :value columns. Also, adjust the DateTime column to start at the same time
    # as the start_time 
    df = df[:, [:DateTime, :value]]
    df.DateTime .= df.DateTime .- df.DateTime[1] .+ start_time
    return df
end

function generate_greedy_dispatch(prices_dollars_per_MWh, max_power_values_MW, min_power_values_MW, budget_MWh)
    # Initialize the optimal power values array
    optimal_power_values_MW = copy(min_power_values_MW)

    @assert sum(optimal_power_values_MW) <= budget_MWh "Initial sum of min power values exceeds budget"

    # Sort the prices in descending order and get the corresponding indices
    sorted_indices = sortperm(prices_dollars_per_MWh, rev=true)
    
    # Allocate power greedily based on the sorted prices
    for idx in sorted_indices
        if isapprox(optimal_power_values_MW[idx], 33.316457567507, atol=1e-3)
            println("Index $(idx) has optimal power value of $(optimal_power_values_MW[idx])")
        end
        optimal_power_values_MW[idx] = max_power_values_MW[idx]
        if sum(optimal_power_values_MW)*1 > budget_MWh
            optimal_power_values_MW[idx] = min_power_values_MW[idx]
            optimal_power_values_MW[idx] = optimal_power_values_MW[idx] + (budget_MWh - sum(optimal_power_values_MW))
            # if this is less than the minimum power value, assert error
            @assert optimal_power_values_MW[idx] >= min_power_values_MW[idx] "Optimal power value is less than minimum power value"
            #println("min_power_values_MW[idx]: ", min_power_values_MW[idx])
            @assert optimal_power_values_MW[idx] > 0 "Optimal power value is less than or equal to zero"
            break
        end
    end

    return optimal_power_values_MW
end


function generate_offer_curve(
    comp,
    start_time::DateTime,
    optimization_horizon_hours::Hour;
    leftover_budget_by_name::AbstractDict{String, Float64},
)
    price_forecast_file = joinpath(HYDRO_DATA_DIR, "dual_copper_plate_Mar12-18.csv")
    price_forecast_df = read_price_forecast(price_forecast_file, start_time)
    price_forecast_df = filter(
        row -> row.DateTime >= start_time && row.DateTime < start_time + optimization_horizon_hours,
        price_forecast_df,
    )
    sort!(price_forecast_df, :DateTime)

    horizon_len = Int(Dates.value(optimization_horizon_hours))
    @assert nrow(price_forecast_df) == horizon_len "Expected $(horizon_len) price rows, got $(nrow(price_forecast_df))"


    ts_max = get_time_series(SingleTimeSeries, comp, "max_active_power")
    max_mw_vals = get_time_series_values(comp, ts_max; start_time = start_time, len = horizon_len)
    ts_min = get_time_series(SingleTimeSeries, comp, "min_active_power")
    min_mw_vals = get_time_series_values(comp, ts_min; start_time = start_time, len = horizon_len)

    budget_MWh = Float64(leftover_budget_by_name[get_name(comp)])


    optimal_power_values_MW =
        generate_greedy_dispatch(price_forecast_df.value, max_mw_vals, min_mw_vals, budget_MWh)

    # Write the optimal power values to a CSV file for debugging with generator names and timestamps
    debug_df = DataFrame(
        DateTime = price_forecast_df.DateTime,
        Generator = get_name(comp),
        OptimalPowerMW = optimal_power_values_MW,
        MinPowerMW = min_mw_vals,
        MaxPowerMW = max_mw_vals,
    )
    CSV.write(joinpath(RESULTS_DIR, "optimal_power_values_$(get_name(comp)).csv"), debug_df)

    # Build one piecewise step bid per hour: zero-cost debug bids with a stable x-range.
    # Choose a conservative upper bound from observed series values to avoid unit-mismatch issues.
    big_m = 1.0e2
    #small_m = 1.0e-2
    eps_mw = 1.0e-2
    # Overall maximum power rating of the component
    component_max_mw = Float64(get_max_active_power(comp))
    hourly_bids = Vector{PiecewiseStepData}(undef, horizon_len)
    for i in 1:horizon_len
        p_star = clamp(Float64(optimal_power_values_MW[i]), Float64(min_mw_vals[i]), Float64(max_mw_vals[i]))
        hourly_bids[i] = PiecewiseStepData(
            #[0.0, p_star/component_max_mw, component_max_mw/component_max_mw],
            [0.0, p_star, component_max_mw],
            [0.0, 1000],
        )
        if get_name(comp) == "gen-297"
            println("hourly_bids[$i] for gen-297: $(hourly_bids[i])")
        end
        println("Generator $(get_name(comp)) Hour $(i): p_star = $(p_star), component_max_mw = $(component_max_mw), min_mw = $(min_mw_vals[i]), max_mw = $(max_mw_vals[i])")

    end

    # Pad variable_cost across the full underlying timeline so transformed forecast counts are consistent.
    max_ta = get_data(ts_max)
    all_timestamps = timestamp(max_ta)
    total_len = length(all_timestamps)
    full_max_mw_vals = get_time_series_values(comp, ts_max; start_time = all_timestamps[1], len = total_len)
    full_min_mw_vals = get_time_series_values(comp, ts_min; start_time = all_timestamps[1], len = total_len)
    observed_upper = maximum(Float64.(full_max_mw_vals))
    observed_lower = maximum(Float64.(full_min_mw_vals))
    debug_upper_mw = max(observed_upper, observed_lower, 1.0)
    @assert debug_upper_mw >= observed_upper "Debug offer upper bound below max_active_power"
    @assert debug_upper_mw >= observed_lower "Debug offer upper bound below min_active_power"
    full_hourly_bids = Vector{PiecewiseStepData}(undef, total_len)
    for i in 1:total_len
        p_star = clamp(Float64(full_min_mw_vals[i]), Float64(full_min_mw_vals[i]), Float64(full_max_mw_vals[i]))
        upper = Float64(full_max_mw_vals[i]) + eps_mw
        full_hourly_bids[i] = PiecewiseStepData(
            [0.0, 100.0],
            [0.0]
        )
    end

    start_idx = findfirst(==(start_time), all_timestamps)
    @assert !isnothing(start_idx) "start_time $(start_time) not found in max_active_power timestamps"
    @assert start_idx + horizon_len - 1 <= total_len "Offer-curve horizon exceeds available timeline"
    for i in 1:horizon_len
        full_hourly_bids[start_idx + i - 1] = hourly_bids[i]
    end

    return SingleTimeSeries(
        ;
        name = "variable_cost",
        data = TimeArray(all_timestamps, full_hourly_bids),
    )

end