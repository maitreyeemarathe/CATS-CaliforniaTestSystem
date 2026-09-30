from __future__ import annotations

import hashlib
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
SUBDIRS = ["historical", "2025_scenarios"]


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def compare_files() -> None:
    root_csvs = sorted(BASE_DIR.glob("*.csv"))
    print(f"Checking {len(root_csvs)} CSV files in {BASE_DIR}")

    matches_found = 0
    mismatches = []
    missing = []

    for root_csv in root_csvs:
        candidate_paths = []
        for subdir in SUBDIRS:
            candidate = BASE_DIR / subdir / root_csv.name
            if candidate.exists():
                candidate_paths.append(candidate)

        if not candidate_paths:
            missing.append(root_csv.name)
            continue

        for candidate in candidate_paths:
            if sha256(root_csv) == sha256(candidate):
                print(f"IDENTICAL: {root_csv.name} == {candidate.relative_to(BASE_DIR)}")
                matches_found += 1
            else:
                mismatches.append((root_csv.name, str(candidate.relative_to(BASE_DIR))))

    if missing:
        print("\nMissing matching files:")
        for name in missing:
            print(f"  - {name}")

    if mismatches:
        print("\nFiles differ:")
        for name, other in mismatches:
            print(f"  - {name} vs {other}")

    print(f"\nSummary: {matches_found} identical file matches found")
    print(f"Mismatches: {len(mismatches)}")
    print(f"Missing matches: {len(missing)}")


if __name__ == "__main__":
    compare_files()
