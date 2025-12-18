ENV["XPRESSDIR"] = "$(homedir())/Documents/Xpress"
# I usually just use PowerSimulations.jl/test environment to run these scripts, but
# this should set it up from scratch:
# using Pkg
# Pkg.activate(".")
# Pkg.instantiate()
# Pkg.add.(["PowerSystems", "PowerSimulations", "HydroPowerSimulations", 
# "PowerSystemCaseBuilder", "Ipopt", "Xpress", "Dates", "JuMP", "PowerFlows",
# "PowerNetworkMatrices"])
using PowerSystems
using PowerSimulations
using HydroPowerSimulations
using PowerSystemCaseBuilder
using Ipopt
using Xpress
using Dates
using JuMP
using PowerFlows
import PowerNetworkMatrices: VirtualPTDF
# using Ipopt

const PSI = PowerSimulations

mip_gap = 0.5

# NOTE: not sure doing UC here actually makes sense. CATS system was built for ED and PF,
# not for UC.

CATS_DIR = "$(homedir())/Documents/julia/CATS-project-2/CATS-CaliforniaTestSystem/Sienna/"
include(joinpath(CATS_DIR, "build_CATS.jl"))
system = build_CATS_system(first_order = true)
 

system_ed = deepcopy(system)

# for multiple time steps:
transform_single_time_series!(
    system,
    Hour(2),  # horizon
    Hour(2),   # interval
);

transform_single_time_series!(
    system_ed,
    Hour(1),  # horizon
    Hour(1),  # interval
);

ptdf = VirtualPTDF(system;
    tol=0.0001,
    max_cache_size=10000,
    # radial_network_reduction = RadialNetworkReduction(PNM.IncidenceMatrix(sys)), #Jose's idea
)

network_model_uc = NetworkModel(PTDFPowerModel; PTDF_matrix=ptdf)
network_model_ed = NetworkModel(ACPPowerModel; use_slacks=true, power_flow_evaluation=PowerFlows.ACPowerFlow(; calculate_loss_factors=true))
#network_model_ed = NetworkModel(ACPPowerModel; use_slacks=true)

template_uc = ProblemTemplate(network_model_uc)
set_device_model!(template_uc, ThermalStandard, ThermalBasicUnitCommitment)
set_device_model!(template_uc, RenewableDispatch, RenewableFullDispatch)
set_device_model!(template_uc, HydroDispatch, HydroDispatchRunOfRiver)
set_device_model!(template_uc, PowerLoad, StaticPowerLoad)
set_device_model!(template_uc, Line, StaticBranch)
set_device_model!(template_uc, Transformer2W, StaticBranch)


template_ed = ProblemTemplate(network_model_ed)
set_device_model!(template_ed, ThermalStandard, ThermalBasicDispatch)
set_device_model!(template_ed, RenewableDispatch, RenewableFullDispatch)
set_device_model!(template_ed, HydroDispatch, HydroDispatchRunOfRiver)
set_device_model!(template_ed, PowerLoad, StaticPowerLoad)
set_device_model!(template_ed, Line, StaticBranchUnbounded)
set_device_model!(template_ed, Transformer2W, StaticBranchUnbounded)

# solver_highs = optimizer_with_attributes(HiGHS.Optimizer, "mip_rel_gap" => mip_gap) #, "presolve" => "off" ) 

solver_xpress = JuMP.optimizer_with_attributes(Xpress.Optimizer, "MIPRELSTOP" => 0.01)


solver_ipopt = JuMP.optimizer_with_attributes(Ipopt.Optimizer,
    "print_level" => 5,
    "tol" => 1e-3,
    "acceptable_tol" => 1e-3,
)


problem_uc = DecisionModel(
    template_uc,
    system;
    optimizer=solver_xpress,
    optimizer_solve_log_print=true,
    calculate_conflict=true,
    name="UC"
)

problem_ed = DecisionModel(
    template_ed,
    system_ed;
    optimizer=solver_ipopt,
    optimizer_solve_log_print=true,
    name="ED"
)

models = SimulationModels(;
    decision_models=[
        problem_uc,
        problem_ed,
    ],
)

sequence = SimulationSequence(;
    models=models,
    feedforwards=Dict(
        "ED" => [
            SemiContinuousFeedforward(;
                component_type=ThermalStandard,
                source=OnVariable,
                affected_values=[ActivePowerVariable],
            ),
        ],
    ),
    ini_cond_chronology=InterProblemChronology(),
)

sim = Simulation(;
    name="no_cache",
    steps=2,
    models=models,
    sequence=sequence,
    simulation_folder=mktempdir(),
)

build_out = build!(sim)
@assert build_out == PSI.SimulationBuildStatus.BUILT

execute!(sim)

exports = Dict(
    "models" => [
        Dict(
            "name" => "UC",
            "store_all_variables" => true,
            "store_all_parameters" => true,
            "store_all_duals" => true,
            "store_all_aux_variables" => true,
        ),
        Dict(
            "name" => "ED",
            "store_all_variables" => true,
            "store_all_parameters" => true,
            "store_all_duals" => true,
            "store_all_aux_variables" => true,
        ),
    ],
    "path" => mktempdir(),
    "optimizer_stats" => true,
)

# Open a file to capture output
#=
open("ipopt_log.txt", "w") do io
    redirect_stdout(io)  # Redirect standard output
    redirect_stderr(io)  # Redirect error output (failure messages)

    try
        execute_out = execute!(sim; exports=exports, in_memory=true)
        @assert execute_out == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    catch err
        println("Solver failed: ", err)
    end
end
=#

results = SimulationResults(sim);
uc_results = get_decision_problem_results(results, "UC")
ed_results = get_decision_problem_results(results, "ED")

vduc = read_variables(uc_results)
on = vduc["OnVariable__ThermalStandard"]

vd = read_variables(ed_results)

ad = read_aux_variables(ed_results)

# reading the loss factors from ED results:
df = ad["PowerFlowLineActivePowerFromTo__Line"]
lf_res = ad["PowerFlowLossFactors__ACBus"]