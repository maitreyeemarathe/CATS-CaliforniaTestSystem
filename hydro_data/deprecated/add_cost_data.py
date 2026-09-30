#!/usr/bin/env python3
"""
Update MATPOWER gencost rows using cost data from california_model.json.

Mapping logic:
- CATS_gens.csv keys: (PlantCode, GenID)
- california_model.json keys: (eia_plant_id, eia_generator_id)

For each generator row in CATS_gens.csv (row i), if a unique JSON match exists,
replace row i in mpc.gencost with the JSON cost definition.

Unmatched or ambiguous mappings are left unchanged.

Output:
- MATPOWER/CaliforniaTestSystem_uc_costs.m (by default)
- optional TSV reports for unmatched and ambiguous mappings
"""

from __future__ import annotations

import argparse
import csv
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple


@dataclass
class JsonCostRecord:
    json_gen_key: str
    model: int
    startup: float
    shutdown: float
    ncost: Optional[int]
    cost: List[float]
    name: Optional[str]
    pmin: Optional[float]


def normalize_plant_code(value: object) -> Optional[str]:
    if value is None:
        return None
    s = str(value).strip()
    if not s:
        return None
    try:
        return str(int(float(s)))
    except Exception:
        return s


def normalize_gen_id(value: object) -> Optional[str]:
    if value is None:
        return None
    s = str(value).strip()
    return s if s else None


def load_csv_keys(csv_path: Path) -> List[Tuple[str, str]]:
    keys: List[Tuple[str, str]] = []
    with csv_path.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        required = {"PlantCode", "GenID"}
        missing = required - set(reader.fieldnames or [])
        if missing:
            raise ValueError(f"Missing required CSV columns: {sorted(missing)}")

        for row in reader:
            plant = normalize_plant_code(row.get("PlantCode"))
            genid = normalize_gen_id(row.get("GenID"))
            if plant is None or genid is None:
                # Preserve row position by storing impossible key; it will not match.
                keys.append(("", ""))
            else:
                keys.append((plant, genid))
    return keys


def load_json_lookup(
    json_path: Path,
) -> Tuple[Dict[Tuple[str, str], JsonCostRecord], Dict[Tuple[str, str], List[JsonCostRecord]]]:
    with json_path.open(encoding="utf-8") as f:
        data = json.load(f)

    gen_obj = data.get("gen")
    if not isinstance(gen_obj, dict):
        raise ValueError("JSON does not contain object field 'gen'")

    unique_lookup: Dict[Tuple[str, str], JsonCostRecord] = {}
    ambiguous_lookup: Dict[Tuple[str, str], List[JsonCostRecord]] = {}

    for k, v in gen_obj.items():
        if not isinstance(v, dict):
            continue

        plant = normalize_plant_code(v.get("eia_plant_id"))
        genid = normalize_gen_id(v.get("eia_generator_id"))
        if plant is None or genid is None:
            continue

        cost_raw = v.get("cost", [])
        cost: List[float]
        if isinstance(cost_raw, list):
            try:
                cost = [float(x) for x in cost_raw]
            except Exception:
                cost = []
        else:
            cost = []

        rec = JsonCostRecord(
            json_gen_key=str(k),
            model=int(v.get("model", 2)),
            startup=float(v.get("startup", 0.0)),
            shutdown=float(v.get("shutdown", 0.0)),
            ncost=(int(v["ncost"]) if isinstance(v.get("ncost"), (int, float)) else None),
            cost=cost,
            name=(str(v.get("name")) if v.get("name") is not None else None),
            pmin=(float(v["pmin"]) if isinstance(v.get("pmin"), (int, float)) else None),
        )

        key = (plant, genid)
        if key in unique_lookup:
            ambiguous_lookup.setdefault(key, [unique_lookup[key]])
            ambiguous_lookup[key].append(rec)
        elif key in ambiguous_lookup:
            ambiguous_lookup[key].append(rec)
        else:
            unique_lookup[key] = rec

    # Remove ambiguous keys from unique lookup.
    for key in ambiguous_lookup:
        unique_lookup.pop(key, None)

    return unique_lookup, ambiguous_lookup


def find_gen_row_indices(lines: List[str]) -> List[int]:
    start_idx = None
    end_idx = None

    for i, ln in enumerate(lines):
        if start_idx is None and re.search(r"^\s*mpc\.gen\s*=\s*\[", ln):
            start_idx = i
            continue
        if start_idx is not None and re.search(r"^\s*\];\s*$", ln):
            end_idx = i
            break

    if start_idx is None or end_idx is None:
        raise RuntimeError("Could not locate mpc.gen block")

    indices: List[int] = []
    for i in range(start_idx + 1, end_idx):
        s = lines[i].strip()
        if not s or s.startswith("%"):
            continue
        indices.append(i)

    return indices


def find_gencost_row_indices(lines: List[str]) -> List[int]:
    start_idx = None
    end_idx = None

    for i, ln in enumerate(lines):
        if start_idx is None and re.search(r"^\s*mpc\.gencost\s*=\s*\[", ln):
            start_idx = i
            continue
        if start_idx is not None and re.search(r"^\s*\];\s*$", ln):
            end_idx = i
            break

    if start_idx is None or end_idx is None:
        raise RuntimeError("Could not locate mpc.gencost block")

    indices: List[int] = []
    for i in range(start_idx + 1, end_idx):
        s = lines[i].strip()
        if not s or s.startswith("%"):
            continue
        indices.append(i)

    return indices


def make_gencost_line(rec: JsonCostRecord) -> str:
    # Force polynomial rows to exactly 3 coefficients (c2, c1, c0).
    # If fewer than 3 are provided, pad leading zeros.
    # If more than 3 are provided, keep the last 3 (lowest-order terms).
    coeffs = list(rec.cost)
    if len(coeffs) < 3:
        coeffs = [0.0] * (3 - len(coeffs)) + coeffs
    elif len(coeffs) > 3:
        coeffs = coeffs[-3:]

    # JSON costs are in p.u. (base 100 MW); convert to per-MW for CATS.
    # c2 ($/MW²h): divide by 100² = 10000; c1 ($/MWh): divide by 100; c0 ($/h): unchanged.
    # coeffs[0] /= 10000.0
    # coeffs[1] /= 100.0

    values = [rec.model, rec.startup, rec.shutdown, 3] + coeffs
    return "    " + "\t".join(str(v) for v in values) + "\n"


def write_tsv(path: Path, header: List[str], rows: List[List[str]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as f:
        f.write("\t".join(header) + "\n")
        for row in rows:
            f.write("\t".join(row) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="Build CaliforniaTestSystem_uc_costs.m from JSON cost data")
    parser.add_argument(
        "--base-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Project root directory (default: parent of hydro_data)",
    )
    parser.add_argument(
        "--input-matpower",
        type=Path,
        default=None,
        help="Input MATPOWER file path (default: <base-dir>/MATPOWER/CaliforniaTestSystem.m)",
    )
    parser.add_argument(
        "--output-matpower",
        type=Path,
        default=None,
        help="Output MATPOWER file path (default: <base-dir>/MATPOWER/CaliforniaTestSystem_uc_costs.m)",
    )
    parser.add_argument(
        "--gens-csv",
        type=Path,
        default=None,
        help="CATS generator CSV path (default: <base-dir>/GIS/CATS_gens.csv)",
    )
    parser.add_argument(
        "--model-json",
        type=Path,
        default=None,
        help="California model JSON path (default: <base-dir>/hydro_data/california_model.json)",
    )
    args = parser.parse_args()

    base_dir = args.base_dir.resolve()
    input_matpower = (args.input_matpower or (base_dir / "MATPOWER" / "CaliforniaTestSystem.m")).resolve()
    output_matpower = (args.output_matpower or (base_dir / "MATPOWER" / "CaliforniaTestSystem_uc_costs.m")).resolve()
    gens_csv = (args.gens_csv or (base_dir / "GIS" / "CATS_gens.csv")).resolve()
    model_json = (args.model_json or (base_dir / "hydro_data" / "california_model.json")).resolve()

    csv_keys = load_csv_keys(gens_csv)
    unique_lookup, ambiguous_lookup = load_json_lookup(model_json)

    lines = input_matpower.read_text(encoding="utf-8").splitlines(keepends=True)
    gen_row_indices = find_gen_row_indices(lines)
    gencost_row_indices = find_gencost_row_indices(lines)

    if len(gencost_row_indices) != len(csv_keys):
        raise RuntimeError(
            f"Row mismatch: gencost rows={len(gencost_row_indices)} vs CATS_gens rows={len(csv_keys)}"
        )
    if len(gen_row_indices) != len(csv_keys):
        raise RuntimeError(
            f"Row mismatch: gen rows={len(gen_row_indices)} vs CATS_gens rows={len(csv_keys)}"
        )

    matched = 0
    unmatched = 0
    ambiguous = 0
    gencost_changed = 0
    pmin_changed = 0
    pmin_log: List[List[str]] = []

    unmatched_rows: List[List[str]] = []

    for rownum, line_idx in enumerate(gencost_row_indices, start=1):
        plant, genid = csv_keys[rownum - 1]
        key = (plant, genid)

        if key in ambiguous_lookup:
            ambiguous += 1
            unmatched += 1
            unmatched_rows.append([str(rownum), plant, genid, "ambiguous"])
            continue

        rec = unique_lookup.get(key)
        if rec is None:
            unmatched += 1
            unmatched_rows.append([str(rownum), plant, genid, "no_match"])
            continue

        matched += 1
        # Only update startup and shutdown; leave cost coefficients unchanged.
        existing = lines[line_idx].rstrip("\n").split()
        existing[1] = str(rec.startup)
        existing[2] = str(rec.shutdown)
        new_line = "    " + "\t".join(existing) + "\n"
        # new_line = make_gencost_line(rec)  # replaces all cost data
        if lines[line_idx] != new_line:
            lines[line_idx] = new_line
            gencost_changed += 1

        # Update Pmin in mpc.gen (column index 9); JSON pmin is in p.u., convert to MW.
        if rec.pmin is not None:
            gen_idx = gen_row_indices[rownum - 1]
            gen_fields = lines[gen_idx].rstrip("\n").split()
            old_pmin = gen_fields[9]
            new_pmin = str(rec.pmin * 100.0)
            gen_fields[9] = new_pmin
            new_gen_line = "    " + "\t".join(gen_fields) + "\n"
            if lines[gen_idx] != new_gen_line:
                lines[gen_idx] = new_gen_line
                pmin_changed += 1
            pmin_log.append([str(rownum), plant, genid, old_pmin, new_pmin])

    output_matpower.write_text("".join(lines), encoding="utf-8")

    # Optional reports in hydro_data folder.
    report_dir = base_dir / "hydro_data"
    unmatched_report = report_dir / "uc_cost_mapping_unmatched.tsv"
    ambiguous_report = report_dir / "uc_cost_mapping_ambiguous.tsv"

    write_tsv(
        unmatched_report,
        ["gencost_row", "PlantCode", "GenID", "reason"],
        unmatched_rows,
    )

    amb_rows: List[List[str]] = []
    for (plant, genid), recs in sorted(ambiguous_lookup.items()):
        amb_rows.append([plant, genid, str(len(recs))])
    write_tsv(ambiguous_report, ["eia_plant_id", "eia_generator_id", "json_records"], amb_rows)

    print(f"Input MATPOWER file:   {input_matpower}")
    print(f"Output MATPOWER file:  {output_matpower}")
    print(f"CATS rows:             {len(csv_keys)}")
    print(f"Matched rows:          {matched}")
    print(f"Unmatched rows:        {unmatched}")
    print(f"Ambiguous rows:        {ambiguous}")
    print(f"Changed gencost rows:  {gencost_changed}")
    print(f"Changed Pmin values:   {pmin_changed}")
    print(f"Unique JSON keys:      {len(unique_lookup)}")
    print(f"Ambiguous JSON keys:   {len(ambiguous_lookup)}")
    print(f"Wrote unmatched report: {unmatched_report}")
    print(f"Wrote ambiguous report: {ambiguous_report}")
    if pmin_log:
        print(f"\n{'row':>5}  {'PlantCode':>12}  {'GenID':>8}  {'old_Pmin_MW':>14}  {'new_Pmin_MW':>14}")
        for row in pmin_log:
            print(f"{row[0]:>5}  {row[1]:>12}  {row[2]:>8}  {row[3]:>14}  {row[4]:>14}")


if __name__ == "__main__":
    main()
