import time

import pandas as pd
import truststore
truststore.inject_into_ssl()

import gridstatus


shasta_node = "JBBLACK2_7_B1"
#PIT5_7_B4
mammoth_node = "MAMOTH1G_7_B1"
#MAMOTH2G_7_B1
devilcanyon_node = "DVLCYN3G_7_B1"
#DVLCYN4G_7_B1
#SHANDIN_1_N008

iso = gridstatus.CAISO()

# This was done because CAISO's API may intermittently fail and needs
# to be retried a few times.
MAX_ATTEMPTS = 4
RETRY_BACKOFF_SECONDS = 30


def get_lmp_for_year(location, year=2025):
    """
    COPILOT GENERATED
    Fetch a full year of day-ahead LMPs one month at a time, retrying failed
    months instead of silently dropping them.

    Note: CAISO.get_lmp is wrapped by @lmp_config *outside* @support_date_range,
    and lmp_config validates kwargs against the undecorated function's real
    signature, so the error="raise" kwarg that support_date_range would
    otherwise accept cannot be passed here. Instead, we detect failures by
    checking for an empty/missing result (support_date_range still prints the
    real "Error: ..." message even in its default error="ignore" mode)."""
    # Build consecutive [start, end) monthly ranges so every month is fetched once.
    months = pd.date_range(f"{year}-01-01", f"{year+1}-01-01", freq="MS")
    frames = []
    for start, end in zip(months[:-1], months[1:]):
        for attempt in range(1, MAX_ATTEMPTS + 1):
            df = iso.get_lmp(
                date=start,
                end=end,
                market="DAY_AHEAD_HOURLY",
                locations=[location],
            )
            if df is not None and not df.empty:
                frames.append(df)
                break
            # Retry transient API failures, but fail loudly if all attempts are exhausted.
            print(f"[{location}] {start.date()}-{end.date()} attempt {attempt} returned no data")
            if attempt == MAX_ATTEMPTS:
                raise RuntimeError(
                    f"[{location}] {start.date()}-{end.date()} failed after {MAX_ATTEMPTS} attempts",
                )
            time.sleep(RETRY_BACKOFF_SECONDS)
    return pd.concat(frames, ignore_index=True)


for node in (devilcanyon_node, mammoth_node, shasta_node):
    df = get_lmp_for_year(node)
    df.to_csv(node + "_2025_lmp_data.csv", index=False)