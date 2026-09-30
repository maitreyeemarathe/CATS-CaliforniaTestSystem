using CSV, DataFrames, Plots

# ── Budget analysis ────────────────────────────────────────────────────────────

"""
    weekly_max_dispatch_hours(df) -> DataFrame

For each of the first 52 weeks in `df`, compute:
  - total_budget  = 168 × budget_hour  (constant within a week)
  - leftover      = total_budget - 168 × week_p_min
  - hours_at_max  = floor(leftover / (week_p_max - week_p_min))
"""
function weekly_max_dispatch_hours(df::DataFrame)::DataFrame
    weeks = combine(groupby(df, :week_start), first)   # one row per week
    weeks = first(weeks, 52)
    weeks.total_budget = 168.0 .* weeks.budget_hour
    weeks.leftover     = weeks.total_budget .- 168.0 .* weeks.week_p_min
    weeks.hours_at_max = floor.(Int, weeks.leftover ./ (weeks.week_p_max .- weeks.week_p_min))
    return select(weeks, :week_start, :week_p_min, :week_p_max, :total_budget, :leftover, :hours_at_max)
end

# ── Gini coefficient ───────────────────────────────────────────────────────────

"""
    gini(x) -> Float64

Gini coefficient of a non-negative vector (0 = perfect equality, 1 = maximum inequality).
Returns NaN when the sum is zero or the vector is empty.
"""
function gini(x::AbstractVector{<:Real})::Float64
    n = length(x)
    (n == 0 || sum(x) ≈ 0) && return NaN
    xs = sort(x)
    return (2.0 * sum(i * xs[i] for i in 1:n)) / (n * sum(xs)) - (n + 1) / n
end

# ── Price Gini analysis ────────────────────────────────────────────────────────

"""
    label_weeks_and_days!(df) -> df

Add :week (1–52) and :day_in_week (1–7) to a price DataFrame sorted by DateTime.
Works by row position: every 168 rows is one week, every 24 rows is one day.
"""
function label_weeks_and_days!(df::DataFrame)
    idx            = 1:nrow(df)
    df.week        = ceil.(Int, idx ./ 168)
    df.day_in_week = ceil.(Int, mod1.(idx, 168) ./ 24)
    return df
end

"""
    week_price_gini(week_df, n) -> Float64

Given the 168 hourly-price rows for one week and `n` = hours_at_max,
count how many of the top-n priced hours fall on each of the 7 days and
return the Gini coefficient of that day-level count distribution.
"""
function week_price_gini(week_df::AbstractDataFrame, n::Int)::Float64
    n <= 0 && return NaN
    top_n   = first(sort(week_df, :value, rev=true), n)
    counts  = zeros(Int, 7)
    for row in eachrow(top_n)
        counts[row.day_in_week] += 1
    end
    return gini(Float64.(counts))
end

"""
    price_gini_by_week(price_csv, budget_df) -> DataFrame

For each of the first 52 weeks, find the top `hours_at_max` priced hours,
count their spread across the 7 days, and compute the Gini coefficient.
"""
function price_gini_by_week(price_csv::String, budget_df::DataFrame)::DataFrame
    prices = CSV.read(price_csv, DataFrame)
    sort!(prices, :DateTime)
    label_weeks_and_days!(prices)

    map(enumerate(eachrow(budget_df))) do (w, brow)
        week_prices = filter(r -> r.week == w, prices)
        (week        = w,
         week_start  = string(brow.week_start),
         hours_at_max = brow.hours_at_max,
         gini_coeff  = week_price_gini(week_prices, brow.hours_at_max))
    end |> DataFrame
end

# ── Plotting ──────────────────────────────────────────────────────────────────

"""
    plot_plant_analysis(gini_df, plant_name, output_path)

Plot hours_at_max (left axis, blue) and gini_coeff (right axis, red) vs week
for a single plant and save to `output_path`.
"""
function plot_plant_analysis(gini_df::DataFrame, plant_name::String, output_path::String)
    weeks = gini_df.week
    p = plot(weeks, gini_df.hours_at_max;
        xlabel      = "Week",
        ylabel      = "Hours at Max Dispatch",
        label       = "Hours at Max",
        color       = :steelblue,
        lw          = 2,
        title       = "$plant_name: Budget Hours & Price Gini by Week",
        legend      = :topleft,
        size        = (900, 400),
        dpi         = 150,
        left_margin = 8Plots.mm,
        right_margin = 12Plots.mm,
    )
    p2 = twinx(p)
    plot!(p2, weeks, gini_df.gini_coeff;
        ylabel  = "Gini Coefficient",
        label   = "Gini Coeff",
        color   = :crimson,
        lw      = 2,
        ls      = :dash,
        legend  = :topright,
        ylims   = (0, 1),
    )
    savefig(p, output_path)
    println("Saved plot         → $output_path")
    return p
end

# ── Entry point ────────────────────────────────────────────────────────────────
price_csv = joinpath(@__DIR__, "baseline_dailybudget_forecast.csv")

plants = [
    ("shasta",      "Shasta"),
    ("mammoth",     "Mammoth"),
    ("devilcanyon", "Devil Canyon"),
]

for (key, name) in plants
    hydro_csv  = joinpath(@__DIR__, "$(key)_hourly.csv")
    out_budget = joinpath(@__DIR__, "$(key)_budget_analysis.csv")
    out_gini   = joinpath(@__DIR__, "$(key)_price_gini.csv")
    out_plot   = joinpath(@__DIR__, "$(key)_analysis.png")

    budget_df = weekly_max_dispatch_hours(CSV.read(hydro_csv, DataFrame))
    CSV.write(out_budget, budget_df)
    println("Wrote budget analysis  → $out_budget")

    gini_df = price_gini_by_week(price_csv, budget_df)
    CSV.write(out_gini, gini_df)
    println("Wrote price Gini table → $out_gini")

    plot_plant_analysis(gini_df, name, out_plot)
end
