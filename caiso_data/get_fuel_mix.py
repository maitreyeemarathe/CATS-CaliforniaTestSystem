
import truststore
truststore.inject_into_ssl()
import pandas as pd
import plotly.express as px
import gridstatus

caiso = gridstatus.CAISO()

start = pd.Timestamp("January 1, 2025").normalize()
end = pd.Timestamp("January 1, 2026").normalize()
mix_df = caiso.get_fuel_mix(start, end=end, verbose=False)


hourly_mix = mix_df.set_index("Time").resample("h").mean()
# CSV export
hourly_mix.to_csv("caiso_fuel_mix_hourly.csv")

