using DataFrames

const MATPOWER_GEN_KEYS = (
    ("bus", Int),
    ("Pg", Float64),
    ("Qg", Float64),
    ("Qmax", Float64),
    ("Qmin", Float64),
    ("Vg", Float64),
    ("mBase", Float64),
    ("status", Int),
    ("Pmax", Float64),
    ("Pmin", Float64),
    ("Pc1", Float64),
    ("Pc2", Float64),
    ("Qc1min", Float64),
    ("Qc1max", Float64),
    ("Qc2min", Float64),
    ("Qc2max", Float64),
    ("ramp_agc", Float64),
    ("ramp_10", Float64),
    ("ramp_30", Float64),
    ("ramp_q", Float64),
    ("apf", Float64)
)

function parse_gen_row(row::AbstractString)
    parts = split(strip(row))
    row_dict = Dict{String, Union{Float64, Int}}()
    for (i, key) in enumerate(MATPOWER_GEN_KEYS)
        if i > length(parts)
            row_dict[key[1]] = missing
        else
            row_dict[key[1]] = parse(key[2], parts[i])
        end
    end
    return row_dict
end

function generator_data_to_dataframe(matpower_file::String)
    found_generators = false
    df = DataFrame([name => Vector{type}() for (name, type) in MATPOWER_GEN_KEYS])
    for line in eachline(matpower_file)
        if startswith(strip(line), "mpc.gen = [")
            found_generators = true
        elseif found_generators && startswith(strip(line), "];")
            return df
        elseif found_generators
            row_dict = parse_gen_row(line)
            @assert length(MATPOWER_GEN_KEYS) == length(row_dict)
            push!(df, row_dict)
        end
    end
    return df
end


const MATPOWER_COST_KEYS = (
    ("model", Int),
    ("startup", Float64),
    ("shutdown", Float64),
    ("n", Int),
    ("c2", Float64),
    ("c1", Float64),
    ("c0", Float64)
)

# could perhaps combine, reduce code duplication.
function parse_cost_row(row::AbstractString)
    parts = split(strip(row))
    row_dict = Dict{String, Union{Float64, Int}}()
    for (i, key) in enumerate(MATPOWER_COST_KEYS)
        if i > length(parts)
            row_dict[key[1]] = missing
        else
            row_dict[key[1]] = parse(key[2], parts[i])
        end
    end
    return row_dict
end

function cost_data_to_dataframe(matpower_file::String)
    found_costs = false
    df = DataFrame([name => Vector{type}() for (name, type) in MATPOWER_COST_KEYS])
    for line in eachline(matpower_file)
        if startswith(strip(line), "mpc.gencost = [")
            found_costs = true
        elseif found_costs && startswith(strip(line), "];")
            return df
        elseif found_costs
            row_dict = parse_cost_row(line)
            push!(df, row_dict)
        end
    end
    return df
end
