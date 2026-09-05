using CSV, DataFrames, Plots, Dates, Statistics, StatsPlots

SCENARIO = "rcp45hotter"
BASE_DIR = normpath(joinpath(@__DIR__, "..", "..", ".."))
HYDRO_DATA_DIR = joinpath(BASE_DIR, "hydro_data", "2025_scenarios")
GEN_CSV = joinpath(BASE_DIR, "GIS", "CATS_gens.csv")

pmin_cases = ["ps0", "ps50", "ps100"]
pmin_scales = Dict("ps0" => 0.0, "ps50" => 0.5, "ps100" => 1.0)
pmin_colors = Dict("ps0" => :lightskyblue, "ps50" => :steelblue, "ps100" => :navy)

plant_keys = Dict("Shasta" => "shasta", "Mammoth" => "mammoth", "Devil Canyon" => "devilcanyon")
plant_markers = Dict("Shasta" => :circle, "Mammoth" => :square, "Devil Canyon" => :diamond)
plant_filters = Dict(
    "Shasta" => (plant_code = 445, bus = 1498, gen_ids = Set(["1", "2", "3", "4", "5"])),
    "Devil Canyon" => (plant_code = 436, bus = 1005, gen_ids = Set(["1", "2", "3", "4"])),
    "Mammoth" => (plant_code = 344, bus = 1636, gen_ids = Set(["1", "2"])),
)

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

function n_max_hours_for_week(plant_name::String, week_start_date::Date, pmin_scale::Float64)::Int
    key = plant_keys[plant_name]
    hydro_df = CSV.read(joinpath(HYDRO_DATA_DIR, "$(key)_$(SCENARIO)_hourly.csv"), DataFrame)
    hydro_df.week_start = Date.(string.(hydro_df.week_start))
    week_rows = filter(r -> r.week_start == week_start_date, hydro_df)
    isempty(week_rows) && return -1

    row = first(week_rows)
    week_p_max = Float64(row.week_p_max)
    week_p_min = pmin_scale * Float64(row.week_p_min)
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

function main()
    plant_gen_names = get_plant_gen_names(GEN_CSV)
    start_date_dirs = sort(filter(d -> isdir(joinpath(@__DIR__, d)) && occursin(r"^\d{4}-\d{2}-\d{2}$", d), readdir(@__DIR__)))

    rows = NamedTuple{(:plant, :pmin_case, :pmin_scale, :week_start, :gini_coeff, :n_max_hours, :revenue_diff_pct),
                      Tuple{String, String, Float64, Date, Float64, Int, Float64}}[]
    weekly_revenue_rows = NamedTuple{(:plant, :pmin_case, :pmin_scale, :week_start, :equal_revenue, :greedy_revenue),
                                     Tuple{String, String, Float64, Date, Float64, Float64}}[]

    for start_date_dir in start_date_dirs
        equal_root = joinpath(@__DIR__, start_date_dir)
        greedy_root = joinpath(@__DIR__, "greedy", start_date_dir)
        isdir(greedy_root) || continue

        for ps in pmin_cases
            equal_dir = joinpath(equal_root, "relaxed_pmin_$ps")
            greedy_dir = joinpath(greedy_root, "relaxed_pmin_$ps")
            (isdir(equal_dir) && isdir(greedy_dir)) || continue

            equal_weekly = weekly_revenue_by_plant(equal_dir, "shadow_prices.csv", plant_gen_names)
            greedy_weekly = weekly_revenue_by_plant(greedy_dir, "hydro_ed_prices.csv", plant_gen_names)
            joined = innerjoin(equal_weekly, greedy_weekly, on = [:plant, :week_start], makeunique = true)

            for row in eachrow(joined)
                plant = String(row.plant)
                week_start = row.week_start
                n_max = n_max_hours_for_week(plant, Date(week_start), pmin_scales[ps])
                n_max < 0 && continue
                g = week_price_gini(greedy_dir, week_start, n_max)
                equal_revenue = Float64(row.revenue)
                greedy_revenue = Float64(row.revenue_1)
                revenue_diff_pct = 100.0 * (greedy_revenue - equal_revenue) / abs(equal_revenue)
                push!(weekly_revenue_rows, (
                    plant = plant,
                    pmin_case = ps,
                    pmin_scale = pmin_scales[ps],
                    week_start = Date(week_start),
                    equal_revenue = equal_revenue,
                    greedy_revenue = greedy_revenue,
                ))
                push!(rows, (
                    plant = plant,
                    pmin_case = ps,
                    pmin_scale = pmin_scales[ps],
                    week_start = Date(week_start),
                    gini_coeff = g,
                    n_max_hours = n_max,
                    revenue_diff_pct = revenue_diff_pct,
                ))
            end
        end
    end

    results_df = DataFrame(rows)
    sort!(results_df, [:week_start, :pmin_scale, :plant])
    CSV.write(joinpath(@__DIR__, "pmin_gini_vs_revenue_diff.csv"), results_df)
    weekly_revenue_df = DataFrame(weekly_revenue_rows)
    sort!(weekly_revenue_df, [:week_start, :pmin_scale, :plant])
    CSV.write(joinpath(@__DIR__, "pmin_weekly_revenue_equal_vs_greedy.csv"), weekly_revenue_df)
    annual_revenue_df = combine(
        groupby(weekly_revenue_df, [:plant, :pmin_case, :pmin_scale]),
        :equal_revenue => sum => :total_equal_revenue,
        :greedy_revenue => sum => :total_greedy_revenue,
    )
    annual_revenue_df.revenue_increase_pct = 100.0 .* (
        annual_revenue_df.total_greedy_revenue .- annual_revenue_df.total_equal_revenue
    ) ./ abs.(annual_revenue_df.total_equal_revenue)
    annual_revenue_table = select(annual_revenue_df, :plant, :pmin_case, :pmin_scale, :revenue_increase_pct)
    annual_revenue_table.plant_order = [plant == "Shasta" ? 1 : plant == "Mammoth" ? 2 : plant == "Devil Canyon" ? 3 : 4 for plant in annual_revenue_table.plant]
    annual_revenue_table.pmin_order = [case == "ps0" ? 1 : case == "ps50" ? 2 : case == "ps100" ? 3 : 4 for case in annual_revenue_table.pmin_case]
    sort!(annual_revenue_table, [:plant_order, :pmin_order])
    annual_revenue_table[!, :plant] = replace.(annual_revenue_table.plant, "Mammoth" => "Mammoth Pool")
    annual_revenue_table[!, :pmin_case] = [case == "ps0" ? "0%" : case == "ps50" ? "50%" : case == "ps100" ? "100%" : case for case in annual_revenue_table.pmin_case]
    annual_revenue_table[!, :revenue_increase_pct] = round.(annual_revenue_table.revenue_increase_pct, digits = 2)
    select!(annual_revenue_table, :plant, :pmin_case, :revenue_increase_pct)
    rename!(annual_revenue_table, :plant => :Plant, :pmin_case => :Pmin_Scale, :revenue_increase_pct => Symbol("Increase in annual revenue (%)"))
    CSV.write(joinpath(@__DIR__, "annual_revenue_increase_by_plant_and_pmin_scale.csv"), annual_revenue_table)
    println("results_df has $(nrow(results_df)) rows")
    println("weekly_revenue_df has $(nrow(weekly_revenue_df)) rows")
    println("Saved -> annual_revenue_increase_by_plant_and_pmin_scale.csv")

    closeall()
    gr()

    p = plot(;
        xlabel = "Gini Coefficient of Top-n Price-Hour Distribution",
        ylabel = "Revenue Increase: Greedy vs Equal (%)",
        legend = :bottomright,
        size = (950, 600),
        dpi = 150,
        left_margin = 10Plots.mm,
        right_margin = 20Plots.mm,
    )

    for ps in pmin_cases
        for plant in keys(plant_markers)
            sub = filter(r -> r.pmin_case == ps && r.plant == plant, results_df)
            isempty(sub) && continue
            scatter!(p, sub.gini_coeff, sub.revenue_diff_pct;
                label = "$(plant), $(ps)",
                marker = plant_markers[plant],
                markersize = 7,
                color = pmin_colors[ps],
                markerstrokewidth = 1,
            )
        end
    end

    hline!(p, [0.0]; color = :black, lw = 1, ls = :dot, label = "")

    savefig(p, joinpath(@__DIR__, "scatter_pmin_gini_vs_revenue_diff.png"))
    println("Saved -> scatter_pmin_gini_vs_revenue_diff.png")

    week_numbers = week.(results_df.week_start)
    p_week = plot(;
        xlabel = "Week Number",
        ylabel = "Revenue Increase: Greedy vs Equal (%)",
        title = "Weekly Greedy vs Equal Revenue Increase by Pmin Scale",
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
            marker_z = results_df.pmin_scale[plant_idx],
            #markercolor = cgrad([:lightskyblue, :navy, :steelblue]),
            markercolor = palette(:lapaz, rev=true), 
            clims = (0.0, 1.0),
            colorbar_title = "Pmin Scale",
            markerstrokewidth = 1,
        )
    end

    hline!(p_week, [0.0]; color = :black, lw = 1, ls = :dot, label = "")
    savefig(p_week, joinpath(@__DIR__, "weekly_revenue_increase_by_pmin_scale.png"))
    println("Saved -> weekly_revenue_increase_by_pmin_scale.png")

    nmax_gini = results_df.n_max_hours .* (1 .+ results_df.gini_coeff)
    #nmax_gini = abs.(results_df.n_max_hours .- 168 / 2) .+ results_df.n_max_hours .* results_df.gini_coeff
    p_nmax_gini = plot(;
        xlabel = "(Nmax Hours x (1 + Gini Coefficient))",
        #xlabel = "(|Nmax Hours - 168/2| + Nmax Hours x Gini Coefficient)",
        ylabel = "Revenue Increase: Greedy vs Equal (%)",
        title = "Greedy vs Equal Revenue Increase by Nmax and Price Gini",
        legend = :topleft,
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
            marker_z = results_df.pmin_scale[plant_idx],
            #markercolor = cgrad([:lightskyblue, :navy, :steelblue,]),
            markercolor = palette(:lapaz, rev=true), 
            clims = (0.0, 1.0),
            colorbar_title = "Pmin Scale",
            markerstrokewidth = 1,
        )
    end

    hline!(p_nmax_gini, [0.0]; color = :black, lw = 1, ls = :dot, label = "")
    savefig(p_nmax_gini, joinpath(@__DIR__, "revenue_increase_by_nmax_gini.png"))
    println("Saved -> revenue_increase_by_nmax_gini.png")

    for plant in keys(plant_markers)
        plant_idx = findall(results_df.plant .== plant)
        isempty(plant_idx) && continue
        plant_slug = replace(lowercase(plant), " " => "_")
        p_plant_nmax_gini = plot(;
            xlabel = "Nmax Hours x (1 + Gini Coefficient)",
            ylabel = "Revenue Increase: Greedy vs Equal (%)",
            title = "$(plant): Greedy vs Equal Revenue Increase by Nmax and Price Gini",
            legend = false,
            size = (950, 600),
            dpi = 150,
            left_margin = 10Plots.mm,
            right_margin = 35Plots.mm,
        )

        scatter!(p_plant_nmax_gini, nmax_gini[plant_idx], results_df.revenue_diff_pct[plant_idx];
            marker = plant_markers[plant],
            markersize = 7,
            marker_z = results_df.pmin_scale[plant_idx],
            markercolor = palette(:lapaz, rev=true), 
            clims = (0.0, 1.0),
            colorbar = true,
            colorbar_title = "Pmin Scale",
            markerstrokewidth = 1,
        )

        hline!(p_plant_nmax_gini, [0.0]; color = :black, lw = 1, ls = :dot, label = "")
        out_file = "revenue_increase_by_nmax_gini_$(plant_slug).png"
        savefig(p_plant_nmax_gini, joinpath(@__DIR__, out_file))
        println("Saved -> $(out_file)")
    end

    for ps in pmin_cases
        p_case = plot(;
            xlabel = "Gini Coefficient of Top-n Price-Hour Distribution",
            ylabel = "Revenue Increase: Greedy vs Equal (%)",
            title = "$(ps): Greedy vs Equal Revenue Increase",
            legend = :bottomright,
            size = (950, 600),
            dpi = 150,
            left_margin = 10Plots.mm,
            right_margin = 20Plots.mm,
        )

        for plant in keys(plant_markers)
            sub = filter(r -> r.pmin_case == ps && r.plant == plant, results_df)
            isempty(sub) && continue
            scatter!(p_case, sub.gini_coeff, sub.revenue_diff_pct;
                label = plant,
                marker = plant_markers[plant],
                markersize = 7,
                color = pmin_colors[ps],
                markerstrokewidth = 1,
            )
        end

        hline!(p_case, [0.0]; color = :black, lw = 1, ls = :dot, label = "")
        out_file = "scatter_gini_vs_revenue_diff_$(ps).png"
        savefig(p_case, joinpath(@__DIR__, out_file))
        println("Saved -> $(out_file)")
    end

    p_violin = plot(;
        xlabel = "Pmin Scale",
        ylabel = "Revenue Increase: Greedy vs Equal (%)",
        title = "Distribution of Greedy Allocation Revenue Increase",
        xticks = (1:length(pmin_cases),  ["0%", "50%", "100%"]),
        legend = :topright,
        size = (950, 600),
        dpi = 150,
        left_margin = 10Plots.mm,
        right_margin = 20Plots.mm,
    )
    summary_rows = NamedTuple{(:pmin_case, :pmin_scale, :min_revenue_increase_pct, :p25_revenue_increase_pct, :median_revenue_increase_pct, :p75_revenue_increase_pct, :max_revenue_increase_pct),
                              Tuple{String, Float64, Float64, Float64, Float64, Float64, Float64}}[]

    for (position, ps) in enumerate(pmin_cases)
        values = results_df.revenue_diff_pct[results_df.pmin_case .== ps]
        values = filter(isfinite, values)
        isempty(values) && continue
        violin!(p_violin, fill(position, length(values)), values;
            label = false,
            color = pmin_colors[ps],
            alpha = 0.6,
        )

        min_value, q25, median_value, q75, max_value = quantile(values, [0.0, 0.25, 0.5, 0.75, 1.0])
        println("Median revenue increase for $(ps): $(round(median_value, digits = 3))%")
        push!(summary_rows, (
            pmin_case = ps,
            pmin_scale = pmin_scales[ps],
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
    savefig(p_violin, joinpath(@__DIR__, "violin_revenue_increase_by_pmin_scale.png"))
    println("Saved -> violin_revenue_increase_by_pmin_scale.png")
    CSV.write(joinpath(@__DIR__, "revenue_increase_summary_by_pmin_scale.csv"), DataFrame(summary_rows))
    println("Saved -> revenue_increase_summary_by_pmin_scale.csv")
end

main()