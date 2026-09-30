# Expects data to be present in DATASET_DIR
DATASET_DIR = "/Users/mmarathe/Documents/scratch-projects/hydro_data_analysis/1.2.0/godeeep_hydro_1.2.0"

from pathlib import Path

import numpy as np
import pandas as pd

# Edit these values to read future scenarios
SCENARIO = "rcp45hotter"
FILETAG = f"{SCENARIO}"
INPUT_CSV= f"{DATASET_DIR}/rcp45hotter_monthly.parquet"
OUTPUT_DIR = "."

plant_dictionary = {
	445.0: "shasta",
	436.0: "devilcanyon",
	344.0: "mammoth",
}

# Read the input CSV file into a DataFrame only once
df = pd.read_parquet(INPUT_CSV)
percentile_array = [0,10,20,30,40,50,60,70,80,90,100]
# For each plant, find the 10th and 90th percentile of the annual water budget and the year that is closest to that percentile
for plant_id, plant_name in plant_dictionary.items():
    plant_df = df[df["eia_id"].astype(str) == str(plant_id)].copy()
    plant_df["datetime"] = pd.to_datetime(plant_df["datetime"], errors="coerce")
    plant_df = plant_df.dropna(subset=["datetime"]).copy()

    annual_budget = plant_df.groupby(plant_df["datetime"].dt.year)["power_predicted_mwh"].sum()
    percentiles = {p: np.percentile(annual_budget, p) for p in percentile_array}
    years = {
        # Subtract the percentile value from each annual budget, take the absolute value, and find the index of the closest year
        p: annual_budget.iloc[(annual_budget - percentiles[p]).abs().argsort()[:1]].index.tolist()
        for p in percentile_array
    }
    print(f"{plant_name}: " + ", ".join([f"{p}th percentile = {percentiles[p]} (Year: {years[p]})\n" for p in percentile_array]))
    # Write to CSV file
    output_csv = f"{plant_name}_{FILETAG}_percentiles.csv"
    pd.DataFrame({
        "percentile": percentile_array,
        "value": [percentiles[p] for p in percentile_array],
        "year": [years[p][0] for p in percentile_array]
    }).to_csv(output_csv, index=False)

# What percentile is the 2025 annual water budget for each plant
for plant_id, plant_name in plant_dictionary.items():
    plant_df = df[df["eia_id"].astype(str) == str(plant_id)].copy()
    plant_df["datetime"] = pd.to_datetime(plant_df["datetime"], errors="coerce")
    plant_df = plant_df.dropna(subset=["datetime"]).copy()

    annual_budget = plant_df.groupby(plant_df["datetime"].dt.year)["power_predicted_mwh"].sum()
    if 2025 in annual_budget.index:
        budget_2025 = annual_budget.loc[2025]
        # Find the number of budgets below the 2025 budget, divide by the total number of budgets, and multiply by 100 to get the percentile
        percentile_2025 = np.searchsorted(np.sort(annual_budget), budget_2025) / len(annual_budget) * 100
        print(f"{plant_name}: 2025 annual water budget = {budget_2025} (Percentile: {percentile_2025})")
    else:
        print(f"{plant_name}: No data for 2025")