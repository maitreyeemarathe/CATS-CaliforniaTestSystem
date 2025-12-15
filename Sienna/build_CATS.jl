using PowerSystems
using CSV
using DataFrames
using Dates
using TimeSeries

const PSY = PowerSystems

include(joinpath(@__DIR__, "parse_matpower.jl"))
include(joinpath(@__DIR__, "generator_types.jl"))
BASE_DIR = joinpath(@__DIR__, "..")

VALIDITY_CHECKS = true

# hardcoded to other CATS repo for now.
# Download from "Time-series data" link at
# https://github.com/WISPO-POP/CATS-CaliforniaTestSystem?tab=readme-ov-file
DATA_DIR = "$(homedir())/Documents/julia/CATS-project/CATS-CaliforniaTestSystem/data/"

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

fix_missings!(data::Vector{Float64}) = nothing # no-op


attach_cost!(gen::ThermalStandard, cost::Union{CostCurve}) =
    set_operation_cost!(gen, ThermalGenerationCost(cost, 0.0, 0, 0.0))

attach_cost!(gen::ThermalStandard, ::Nothing) =
    set_operation_cost!(gen, ThermalGenerationCost(nothing))

attach_cost!(gen::RenewableDispatch, cost::Union{CostCurve}) =
    set_operation_cost!(gen, RenewableGenerationCost(cost))

attach_cost!(gen::RenewableDispatch, ::Nothing) =
    set_operation_cost!(gen, RenewableGenerationCost(nothing))

attach_cost!(gen::HydroDispatch, cost::Union{CostCurve, Nothing}) = 
    set_operation_cost!(gen, HydroGenerationCost(cost, 0.0))

attach_cost!(gen::HydroDispatch, ::Nothing) = 
    set_operation_cost!(gen, HydroGenerationCost(nothing))

attach_cost!(gen::Source, cost::CostCurve) = 
    set_operation_cost!(gen, ImportExportCost(; import_offer_curves = cost))

attach_cost!(gen::Source, ::Nothing) = 
    set_operation_cost!(gen, ImportExportCost(; import_offer_curves = zero(CostCurve)))

function build_CATS_system(;
    matpower_file::String = "$BASE_DIR/MATPOWER/CaliforniaTestSystem.m",
    generator_csv::String = "$BASE_DIR/GIS/CATS_gens.csv",
    timeseries_csv::String = joinpath(DATA_DIR, "HourlyProduction2019.csv"),
    first_order::Bool = false
)

    system = System(matpower_file)
    # everything in the CSV is in natural units.
    set_units_base_system!(system, "NATURAL_UNITS")
    gen_csv = CSV.read(generator_csv, DataFrame)
    gen_df = generator_data_to_dataframe(matpower_file)

    needed_keys = Set{Tuple{PrimeMovers, ThermalFuels}}()
    missing_keys = 0

    # STEP 1: fix gen types. All are parsed as ThermalStandard, but some are hydro or renewable.
    for (i, row) in enumerate(eachrow(gen_csv))
        gen_name = "gen-$(i)"
        gen = get_component(ThermalStandard, system, gen_name)
        gen_type  = row[:FuelType]
        pm_type = PM_TYPE_DICT[gen_type]
        if occursin("Hydroelectric", gen_type)
            hydro_gen = try_convert(HydroDispatch, gen, pm_type)
            remove_component!(system, gen)
            add_component!(system, hydro_gen)
        elseif occursin("Solar", gen_type) || occursin("Wind", gen_type) || occursin("Batteries", gen_type)
            renewable_gen = try_convert(RenewableDispatch, gen, pm_type)
            remove_component!(system, gen)
            add_component!(system, renewable_gen)
        elseif gen_type == "IMPORT"
            import_gen = try_convert(Source, gen, pm_type)
            remove_component!(system, gen)
            add_component!(system, import_gen)
        elseif gen_type == "Synchronous Condenser"
            sc_gen = try_convert(SynchronousCondenser, gen, pm_type)
            remove_component!(system, gen)
            add_component!(system, sc_gen)
        else
            # non-renewable non-hydro remain ThermalStandard
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
        comp  = get_component(StaticInjection, system, gen_name)
        if !(comp isa Source) && !(comp isa SynchronousCondenser)
            set_prime_mover_type!(comp, PM_TYPE_DICT[row[:FuelType]])
        end

        # some data validity checks
        if VALIDITY_CHECKS
            matpower_row = gen_df[i, :]

            if !(comp isa SynchronousCondenser)
                @assert isapprox(get_active_power(comp), row[:Pg])
                @assert isapprox(row[:Pmax], matpower_row[:Pmax])
                @assert isapprox(row[:Pmin], matpower_row[:Pmin])
            end

            @assert isapprox(get_reactive_power(comp), row[:Qg])
            @assert isapprox(row[:Pg], matpower_row[:Pg])
            @assert isapprox(row[:Qg], matpower_row[:Qg])

            @assert isapprox(get_reactive_power_limits(comp).max, row[:Qmax])
            @assert isapprox(get_reactive_power_limits(comp).min, row[:Qmin])

            if !(comp isa RenewableDispatch) && !(comp isa SynchronousCondenser)
                @assert isapprox(get_active_power_limits(comp).max, row[:Pmax])
                @assert isapprox(get_active_power_limits(comp).min, row[:Pmin])
            end
        end
    end


    # STEP 2: attach timeseries data
    col_to_type_and_kwargs = Dict(
        "Solar" => (RenewableDispatch, Dict(:prime_mover_type => PrimeMovers.PVe)),
        "Wind" => (RenewableDispatch, Dict(:prime_mover_type => PrimeMovers.WT)),
        "Large Hydro" => (HydroDispatch, Dict()),
        "Nuclear" => (ThermalStandard, Dict(:fuel => ThermalFuels.NUCLEAR)),
        # here I should really have "fuel not nuclear", but I'll special-case it.
        "Thermal" => (ThermalStandard, Dict()),
        "Load" => (PowerLoad, Dict()),
        "Imports" => (Source, Dict())
    )

    ts_df = CSV.read(timeseries_csv, DataFrame; 
        header=1,
        types=(i, name) -> i <= 3 ? String : Float64,
    )

    timestamps = range(DateTime("2019-01-01T00:00:00"); step = Hour(1), length = nrow(ts_df))
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

        # data validity check: total across comps should match csv value.
        if VALIDITY_CHECKS
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

    # STEP 3: add cost data

    cost_df = cost_data_to_dataframe(matpower_file)
    for (i, row) in enumerate(eachrow(cost_df))
        gen_name = "gen-$(i)"
        comp = get_component(StaticInjection, system, gen_name)
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
            function_data = PiecewiseIncrementalCurve(c0, [0.0, Inf], [c1])
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
