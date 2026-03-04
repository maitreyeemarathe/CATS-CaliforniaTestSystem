using Distributed
global USERNAME = "lkiernan"
global CATS_DIR = "/scratch/$USERNAME/CATS-CaliforniaTestSystem"
global DATA_DIR = "/scratch/$USERNAME/CATS-CaliforniaTestSystem/data"
global SMALL_TEST = false
addprocs(10)
# make sure globals are defined on all workers
@everywhere global CATS_DIR = $CATS_DIR
@everywhere global DATA_DIR = $DATA_DIR
@everywhere global SMALL_TEST = $SMALL_TEST
@everywhere begin
    global HSL = false
    using Pkg
    Pkg.activate(CATS_DIR)
    
    # using MKL
    #using LinearAlgebra
    #BLAS.set_num_threads(1)
    if HSL
        #Pkg.develop(path = "/home/jlara/HSL_jll.jl-2023.11.7")
        using HSL_jll
    end
    using PowerModels
    using JuMP
    using CSV, JSON
    using DataFrames
    using Ipopt
    using Tables
    include("$CATS_DIR/Script/test_eval_functions.jl")

    function eval(range, NetworkData_input, load_scenarios, load_mapping, HourlyData2019, gen_data)
        @info "begin eval call $(range)"
        solver_attr = if HSL
            [
                "print_level" => 5,
                "hsllib" => HSL_jll.libhsl_path,
                "linear_solver" => "ma57"
            ]
        else
            ["print_level" => 5]
        end
        solver = JuMP.optimizer_with_attributes(() -> Ipopt.Optimizer(),
            solver_attr...
        )

        @info "Ipopt Instantiated"
        NetworkData = deepcopy(NetworkData_input)
        @info "NetworkData initialized"

        N = SMALL_TEST ? 10 : 8760
        load_scenarios = load_scenarios[:,1:N]
        condenserIndices = [g for g in 1:size(gen_data)[1] if occursin("condenser", lowercase(gen_data.FuelType[g]))]
        NUM_GENS = size(gen_data)[1]

        SolarGenIndex = [g for g in 1:NUM_GENS if occursin("solar", lowercase(gen_data.FuelType[g]))]
        WindGenIndex= [g for g in 1:NUM_GENS if occursin("wind", lowercase(gen_data.FuelType[g]))]

        SolarCap = sum(g["pmax"] for (i,g) in NetworkData["gen"] if g["index"] in SolarGenIndex)
        WindCap = sum(g["pmax"] for (i,g) in NetworkData["gen"] if g["index"] in WindGenIndex)

        SolarGeneration = HourlyData2019[1:N,"Solar"]
        WindGeneration = HourlyData2019[1:N,"Wind"]
        PMaxOG = [NetworkData["gen"][string(i)]["pmax"] for i in 1:NUM_GENS]
        @info "started $(range)"
        for k in range
            # Change renewable generators' pg for the current scenario
            update_rgen!(k,NetworkData,gen_data,SolarGeneration,WindGeneration,PMaxOG,SolarCap,WindCap)
            #println(sum(NetworkData["gen"][string(i)]["pmax"] for i in 1:size(gen_data)[1]))

            # Change load buses' Pd and Qd for the current scenario
            update_loads!(k, load_scenarios, load_mapping, NetworkData)

            # Run power flow
            pm = instantiate_model(NetworkData, ACPPowerModel, PowerModels.build_opf)
            penalize_reactive_power!(pm, condenserIndices)
            @info "Solving case $k in range $range"
            solution = optimize_model!(pm, optimizer=solver)

            #Save solution dictionary to JSON
            # push!(results,  solution["termination_status"])
            #nextRow = solution["solution"]["gen"][FIRST_CONDENSER:NUM_GENS]
            if solution["termination_status"] == LOCALLY_INFEASIBLE
                @error "$k Infeasible skipping write"
                tmp_condenserReactiveFlows = Tables.table([k, [-99 for x in condenserIndices]...]')
                CSV.write("SimplifiedcondenserReactiveFlows_lb.csv", tmp_condenserReactiveFlows; append=true)
            else
                tmp_condenserReactiveFlows = Tables.table([k, [round(solution["solution"]["gen"]["$x"]["qg"], digits = 4) for x in condenserIndices]...]')
                CSV.write("SimplifiedcondenserReactiveFlows_lb.csv", tmp_condenserReactiveFlows; append=true)
                @info "Wrote case $k in range $range"
            end
        end
    end
end

split_N = SMALL_TEST ? 1 : 120
TOTAL = SMALL_TEST ? 10 : 8760
splits = [range(N, N + split_N - 1) for N in 1:split_N:TOTAL]

load_scenarios = CSV.read("$DATA_DIR/Load_Agg_Post_Assignment_v3_latest.csv",header = false, DataFrame)
HourlyData2019 = CSV.read("$DATA_DIR/HourlyProduction2019.csv",DataFrame)
gen_data = CSV.read("$CATS_DIR/GIS/SimplifiedCATS_gens.csv",DataFrame)
condenserIndices = [g for g in 1:size(gen_data)[1] if occursin("condenser", lowercase(gen_data.FuelType[g]))]

condenserReactiveFlows = DataFrame("timestep" => Int[],
("gen $x" => Float64[] for x in condenserIndices)...)
CSV.write("SimplifiedcondenserReactiveFlows_lb.csv", condenserReactiveFlows)

NetworkData = PowerModels.parse_file("$CATS_DIR/MATPOWER/SimplifiedCaliforniaTestSystem.m")
load_mapping = map_buses_to_loads(NetworkData)
update_lower_bound_voltages!(NetworkData, condenserIndices)

@info "finished reading the data"
pmap(x-> eval(x, NetworkData, load_scenarios, load_mapping, HourlyData2019, gen_data), splits)
