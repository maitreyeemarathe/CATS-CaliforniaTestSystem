using CSV
using JLD2

# Path to the CSV file
DATA_DIR = "$(homedir())/Documents/julia/CATS-project/CATS-CaliforniaTestSystem/data/"
csv_file = joinpath(DATA_DIR, "Load_Agg_Post_Assignment_v3_latest.csv")
jld2_file = joinpath(DATA_DIR, "Load_Agg_Post_Assignment_v3_latest.jld2")

if isfile(jld2_file)
    println("JLD2 file already exists at $jld2_file. Delete it first if you want to recreate.")
    exit(0)
end

println("Reading CSV file: $csv_file")
println("This may take several minutes...")

# Read the CSV and parse to ComplexF64
data = Vector{Vector{ComplexF64}}()

for (i, row) in enumerate(CSV.Rows(csv_file; header=false))
    if i % 100 == 0
        print("\rProcessing row $i...")
    end
    row_values = parse.(ComplexF64, collect(row))
    push!(data, row_values)
end
println("\rFinished processing all rows. Total rows: $(length(data))")

# Convert to matrix and transpose for column-major storage
# Each column will be one bus's time series (better cache locality)
println("Converting to matrix...")
load_matrix = stack(data)

# Save to JLD2
println("Writing to JLD2 file: $jld2_file")
jldsave(jld2_file; load_data=load_matrix)

println("Done! Saved $(size(load_matrix)) matrix (timesteps × buses) to JLD2 format.")
println("File size: $(round(filesize(jld2_file) / 1024^2, digits=2)) MB")
