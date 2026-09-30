using CSV, DataFrames, Plots, Dates, Statistics, StatsPlots

SCENARIO = "rcp45hotter"
BASE_DIR = normpath(joinpath(@__DIR__,"..", "..", ".."))
HYDRO_DATA_DIR = joinpath(BASE_DIR, "hydro_data", "2025_scenarios")
GEN_CSV = joinpath(BASE_DIR, "GIS", "CATS_gens.csv")

plant_keys = Dict("Shasta" => "shasta", "Mammoth" => "mammoth", "Devil Canyon" => "devilcanyon")
plant_markers = Dict("Shasta" => :circle, "Mammoth" => :square, "Devil Canyon" => :diamond)
plant_filters = Dict(
    "Shasta" => (plant_code = 445, bus = 1498, gen_ids = Set(["1", "2", "3", "4", "5"])),
    "Devil Canyon" => (plant_code = 436, bus = 1005, gen_ids = Set(["1", "2", "3", "4"])),
    "Mammoth" => (plant_code = 344, bus = 1636, gen_ids = Set(["1", "2"])),
)

GUIDEFONTSIZE = 16
TITLEFONTSIZE = 16
TICKFONTSIZE = 12
LEGENDFONTSIZE = 14

# Fix datetime format if necessary
function parse_datetime(x)::DateTime
    x isa DateTime && return x
    s = replace(string(x), "T" => " ")
    s = replace(s, r"\.\d+" => "")
    s = replace(s, r"[+-]\d{2}:\d{2}$" => "")
    return DateTime(s[1:19], dateformat"yyyy-mm-dd HH:MM:SS")
end

# Apply parse_datetime to the column col
function normalize_datetime!(df::DataFrame, col::Symbol)
    df[!, col] = parse_datetime.(df[!, col])
    return df
end

# Create a dictionary mapping plant names to their corresponding generator names
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

# Find the start date of the week for each datetime in the input vector
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
    return DataFrame(rows), prices
end


function discover_fraction_cases(start_date_dir::String)
    # equal_tags will be a Set containing ps0,ps10, ... corresponding to equal_ps0, equal_ps10, ... respectively
    equal_tags = Set(String[replace(d, "equal_" => "") for d in readdir(joinpath(@__DIR__, start_date_dir)) if startswith(d, "equal_ps")])
    # greedy_tags will be a Set containing ps0,ps10, ... corresponding to greedy_ps0, greedy_ps10, ... respectively
    greedy_tags = Set(String[replace(d, "greedy_" => "") for d in readdir(joinpath(@__DIR__, start_date_dir)) if startswith(d, "greedy_ps")])
    # tags will be a sorted array of the common fraction reduction tags between equal and greedy cases
    tags = sort(collect(intersect(equal_tags, greedy_tags)); by = tag -> parse(Int, replace(tag, "ps" => "")))
    # Return a vector of named tuples which contain [(tag = "ps0", pmin = 0.0), (tag = "ps10", pmin = 0.1), ...]
    return [(tag = tag, pmin_fraction = parse(Int, replace(tag, "ps" => "")) / 100.0) for tag in tags]
end

function main()
    plant_gen_names = get_plant_gen_names(GEN_CSV)
    # Finds the folders that have names like YYYY-MM-DD
    start_date_dirs = sort(filter(d -> isdir(joinpath(@__DIR__, d)) && occursin(r"^\d{4}-\d{2}-\d{2}$", d), readdir(@__DIR__)))

    weekly_revenue_rows = NamedTuple{(:plant, :ps_case, :pmin_fraction, :week_start, :equal_revenue, :greedy_revenue, :revenue_diff_pct),
                                     Tuple{String, String, Float64, Date, Float64, Float64, Float64}}[]

    price_rows = DataFrame(DateTime = DateTime[], series = String[], price = Float64[])

    for start_date_dir in start_date_dirs
        for case in discover_fraction_cases(start_date_dir) # here case is a named tuple with fields :tag and :pmin
            equal_dir = joinpath(@__DIR__, start_date_dir, "equal_$(case.tag)")
            greedy_dir = joinpath(@__DIR__, start_date_dir, "greedy_$(case.tag)")
            (isdir(equal_dir) && isdir(greedy_dir)) || continue # if either the equal or greedy directory does not exist, skip this case

            equal_weekly, equal_prices = weekly_revenue_by_plant(equal_dir, "shadow_prices.csv", plant_gen_names)
            greedy_weekly, greedy_prices = weekly_revenue_by_plant(greedy_dir, "hydro_ed_prices.csv", plant_gen_names)
            
            append!(price_rows, DataFrame(
                DateTime = equal_prices.DateTime,
                series = fill("equal_$(case.tag)", nrow(equal_prices)),
                price = Float64.(equal_prices.value),
            ))
            append!(price_rows, DataFrame(
                DateTime = greedy_prices.DateTime,
                series = fill("greedy_$(case.tag)", nrow(greedy_prices)),
                price = Float64.(greedy_prices.value),
            ))

            joined = innerjoin(equal_weekly, greedy_weekly, on = [:plant, :week_start], makeunique = true)
            for row in eachrow(joined)
                plant = String(row.plant)
                week_start = row.week_start
                equal_revenue = Float64(row.revenue)
                greedy_revenue = Float64(row.revenue_1)
                revenue_diff_pct = 100.0 * (greedy_revenue - equal_revenue) / abs(equal_revenue)

                push!(weekly_revenue_rows, (
                    plant = plant,
                    ps_case = case.tag,
                    pmin_fraction = case.pmin_fraction,
                    week_start = Date(week_start),
                    equal_revenue = equal_revenue,
                    greedy_revenue = greedy_revenue,
                    revenue_diff_pct = revenue_diff_pct,
                ))
            end
        end
    end

    # Converts price_rows from long format to wide format.
    # :DateTime is the row key, :series is the column key, :price are the values
    equal_greedy_prices_df = unstack(price_rows, :DateTime, :series, :price)
    sort!(equal_greedy_prices_df, :DateTime)
    CSV.write(joinpath(@__DIR__, "equal_vs_greedy_prices.csv"), equal_greedy_prices_df)

    weekly_revenue_df = DataFrame(weekly_revenue_rows)
    sort!(weekly_revenue_df, [:week_start, :pmin_fraction, :plant])
    CSV.write(joinpath(@__DIR__, "pmin_weekly_revenue_equal_vs_greedy.csv"), weekly_revenue_df)
    
    # Annual analysis
    annual_revenue_df = combine(
        groupby(weekly_revenue_df, [:plant, :pmin_fraction]),
        :equal_revenue => sum => :total_equal_revenue,
        :greedy_revenue => sum => :total_greedy_revenue,
    )
    annual_revenue_df.revenue_increase_pct = 100.0 .* (
        annual_revenue_df.total_greedy_revenue .- annual_revenue_df.total_equal_revenue
    ) ./ abs.(annual_revenue_df.total_equal_revenue)
    annual_revenue_table = select(annual_revenue_df, :plant, :pmin_fraction, :revenue_increase_pct)
    annual_revenue_table.plant_order = [plant == "Shasta" ? 1 : plant == "Mammoth" ? 2 : plant == "Devil Canyon" ? 3 : 4 for plant in annual_revenue_table.plant]
    pmin_levels = sort(unique(annual_revenue_table.pmin_fraction))
    annual_revenue_table.pmin_order = [findfirst(==(fraction), pmin_levels) for fraction in annual_revenue_table.pmin_fraction]
    sort!(annual_revenue_table, [:plant_order, :pmin_order])
    annual_revenue_table[!, :plant] = replace.(annual_revenue_table.plant, "Mammoth" => "Mammoth Pool")
    annual_revenue_table[!, :pmin_fraction] = ["$(round(Int, 100 * fraction))%" for fraction in annual_revenue_table.pmin_fraction]
    annual_revenue_table[!, :revenue_increase_pct] = round.(annual_revenue_table.revenue_increase_pct, digits = 2)
    select!(annual_revenue_table, :plant, :pmin_fraction, :revenue_increase_pct)
    rename!(annual_revenue_table, :plant => :Plant, :pmin_fraction => :Pmin_Fraction, :revenue_increase_pct => Symbol("Increase in annual revenue (%)"))
    CSV.write(joinpath(@__DIR__, "annual_revenue_increase_by_plant_and_pmin_fraction.csv"), annual_revenue_table)

    # Total across all three plants, by load skew case.
    total_annual_revenue_df = combine(
        groupby(weekly_revenue_df, :pmin_fraction),
        :equal_revenue => sum => :total_equal_revenue,
        :greedy_revenue => sum => :total_greedy_revenue,
    )
    total_annual_revenue_df.revenue_increase_pct = 100.0 .* (
        total_annual_revenue_df.total_greedy_revenue .- total_annual_revenue_df.total_equal_revenue
    ) ./ abs.(total_annual_revenue_df.total_equal_revenue)
    sort!(total_annual_revenue_df, :pmin_fraction)
    total_annual_revenue_df[!, :pmin_fraction_pct] = ["$(round(Int, 100 * fraction))%" for fraction in total_annual_revenue_df.pmin_fraction]
    select!(total_annual_revenue_df, :pmin_fraction_pct, :total_equal_revenue, :total_greedy_revenue, :revenue_increase_pct)
    rename!(total_annual_revenue_df, :pmin_fraction_pct => :Pmin_Fraction, :total_equal_revenue => :Total_Equal_Revenue,
        :total_greedy_revenue => :Total_Greedy_Revenue, :revenue_increase_pct => Symbol("Increase in annual revenue (%)"))
    CSV.write(joinpath(@__DIR__, "annual_revenue_total_all_plants_by_pmin_fraction.csv"), total_annual_revenue_df)

    println("weekly_revenue_df has $(nrow(weekly_revenue_df)) rows")
    println("Saved -> annual_revenue_increase_by_plant_and_pmin_fraction.csv")
    println("Saved -> annual_revenue_total_all_plants_by_pmin_fraction.csv")

    closeall()
    gr()

    week_numbers = week.(weekly_revenue_df.week_start)
    skew_colors = Dict(
        "0" => :lightskyblue,
        "50" => :steelblue,
        "100" => :navy,
    )

    fraction_levels = sort(unique(weekly_revenue_df.pmin_fraction))
    fraction_labels = ["$(round(Int, 100 * fraction))%" for fraction in fraction_levels]


    # Plant-specific distributions and weekly revenue-increase charts.
    plant_order = ["Shasta", "Mammoth", "Devil Canyon"]
    plant_violin_plots = Plots.Plot[]
    plant_week_plots = Plots.Plot[]
    for plant in plant_order
        plant_results = filter(r -> r.plant == plant, weekly_revenue_df)
        isempty(plant_results) && continue
        plant_slug = lowercase(replace(plant, " " => "_"))
        plant_summary_rows = NamedTuple{(:pmin_fraction, :pmin_fraction_pct, :min_revenue_increase_pct, :p25_revenue_increase_pct, :median_revenue_increase_pct, :p75_revenue_increase_pct, :max_revenue_increase_pct),
                                       Tuple{Float64, Int, Float64, Float64, Float64, Float64, Float64}}[]

        if plant == "Shasta"
            p_plant_violin = plot(;
                xlabel = "Pmin Fraction",
                ylabel = "Weekly Revenue Increase (%)",
                title = "$(plant)",
                xticks = (eachindex(fraction_levels), fraction_labels),
                legend = :topleft,
                size = (1050, 600),
                dpi = 150,
                ylim = (-1.4,7.2),
                left_margin = 10Plots.mm,
                guidefontsize = GUIDEFONTSIZE,
                titlefontsize = TITLEFONTSIZE,
                legendfontsize = LEGENDFONTSIZE,
                tickfontsize = TICKFONTSIZE,
            )
        elseif plant == "Mammoth"
            p_plant_violin = plot(;
                xlabel = "Pmin Fraction",
                #ylabel = "Weekly Revenue Increase: Greedy vs Equal (%)",
                title = "$(plant)",
                xticks = (eachindex(fraction_levels), fraction_labels),
                legend = :topleft,
                size = (950, 600),
                dpi = 150,
                ylim = (-1.4,7.2),
                guidefontsize = GUIDEFONTSIZE,
                titlefontsize = TITLEFONTSIZE,
                legendfontsize = LEGENDFONTSIZE,
                tickfontsize = TICKFONTSIZE,
            )
        elseif plant == "Devil Canyon"
            p_plant_violin = plot(;
                xlabel = "Pmin Fraction",
                #ylabel = "Weekly Revenue Increase: Greedy vs Equal (%)",
                title = "$(plant)",
                xticks = (eachindex(fraction_levels), fraction_labels),
                legend = :topleft,
                size = (950, 600),
                dpi = 150,
                ylim = (-1.4,7.2),
                guidefontsize = GUIDEFONTSIZE,
                titlefontsize = TITLEFONTSIZE,
                legendfontsize = LEGENDFONTSIZE,
                tickfontsize = TICKFONTSIZE,
            )            
        end
        for (position, fraction) in enumerate(fraction_levels)
            values = plant_results.revenue_diff_pct[plant_results.pmin_fraction .== fraction]
            values = filter(isfinite, values)
            isempty(values) && continue
            violin!(p_plant_violin, fill(position, length(values)), values;
                label = false,
                color = skew_colors[string(round(Int, 100 * fraction))],
                alpha = 0.6,
            )
            min_value, q25, median_value, q75, max_value = quantile(values, [0.0, 0.25, 0.5, 0.75, 1.0])
            push!(plant_summary_rows, (
                pmin_fraction = fraction,
                pmin_fraction_pct = round(Int, 100 * fraction),
                min_revenue_increase_pct = min_value,
                p25_revenue_increase_pct = q25,
                median_revenue_increase_pct = median_value,
                p75_revenue_increase_pct = q75,
                max_revenue_increase_pct = max_value,
            ))
            x_span = [position - 0.18, position + 0.18]
            plot!(p_plant_violin, x_span, fill(median_value, 2); label = position == 1 ? "Median" : false, color = :black, lw = 2)
            plot!(p_plant_violin, x_span, fill(q25, 2); label = position == 1 ? "P25/P75" : false, color = :black, lw = 1.5, ls = :dash)
            plot!(p_plant_violin, x_span, fill(q75, 2); label = false, color = :black, lw = 1.5, ls = :dash)
        end

        hline!(p_plant_violin, [0.0]; color = :black, lw = 1, ls = :dot, label = false)
        push!(plant_violin_plots, p_plant_violin)
        violin_output = "violin_revenue_increase_by_pmin_fraction_$(plant_slug).png"
        savefig(p_plant_violin, joinpath(@__DIR__, violin_output))
        println("Saved -> $(violin_output)")
        summary_output = "revenue_increase_summary_by_pmin_fraction_$(plant_slug).csv"
        CSV.write(joinpath(@__DIR__, summary_output), DataFrame(plant_summary_rows))
        println("Saved -> $(summary_output)")

        plant_unique_weeks = unique(sort(plant_results.week_start))
        plant_month_tick_positions = Int[]
        plant_month_tick_labels = String[]
        plant_seen_months = Set{Int}()
        for (idx, week_start) in enumerate(plant_unique_weeks)
            month_num = month(week_start)
            if month_num ∉ plant_seen_months
                push!(plant_month_tick_positions, idx)
                push!(plant_month_tick_labels, Dates.monthname(week_start)[1:3])
                push!(plant_seen_months, month_num)
            end
        end
        if plant == "Shasta"
            p_plant_week = plot(;
                xlabel = "Month",
                ylabel = "Weekly Revenue Increase (%)",
                title = "$(plant)",
                xticks = (plant_month_tick_positions, plant_month_tick_labels),
                legend = :topright,
                size = (950, 600),
                dpi = 150,
                left_margin = 10Plots.mm,
                guidefontsize = GUIDEFONTSIZE,
                titlefontsize = TITLEFONTSIZE,
                legendfontsize = LEGENDFONTSIZE,
                tickfontsize = TICKFONTSIZE,
                ylim = (-1.4,7.2)
            )
        else
            p_plant_week = plot(;
                xlabel = "Month",
                title = "$(plant)",
                xticks = (plant_month_tick_positions, plant_month_tick_labels),
                legend = :topright,
                size = (950, 600),
                dpi = 150,
                guidefontsize = GUIDEFONTSIZE,
                titlefontsize = TITLEFONTSIZE,
                legendfontsize = LEGENDFONTSIZE,
                tickfontsize = TICKFONTSIZE,
                ylim = (-1.4,7.2),
            )
        end
        for fraction in sort(unique(plant_results.pmin_fraction))
            subset = plant_results[plant_results.pmin_fraction .== fraction, :]
            sort!(subset, :week_start)
            plant_x_positions = [findfirst(==(week_start), plant_unique_weeks) for week_start in subset.week_start]
            plot!(p_plant_week, plant_x_positions, subset.revenue_diff_pct;
                label = "$(round(Int, 100 * fraction))% Pmin fraction",
                marker = plant_markers[plant],
                color = skew_colors[string(round(Int, 100 * fraction))],
            )
        end
        hline!(p_plant_week, [0.0]; color = :black, lw = 1, ls = :dot, label = "")
        push!(plant_week_plots, p_plant_week)
        week_output = "weekly_revenue_increase_by_pmin_fraction_$(plant_slug).png"
        savefig(p_plant_week, joinpath(@__DIR__, week_output))
        println("Saved -> $(week_output)")
    end

    plant_violin_figure = plot(plant_violin_plots...; layout = (1, 3), size = (1800, 600), dpi = 150, bottom_margin = 12Plots.mm)
    savefig(plant_violin_figure, joinpath(@__DIR__, "violin_revenue_increase_by_pmin_fraction_all_plants.png"))
    println("Saved -> violin_revenue_increase_by_pmin_fraction_all_plants.png")

    plant_week_figure = plot(plant_week_plots...; layout = (1, 3), size = (1800, 600), dpi = 150, bottom_margin = 12Plots.mm)
    savefig(plant_week_figure, joinpath(@__DIR__, "weekly_revenue_increase_by_pmin_fraction_all_plants.png"))
    println("Saved -> weekly_revenue_increase_by_pmin_fraction_all_plants.png")

end

main()

function plot_weekly_revenue_equal_by_pmin()
    weekly_revenue_df = CSV.read(joinpath(@__DIR__, "pmin_weekly_revenue_equal_vs_greedy.csv"), DataFrame)
    skew_colors = Dict(0.0 => :lightskyblue, 0.5 => :steelblue, 1.0 => :navy)

    for plant in unique(weekly_revenue_df.plant)
        plant_revenue = weekly_revenue_df[weekly_revenue_df.plant .== plant, :]
        sort!(plant_revenue, [:pmin_fraction, :week_start])

        p = plot(;
            xlabel = "Week Number",
            ylabel = "Weekly Revenue (Equal Allocation)",
            legend = :bottomright,
            size = (950, 600),
            dpi = 150,
            left_margin = 10Plots.mm,
            right_margin = 20Plots.mm,
        )

        for fraction in sort(unique(plant_revenue.pmin_fraction))
            subset = plant_revenue[plant_revenue.pmin_fraction .== fraction, :]
            plot!(p, week.(subset.week_start), subset.equal_revenue;
                label = "$(round(Int, 100 * fraction))% pmin fraction",
                marker = :circle,
                color = get(skew_colors, fraction, :gray),
            )
        end

        plant_slug = lowercase(replace(plant, " " => "_"))
        savefig(p, joinpath(@__DIR__, "weekly_revenue_equal_allocation_by_pmin_fraction_$(plant_slug).png"))
        println("Saved -> weekly_revenue_equal_allocation_by_pmin_fraction_$(plant_slug).png")
    end
end

plot_weekly_revenue_equal_by_pmin()
