
ENV["XPRESSDIR"] = "$(homedir())/Documents/Xpress"

using PowerSystems
using PowerSimulations
using HydroPowerSimulations
using PowerSystemCaseBuilder
using PowerFlows
using Xpress
using Dates
using JuMP
using PowerFlows
import PowerNetworkMatrices: VirtualPTDF
using TimeSeries
using XLSX
using Plots

# Choose the week to solve.
start_time = DateTime("2019-12-24T00:00:00")

BASE_DIR = joinpath(@__DIR__, "../..")
HYDRO_DATA_DIR = "$BASE_DIR/hydro_data/"
RESULTS_DIR = "$BASE_DIR/results/equal_v_greedy_daily_budget/$(Dates.format(start_time, "yyyy-mm-dd"))/"
EQUAL_RESULTS_DIR = "$RESULTS_DIR/equal/"
GREEDY_RESULTS_DIR = "$RESULTS_DIR/greedy/"
CATS_DIR = "$BASE_DIR/Sienna/"

include(joinpath(CATS_DIR, "build_CATS_equal_v_greedy_daily_budget.jl"))
include("equal_daily_budget.jl")
include("greedy_daily_budget.jl")
include(joinpath(BASE_DIR, "Script", "calculate_budget.jl"))

gen_csv = CSV.read("$BASE_DIR/GIS/CATS_gens.csv", DataFrame)

# Find selected hydro units and assign budget
shasta_csv = joinpath(HYDRO_DATA_DIR, "shasta_hourly.csv")
devilcanyon_csv = joinpath(HYDRO_DATA_DIR, "devilcanyon_hourly.csv")
mammoth_csv = joinpath(HYDRO_DATA_DIR, "mammoth_hourly.csv")
shasta_gen_names = get_hydro_gen_names(gen_csv; plant_code=445, bus=1498, gen_ids=["1", "2", "3", "4", "5"], expected_count=5)
devilcanyon_gen_names = get_hydro_gen_names(gen_csv; plant_code=436, bus=1005, gen_ids=["1", "2", "3", "4"], expected_count=4) 
mammoth_gen_names = get_hydro_gen_names(gen_csv; plant_code=344, bus=1636, gen_ids=["1", "2"], expected_count=2)  
selected_hydro_details = Dict(
    "Shasta" => (shasta_csv, shasta_gen_names),
    "Devil Canyon" => (devilcanyon_csv, devilcanyon_gen_names),
    "Mammoth" => (mammoth_csv, mammoth_gen_names)
)
selected_gen_names = union(shasta_gen_names, devilcanyon_gen_names, mammoth_gen_names)

template = ProblemTemplate(NetworkModel(CopperPlatePowerModel; use_slacks=false, duals=[CopperPlateBalanceConstraint]))

set_device_model!(template, ThermalStandard, ThermalBasicDispatch)
set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
set_device_model!(template, HydroDispatch, HydroDispatchRunOfRiverBudget)
set_device_model!(template, PowerLoad, StaticPowerLoad)
set_device_model!(template, Line, StaticBranch)
set_device_model!(template, Transformer2W, StaticBranch)

solver_xpress = JuMP.optimizer_with_attributes(Xpress.Optimizer, 
    "RANDOMSEED" => 123,  # Lock the random seed to a fixed integer
    "THREADS"    => 1,   # Limit solver to a single thread to prevent multi-threading
    "MIPRELSTOP" => 0.001,
    "DETERMINISTIC" => 1,  # Enable deterministic mode for reproducibility
)

sweep_results = DataFrame(fraction_reduction=Float64[], plant=String[], equal_revenue=Float64[], greedy_revenue=Float64[])

for fraction_reduction in 0.0:0.1:0.2
    println("\n===== fraction_reduction = $fraction_reduction =====")
    fr_system = build_CATS_system(; fraction_reduction = fraction_reduction, start_time = start_time)

    fr_tag     = "fr$(round(Int, fraction_reduction*100))"
    equal_dir  = joinpath(RESULTS_DIR, "equal_$fr_tag")
    greedy_dir = joinpath(RESULTS_DIR, "greedy_$fr_tag")
    mkpath(equal_dir)
    mkpath(greedy_dir)

    run_equal_daily_budget(template, deepcopy(fr_system), solver_xpress, start_time, equal_dir, selected_gen_names, selected_hydro_details)
    equal_revenue_df = CSV.read(joinpath(equal_dir, "hydro_revenue_by_plant.csv"), DataFrame)

    run_greedy_daily_budget(deepcopy(fr_system), selected_gen_names, selected_hydro_details, start_time, solver_xpress, equal_dir, greedy_dir)
    greedy_revenue_df = CSV.read(joinpath(greedy_dir, "hydro_ed_total_revenue_by_plant.csv"), DataFrame)

    eq_lookup = Dict(row.plant => row.revenue for row in eachrow(equal_revenue_df))
    for row in eachrow(greedy_revenue_df)
        push!(sweep_results, (
            fraction_reduction = fraction_reduction,
            plant              = row.plant,
            equal_revenue      = get(eq_lookup, row.plant, NaN),
            greedy_revenue     = row.revenue,
        ))
    end
end

# Add a column for percentage difference between greedy and equal revenue
sweep_results[!, :revenue_diff_pct] = 100.0 * (sweep_results[!, :greedy_revenue] .- sweep_results[!, :equal_revenue]) ./ sweep_results[!, :equal_revenue]

# Add start_time in the file name for clarity
CSV.write(joinpath(RESULTS_DIR, "sweep_revenue_comparison_$(Dates.format(start_time, "yyyy-mm-dd"))_week.csv"), sweep_results)
println("\nSweep complete. Results written to sweep_revenue_comparison_$(Dates.format(start_time, "yyyy-mm-dd"))_week.csv")
