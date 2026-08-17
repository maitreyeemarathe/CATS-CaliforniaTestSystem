using CSV, DataFrames, Plots, Dates

N_WEEKS = 1

HYDRO_DATA_DIR = joinpath(@__DIR__, "../../hydro_data")

plant_keys = Dict("Shasta" => "shasta", "Mammoth" => "mammoth", "Devil Canyon" => "devilcanyon")
plant_markers = Dict("Shasta" => :circle, "Mammoth" => :square, "Devil Canyon" => :diamond)
plant_colors  = Dict("Shasta" => :steelblue, "Mammoth" => :darkorange, "Devil Canyon" => :forestgreen)

# ── Budget analysis ────────────────────────────────────────────────────────────

function weekly_max_dispatch_hours(df::DataFrame)::DataFrame
    weeks = combine(groupby(df, :week_start), first)
    weeks = first(weeks, N_WEEKS)
    weeks.total_budget = 168.0 .* weeks.budget_hour
    weeks.leftover     = weeks.total_budget .- 168.0 .* weeks.week_p_min
    weeks.hours_at_max = floor.(Int, weeks.leftover ./ (weeks.week_p_max .- weeks.week_p_min))
    return select(weeks, :week_start, :week_p_min, :week_p_max, :total_budget, :leftover, :hours_at_max)
end

function gini(x::AbstractVector{<:Real})::Float64
    n = length(x)
    (n == 0 || sum(x) ≈ 0) && return NaN
    xs = sort(x)
    return (2.0 * sum(i * xs[i] for i in 1:n)) / (n * sum(xs)) - (n + 1) / n
end

function label_weeks_and_days!(df::DataFrame)
    idx            = 1:nrow(df)
    df.week        = ceil.(Int, idx ./ 168)
    df.day_in_week = ceil.(Int, mod1.(idx, 168) ./ 24)
    return df
end

function week_price_gini(week_df::AbstractDataFrame, n::Int)::Float64
    n <= 0 && return NaN
    top_n  = first(sort(week_df, :value, rev=true), n)
    counts = zeros(Int, 7)
    for row in eachrow(top_n)
        counts[row.day_in_week] += 1
    end
    return gini(Float64.(counts))
end

# ── Compute n_max_hours per (week, plant) ─────────────────────────────────────
# n_max_hours does not depend on fraction_reduction

function n_max_hours_for_week(plant_name::String, week_start_date::Date)::Int
    key      = plant_keys[plant_name]
    hydro_df = CSV.read(joinpath(HYDRO_DATA_DIR, "$(key)_hourly.csv"), DataFrame)
    # parse week_start if stored as string
    hydro_df.week_start = Date.(string.(hydro_df.week_start))
    week_rows = filter(r -> r.week_start == week_start_date, hydro_df)
    isempty(week_rows) && return -1
    budget_df = weekly_max_dispatch_hours(week_rows)
    return first(budget_df.hours_at_max)
end

# ── Collect results ────────────────────────────────────────────────────────────

week_start_dates = sort(collect(Set([Date(2019,01,01),
                       Date(2019,02,12), Date(2019,03,05), Date(2019,04,02),
                       Date(2019,05,07), Date(2019,06,04), Date(2019,07,02),
                       Date(2019,08,06), Date(2019,09,24), Date(2019,10,22),
                       Date(2019,11,19), Date(2019,12,24)])))

# accumulate rows: (plant, fraction_reduction, gini_coeff, n_max_hours, revenue_diff_pct)
rows = NamedTuple{(:plant, :fraction_reduction, :gini_coeff, :n_max_hours, :revenue_diff_pct),
                  Tuple{String,Float64,Float64,Int,Float64}}[]

for week_start_date in week_start_dates
    week_dir = joinpath(@__DIR__, string(week_start_date))
    isdir(week_dir) || continue

    sweep_file = joinpath(week_dir, "sweep_revenue_comparison_$(week_start_date)_week.csv")
    isfile(sweep_file) || continue
    sweep_df = CSV.read(sweep_file, DataFrame)

    for fr_tag_row in unique(sweep_df.fraction_reduction)
        fr_int     = round(Int, fr_tag_row * 100)
        price_file = joinpath(week_dir, "greedy_fr$(fr_int)", "hydro_ed_prices.csv")
        isfile(price_file) || continue

        prices = CSV.read(price_file, DataFrame)
        sort!(prices, :DateTime)
        label_weeks_and_days!(prices)
        week_prices = filter(r -> r.week == 1, prices)

        fr_rows = filter(r -> r.fraction_reduction == fr_tag_row, sweep_df)

        for plant in unique(fr_rows.plant)
            plant_row   = first(filter(r -> r.plant == plant, fr_rows))
            n_max        = n_max_hours_for_week(String(plant), week_start_date)
            n_max < 0 && continue
            g            = week_price_gini(week_prices, n_max)
            push!(rows, (
                plant              = plant,
                fraction_reduction = fr_tag_row,
                gini_coeff         = g,
                n_max_hours        = n_max,
                revenue_diff_pct   = plant_row.revenue_diff_pct,
            ))
        end
    end
end

results_df = DataFrame(rows)

# ── Plot ──────────────────────────────────────────────────────────────────────

println("results_df has $(nrow(results_df)) rows")

closeall()
gr()

p = plot(;
    xlabel      = "Gini Coefficient of Price Distribution",
    ylabel      = "Revenue Increase: Greedy vs Equal (%)",
    #title       = "Greedy Budget Advantage vs Price Concentration",
    legend      = :topleft,
    size        = (950, 600),
    dpi         = 150,
    left_margin = 10Plots.mm,
    right_margin = 35Plots.mm,
)

# Plot each plant with its marker shape, colored by fraction_reduction
for plant in keys(plant_markers)
    sub = filter(r -> r.plant == plant, results_df)
    isempty(sub) && continue
    
    # Use zcolor to map fraction_reduction to color gradient
    scatter!(p, sub.gini_coeff, sub.revenue_diff_pct;
        label       = plant,
        marker      = plant_markers[plant],
        markersize  = 7,
        zcolor      = sub.fraction_reduction,
        palette     = :viridis,
        markerstrokewidth = 1,
        colorbar_title = "Fraction\nReduction",
    )
end

hline!(p, [0.0]; color=:black, lw=1, ls=:dot, label="")

savefig(p, joinpath(@__DIR__, "scatter_gini_vs_revenue_diff.png"))
println("Saved → scatter_gini_vs_revenue_diff.png")
#display(p)



# Read each sub-directory
#=
week_start_dates = Set([Date(2019,01,01), 
                       Date(2019,02,12),
                       Date(2019,03,05),
                       Date(2019,04,02),
                       Date(2019,05,07),
                       Date(2019,06,04),
                       Date(2019,07,02),
                       Date(2019,08,06),
                       Date(2019,09,24),
                       Date(2019,10,22),
                       Date(2019,11,19),
                       Date(2019,12,24)
                       ])
mammoth_df = DataFrame(revenue_diff_pct = Float64[])
shasta_df = DataFrame(revenue_diff_pct = Float64[])
devilcanyon_df = DataFrame(revenue_diff_pct = Float64[])
i = 0
for week_start_date in week_start_dates
    global i = i + 1
    directory = joinpath("./",string(week_start_date))
    if(isdir(directory))
        df = CSV.read(joinpath(directory,"sweep_revenue_comparison_"*string(week_start_date)*"_week.csv"), DataFrame)
        plant_dfs = Dict(p => DataFrame(g) for g in groupby(df, :plant) for p in [first(g.plant)])
        append!(mammoth_df,select(plant_dfs["Mammoth"], :revenue_diff_pct))
        append!(shasta_df,select(plant_dfs["Shasta"], :revenue_diff_pct))
        append!(devilcanyon_df,select(plant_dfs["Devil Canyon"], :revenue_diff_pct))
    end
end
=#
# scatter(x,y)