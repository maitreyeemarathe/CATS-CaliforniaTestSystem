"""Plot weekly hydro budget vs. week for each plant, comparing all 4 climate scenarios."""

from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd

DATA_DIR = Path(__file__).parent
PLANTS = ["shasta", "devilcanyon", "mammoth"]
SCENARIOS = ["rcp45cooler", "rcp45hotter", "rcp85cooler", "rcp85hotter"]


def load_weekly_budget(plant: str, scenario: str) -> pd.DataFrame:
    file_path = DATA_DIR / f"{plant}_{scenario}_hourly.csv"
    df = pd.read_csv(file_path, usecols=["week_start", "p_avg_week"], parse_dates=["week_start"])
    weekly = df.drop_duplicates(subset="week_start").sort_values("week_start")
    return weekly[weekly["week_start"] != "2025-12-31"]


def plot_plant(plant: str) -> None:
    fig, ax = plt.subplots(figsize=(10, 6))
    for scenario in SCENARIOS:
        weekly = load_weekly_budget(plant, scenario)
        ax.plot(weekly["week_start"], weekly["p_avg_week"], label=scenario, marker="o", markersize=3)

    ax.set_title(f"{plant.capitalize()}: Average Power per week by Scenario (2025)")
    ax.set_xlabel("Week")
    ax.set_ylabel("Average Power (MW)")
    ax.legend(title="Scenario")
    ax.grid(True, alpha=0.3)
    fig.autofmt_xdate()
    fig.tight_layout()
    fig.savefig(DATA_DIR / f"{plant}_weekly_budget.png", dpi=150)


def main() -> None:
    for plant in PLANTS:
        plot_plant(plant)
        print(f"Saved figure for {plant}")


if __name__ == "__main__":
    main()
