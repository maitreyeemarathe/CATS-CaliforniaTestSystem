using CSV, DataFrames

CSV_PATH = "../CondenserReactiveFlows_lb.csv"
GEN_CSV_PATH = "../GIS/CATS_gens.csv"
OUTLIER_NONZERO_THRESHOLD = 1000
MIN_NONZEROS = 10

df = CSV.read(CSV_PATH, DataFrame)
gen_cols = names(df, Not(:timestep))

# Filter out timestep=0 and -99 rows
df = filter(:timestep => !=(0), df)
valid = [!all(row[col] == -99 for col in gen_cols) for row in eachrow(df)]
df = df[valid, :]

# Exclude outlier timesteps
nz_per_row = [count(!=(0.0), row[col] for col in gen_cols) for row in eachrow(df)]
df = df[nz_per_row .< OUTLIER_NONZERO_THRESHOLD, :]

gen_data = CSV.read(GEN_CSV_PATH, DataFrame)

scs_keep = DataFrame(generator = String[], bus = Int[])
scs_to_storage = DataFrame(generator = String[], bus = Int[])
for col in gen_cols
    nz = count(!=(0.0), df[!, col])
    idx = parse(Int, split(col)[2])
    bus = gen_data.bus[idx]
    if nz >= MIN_NONZEROS
        push!(scs_keep, (col, bus))
    elseif nz >= 1
        push!(scs_to_storage, (col, bus))
    end
end

println("SCs to keep (≥$(MIN_NONZEROS) nonzeros): $(nrow(scs_keep))")
println("SCs to replace with storage (1-$(MIN_NONZEROS-1) nonzeros): $(nrow(scs_to_storage))")
CSV.write("../data/scs_to_keep.csv", scs_keep)
CSV.write("../data/scs_to_storage.csv", scs_to_storage)
println("Saved to data/scs_to_keep.csv and data/scs_to_storage.csv")
