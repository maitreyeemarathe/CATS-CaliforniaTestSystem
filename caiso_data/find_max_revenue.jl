using CSV, DataFrames, Dates, Plots

# Week 1 = Jan 1–7, week 2 = Jan 8–14, etc.
week_num(dt) = div(Dates.dayofyear(dt) - 1, 7) + 1

# Gini coefficient of a non-negative vector; returns 0 for uniform, 1 for maximally unequal
function gini(x)
    n = length(x)
    n == 0 && return NaN
    x_sorted = sort(x)
    s = sum(x_sorted)
    s == 0 && return 0.0
    return (2 * sum(i * v for (i, v) in enumerate(x_sorted)) / (n * s)) - (n + 1) / n
end

# output_prefix is prepended to all saved files, e.g. "devilcanyon" -> "devilcanyon_weekly_revenue.csv"
function analyze_revenue(lmp_filename, budget_filename; output_prefix="output")
    strip_tz(s) = DateTime(replace(string(s), r"[+-]\d{2}:\d{2}$" => ""), dateformat"yyyy-mm-dd HH:MM:SS")

    df_lmp = CSV.read(lmp_filename, DataFrame, select=[:Time, :LMP])
    df_budget = CSV.read(budget_filename, DataFrame, select=[:datetime, :week_p_max, :week_p_min, :budget_hour])
    df_lmp.Time = strip_tz.(df_lmp.Time)
    df_budget.datetime = strip_tz.(df_budget.datetime)

    results = DataFrame(week=Int[], total_revenue=Float64[], uniform_revenue=Float64[], pct_increase=Float64[], greedy_energy_mwh=Float64[], uniform_energy_mwh=Float64[], budget_mwh=Float64[], gini_top_n=Float64[])
    dispatch = DataFrame(Time=DateTime[], greedy_power=Float64[], uniform_power=Float64[])

    for week in 1:52
        week_data = filter(row -> week_num(row.datetime) == week, df_budget)
        isempty(week_data) && continue

        week_p_max = week_data.week_p_max[1]
        week_p_min = week_data.week_p_min[1]
        budget_hour = week_data.budget_hour[1]

        df_lmp_week = filter(row -> week_num(row.Time) == week, df_lmp)
        isempty(df_lmp_week) && continue
        #week in [14, 40] && continue
        df_lmp_week[!, :assigned_power] .= week_p_min

        # Uniform-daily: split weekly budget equally across days, greedy within each day
        df_lmp_week[!, :uniform_power] .= week_p_min
        days = unique(Date.(df_lmp_week.Time))
        daily_budget = budget_hour * nrow(df_lmp_week) / length(days)
        for day in days
            idx = findall(row -> Date(df_lmp_week.Time[row]) == day, 1:nrow(df_lmp_week))
            day_remaining = daily_budget - week_p_min * length(idx)
            if day_remaining > 0
                order = sortperm(df_lmp_week.LMP[idx], rev=true)
                for i in order
                    day_remaining <= 0 && break
                    additional_power = min(week_p_max - df_lmp_week.uniform_power[idx[i]], day_remaining)
                    df_lmp_week.uniform_power[idx[i]] += additional_power
                    day_remaining -= additional_power
                end
            end
        end

        remaining_budget = budget_hour * nrow(df_lmp_week) - week_p_min * nrow(df_lmp_week)
        if remaining_budget > 0
            sort!(df_lmp_week, :LMP, rev=true)
            for i in 1:nrow(df_lmp_week)
                remaining_budget <= 0 && break
                additional_power = min(week_p_max - df_lmp_week.assigned_power[i], remaining_budget)
                df_lmp_week.assigned_power[i] += additional_power
                remaining_budget -= additional_power
            end
        end

        total_revenue = sum(df_lmp_week.LMP .* df_lmp_week.assigned_power)
        uniform_revenue = sum(df_lmp_week.LMP .* df_lmp_week.uniform_power)
        greedy_energy = sum(df_lmp_week.assigned_power)
        uniform_energy = sum(df_lmp_week.uniform_power)
        # n = hours at max dispatch; find their day distribution via top-n LMP hours
        n = count(p -> p >= week_p_max, df_lmp_week.assigned_power)
        top_n_times = sort(df_lmp_week, :LMP, rev=true).Time[1:max(n,1)]
        counts_per_day = [count(t -> Date(t) == day, top_n_times) for day in days]
        gini_val = n == 0 ? 0.0 : gini(float.(counts_per_day))
        pct_increase = (total_revenue - uniform_revenue) / abs(uniform_revenue) * 100
        println("Week $week: Greedy = $total_revenue, Uniform = $uniform_revenue, Δ = $(round(pct_increase, digits=2))%, Gini = $(round(gini_val, digits=3))")
        push!(results, (week, total_revenue, uniform_revenue, pct_increase, greedy_energy, uniform_energy, budget_hour*nrow(df_lmp_week), gini_val))
        # restore original sort order before plotting and accumulating
        sort!(df_lmp_week, :Time)
        #p = plot(df_lmp_week.Time, df_lmp_week.assigned_power, label="Greedy", linewidth=1, xlabel="Time", ylabel="Power (MW)", title="Week $week Dispatch")
        #plot!(p, df_lmp_week.Time, df_lmp_week.uniform_power, label="Uniform", linewidth=1, linestyle=:dash)
        #savefig(p, "$(output_prefix)_dispatch_week_$(lpad(week, 2, '0')).png")
        append!(dispatch, DataFrame(Time=df_lmp_week.Time, greedy_power=df_lmp_week.assigned_power, uniform_power=df_lmp_week.uniform_power))
    end

    total_revenue_year = sum(results.total_revenue)
    uniform_revenue_year = sum(results.uniform_revenue)
    println("Total revenue for the year: Greedy = $total_revenue_year, Uniform = $uniform_revenue_year")

    CSV.write("$(output_prefix)_weekly_revenue.csv", results)

    sort!(dispatch, :Time)
    p = plot(dispatch.Time, dispatch.greedy_power, label="Greedy", linewidth=1, xlabel="Time", ylabel="Power (MW)", title="Generator Dispatch")
    plot!(p, dispatch.Time, dispatch.uniform_power, label="Uniform", linewidth=1, linestyle=:dash)
    savefig(p, "$(output_prefix)_dispatch_plot.png")

    # Use sequential index as x so gaps in week numbers don't stretch the axis
    xs = 1:nrow(results)
    tick_idx = 1:4:nrow(results)  # show every 4th week to avoid label overlap
    week_ticks = (xs[tick_idx], string.(results.week[tick_idx]))
    p2 = plot(xs, results.pct_increase, label="% Increase", color=:blue, linewidth=2, legend=:bottomright,
        xlabel="Week", ylabel="Revenue Increase (%)", title="$(split(output_prefix, '_')[1]): increase in revenue and Gini coefficient by week",
        xticks=week_ticks)
    p2r = twinx(p2)
    plot!(p2r, xs, results.gini_top_n, label="Gini", color=:red, linewidth=2,
        ylabel="Gini Coefficient", linestyle=:dash, legend=:topright)
    savefig(p2, "$(output_prefix)_pct_increase_gini.png")

    return results, dispatch
end

analyze_revenue("DVLCYN3G_7_B1_2025_lmp_data.csv", "devilcanyon_rcp45hotter_hourly.csv", output_prefix="devilcanyon_2025")
analyze_revenue("MAMOTH1G_7_B1_2025_lmp_data.csv", "mammoth_rcp45hotter_hourly.csv", output_prefix="mammoth_2025")
analyze_revenue("JBBLACK2_7_B1_2025_lmp_data.csv", "shasta_rcp45hotter_hourly.csv", output_prefix="shasta_2025")
