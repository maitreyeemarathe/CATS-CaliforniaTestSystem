using PowerSystems
using CSV
using DataFrames
using Dates
using TimeSeries
using JLD2

const PSY = PowerSystems

include(joinpath(@__DIR__, "parse_matpower.jl"))
include(joinpath(@__DIR__, "generator_types.jl"))
BASE_DIR = joinpath(@__DIR__, "..")

VALIDITY_CHECKS = true

DATA_DIR = joinpath(BASE_DIR, "data")
additional_fields(::Type{T}) where T<:StaticInjection = Dict{Symbol, Any}()

additional_fields(::Type{RenewableDispatch}) = Dict{Symbol, Any}(
    :power_factor => 0.95,
    :operation_cost => RenewableGenerationCost(nothing),
)

additional_fields(::Type{HydroDispatch}) = Dict{Symbol, Any}(
    :operation_cost => HydroGenerationCost(nothing),
)

additional_fields(::Type{Source}) = Dict{Symbol, Any}(
    :operation_cost => ImportExportCost(nothing),
)

additional_fields(::Type{EnergyReservoirStorage}) = Dict{Symbol, Any}(
    :storage_technology_type => StorageTech.LIB,
    :storage_capacity => 0.0,
    :storage_level_limits => (0.0, 1.0),
    :initial_storage_capacity_level => 0.0,
    :input_active_power_limits => (0.0, 0.0),
    :output_active_power_limits => (0.0, 0.0),
    :efficiency => (1.0, 1.0),
)

# most things have a prime mover type...
function maybe_add_prime_mover_type!(
    d::Dict{Symbol, Any},
    pm_type::PSY.PrimeMovers,
    ::Type{<:StaticInjection}
)
    d[:prime_mover_type] = pm_type
end

# ...except for imports and SCs.
maybe_add_prime_mover_type!(
    ::Dict{Symbol, Any},
    ::PSY.PrimeMovers,
    ::Type{<:Union{Source, SynchronousCondenser}}
) = nothing

"""
A somewhat hacky way of converting a ThermalStandard generator to another type of generator.
"""
function try_convert(T::Type{<:StaticInjection}, gen::ThermalStandard, pm_type::PSY.PrimeMovers)
    commonKeys = intersect(fieldnames(ThermalStandard), fieldnames(T))
    old_data = Dict(key=>getfield(gen, key) for key ∈ commonKeys)
    delete!.((old_data,), (:operation_cost, :internal, :prime_mover_type))
    maybe_add_prime_mover_type!(old_data, pm_type, T)
    return T(;
        old_data...,
        additional_fields(T)...
    )
end

function fix_missings!(data::Vector{Union{Float64, Missing}})
    last_valid = 0.0
    for i in eachindex(data)
        if ismissing(data[i]) || isnan(data[i])
            data[i] = last_valid
        else
            last_valid = data[i]
        end
    end
end

fix_missings!(::Vector{Float64}) = nothing # no-op

attach_cost!(gen::ThermalStandard, cost::CostCurve) =
    set_operation_cost!(gen, ThermalGenerationCost(cost, 0.0, 0, 0.0))

attach_cost!(gen::ThermalStandard, ::Nothing) =
    set_operation_cost!(gen, ThermalGenerationCost(nothing))

attach_cost!(gen::RenewableDispatch, cost::CostCurve) =
    set_operation_cost!(gen, RenewableGenerationCost(cost))

attach_cost!(gen::RenewableDispatch, ::Nothing) =
    set_operation_cost!(gen, RenewableGenerationCost(nothing))

attach_cost!(gen::HydroDispatch, cost::CostCurve) = 
    set_operation_cost!(gen, HydroGenerationCost(cost, 0.0))

attach_cost!(gen::HydroDispatch, ::Nothing) = 
    set_operation_cost!(gen, HydroGenerationCost(nothing))

attach_cost!(gen::Source, cost::CostCurve) = 
    set_operation_cost!(gen, ImportExportCost(; import_offer_curves = cost))

attach_cost!(gen::Source, ::Nothing) = 
    set_operation_cost!(gen, ImportExportCost(; import_offer_curves = zero(CostCurve)))

attach_cost!(gen::EnergyReservoirStorage, cost::CostCurve) = 
    set_operation_cost!(gen, StorageCost(cost, cost, 0, 0.0, 0, 0, 0))

attach_cost!(gen::EnergyReservoirStorage, ::Nothing) =
    set_operation_cost!(gen, StorageCost())

function convert_to_battery(system::System,
    gen::StaticInjection,
    k_p::Float64,
    k_q::Union{Float64, Nothing} = nothing
)
    battery_gen = try_convert(EnergyReservoirStorage, gen, PrimeMovers.BA)
    remove_component!(system, gen)
    add_component!(system, battery_gen)
    # same rating as gen
    rating = get_rating(battery_gen)
    # active power: initial 0.0, limits (0, k_p * rating)
    set_storage_capacity!(battery_gen, k_p*rating)
    set_active_power!(battery_gen, 0.0)
    set_initial_storage_capacity_level!(battery_gen, 0.0)
    p_limits = (min = 0.0, max = k_p*rating)
    set_input_active_power_limits!(battery_gen, p_limits)
    set_output_active_power_limits!(battery_gen, p_limits)
    # reactive power: initial 0.0, limits (-k_q * rating, k_q * rating)
    if k_q !== nothing
        q_limits = (min = -k_q*rating, max = k_q*rating)
        set_reactive_power!(battery_gen, 0.0)
        set_reactive_power_limits!(battery_gen, q_limits)
    end
end

function build_CATS_system(;
    matpower_file::String = "$BASE_DIR/MATPOWER/CaliforniaTestSystem.m",
    generator_csv::String = "$BASE_DIR/GIS/CATS_gens.csv", # oh I think the problem is that we've changed this for the
    # simplified system.
    timeseries_csv::String = joinpath(DATA_DIR, "HourlyProduction2019.csv"),
    load_timeseries::String = joinpath(DATA_DIR, "Load_Agg_Post_Assignment_v3_latest.csv"),
    first_order::Bool = false,
    remove_scs::Bool = true,
)
    if !isfile(timeseries_csv) || !isfile(load_timeseries)
        error("Data directory $DATA_DIR does not contain expected data. Please download " *
            "time series (HourlyProduction2019.csv) and load (Load_Agg_Post_Assignment_v3_"*
            "latest.csv) data from the Google drive linked at "*
            "https://github.com/WISPO-POP/CATS-CaliforniaTestSystem?tab=readme-ov-file"
        )
    end 


    system = System(matpower_file)
    # everything in the CSV is in natural units.
    set_units_base_system!(system, "NATURAL_UNITS")
    n_buses = length(get_components(Bus, system))
    n_gens = length(get_components(ThermalStandard, system))
    # n_loads = length(get_components(PowerLoad, system))
    gen_csv = CSV.read(generator_csv, DataFrame)
    gen_df = generator_data_to_dataframe(matpower_file)


    scs_convert_df = CSV.read(joinpath(BASE_DIR, "data", "scs_to_storage.csv"), DataFrame)
    scs_convert = Set{String}([replace(x, " " => "-") for x in scs_convert_df.generator])
    scs_df = CSV.read(joinpath(BASE_DIR, "data", "scs_to_keep.csv"), DataFrame)
    scs_keep = Set{String}([replace(x, " " => "-") for x in scs_df.generator])
    original_sc_count = 0
    converted_scs = 0
    kept_sc_count = 0

    # STEP 1: fix gen types. All are parsed as ThermalStandard, but some are hydro or renewable.
    for (i, row) in enumerate(eachrow(gen_csv))
        gen_name = "gen-$(i)"
        gen = get_component(ThermalStandard, system, gen_name)
        @assert !isnothing(gen) "Generator $gen_name not found in system."
        gen_type  = row[:FuelType]
        pm_type = PM_TYPE_DICT[gen_type]
        if occursin("Hydroelectric", gen_type)
            hydro_gen = try_convert(HydroDispatch, gen, pm_type)
            remove_component!(system, gen)
            add_component!(system, hydro_gen)
        elseif occursin("Solar", gen_type) || occursin("Wind", gen_type)
            renewable_gen = try_convert(RenewableDispatch, gen, pm_type)
            remove_component!(system, gen)
            add_component!(system, renewable_gen)
        elseif gen_type == "IMPORT"
            import_gen = try_convert(Source, gen, pm_type)
            remove_component!(system, gen)
            add_component!(system, import_gen)
        elseif gen_type == "Synchronous Condenser"
            original_sc_count += 1
            # the SCs-to-keep list here is subject to manual tuning: run on HPC, 
            # penalizing reactive power at SCs to CSV. See write_sc_bus.jl for details.
            # there's a handful of the "keep" ones that could be converted to fixed admittance, 
            # --see fixed_admittance_candidates.csv--but it's only ~25 of 150.
            if gen_name ∈ scs_convert
                convert_to_battery(system, gen, 3.0, 3.0)
                converted_scs += 1
            elseif gen_name ∈ scs_keep
                sc_gen = try_convert(SynchronousCondenser, gen, pm_type)
                remove_component!(system, gen)
                add_component!(system, sc_gen)
                kept_sc_count += 1
            else
                # if it's not in either list, remove it entirely.
                remove_component!(system, gen)
            end
        elseif occursin("Batteries", gen_type)
            convert_to_battery(system, gen, 3.0)
        else
            # the rest remain ThermalStandard
            # fields unique to thermal: fuel type, ramp limits, time limits
            set_prime_mover_type!(gen, pm_type)
            if occursin("Natural Gas", gen_type)
                set_fuel!(gen, ThermalFuels.NATURAL_GAS)
            elseif gen_type in OTHER_TYPES
                set_fuel!(gen, ThermalFuels.OTHER)
            else
                set_fuel!(gen, FUELS_DICT[gen_type])
            end

            pm_type = get_prime_mover_type(gen)
            fuel_type = get_fuel(gen)
            maxPower = get_max_active_power(gen)

            if (pm_type, fuel_type) in keys(RAMP_LIMIT_DICT)
                WECC_string = PSY_TO_WECC_DICT[(pm_type, fuel_type)]
                size_string = get_size(WECC_string, maxPower)
                set_ramp_limits!(gen, RAMP_LIMIT_DICT[(pm_type, fuel_type)])
                set_time_limits!(gen, DURATION_LIMIT_DICT[(WECC_string, size_string)])
            elseif pm_type == PrimeMovers.ST
                # Other steam turbine movers use the same scheme as coal
                size_string = get_size("CLLIG", maxPower)
                set_ramp_limits!(gen, RAMP_LIMIT_DICT[(PrimeMovers.ST, ThermalFuels.COAL)])
                set_time_limits!(gen, DURATION_LIMIT_DICT[("CLLIG", size_string)])
            elseif pm_type == PrimeMovers.IC
                # IC engines without explicit entries - use generic internal combustion values
                # TODO CoPilot generated: are these reasonable?
                set_ramp_limits!(gen, (up = 0.01, down = 0.01))
                set_time_limits!(gen, (up = 1.0, down = 1.0))
            elseif pm_type == PrimeMovers.OT
                # Other types without explicit entries - use conservative values
                # TODO CoPilot generated: are these reasonable?
                set_ramp_limits!(gen, (up = 0.01, down = 0.01))
                set_time_limits!(gen, (up = 1.0, down = 1.0))
            end
        end

        # comp may be different than gen if we converted it
        if gen_type == "Synchronous Condenser" && !(gen_name in scs_keep) && !(gen_name in scs_convert)
            continue
        end
        comp  = get_component(StaticInjection, system, gen_name)
        if !(comp isa Source) && !(comp isa SynchronousCondenser) && !(comp isa EnergyReservoirStorage)
            set_prime_mover_type!(comp, PM_TYPE_DICT[row[:FuelType]])
        elseif comp isa SynchronousCondenser && gen_name in scs_convert
            set_prime_mover_type!(comp, PrimeMovers.BA)
        end

        # some data validity checks on the specific row
        # (if it's a system wide check, put it outside the for loop)
        if VALIDITY_CHECKS
            matpower_row = gen_df[i, :]
            if !(comp isa SynchronousCondenser || comp isa EnergyReservoirStorage)
                @assert isapprox(get_active_power(comp), row[:Pg])
                @assert isapprox(row[:Pmax], matpower_row[:Pmax])
                @assert isapprox(row[:Pmin], matpower_row[:Pmin])
            end
            if !(gen_name in scs_convert)
                @assert isapprox(get_reactive_power(comp), row[:Qg])
                @assert isapprox(row[:Pg], matpower_row[:Pg])
                @assert isapprox(row[:Qg], matpower_row[:Qg])

                @assert isapprox(get_reactive_power_limits(comp).max, row[:Qmax])
                @assert isapprox(get_reactive_power_limits(comp).min, row[:Qmin])
            end

            if !(comp isa RenewableDispatch) && !(comp isa SynchronousCondenser) && !(comp isa EnergyReservoirStorage)
                @assert isapprox(get_active_power_limits(comp).max, row[:Pmax])
                @assert isapprox(get_active_power_limits(comp).min, row[:Pmin])
            end
        end
    end

    @assert converted_scs == length(scs_convert)
    @assert kept_sc_count == length(scs_keep)
    if VALIDITY_CHECKS
        # check first one
        @assert n_gens == nrow(gen_csv)
        first_gen = get_component(StaticInjection, system, "gen-1")
        @assert first_gen isa HydroDispatch
        @assert isapprox(get_reactive_power_limits(first_gen).max, 18.7771429)
        @assert get_number(get_bus(first_gen)) == 745
        # check last non-SC non-import generator.
        n_imports = length(get_components(Source, system))
        last_gen_index = n_gens - n_imports - original_sc_count
        last_gen = get_component(StaticInjection, system, "gen-$(last_gen_index)")
        @assert last_gen isa RenewableDispatch && get_prime_mover_type(last_gen) == PrimeMovers.PVe
        
        first_import = get_component(Source, system, "gen-$(last_gen_index + 1)")
        @assert !isnothing(first_import)
    end

    # STEP 2: attach timeseries data
    col_to_type_and_kwargs = Dict(
        "Solar" => (RenewableDispatch, Dict(:prime_mover_type => PrimeMovers.PVe)),
        "Wind" => (RenewableDispatch, Dict(:prime_mover_type => PrimeMovers.WT)),
        "Large Hydro" => (HydroDispatch, Dict()),
        "Nuclear" => (ThermalStandard, Dict(:fuel => ThermalFuels.NUCLEAR)),
        # here I should really have "fuel not nuclear", but I'll special-case it.
        "Thermal" => (ThermalStandard, Dict()),
        "Imports" => (Source, Dict())
    )
    if isnothing(load_timeseries)
        col_to_type_and_kwargs["Load"] = (PowerLoad, Dict())
    end

    ts_df = CSV.read(timeseries_csv, DataFrame; 
        header=1,
        types=(i, name) -> i <= 3 ? String : Float64,
    )

    timestamps = range(DateTime("2019-01-01T00:00:00"); step = Hour(1), length = 24*365)
    @assert length(timestamps) == nrow(ts_df) "Number of timestamps ($(length(timestamps))) " *
        "does not match number of rows in time series data ($(nrow(ts_df)))."
    for (col_name, col_info) in col_to_type_and_kwargs

        comp_type, kwargs = col_info
        if col_name == "Thermal"
            filter_func = comp -> get_fuel(comp) != ThermalFuels.NUCLEAR
        else
            filter_func = comp -> all(getfield(comp, key) == value for (key, value) in kwargs)
        end
        comps = get_components(filter_func, comp_type, system)

        # values in csv are totals, across all components of that type: we want
        # to rescale per-component by get_max_active_power(comp) / total_max_active_power.
        # so I'll rescale the csv's totals by 1 / total_max_active_power,
        # then rescale per-component by get_max_active_power(comp).

        ts_values = collect(ts_df[!, col_name])
        fix_missings!(ts_values)
        ts_values = convert(Vector{Float64}, ts_values)
        total_max_active_power = sum(get_max_active_power(comp) for comp in comps)
        ts_values ./= total_max_active_power
        if comp_type != Source
            # imports can be negative (i.e., exports)
            @assert all(ts_values .>= 0.0) "time series goes negative for some time " *
                "steps for $comp_type"
        elseif comp_type != RenewableDispatch && comp_type != Source
            total_min_active_power = sum(get_active_power_limits(comp).min for comp in comps)
            renormalized_min = total_min_active_power / total_max_active_power
            @assert all(ts_values .>= renormalized_min) "time series goes below min " *
                "generation for some time steps for $comp_type"
        end
        if any(ts_values .> 1.0)
            scale_up = maximum(ts_values)
            @warn "total generation (from time series csv) exceeds total of max active "*
                 "powers for some time steps for $comp_type; multiplying max active " *
                 "powers for those components by $(round(scale_up; sigdigits = 3))"
            ts_values ./= scale_up
            for comp in comps
                set_active_power_limits!(
                    comp,
                    (min = get_active_power_limits(comp).min,
                     max = get_active_power_limits(comp).max * scale_up)
                )
            end
            @assert all(ts_values .<= 1.0)
        end
	    ts = SingleTimeSeries(;
           name = "max_active_power",
           data = TimeArray(timestamps, ts_values),
           scaling_factor_multiplier = get_max_active_power,
        )
        associations = (TimeSeriesAssociation(comp, ts) for comp in comps)
        bulk_add_time_series!(system, associations)

        # data validity check
        if VALIDITY_CHECKS
            # total across comps should match csv value.
            validity_check_row = 9
            total_generation = 0.0
            for comp in comps
                ts_comp = get_time_series(SingleTimeSeries, comp, "max_active_power")
                total_generation += first(get_time_series_values(
                    comp,
                    ts_comp;
                    start_time = timestamps[validity_check_row],
                    len = 1
                ))
            end
            @assert isapprox(total_generation, ts_df[validity_check_row, col_name])
        end
    end
    # all renewables should have time series values
    @assert all(comp -> has_time_series(comp, SingleTimeSeries, "max_active_power"),
                    get_components(RenewableDispatch, system))

    # STEP 2B: attach per-load time series.
    # Try to load from JLD2 first.
    jld2_file = replace(load_timeseries, ".csv" => ".jld2")
    if endswith(load_timeseries, ".jld2")
        jld2_file = load_timeseries
    end
    
    load_data = nothing
    if isfile(jld2_file)
        println("Loading time series data from JLD2: $jld2_file")
        load_data = load(jld2_file, "load_data")
        if VALIDITY_CHECKS
            # first row of CSV should match first column of load_data.
            first_row_csv = first(CSV.Rows(load_timeseries; header=false))
            first_row_complex = parse.(ComplexF64, collect(first_row_csv))
            @assert all(isapprox.(view(load_data, :, 1), first_row_complex))
        end
    elseif isfile(load_timeseries)
        # I could load from CSV, but users probably don't actually want to do that.
        error("Please convert CSV to JLD2 first using convert_load_csv_to_jld2.jl." *
            " (It takes ~10 minutes to load the CSV, versus ~10 seconds for JLD2, " *
            "so writing that intermediate JDL2 file saves significant build time.)")
    end
    @assert size(load_data, 2) == n_buses "Number of columns in load time series data " *
        "($(ncol(load_data))) does not match number of buses ($n_buses)"
    
    increased = 0
    most_increase = 0.0
    begin_time_series_update(system) do
        for i in 1:n_buses
            load_name = "bus$i"
            load = get_component(PowerLoad, system, load_name)
            
            row_values = view(load_data, :, i)
            
            # Early skip for zero loads
            if isnothing(load)
                @assert all(row_values .== 0.0)
                continue
            else
                @assert get_number(get_bus(load)) == i "expected load $load_name to "*
                    "be at bus $i, got bus $(get_number(get_bus(load)))"
            end
            
            real_values = real.(row_values)
            @assert all(real_values .>= 0.0) "Negative real values found for load $load_name"
            max_ts = maximum(real_values)
            
            if max_ts > get_max_active_power(load)
                increased += 1
                most_increase = max(most_increase, max_ts / get_max_active_power(load))
                set_max_active_power!(load, max_ts)
            end
            @assert all(real_values .<= get_max_active_power(load) + 1e-6)
            
            # PSI prefers values to be between 0 and 1.
            real_values ./= get_max_active_power(load)

            ts = SingleTimeSeries(;
                name = "max_active_power",
                data = TimeArray(timestamps, real_values),
                scaling_factor_multiplier = get_max_active_power,
            )
            add_time_series!(system, load, ts)
        end
        if increased > 0
            num_loads = length(get_components(PowerLoad, system))
            @warn "increased max active power for $increased (of $num_loads) loads based "*
                "on load time series; largest increase was by a factor of " *
                "$(round(most_increase; sigdigits=3))"
        end
    end

    # STEP 3: add cost data

    cost_df = cost_data_to_dataframe(matpower_file)
    @assert n_gens == nrow(cost_df) "Number of generators in system ($n_gens) does not "* 
        "match number of rows in cost data ($nrow(cost_df))"
    for (i, row) in enumerate(eachrow(cost_df))
        gen_name = "gen-$(i)"
        comp = get_component(StaticInjection, system, gen_name)
        isnothing(comp) && continue  # skip removed components (e.g., SCs)
        @assert row[:startup] == 0.0
        @assert row[:shutdown] == 0.0
        n = row[:n]
        # assume quadratic cost function
        @assert n == 3 "Only quadratic cost functions supported."
        c2 = row[:c2]
        c1 = row[:c1]
        c0 = row[:c0]
        if all((c2, c1, c0) .== 0.0)
            # cost is zero (SCs don't have an operation cost)
            comp isa SynchronousCondenser || attach_cost!(comp, nothing)
            continue
        end

        if comp isa Source
            # ImportExportCost must be piecewise incremental, when we have quadratic.
            # so for simplicity we drop the quadratic term.
            # FIXME they use negative exports to represent imports, whereas we use
            # separate curves...
            function_data = PiecewiseIncrementalCurve(c0, [0.0, 1.0e12], [c1])
        elseif first_order
            function_data = LinearCurve(c1, c0)
        else
            function_data = QuadraticCurve(c2, c1, c0)
        end
        cost_curve = CostCurve(function_data)
        attach_cost!(comp, cost_curve)
    end

    return system
end
