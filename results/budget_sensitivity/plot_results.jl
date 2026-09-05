using CSV, DataFrames, Plots, Dates, Statistics, StatsPlots

SCENARIO = "hist"
BASE_DIR = normpath(joinpath(@__DIR__, "..", ".."))
HYDRO_DATA_DIR = joinpath(BASE_DIR, "hydro_data", "historical")
GEN_CSV = joinpath(BASE_DIR, "GIS", "CATS_gens.csv")

plant_keys = Dict("Shasta" => "shasta", "Mammoth" => "mammoth", "Devil Canyon" => "devilcanyon")
plant_markers = Dict("Shasta" => :circle, "Mammoth" => :square, "Devil Canyon" => :diamond)
plant_filters = Dict(
    "Shasta" => (plant_code = 445, bus = 1498, gen_ids = Set(["1", "2", "3", "4", "5"])),
    "Devil Canyon" => (plant_code = 436, bus = 1005, gen_ids = Set(["1", "2", "3", "4"])),
    "Mammoth" => (plant_code = 344, bus = 1636, gen_ids = Set(["1", "2"])),
)

# Set false (or comment out the analysis block in main) to skip the estimated-allocation analysis.
RUN_ESTIMATED_ALLOCATION_ANALYSIS = true

function parse_datetime(x)::DateTime
    x isa DateTime && return x
    s = replace(string(x), "T" => " ")
    s = replace(s, r"\.\d+" => "")
    s = replace(s, r"[+-]\d{2}:\d{2}$" => "")
    return DateTime(s[1:19], dateformat"yyyy-mm-dd HH:MM:SS")
end

function normalize_datetime!(df::DataFrame, col::Symbol)
    df[!, col] = parse_datetime.(df[!, col])
    return df
end

function get_plant_gen_names(gen_csv_path::String)
    gens = CSV.read(gen_csv_path, DataFrame)
    plant_gen_names = Dict{String, Set{String}}()
    for (plant, filter) in plant_filters
        gen_names = Set{String}()
        for (i, row) in enumerate(eachrow(gens))
            if row.PlantCode == filter.plant_code && row.bus == filter.bus && string(row.GenID) in filter.gen_ids
                push!(gen_names, "gen-$i")
            end
        end
        plant_gen_names[plant] = gen_names
    end
    return plant_gen_names
end

function week_start_dates(datetimes::AbstractVector{DateTime})
    run_start = minimum(datetimes)
    week_ms = 7 * 24 * 60 * 60 * 1000
    return [run_start + Millisecond(fld(Dates.value(dt - run_start), week_ms) * week_ms) for dt in datetimes]
end

function weekly_revenue_by_plant(run_dir::String, price_filename::String, plant_gen_names::Dict{String, Set{String}})
    dispatch = CSV.read(joinpath(run_dir, "selected_hydro_dispatch_wide.csv"), DataFrame)
    prices = CSV.read(joinpath(run_dir, price_filename), DataFrame)
    normalize_datetime!(dispatch, :DateTime)
    normalize_datetime!(prices, :DateTime)

    price_by_time = Dict(row.DateTime => Float64(row.value) for row in eachrow(prices))
    price_values = [price_by_time[dt] for dt in dispatch.DateTime]
    week_starts = week_start_dates(dispatch.DateTime)

    rows = NamedTuple{(:plant, :week_start, :revenue), Tuple{String, DateTime, Float64}}[]
    for (plant, gen_names) in plant_gen_names
        gen_cols = intersect(names(dispatch), collect(gen_names))
        isempty(gen_cols) && continue

        plant_dispatch = zeros(Float64, nrow(dispatch))
        for gen_col in gen_cols
            plant_dispatch .+= Float64.(dispatch[!, gen_col])
        end

        revenue_df = DataFrame(week_start = week_starts, revenue = plant_dispatch .* price_values)
        weekly = combine(groupby(revenue_df, :week_start), :revenue => sum => :revenue)
        for row in eachrow(weekly)
            push!(rows, (plant = plant, week_start = row.week_start, revenue = Float64(row.revenue)))
        end
    end
    return DataFrame(rows)
end

function gini(x::AbstractVector{<:Real})::Float64
    n = length(x)
    (n == 0 || sum(x) ≈ 0) && return NaN
    xs = sort(Float64.(x))
    return (2.0 * sum(i * xs[i] for i in 1:n)) / (n * sum(xs)) - (n + 1) / n
end

function n_max_hours_for_week(plant_name::String, week_start_date::Date, budget_year::Int)::Int
    key = plant_keys[plant_name]
    hydro_df = CSV.read(joinpath(HYDRO_DATA_DIR, "$(key)_$(SCENARIO)_$(budget_year)_hourly.csv"), DataFrame)
    hydro_df.week_start = Date.(string.(hydro_df.week_start))
    week_rows = filter(r -> r.week_start == week_start_date, hydro_df)
    isempty(week_rows) && return -1

    row = first(week_rows)
    week_p_max = Float64(row.week_p_max)
    week_p_min = Float64(row.week_p_min)
    total_budget = 168.0 * Float64(row.budget_hour)
    available_budget = total_budget - 168.0 * week_p_min
    max_increment = week_p_max - week_p_min
    max_increment <= 0 && return 0
    return clamp(floor(Int, available_budget / max_increment), 0, 168)
end

function week_price_gini(run_dir::String, week_start::DateTime, n::Int)::Float64
    n <= 0 && return NaN
    prices = CSV.read(joinpath(run_dir, "hydro_ed_prices.csv"), DataFrame)
    normalize_datetime!(prices, :DateTime)
    week_end = week_start + Day(7)
    week_prices = filter(r -> week_start <= r.DateTime < week_end, prices)
    isempty(week_prices) && return NaN

    sort!(week_prices, :value, rev = true)
    top_n = first(week_prices, min(n, nrow(week_prices)))
    counts = zeros(Int, 7)
    day_ms = 24 * 60 * 60 * 1000
    for row in eachrow(top_n)
        day_in_week = fld(Dates.value(row.DateTime - week_start), day_ms) + 1
        if 1 <= day_in_week <= 7
            counts[day_in_week] += 1
        end
    end
    return gini(counts)
end

# ── Optional estimated-allocation analysis ────────────────────────────────────

function greedy_dispatch(prices::Vector{Float64}, p_max::Vector{Float64}, p_min::Vector{Float64}, budget_mwh::Float64)
    dispatch = copy(p_min)
    remaining_budget = budget_mwh - sum(dispatch)
    remaining_budget < -1e-6 && error("Weekly budget is below the Pmin energy requirement")

    for i in sortperm(prices, rev = true)
        remaining_budget <= 1e-6 && break
        increment = min(p_max[i] - dispatch[i], remaining_budget)
        dispatch[i] += increment
        remaining_budget -= increment
    end
    remaining_budget > 1e-6 && error("Weekly budget exceeds the Pmax energy limit")
    return dispatch
end

function estimate_allocation_revenues(plant_name::String, week_start::DateTime, budget_year::Int, equal_dir::String)
    key = plant_keys[plant_name]
    hydro_df = CSV.read(joinpath(HYDRO_DATA_DIR, "$(key)_$(SCENARIO)_$(budget_year)_hourly.csv"), DataFrame)
    normalize_datetime!(hydro_df, :datetime)
    week_end = week_start + Day(7)
    week_hydro = filter(r -> week_start <= r.datetime < week_end, hydro_df)
    nrow(week_hydro) == 168 || error("Expected 168 hydro rows for $plant_name starting $week_start")
    sort!(week_hydro, :datetime)

    prices = CSV.read(joinpath(equal_dir, "shadow_prices.csv"), DataFrame)
    normalize_datetime!(prices, :DateTime)
    price_by_time = Dict(row.DateTime => Float64(row.value) for row in eachrow(prices))
    price_values = [price_by_time[dt] for dt in week_hydro.datetime]
    p_max = Float64.(week_hydro.week_p_max)
    p_min = Float64.(week_hydro.week_p_min)
    weekly_budget = sum(Float64.(week_hydro.budget_hour))

    greedy_power = greedy_dispatch(price_values, p_max, p_min, weekly_budget)
    equal_power = zeros(Float64, length(price_values))
    daily_budget = weekly_budget / 7.0
    for day in 1:7
        day_idx = (day - 1) * 24 + 1:day * 24
        equal_power[day_idx] = greedy_dispatch(price_values[day_idx], p_max[day_idx], p_min[day_idx], daily_budget)
    end

    equal_revenue = sum(price_values .* equal_power)
    greedy_revenue = sum(price_values .* greedy_power)
    return equal_revenue, greedy_revenue
end

function discover_budget_cases(start_date_dir::String)
    equal_tags = Set(String[replace(d, "equal_" => "") for d in readdir(joinpath(@__DIR__, start_date_dir)) if startswith(d, "equal_bud")])
    greedy_tags = Set(String[replace(d, "greedy_" => "") for d in readdir(joinpath(@__DIR__, start_date_dir)) if startswith(d, "greedy_bud")])
    tags = sort(collect(intersect(equal_tags, greedy_tags)); by = tag -> parse(Int, replace(tag, "bud" => "")))
    return [(tag = tag, budget_year = parse(Int, replace(tag, "bud" => ""))) for tag in tags]
end

function main()
    plant_gen_names = get_plant_gen_names(GEN_CSV)
    start_date_dirs = sort(filter(d -> isdir(joinpath(@__DIR__, d)) && occursin(r"^\d{4}-\d{2}-\d{2}$", d), readdir(@__DIR__)))

    rows = NamedTuple{(:plant, :budget_case, :budget_year, :week_start, :gini_coeff, :n_max_hours, :revenue_diff_pct),
                      Tuple{String, String, Int, Date, Float64, Int, Float64}}[]
    weekly_revenue_rows = NamedTuple{(:plant, :budget_case, :budget_year, :week_start, :equal_revenue, :greedy_revenue),
                                     Tuple{String, String, Int, Date, Float64, Float64}}[]
    estimated_revenue_rows = NamedTuple{(:plant, :budget_case, :budget_year, :week_start, :actual_revenue_increase_pct, :estimated_equal_revenue, :estimated_greedy_revenue, :estimated_revenue_increase_pct),
                                        Tuple{String, String, Int, Date, Float64, Float64, Float64, Float64}}[]

    for start_date_dir in start_date_dirs
        for case in discover_budget_cases(start_date_dir)
            equal_dir = joinpath(@__DIR__, start_date_dir, "equal_$(case.tag)")
            greedy_dir = joinpath(@__DIR__, start_date_dir, "greedy_$(case.tag)")
            (isdir(equal_dir) && isdir(greedy_dir)) || continue

            equal_weekly = weekly_revenue_by_plant(equal_dir, "shadow_prices.csv", plant_gen_names)
            greedy_weekly = weekly_revenue_by_plant(greedy_dir, "hydro_ed_prices.csv", plant_gen_names)
            joined = innerjoin(equal_weekly, greedy_weekly, on = [:plant, :week_start], makeunique = true)

            for row in eachrow(joined)
                plant = String(row.plant)
                week_start = row.week_start
                n_max = n_max_hours_for_week(plant, Date(week_start), case.budget_year)
                n_max < 0 && continue
                g = week_price_gini(greedy_dir, week_start, n_max)
                equal_revenue = Float64(row.revenue)
                greedy_revenue = Float64(row.revenue_1)
                revenue_diff_pct = 100.0 * (greedy_revenue - equal_revenue) / abs(equal_revenue)

                if RUN_ESTIMATED_ALLOCATION_ANALYSIS
                    estimated_equal_revenue, estimated_greedy_revenue = estimate_allocation_revenues(
                        plant,
                        week_start,
                        case.budget_year,
                        equal_dir,
                    )
                    estimated_revenue_increase_pct = 100.0 * (estimated_greedy_revenue - estimated_equal_revenue) / abs(estimated_equal_revenue)
                    push!(estimated_revenue_rows, (
                        plant = plant,
                        budget_case = case.tag,
                        budget_year = case.budget_year,
                        week_start = Date(week_start),
                        actual_revenue_increase_pct = revenue_diff_pct,
                        estimated_equal_revenue = estimated_equal_revenue,
                        estimated_greedy_revenue = estimated_greedy_revenue,
                        estimated_revenue_increase_pct = estimated_revenue_increase_pct,
                    ))
                end

                push!(weekly_revenue_rows, (
                    plant = plant,
                    budget_case = case.tag,
                    budget_year = case.budget_year,
                    week_start = Date(week_start),
                    equal_revenue = equal_revenue,
                    greedy_revenue = greedy_revenue,
                ))
                push!(rows, (
                    plant = plant,
                    budget_case = case.tag,
                    budget_year = case.budget_year,
                    week_start = Date(week_start),
                    gini_coeff = g,
                    n_max_hours = n_max,
                    revenue_diff_pct = revenue_diff_pct,
                ))
            end
        end
    end

    results_df = DataFrame(rows)
    sort!(results_df, [:week_start, :budget_year, :plant])
    CSV.write(joinpath(@__DIR__, "budget_gini_vs_revenue_diff.csv"), results_df)
    weekly_revenue_df = DataFrame(weekly_revenue_rows)
    sort!(weekly_revenue_df, [:week_start, :budget_year, :plant])
    CSV.write(joinpath(@__DIR__, "budget_weekly_revenue_equal_vs_greedy.csv"), weekly_revenue_df)
    annual_revenue_df = combine(
        groupby(weekly_revenue_df, [:plant, :budget_year]),
        :equal_revenue => sum => :total_equal_revenue,
        :greedy_revenue => sum => :total_greedy_revenue,
    )
    annual_revenue_df.budget_level = [
        year == 2015 ? "Low" : year == 2012 ? "Medium" : year == 2006 ? "High" : "Unknown"
        for year in annual_revenue_df.budget_year
    ]
    annual_revenue_df.revenue_increase_pct = 100.0 .* (
        annual_revenue_df.total_greedy_revenue .- annual_revenue_df.total_equal_revenue
    ) ./ abs.(annual_revenue_df.total_equal_revenue)
    select!(annual_revenue_df, :plant, :budget_level, :budget_year, :total_equal_revenue, :total_greedy_revenue, :revenue_increase_pct)
    sort!(annual_revenue_df, [:budget_year, :plant])
    CSV.write(joinpath(@__DIR__, "annual_revenue_increase_by_plant_and_budget_level.csv"), annual_revenue_df)
    annual_revenue_table = select(annual_revenue_df, :plant, :budget_level, :revenue_increase_pct)
    annual_revenue_table.plant_order = [plant == "Shasta" ? 1 : plant == "Mammoth" ? 2 : plant == "Devil Canyon" ? 3 : 4 for plant in annual_revenue_table.plant]
    annual_revenue_table.budget_order = [budget == "Low" ? 1 : budget == "Medium" ? 2 : budget == "High" ? 3 : 4 for budget in annual_revenue_table.budget_level]
    sort!(annual_revenue_table, [:plant_order, :budget_order])
    annual_revenue_table[!, :plant] = replace.(annual_revenue_table.plant, "Mammoth" => "Mammoth Pool")
    annual_revenue_table[!, :revenue_increase_pct] = round.(annual_revenue_table.revenue_increase_pct, digits = 2)
    select!(annual_revenue_table, :plant, :budget_level, :revenue_increase_pct)
    rename!(annual_revenue_table, :plant => :Plant, :budget_level => :Budget, :revenue_increase_pct => Symbol("Increase in annual revenue (%)"))
    CSV.write(joinpath(@__DIR__, "annual_revenue_increase_table.csv"), annual_revenue_table)
    println("results_df has $(nrow(results_df)) rows")
    println("weekly_revenue_df has $(nrow(weekly_revenue_df)) rows")
    println("annual_revenue_df has $(nrow(annual_revenue_df)) rows")
    println("Saved -> annual_revenue_increase_table.csv")

    if RUN_ESTIMATED_ALLOCATION_ANALYSIS
        estimated_revenue_df = DataFrame(estimated_revenue_rows)
        sort!(estimated_revenue_df, [:week_start, :budget_year, :plant])
        CSV.write(joinpath(@__DIR__, "budget_estimated_vs_actual_revenue_increase.csv"), estimated_revenue_df)
        println("estimated_revenue_df has $(nrow(estimated_revenue_df)) rows")
    end

    closeall()
    gr()

    p = plot(;
        xlabel = "Gini Coefficient of Top-n Price-Hour Distribution",
        ylabel = "Revenue Increase: Greedy vs Equal (%)",
        legend = :bottomright,
        size = (950, 600),
        dpi = 150,
        left_margin = 10Plots.mm,
        right_margin = 35Plots.mm,
    )

    for plant in keys(plant_markers)
        plant_idx = findall(results_df.plant .== plant)
        isempty(plant_idx) && continue
        scatter!(p, results_df.gini_coeff[plant_idx], results_df.revenue_diff_pct[plant_idx];
            label = plant,
            marker = plant_markers[plant],
            markersize = 7,
            marker_z = results_df.budget_year[plant_idx],
            markercolor = cgrad(:viridis),
            markerstrokewidth = 1,
            colorbar_title = "Budget\nYear",
        )
    end

    hline!(p, [0.0]; color = :black, lw = 1, ls = :dot, label = "")
    savefig(p, joinpath(@__DIR__, "scatter_budget_gini_vs_revenue_diff.png"))
    println("Saved -> scatter_budget_gini_vs_revenue_diff.png")

    if RUN_ESTIMATED_ALLOCATION_ANALYSIS
        p_estimate = plot(;
            xlabel = "Estimated Revenue Increase: Greedy vs Equal (%)",
            ylabel = "Actual Revenue Increase: Greedy vs Equal (%)",
            title = "Actual vs Estimated Greedy Allocation Benefit",
            legend = :bottomright,
            size = (950, 600),
            dpi = 150,
            left_margin = 10Plots.mm,
            right_margin = 35Plots.mm,
        )
        for plant in keys(plant_markers)
            sub = filter(r -> r.plant == plant, estimated_revenue_df)
            isempty(sub) && continue
            scatter!(p_estimate, sub.estimated_revenue_increase_pct, sub.actual_revenue_increase_pct;
                label = plant,
                marker = plant_markers[plant],
                markersize = 7,
                marker_z = sub.budget_year,
                markercolor = cgrad(:viridis),
                markerstrokewidth = 1,
                colorbar_title = "Budget\nYear",
            )
        end
        plot!(p_estimate, [-0.5, 2.5], [-0.5, 2.5]; color = :black, lw = 1, ls = :dash, label = "Actual = Estimated")
        savefig(p_estimate, joinpath(@__DIR__, "actual_vs_estimated_revenue_increase.png"))
        println("Saved -> actual_vs_estimated_revenue_increase.png")
    end

    #nmax_gini = results_df.n_max_hours .* (1 .+ results_df.gini_coeff)
    nmax_gini = (1 .- abs.(results_df.n_max_hours .- 168/2)./ (168/2)) + results_df.gini_coeff
    p_nmax_gini = plot(;
        #xlabel = "Nmax Hours x (1 + Gini Coefficient)",
        xlabel = "|Nmax Hours - 84| / 84 + Gini Coefficient",
        ylabel = "Revenue Increase: Greedy vs Equal (%)",
        legend = :bottomright,
        size = (950, 600),
        dpi = 150,
        left_margin = 10Plots.mm,
        right_margin = 35Plots.mm,
    )

    for plant in keys(plant_markers)
        plant_idx = findall(results_df.plant .== plant)
        isempty(plant_idx) && continue
        scatter!(p_nmax_gini, nmax_gini[plant_idx], results_df.revenue_diff_pct[plant_idx];
            label = plant,
            marker = plant_markers[plant],
            markersize = 7,
            marker_z = results_df.budget_year[plant_idx],
            markercolor = cgrad(:viridis),
            markerstrokewidth = 1,
            colorbar_title = "Budget\nYear",
        )
    end

    hline!(p_nmax_gini, [0.0]; color = :black, lw = 1, ls = :dot, label = "")
    savefig(p_nmax_gini, joinpath(@__DIR__, "scatter_budget_nmax_gini_vs_revenue_diff.png"))
    println("Saved -> scatter_budget_nmax_gini_vs_revenue_diff.png")

    week_numbers = week.(results_df.week_start)
    p_week = plot(;
        xlabel = "Week Number",
        ylabel = "Revenue Increase: Greedy vs Equal (%)",
        legend = :bottomright,
        size = (950, 600),
        dpi = 150,
        left_margin = 10Plots.mm,
        right_margin = 35Plots.mm,
    )

    for plant in keys(plant_markers)
        plant_idx = findall(results_df.plant .== plant)
        isempty(plant_idx) && continue
        scatter!(p_week, week_numbers[plant_idx], results_df.revenue_diff_pct[plant_idx];
            label = plant,
            marker = plant_markers[plant],
            markersize = 7,
            marker_z = results_df.budget_year[plant_idx],
            markercolor = cgrad(:viridis),
            markerstrokewidth = 1,
            colorbar_title = "Budget\nYear",
        )
    end

    hline!(p_week, [0.0]; color = :black, lw = 1, ls = :dot, label = "")
    savefig(p_week, joinpath(@__DIR__, "weekly_revenue_increase_by_budget_year.png"))
    println("Saved -> weekly_revenue_increase_by_budget_year.png")

    budget_levels = [("Low", 2015), ("Medium", 2012), ("High", 2006)]
    p_violin = plot(;
        xlabel = "Hydro Energy Budget",
        ylabel = "Revenue Increase: Greedy vs Equal (%)",
        title = "Distribution of Greedy Allocation Revenue Increase",
        xticks = (1:3, first.(budget_levels)),
        legend = :topright,
        size = (950, 600),
        dpi = 150,
        left_margin = 10Plots.mm,
        right_margin = 20Plots.mm,
    )
    budget_colors = Dict(
        "Low" => :lightskyblue,
        "Medium" => :steelblue,
        "High" => :navy,
    )
    summary_rows = NamedTuple{(:budget_level, :budget_year, :min_revenue_increase_pct, :p25_revenue_increase_pct, :median_revenue_increase_pct, :p75_revenue_increase_pct, :max_revenue_increase_pct),
                              Tuple{String, Int, Float64, Float64, Float64, Float64, Float64}}[]
    for (position, (label, budget_year)) in enumerate(budget_levels)
        values = results_df.revenue_diff_pct[results_df.budget_year .== budget_year]
        values = filter(isfinite, values)
        isempty(values) && continue
        violin!(p_violin, fill(position, length(values)), values;
            label = false,
            color = budget_colors[label],
            alpha = 0.6,
        )

        min_value, q25, median_value, q75, max_value = quantile(values, [0.0, 0.25, 0.5, 0.75, 1.0])
        println("Median revenue increase for $(lowercase(label)) budget ($(budget_year)): $(round(median_value, digits = 3))%")
        push!(summary_rows, (
            budget_level = label,
            budget_year = budget_year,
            min_revenue_increase_pct = min_value,
            p25_revenue_increase_pct = q25,
            median_revenue_increase_pct = median_value,
            p75_revenue_increase_pct = q75,
            max_revenue_increase_pct = max_value,
        ))
        x_span = [position - 0.18, position + 0.18]
        plot!(p_violin, x_span, fill(median_value, 2); label = position == 1 ? "Median" : false, color = :black, lw = 2)
        plot!(p_violin, x_span, fill(q25, 2); label = position == 1 ? "25th / 75th percentile" : false, color = :black, lw = 1.5, ls = :dash)
        plot!(p_violin, x_span, fill(q75, 2); label = false, color = :black, lw = 1.5, ls = :dash)
    end

    hline!(p_violin, [0.0]; color = :black, lw = 1, ls = :dot, label = false)
    savefig(p_violin, joinpath(@__DIR__, "violin_revenue_increase_by_budget_level.png"))
    println("Saved -> violin_revenue_increase_by_budget_level.png")
    CSV.write(joinpath(@__DIR__, "revenue_increase_summary_by_budget_level.csv"), DataFrame(summary_rows))
    println("Saved -> revenue_increase_summary_by_budget_level.csv")
end

main()


