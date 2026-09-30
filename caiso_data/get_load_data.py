import truststore
truststore.inject_into_ssl()
import pandas as pd
import plotly.express as px
import gridstatus
caiso = gridstatus.CAISO()

start = pd.Timestamp("January 1, 2025").normalize()
end = pd.Timestamp("January 1, 2026").normalize()
load_df = caiso.get_load(start, end=end)

hourly_load = load_df.set_index("Time").resample("h").mean()
# CSV export
hourly_load.to_csv("caiso_load_hourly.csv")
