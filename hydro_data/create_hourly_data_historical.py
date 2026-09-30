# Expects data to be present in DATASET_DIR
DATASET_DIR = "/Users/mmarathe/Documents/scratch-projects/hydro_data_analysis/1.2.0/godeeep_hydro_1.2.0"

from pathlib import Path

import numpy as np
import pandas as pd

# Edit these values to read historical data
YEAR = 2006
SCENARIO = "hist"
FILETAG = f"{SCENARIO}_{YEAR}"
INPUT_CSV_ARRAY = [f"{DATASET_DIR}/hist_weekly.parquet"]
OUTPUT_DIR = "."

plant_dictionary = {
	445.0: "shasta",
	436.0: "devilcanyon",
	344.0: "mammoth",
}


def generate_hourly(
	weekly_df: pd.DataFrame,
	plant_id: int | str,
	year: int,
) -> pd.DataFrame:
	# Work from weekly rows for a single plant and year, then expand to hourly rows.
	plant_weekly = weekly_df[weekly_df["eia_id"].astype(str) == str(plant_id)].copy()

	for col in ["p_max", "p_min", "ador", "p_avg"]:
		plant_weekly[col] = pd.to_numeric(plant_weekly[col], errors="coerce")

	plant_weekly = plant_weekly.dropna(subset=["datetime", "p_max", "p_min", "ador","power_predicted_mwh","n_hours"])
	plant_weekly["datetime"] = pd.to_datetime(plant_weekly["datetime"])
	plant_weekly = plant_weekly[plant_weekly["datetime"].dt.year == year].copy()

	hourly_rows = []

	for _, row in plant_weekly.iterrows():
		week_start = row["datetime"]
		week_pmax = float(row["p_max"])
		week_pmin = float(row["p_min"])
		week_budget = float(row["power_predicted_mwh"])
		week_n_hours = int(row["n_hours"])

		for day in range(7):
			day_start = week_start + pd.Timedelta(days=day)
			if day_start.year != year:
				# Skip days that fall outside the target year.
				continue

			budget_hour = week_budget/week_n_hours

			for hour in range(24):
						
				hourly_rows.append(
					{
						"datetime": day_start + pd.Timedelta(hours=hour),
						"eia_id": row["eia_id"],
						"plant": row["plant"],
						"scenario": row.get("scenario"),
						"week_start": week_start,
						"week_p_max": week_pmax,
						"week_p_min": week_pmin,
						"p_avg_week": row.get("p_avg"),
						"budget_hour": budget_hour,	
					}
				)

	hourly = pd.DataFrame(hourly_rows).sort_values("datetime").reset_index(drop=True)
	return hourly


def replace_output_year(hourly_df: pd.DataFrame, output_year: int = 2025) -> pd.DataFrame:
	hourly_df = hourly_df.copy()
	for col in ["datetime", "week_start"]:
		hourly_df[col] = pd.to_datetime(hourly_df[col])

	original_years = {col: hourly_df[col].dt.year.copy() for col in ["datetime", "week_start"]}

	# In leap years, shift dates on/after Feb 29 forward by 1 day so Feb 29 maps to
	# Mar 1 (and every later date shifts accordingly), instead of dropping Feb 29 outright.
	for col in ["datetime", "week_start"]:
		# Produce a series of Booleans indicating which rows are on or after the leap day.
		on_or_after_leap_day = hourly_df[col].dt.is_leap_year & (hourly_df[col].dt.dayofyear >= 60)
		hourly_df.loc[on_or_after_leap_day, col] += pd.Timedelta(days=1)

	# Drop rows that spilled into the following calendar year (the last day of a leap
	# year has no slot left once everything after Feb 29 shifts forward by one day).
	# Series of Booleans indicating which rows have spilled into the next year.
	spilled_into_next_year = pd.Series(False, index=hourly_df.index)
	for col in ["datetime", "week_start"]:
		# Finds which datetime has a year not equal to the original year
		spilled_into_next_year |= hourly_df[col].dt.year != original_years[col]
	# Remove rows that have spilled into the next year.
	hourly_df = hourly_df.loc[~spilled_into_next_year].copy()

	for col in ["datetime", "week_start"]:
		# lambda is an anonymous function
		# ts.replace(year=output_year) replaces the year of the timestamp with the output year
		hourly_df[col] = hourly_df[col].map(lambda ts: ts.replace(year=output_year))
	return hourly_df


def process_file(
	input_csv: str,
	output_csv: str,
	plant_id: int | str,
	year: int,
) -> int:
	# File-level orchestration so callers can reuse this in loops or other modules.
	weekly_df = df = pd.read_parquet(input_csv)
	hourly_df = generate_hourly(weekly_df, plant_id=plant_id, year=year)
	##### ONLY NECESSARY FOR years other than 2025 RCP 4.5 hotter
	hourly_df = replace_output_year(hourly_df, output_year=2025)
	hourly_df.to_csv(output_csv, index=False)
	return len(hourly_df)


def main() -> None:

	# Process each configured input independently.
	for plant_id, plant_name in plant_dictionary.items():
		for input_csv in INPUT_CSV_ARRAY:
			row_count = process_file(
				input_csv=input_csv,
				output_csv=f"{plant_name}_{FILETAG}_hourly.csv",
				plant_id=plant_id,
				year=YEAR,
			)
			print(f"Wrote {row_count} hourly rows to {plant_name}_{FILETAG}_hourly.csv")


if __name__ == "__main__":
	main()

