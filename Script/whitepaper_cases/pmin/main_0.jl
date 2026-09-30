
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

const PSI = PowerSimulations

SCENARIO = "rcp45hotter"
BASE_DIR = joinpath(@__DIR__, "../../..")
HYDRO_DATA_DIR = "$BASE_DIR/hydro_data/2025_scenarios/"
CATS_DIR = "$BASE_DIR/Sienna/"
gen_csv = CSV.read("$BASE_DIR/GIS/CATS_gens.csv", DataFrame)

include(joinpath(CATS_DIR, "build_CATS_2025_whitepaper.jl"))
include("equal_daily_budget.jl")
include("greedy_daily_budget.jl")
include(joinpath(BASE_DIR, "Script", "whitepaper_cases", "calculate_budget.jl"))

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

pmin_scale = 0.0

load_skew = 0.0
load_scale = 1.0

tag     = "ps$(round(Int, pmin_scale*100))"

# Daylight saving days - 3/9 and 11/2 - skip weeks containing these days
################################################
# 1/1, 1/8, 1/15, 1/22, 1/29, 2/5, 2/12, 2/19, 2/26
HORIZON_WEEKS = 9
start_time = DateTime("2025-01-01T00:00:00")
results_dir = "$BASE_DIR/results/whitepaper_results/pmin/$(Dates.format(start_time, "yyyy-mm-dd"))/"
equal_results_dir = "$results_dir/equal/"
greedy_results_dir = "$results_dir/greedy/"


println("\n===== pmin_scale = $pmin_scale =====")
cats_system = build_CATS_system(; fraction_reduction = load_skew, start_time = start_time, pmin_scale = pmin_scale, load_scale = load_scale)


equal_dir  = joinpath(results_dir, "equal_$tag")
greedy_dir = joinpath(results_dir, "greedy_$tag")
mkpath(equal_dir)
mkpath(greedy_dir)


run_equal_daily_budget(template, deepcopy(cats_system), solver_xpress, start_time, equal_dir, selected_gen_names, selected_hydro_details)

run_greedy_daily_budget(deepcopy(cats_system), selected_gen_names, selected_hydro_details, start_time, solver_xpress, equal_dir, greedy_dir)

################################################
# 3/12, 3/19, 3/26, 4/2, 4/9, 4/16, 4/23, 4/30, 5/7, 5/14, 5/21, 5/28,
# 6/4, 6/11, 6/18, 6/25, 7/2, 7/9, 7/16, 7/23, 7/30, 8/6, 8/13, 8/20, 8/27,
# 9/2, 9/9, 9/16, 9/23, 9/30, 10/8, 10/15, 10/22
HORIZON_WEEKS = 33
start_time = DateTime("2025-03-12T00:00:00")
results_dir = "$BASE_DIR/results/whitepaper_results/pmin/$(Dates.format(start_time, "yyyy-mm-dd"))/"
equal_results_dir = "$results_dir/equal/"
greedy_results_dir = "$results_dir/greedy/"


println("\n===== pmin_scale = $pmin_scale =====")
cats_system = build_CATS_system(; fraction_reduction = load_skew, start_time = start_time, pmin_scale = pmin_scale, load_scale = load_scale)

equal_dir  = joinpath(results_dir, "equal_$tag")
greedy_dir = joinpath(results_dir, "greedy_$tag")
mkpath(equal_dir)
mkpath(greedy_dir)


run_equal_daily_budget(template, deepcopy(cats_system), solver_xpress, start_time, equal_dir, selected_gen_names, selected_hydro_details)

run_greedy_daily_budget(deepcopy(cats_system), selected_gen_names, selected_hydro_details, start_time, solver_xpress, equal_dir, greedy_dir)

################################################
# 11/5, 11/12, 11/19, 11/26, 12/3, 12/10, 12/17, 12/24
HORIZON_WEEKS = 8
start_time = DateTime("2025-11-05T00:00:00")
results_dir = "$BASE_DIR/results/whitepaper_results/pmin/$(Dates.format(start_time, "yyyy-mm-dd"))/"
equal_results_dir = "$results_dir/equal/"
greedy_results_dir = "$results_dir/greedy/"


println("\n===== pmin_scale = $pmin_scale =====")
cats_system = build_CATS_system(; fraction_reduction = load_skew, start_time = start_time, pmin_scale = pmin_scale, load_scale = load_scale)


equal_dir  = joinpath(results_dir, "equal_$tag")
greedy_dir = joinpath(results_dir, "greedy_$tag")
mkpath(equal_dir)
mkpath(greedy_dir)


run_equal_daily_budget(template, deepcopy(cats_system), solver_xpress, start_time, equal_dir, selected_gen_names, selected_hydro_details)

run_greedy_daily_budget(deepcopy(cats_system), selected_gen_names, selected_hydro_details, start_time, solver_xpress, equal_dir, greedy_dir)
