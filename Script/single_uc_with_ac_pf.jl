ENV["XPRESSDIR"] = "$(homedir())/Documents/Xpress"

# if environmnent isn't set up, see top of Script/uc_ed_with_ac_pf.jl for setup instructions
using PowerSystems
using PowerSimulations
using HydroPowerSimulations
using PowerSystemCaseBuilder
using PowerFlows
using Ipopt
using Xpress
using Dates
using JuMP
using PowerFlows
import PowerNetworkMatrices: VirtualPTDF
 
const PSI = HydroPowerSimulations
mip_gap = 0.5
 
# CATS_DIR = "/home/lkiernan/pf-in-the-loop/building-CATS-in-Sienna/"
# CATS_DIR = "$(homedir())/Documents/julia/CATS-project/building-CATS-in-Sienna/"

# repo: https://github.com/NREL-Sienna/CATS-CaliforniaTestSystem/tree/lk/redo-Sienna-scripts-rebase
CATS_DIR = "$(homedir())/Documents/julia/CATS-project-2/CATS-CaliforniaTestSystem/Sienna/"
include(joinpath(CATS_DIR, "build_CATS.jl"))
system = build_CATS_system(first_order = true)
 

arc_to_line_impedance = Dict{Tuple{Int, Int}, ComplexF64}()
for line in get_components(Line, system)
    arc = get_arc(line)
    arc_tuple = (arc.from.number, arc.to.number)
    if haskey(arc_to_line_impedance, arc_tuple)
        set_r!(line, real(arc_to_line_impedance[arc_tuple]))
        set_x!(line, imag(arc_to_line_impedance[arc_tuple]))
    else
        @assert !haskey(arc_to_line_impedance, reverse(arc_tuple))
        arc_to_line_impedance[arc_tuple] = get_r(line) + im * get_x(line)
    end
end
 
# for multiple time steps:
transform_single_time_series!(
    system,
    Hour(2),  # horizon
    Hour(2),   # interval
);
ptdf = VirtualPTDF(system;
    tol=0.0001,
    max_cache_size=10000,
    # radial_network_reduction = RadialNetworkReduction(PNM.IncidenceMatrix(sys)), #Jose's idea
)
 
template_uc = ProblemTemplate(NetworkModel(PTDFPowerModel; use_slacks=true, duals=[CopperPlateBalanceConstraint], power_flow_evaluation=PowerFlows.ACPowerFlow{TrustRegionACPowerFlow}(; calculate_loss_factors=true)))
 
set_device_model!(template_uc, ThermalStandard, ThermalBasicUnitCommitment)
set_device_model!(template_uc, RenewableDispatch, RenewableFullDispatch)
set_device_model!(template_uc, HydroDispatch, HydroDispatchRunOfRiver)
set_device_model!(template_uc, PowerLoad, StaticPowerLoad)
set_device_model!(template_uc, Line, StaticBranch)
set_device_model!(template_uc, Transformer2W, StaticBranch)
 
solver_xpress = JuMP.optimizer_with_attributes(Xpress.Optimizer, "MIPRELSTOP" => 0.01, "MAXTIME" => 60*60)
 
problem_uc = DecisionModel(
    template_uc,
    system;
    optimizer=solver_xpress,
    optimizer_solve_log_print=true,
    calculate_conflict=true,
    name="UC"
)
 
 
build!(problem_uc, output_dir=mktempdir())
 
solve!(problem_uc)
 
results_uc_1 = OptimizationProblemResults(problem_uc)
aux_variables = read_aux_variables(results_uc_1)
df = aux_variables["PowerFlowLineActivePowerFromTo__Line"]
DF = aux_variables["PowerFlowLossFactors__ACBus"]