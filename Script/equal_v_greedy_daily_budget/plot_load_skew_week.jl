using CSV
using DataFrames
using Dates
using JLD2
using Plots

const BASE_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const DATA_DIR = joinpath(BASE_DIR, "data")
const RESULTS_DIR = joinpath(BASE_DIR, "results", "equal_v_greedy_daily_budget", "2025-11-05")
const LOAD_FILE = joinpath(DATA_DIR, "Load_Agg_2025.jld2")
const START_TIME = DateTime("2025-11-05T00:00:00")
const END_TIME = START_TIME + Week(1)
const FRACTION_REDUCTION = 0.20

function load_active_power_matrix(path::String)
    load_data = load(path, "load_data")
    return Float64.(real.(load_data))
end

function apply_load_skew(active_load::Matrix{Float64}, fraction_reduction::Float64)
    skewed_load = copy(active_load)
    timestamps = collect(DateTime("2025-01-01T00:00:00"):Hour(1):DateTime("2025-12-31T23:00:00"))

    for week_start in START_TIME:Week(1):(START_TIME + Week(7))
        week_end = min(week_start + Week(1), last(timestamps) + Hour(1))
        week_rows = findall(t -> week_start <= t < week_end, timestamps)
        weekday_rows = filter(i -> dayofweek(Date(timestamps[i])) <= 5, week_rows)
        weekend_rows = filter(i -> dayofweek(Date(timestamps[i])) >= 6, week_rows)

        weekday_active_total = sum(skewed_load[weekday_rows, :])
        weekend_active_total = sum(skewed_load[weekend_rows, :])
        weekday_scale = (weekday_active_total + weekend_active_total * fraction_reduction) / weekday_active_total
        skewed_load[weekday_rows, :] .*= weekday_scale
        skewed_load[weekend_rows, :] .*= (1.0 - fraction_reduction)
    end

    return skewed_load
end

function load_weekly_prices(path::String)
    prices = CSV.read(path, DataFrame)
    prices.DateTime = parse_datetime.(prices.DateTime)
    return filter(row -> START_TIME <= row.DateTime < END_TIME, prices)
end

function parse_datetime(x)::DateTime
    value = replace(string(x), "T" => " ")
    value = replace(value, r"\.\d+" => "")
    return DateTime(value[1:19], dateformat"yyyy-mm-dd HH:MM:SS")
end

timestamps = collect(DateTime("2025-01-01T00:00:00"):Hour(1):DateTime("2025-12-31T23:00:00"))
load_matrix = load_active_power_matrix(LOAD_FILE)
@assert size(load_matrix, 1) == length(timestamps) "Load row count does not match the 2025 hourly timestamp grid"

unskewed_load = load_matrix
skewed_load = apply_load_skew(load_matrix, FRACTION_REDUCTION)
week_rows = findall(t -> START_TIME <= t < END_TIME, timestamps)
week_timestamps = timestamps[week_rows]
unskewed_total = vec(sum(unskewed_load[week_rows, :], dims = 2))
skewed_total = vec(sum(skewed_load[week_rows, :], dims = 2))

equal_fr0_prices = load_weekly_prices(joinpath(RESULTS_DIR, "equal_fr0", "shadow_prices.csv"))
equal_fr20_prices = load_weekly_prices(joinpath(RESULTS_DIR, "equal_fr20", "shadow_prices.csv"))
@assert nrow(equal_fr0_prices) == 168 "Expected 168 unskewed price rows"
@assert nrow(equal_fr20_prices) == 168 "Expected 168 skewed price rows"

figure = plot(
    layout = (2, 1),
    size = (1100, 850),
    dpi = 150,
    left_margin = 12Plots.mm,
    right_margin = 18Plots.mm,
    bottom_margin = 15Plots.mm,
)

plot!(figure[1], week_timestamps, unskewed_total;
    label = "0% skew",
    color = :steelblue,
    linewidth = 2,
    xlabel = "Day of week",
    ylabel = "Load (MW)",
    #title = "System load before and after 20% weekend-to-weekday skew",
    xticks = (collect(START_TIME:Day(1):START_TIME + Day(6)), string.(1:7)),
    legend = :bottomright,
)
plot!(figure[1], week_timestamps, skewed_total;
    label = "20% skew",
    color = :steelblue,
    linewidth = 2,
    linestyle = :dash,
)

plot!(figure[2], equal_fr0_prices.DateTime, equal_fr0_prices.value;
    label = "0% skew",
    color = :darkorange,
    linewidth = 2,
    xlabel = "Day of week",
    ylabel = "Shadow Price (\$/MWh)",
    #title = "Equal-case shadow price before and after load skew",
    xticks = (collect(START_TIME:Day(1):START_TIME + Day(6)), string.(1:7)),
    legend = :bottomright,
)
plot!(figure[2], equal_fr20_prices.DateTime, equal_fr20_prices.value;
    label = "20% skew",
    color = :darkorange,
    linewidth = 2,
    linestyle = :dash,
)

output = joinpath(@__DIR__, "load_skew_week_2025-11-05.png")
savefig(figure, output)
println("Saved -> $(output)")