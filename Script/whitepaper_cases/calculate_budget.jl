function read_price_forecast(file_name, start_time::DateTime)
    # Read the CSV file into a DataFrame
    df = CSV.read(file_name, DataFrame)
    # The data frame has the following columns: :DateTime, :name, :value. Create a new data frame
    # with only the :DateTime and :value columns. Also, adjust the DateTime column to start at the same time
    # as the start_time 
    df = df[:, [:DateTime, :value]]
    #df.DateTime .= df.DateTime .- df.DateTime[1] .+ start_time
    return df
end

function calculate_budget(week_budget_for_comp, start_time, max_power_values_MW, min_power_values_MW, prices_dollars_per_MWh)
    optimal_power_values_MW = generate_greedy_dispatch(prices_dollars_per_MWh, max_power_values_MW, min_power_values_MW, week_budget_for_comp)
    # Calculate daily budget by summing up each day's optimal power values and multiplying by 1 hour to get MWh
    daily_budget = Vector{Float64}(undef, 7)
    for i in 1:7
        daily_budget[i] = sum(optimal_power_values_MW[(i-1)*24+1:i*24]) * 1.0 # 1 hour
    end
    # Calculate hourly budget by dividing each day's daily budget by 24 hours
    hourly_budget = Vector{Float64}(undef, 7*24)
    for i in 1:7
        hourly_budget[(i-1)*24+1:i*24] .= daily_budget[i] / 24.0
    end
    return hourly_budget
end

function generate_greedy_dispatch(prices_dollars_per_MWh, max_power_values_MW, min_power_values_MW, budget_MWh)
    # Initialize the optimal power values array
    optimal_power_values_MW = copy(min_power_values_MW)

    @assert sum(optimal_power_values_MW) <= budget_MWh "Initial sum of min power values exceeds budget"

    # Sort the prices in descending order and get the corresponding indices
    sorted_indices = sortperm(prices_dollars_per_MWh, rev=true)
    
    # Allocate power greedily based on the sorted prices
    for idx in sorted_indices
        optimal_power_values_MW[idx] = max_power_values_MW[idx]
        if sum(optimal_power_values_MW)*1 > budget_MWh
            optimal_power_values_MW[idx] = min_power_values_MW[idx]
            optimal_power_values_MW[idx] = optimal_power_values_MW[idx] + (budget_MWh - sum(optimal_power_values_MW))
            # if this is less than the minimum power value, assert error
            @assert optimal_power_values_MW[idx] >= min_power_values_MW[idx] "Optimal power value is less than minimum power value"
            #println("min_power_values_MW[idx]: ", min_power_values_MW[idx])
            @assert optimal_power_values_MW[idx] >= 0 "Optimal power value is less than zero"
            break
        end
    end

    return optimal_power_values_MW
end