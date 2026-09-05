
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
using CSV
using DataFrames

HORIZON_WEEKS = 8

SCENARIO = "rcp45hotter"
BASE_DIR = joinpath(@__DIR__, "../..")
HYDRO_DATA_DIR = "$BASE_DIR/hydro_data/2025_scenarios/"
CATS_DIR = "$BASE_DIR/Sienna/"
gen_csv = CSV.read("$BASE_DIR/GIS/CATS_gens.csv", DataFrame)

include(joinpath(CATS_DIR, "build_CATS_2025_scenarios_relaxed_constraints_ed.jl"))
include("equal_daily_budget.jl")
include("greedy_daily_budget.jl")
include(joinpath(BASE_DIR, "Script", "calculate_budget.jl"))

# Find selected hydro units and assign budget
shasta_csv = joinpath(HYDRO_DATA_DIR, "shasta_$(SCENARIO)_hourly.csv")
devilcanyon_csv = joinpath(HYDRO_DATA_DIR, "devilcanyon_$(SCENARIO)_hourly.csv")
mammoth_csv = joinpath(HYDRO_DATA_DIR, "mammoth_$(SCENARIO)_hourly.csv")
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

start_time = DateTime("2025-11-05T00:00:00")
results_dir = "$BASE_DIR/results/equal_v_greedy_daily_budget/$(Dates.format(start_time, "yyyy-mm-dd"))/"
equal_results_dir = "$results_dir/equal/"
greedy_results_dir = "$results_dir/greedy/"

fraction_reduction = 0.0
println("\n===== fraction_reduction = $fraction_reduction =====")
fr_system = build_CATS_system(; fraction_reduction =fraction_reduction, start_time = start_time, pmin_scale = 1.0)

fr_tag     = "fr$(round(Int, fraction_reduction*100))"
equal_dir  = joinpath(results_dir, "equal_$fr_tag")
greedy_dir = joinpath(results_dir, "greedy_$fr_tag")
mkpath(equal_dir)
mkpath(greedy_dir)

run_equal_daily_budget(template, deepcopy(fr_system), solver_xpress, start_time, equal_dir, selected_gen_names, selected_hydro_details)

run_greedy_daily_budget(deepcopy(fr_system), selected_gen_names, selected_hydro_details, start_time, solver_xpress, equal_dir, greedy_dir)
