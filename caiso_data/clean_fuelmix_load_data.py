import pandas as pd

hourly_mix = pd.read_csv("caiso_fuel_mix_hourly.csv", index_col="Time")
# CSV mixes -08:00/-07:00 across DST, so parse via UTC to get a real DatetimeIndex
hourly_mix.index = pd.to_datetime(hourly_mix.index, utc=True).tz_convert("US/Pacific")
# Remove columns Interval Start and Interval End
hourly_mix = hourly_mix.drop(columns=["Interval Start", "Interval End"])
# If a value inside Solar is negative, replace it with 0
hourly_mix["Solar"] = hourly_mix["Solar"].apply(lambda x: max(x, 0))
# If a value inside Wind is negative, replace it with 0
hourly_mix["Wind"] = hourly_mix["Wind"].apply(lambda x: max(x, 0))
# If a value inside Large Hydro is negative, replace it with 0
hourly_mix["Large Hydro"] = hourly_mix["Large Hydro"].apply(lambda x: max(x, 0))
# Sum Geothermal, Biomass, Biogas, Small Hydro, Batteries and make a new column called Renewables
#hourly_mix["Renewables"] = hourly_mix[["Geothermal", "Biomass", "Biogas", "Small Hydro", "Batteries"]].sum(axis=1)
# Drop the columns Geothermal, Biomass, Biogas, Small Hydro, Batteries, Other
hourly_mix = hourly_mix.drop(columns=["Geothermal", "Biomass", "Biogas", "Small Hydro", "Batteries", "Other"])
# If a value inside Nuclear is negative, replace it with 0
hourly_mix["Nuclear"] = hourly_mix["Nuclear"].apply(lambda x: max(x, 0))
# If a value inside Natural Gas is negative, replace it with 0
hourly_mix["Natural Gas"] = hourly_mix["Natural Gas"].apply(lambda x: max(x, 0))
# If a value inside Coal is negative, replace it with 0
hourly_mix["Coal"] = hourly_mix["Coal"].apply(lambda x: max(x, 0))
# Add Natural Gas and Coal to make a new column called Thermal
hourly_mix["Thermal"] = hourly_mix["Natural Gas"] + hourly_mix["Coal"]
# Drop the columns Natural Gas and Coal
hourly_mix = hourly_mix.drop(columns=["Natural Gas", "Coal"])

# Read caiso_load_hourly.csv and clean the data
hourly_load = pd.read_csv("caiso_load_hourly.csv", index_col="Time")
hourly_load.index = pd.to_datetime(hourly_load.index, utc=True).tz_convert("US/Pacific")
# Remove columns Interval Start and Interval End
hourly_load = hourly_load.drop(columns=["Interval Start", "Interval End"])
# If a value inside Load is negative, replace it with 0
hourly_load["Load"] = hourly_load["Load"].apply(lambda x: max(x, 0))
# Add a new column called Load in houry_mix that is equal to the Load column in hourly_load
hourly_mix["Load"] = hourly_load["Load"]

# Drop the timezone information from the index, only after the tz-aware join above
hourly_mix.index = hourly_mix.index.tz_localize(None)

# Check row 7322 - if all values are zero, interpolate values from surrounding rows
if (hourly_mix.iloc[7321].isna()).all():
    print("Row 7321 has NaN due to daylight saving time, interpolating from surrounding rows.")
    hourly_mix.iloc[7321] = hourly_mix.iloc[[7320, 7322]].mean()

# If any value is NaN, replace it with 0
hourly_mix = hourly_mix.fillna(0)

# Write the cleaned data to a new CSV file
hourly_mix.to_csv("HourlyProduction2025_daylightsavingfix.csv")