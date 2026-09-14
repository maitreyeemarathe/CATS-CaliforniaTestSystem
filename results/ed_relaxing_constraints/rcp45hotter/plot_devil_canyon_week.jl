using CSV, DataFrames, Dates, Plots, Statistics

const BASE_DIR = normpath(joinpath(@__DIR__, "..", "..", ".."))
const EQUAL_DIR = joinpath(@__DIR__, "2025-01-01", "relaxed_pmin_ps100")
const GREEDY_DIR = joinpath(@__DIR__, "greedy", "2025-01-01", "relaxed_pmin_ps100")
const HYDRO_FILE = joinpath(BASE_DIR, "hydro_data", "2025_scenarios", "devilcanyon_rcp45hotter_hourly.csv")
const WEEK_START = DateTime(2025, 2, 12)
const WEEK_END = WEEK_START + Day(7)
const DEVIL_CANYON_COLUMNS = ["gen-271", "gen-272", "gen-273", "gen-274"]

function parse_datetime(x)::DateTime
    s = replace(string(x), "T" => " ")
    s = replace(s, r"\.\d+" => "")
    return DateTime(s[1:19], dateformat"yyyy-mm-dd HH:MM:SS")
end

function load_weekly_prices(path::String)
    prices = CSV.read(path, DataFrame)
    prices.DateTime = parse_datetime.(prices.DateTime)
    return filter(row -> WEEK_START <= row.DateTime < WEEK_END, prices)
end

function load_daily_devil_canyon_energy(path::String)
    dispatch = CSV.read(path, DataFrame)
    dispatch.DateTime = parse_datetime.(dispatch.DateTime)
    dispatch = filter(row -> WEEK_START <= row.DateTime < WEEK_END, dispatch)
    dispatch.daily = Date.(dispatch.DateTime)
    dispatch.energy_mwh = zeros(Float64, nrow(dispatch))
    for column in DEVIL_CANYON_COLUMNS
        dispatch.energy_mwh .+= Float64.(dispatch[!, column])
    end
    return combine(groupby(dispatch, :daily), :energy_mwh => sum => :energy_mwh)
end

prices = load_weekly_prices(joinpath(EQUAL_DIR, "shadow_prices.csv"))
greedy_prices = load_weekly_prices(joinpath(GREEDY_DIR, "hydro_ed_prices.csv"))
equal_daily = load_daily_devil_canyon_energy(joinpath(EQUAL_DIR, "selected_hydro_dispatch_wide.csv"))
greedy_daily = load_daily_devil_canyon_energy(joinpath(GREEDY_DIR, "selected_hydro_dispatch_wide.csv"))

hydro = CSV.read(HYDRO_FILE, DataFrame)
hydro.week_start = Date.(string.(hydro.week_start))
week_hydro = filter(row -> row.week_start == Date(WEEK_START), hydro)
@assert nrow(prices) == 168 "Expected 168 equal-case shadow-price rows"
@assert nrow(greedy_prices) == 168 "Expected 168 greedy-case price rows"
@assert nrow(equal_daily) == 7 && nrow(greedy_daily) == 7 "Expected seven daily values for each dispatch case"
@assert nrow(week_hydro) == 168 "Expected 168 hydro-budget rows"

daily_budget_mwh = 24.0 * Float64(first(week_hydro).budget_hour)
daily_dates = collect(Date(WEEK_START):Day(1):Date(WEEK_END - Hour(1)))
equal_values = [equal_daily.energy_mwh[equal_daily.daily .== day][1] for day in daily_dates]
greedy_values = [greedy_daily.energy_mwh[greedy_daily.daily .== day][1] for day in daily_dates]
energy_step_times = collect(Date(WEEK_START):Day(1):Date(WEEK_END))
equal_energy_step_values = vcat(equal_values, last(equal_values))
greedy_energy_step_values = vcat(greedy_values, last(greedy_values))
weekly_budget_mwh = 168.0 * Float64(first(week_hydro).budget_hour)
equal_budget_used_pct = 100.0 * sum(equal_values) / weekly_budget_mwh
greedy_budget_used_pct = 100.0 * sum(greedy_values) / weekly_budget_mwh
prices.daily = Date.(prices.DateTime)
daily_average_prices = combine(groupby(prices, :daily), :value => mean => :average_price)
daily_average_values = [daily_average_prices.average_price[daily_average_prices.daily .== day][1] for day in daily_dates]
price_step_times = collect(WEEK_START:Day(1):WEEK_END)
price_step_values = vcat(daily_average_values, last(daily_average_values))
greedy_prices.daily = Date.(greedy_prices.DateTime)
greedy_daily_average_prices = combine(groupby(greedy_prices, :daily), :value => mean => :average_price)
greedy_daily_average_values = [greedy_daily_average_prices.average_price[greedy_daily_average_prices.daily .== day][1] for day in daily_dates]
greedy_price_step_values = vcat(greedy_daily_average_values, last(greedy_daily_average_values))

figure = plot(layout = (2, 1), size = (1100, 850), dpi = 150, left_margin = 12Plots.mm, right_margin = 18Plots.mm, bottom_margin = 12Plots.mm)

viridis_colors = Plots.palette(:viridis, 4)
plot!(figure[1], prices.DateTime, prices.value;
    label = "Hourly",
    color = :lightsteelblue,
    linewidth = 2,
    xlabel = "Day",
    ylabel = "Shadow Price (\$/MWh)",
    linestyle = :dash,
    #title = "Prices",
    xticks = (collect(WEEK_START:Day(1):WEEK_END - Day(1)), string.(1:7)),
    #xrotation = 30,
    legend = :bottomright,
)
plot!(figure[1], price_step_times, price_step_values;
    label = "Daily Average",
    color = :steelblue,
    linewidth = 2,
    seriestype = :steppost,
)
#=
plot!(figure[1], greedy_prices.DateTime, greedy_prices.value;
    label = "Greedy",
    color = :firebrick,
    linewidth = 2,
    linestyle = :dot,
)
plot!(figure[1], price_step_times, greedy_price_step_values;
    label = "Greedy daily average",
    color = :purple,
    linewidth = 3,
    linestyle = :dash,
    seriestype = :steppost,
)
=#

plot!(figure[2], energy_step_times, equal_energy_step_values;
    label = "Equal",
    color = :orange,
    linewidth = 2,
    xlabel = "Day",
    ylabel = "Daily Average Energy Generated (MWh)",
    #title = "Energy",
    legend = :topright,
    linestyle = :dash,
    xticks = (daily_dates, string.(1:7)),
    #xrotation = 30,
    seriestype = :steppost,
)
plot!(figure[2], energy_step_times, greedy_energy_step_values;
    label = "Greedy",
    color = :darkorange,
    linewidth = 2,
    seriestype = :steppost,
)

#=
hline!(figure[2], [daily_budget_mwh];
    label = "Daily budget target",
    color = :black,
    linestyle = :dash,
    linewidth = 1.5,
)
=#


output = joinpath(@__DIR__, "devil_canyon_week_2025-02-12_equal_vs_greedy.png")
savefig(figure, output)
println("Saved -> $(output)")
println("Daily budget target: $(round(daily_budget_mwh, digits = 2)) MWh/day")
println("Equal weekly budget used: $(round(equal_budget_used_pct, digits = 2))%")
println("Greedy weekly budget used: $(round(greedy_budget_used_pct, digits = 2))%")