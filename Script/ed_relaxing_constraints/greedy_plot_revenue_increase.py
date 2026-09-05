"""
Plot the weekly increase in hydro revenue for the pmin-relaxation scenarios
(ps50, ps0) relative to the ps100 baseline, one plot per plant (Shasta,
Devil Canyon, Mammoth).

Each results/ed_relaxing_constraints/rcp45hotter/greedy/<start_date>/ folder holds a
simulation starting on <start_date> and covering some number of 7-day weeks
This script recomputes hourly revenue (= dispatch * system
price) for each plant's generators from the per-run CSV outputs, aggregates
it into weekly totals keyed by the absolute start date of each week, and
compares ps50/ps0 to the ps100 baseline for matching weeks.
"""

import os

import matplotlib.pyplot as plt
import pandas as pd

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BASE_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
RESULTS_DIR = os.path.join(BASE_DIR, "results", "ed_relaxing_constraints", "rcp45hotter", "greedy")
GEN_CSV = os.path.join(BASE_DIR, "GIS", "CATS_gens.csv")

PS_CASES = ["ps0", "ps50", "ps100"]
BASELINE = "ps100"

# Explicit colors so ps0/ps50 match the matplotlib defaults used when ps100
# (the baseline) was excluded from the revenue-increase plots.
PS_COLORS = {"ps0": "C0", "ps50": "C1", "ps100": "C2"}

# Selection criteria mirroring get_hydro_gen_names(...) calls in main_*.jl
PLANT_FILTERS = {
    "Shasta": dict(plant_code=445, bus=1498, gen_ids={"1", "2", "3", "4", "5"}),
    "Devil Canyon": dict(plant_code=436, bus=1005, gen_ids={"1", "2", "3", "4"}),
    "Mammoth": dict(plant_code=344, bus=1636, gen_ids={"1", "2"}),
}


def get_plant_gen_names(gen_csv_path):
    """Reproduce Julia's get_hydro_gen_names per plant: gen-<1-based row index>."""
    gens = pd.read_csv(gen_csv_path)
    gens["GenID"] = gens["GenID"].astype(str)

    plant_gen_names = {}
    for plant, filt in PLANT_FILTERS.items():
        mask = (
            (gens["PlantCode"] == filt["plant_code"])
            & (gens["bus"] == filt["bus"])
            & (gens["GenID"].isin(filt["gen_ids"]))
        )
        matched_rows = gens.index[mask] + 1  # Julia enumerate is 1-based
        plant_gen_names[plant] = {f"gen-{i}" for i in matched_rows}
    return plant_gen_names


def week_start_dates(datetimes):
    """Map each timestamp to the absolute start date of its 7-day week."""
    run_start = datetimes.min()
    week_index = (datetimes - run_start).dt.days // 7
    return run_start + pd.to_timedelta(week_index * 7, unit="D")


def weekly_revenue_by_plant(run_dir, plant_gen_names):
    """Return {plant: Series of weekly revenue indexed by week start date}."""
    dispatch = pd.read_csv(
        os.path.join(run_dir, "selected_hydro_dispatch_wide.csv"), parse_dates=["DateTime"]
    )
    price = pd.read_csv(
        os.path.join(run_dir, "hydro_ed_prices.csv"), parse_dates=["DateTime"]
    )
    price = price.set_index("DateTime")["value"]
    price_values = price.reindex(dispatch["DateTime"]).values

    week_start = week_start_dates(dispatch["DateTime"])

    weekly_by_plant = {}
    for plant, gen_names in plant_gen_names.items():
        gen_cols = [c for c in dispatch.columns if c in gen_names]
        hourly_revenue = dispatch[gen_cols].sum(axis=1) * price_values
        weekly_by_plant[plant] = hourly_revenue.groupby(week_start).sum()
    return weekly_by_plant


def weekly_price_variance(run_dir):
    """Return a Series of shadow-price variance indexed by week start date."""
    price = pd.read_csv(
        os.path.join(run_dir, "hydro_ed_prices.csv"), parse_dates=["DateTime"]
    )
    week_start = week_start_dates(price["DateTime"])
    return price["value"].groupby(week_start).var()


def main():
    plant_gen_names = get_plant_gen_names(GEN_CSV)

    run_folders = sorted(
        d for d in os.listdir(RESULTS_DIR)
        if os.path.isdir(os.path.join(RESULTS_DIR, d)) and d[0].isdigit()
    )

    # revenue_by_case[plant][ps] -> {week_start: revenue}
    revenue_by_case = {plant: {ps: {} for ps in PS_CASES} for plant in plant_gen_names}
    # price_variance_by_case[ps] -> {week_start: variance}
    price_variance_by_case = {ps: {} for ps in PS_CASES}
    for folder in run_folders:
        for ps in PS_CASES:
            run_dir = os.path.join(RESULTS_DIR, folder, f"relaxed_pmin_{ps}")
            if not os.path.isdir(run_dir):
                continue
            weekly_by_plant = weekly_revenue_by_plant(run_dir, plant_gen_names)
            for plant, weekly in weekly_by_plant.items():
                revenue_by_case[plant][ps].update(weekly.to_dict())
            price_variance_by_case[ps].update(weekly_price_variance(run_dir).to_dict())

    for plant in plant_gen_names:
        baseline = pd.Series(revenue_by_case[plant][BASELINE]).sort_index()

        pct_increase = {}
        for ps in PS_CASES:
            if ps == BASELINE:
                continue
            series = pd.Series(revenue_by_case[plant][ps]).sort_index()
            common_weeks = series.index.intersection(baseline.index)
            pct_increase[ps] = 100 * (series[common_weeks] - baseline[common_weeks]) / baseline[common_weeks]

        fig, ax = plt.subplots(figsize=(10, 5))
        for ps, series in pct_increase.items():
            ax.plot(series.index, series.values, marker="o", label=ps, color=PS_COLORS[ps])

        ax.set_xlabel("Week start date")
        ax.set_ylabel("Increase in weekly revenue vs. ps100 baseline (%)")
        ax.set_title(f"{plant} revenue increase from relaxing Pmin")
        ax.legend(title="Scenario")
        ax.grid(True, alpha=0.3)
        fig.autofmt_xdate()
        fig.tight_layout()

        plant_slug = plant.lower().replace(" ", "_")
        out_path = os.path.join(RESULTS_DIR, f"revenue_increase_vs_baseline_{plant_slug}.png")
        fig.savefig(out_path, dpi=150)
        plt.close(fig)
        print(f"Saved plot to {out_path}")

    fig, ax = plt.subplots(figsize=(10, 5))
    for ps in PS_CASES:
        series = pd.Series(price_variance_by_case[ps]).sort_index()
        ax.plot(series.index, series.values, marker="o", label=ps, color=PS_COLORS[ps])

    ax.set_xlabel("Week start date")
    ax.set_ylabel("Variance of shadow price ($/MWh)$^2$")
    ax.set_title("Weekly shadow price variance")
    ax.legend(title="Scenario")
    ax.grid(True, alpha=0.3)
    fig.autofmt_xdate()
    fig.tight_layout()

    out_path = os.path.join(RESULTS_DIR, "shadow_price_variance.png")
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"Saved plot to {out_path}")


if __name__ == "__main__":
    main()
