#!/usr/bin/env python3
"""
OCP SRV CMS - Intel MLC Results Parser (parse_results.py)

Parses MLC benchmark output files and normalizes into:
  - JSON (primary) — structured data with metadata, config, results, and errors
  - CSV (secondary) — for generate_report.sh HTML table rendering

Usage:
    python3 parse_results.py <mlc_output_dir>

JSON output:  results_mlc.json  (single combined file)
CSV output:   results_mlc_bandwidth.csv, results_mlc_bw_ramp.csv, etc.
"""

import csv
import glob
import json
import os
import re
import sys
from datetime import datetime, timezone


def log(msg):
    print(f"[PARSER] {msg}")


def _safe_float(val, default=None):
    try:
        return float(val)
    except (ValueError, TypeError):
        return default


def _safe_int(val, default=None):
    try:
        return int(val)
    except (ValueError, TypeError):
        return default


# =============================================================================
# Idle Latency
# =============================================================================

def parse_idle_latency(output_dir):
    """Parse idle_latency_*.txt files."""
    results = []
    errors = []

    files = sorted(glob.glob(os.path.join(output_dir, "idle_latency_*.txt")))
    if not files:
        log("No idle latency files found")
        return results, errors

    for txt in files:
        basename = os.path.basename(txt)
        m = re.match(r"idle_latency_(seq|rand)_numa_node_(\d+)\.txt", basename)
        if not m:
            errors.append({"file": basename, "error": "Filename does not match expected pattern"})
            continue

        pattern = m.group(1)
        node = int(m.group(2))

        with open(txt) as f:
            content = f.read()

        lat_match = re.search(r"Each iteration took\s+([\d.]+)\s*ns", content)
        if lat_match:
            results.append({
                "numa_node": node,
                "pattern": pattern,
                "latency_ns": _safe_float(lat_match.group(1)),
            })
        else:
            errors.append({"file": basename, "error": "Could not extract latency value"})

    log(f"Idle latency: {len(results)} results, {len(errors)} errors")
    return results, errors


# =============================================================================
# Peak Bandwidth
# =============================================================================

def parse_bandwidth(output_dir):
    """Parse bw_node*.txt files."""
    results = []
    errors = []

    files = sorted(glob.glob(os.path.join(output_dir, "bw_node*.txt")))
    if not files:
        log("No bandwidth files found")
        return results, errors

    for txt in files:
        basename = os.path.basename(txt)
        m = re.match(r"bw_node(\d+)_(seq|rnd)_(.+)\.txt", basename)
        if not m:
            errors.append({"file": basename, "error": "Filename does not match expected pattern"})
            continue

        node = int(m.group(1))
        access = m.group(2)
        traffic = m.group(3)

        with open(txt) as f:
            content = f.read()

        # MLC loaded_latency output: after === separator, data lines are "Delay Latency Bandwidth"
        bw_value = None
        lat_value = None
        in_data = False
        for line in content.strip().split("\n"):
            if "===========" in line:
                in_data = True
                continue
            if in_data:
                parts = line.split()
                if len(parts) >= 3:
                    lat_value = _safe_float(parts[1])
                    bw_value = _safe_float(parts[2])

        if bw_value is not None:
            results.append({
                "numa_node": node,
                "access_pattern": access,
                "traffic_type": traffic,
                "bandwidth_mib_s": bw_value,
                "latency_ns": lat_value,
            })
        else:
            errors.append({"file": basename, "error": "Could not extract bandwidth value"})

    log(f"Bandwidth: {len(results)} results, {len(errors)} errors")
    return results, errors


# =============================================================================
# BW Ramp (merge per-config CSVs)
# =============================================================================

def parse_ramp_csvs(output_dir, pattern, label):
    """Merge per-config bw_ramp CSVs into structured data."""
    csv_files = sorted(glob.glob(os.path.join(output_dir, pattern)))
    results = []
    errors = []

    if not csv_files:
        log(f"No {label} CSV files found")
        return results, errors

    for cf in csv_files:
        try:
            with open(cf) as f:
                reader = csv.DictReader(f)
                for row in reader:
                    cleaned = {}
                    for k, v in row.items():
                        k = k.strip()
                        if v is not None:
                            v = v.strip().strip('"')
                        # Try numeric conversion
                        float_val = _safe_float(v)
                        int_val = _safe_int(v)
                        if int_val is not None and str(int_val) == v:
                            cleaned[k] = int_val
                        elif float_val is not None:
                            cleaned[k] = float_val
                        else:
                            cleaned[k] = v
                    results.append(cleaned)
        except Exception as e:
            errors.append({"file": os.path.basename(cf), "error": str(e)})

    log(f"{label}: {len(results)} rows from {len(csv_files)} files")
    return results, errors


# =============================================================================
# Latency Matrix
# =============================================================================

def parse_latency_matrix(output_dir):
    """Parse latency_matrix.txt into structured data."""
    src = os.path.join(output_dir, "latency_matrix.txt")
    if not os.path.isfile(src):
        log("No latency_matrix.txt found")
        return None, []

    with open(src) as f:
        lines = f.readlines()

    node_ids = []
    matrix = []

    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.lower().startswith("numa"):
            # Header: "numa  node0  node1  ..."
            parts = stripped.split()
            node_ids = [p for p in parts if p.lower() != "numa"]
            continue
        parts = stripped.split()
        if parts and parts[0].isdigit():
            source = int(parts[0])
            latencies = [_safe_float(p) for p in parts[1:]]
            entry = {"source_node": source}
            for i, nid in enumerate(node_ids):
                if i < len(latencies):
                    entry[nid] = latencies[i]
            matrix.append(entry)

    if matrix:
        log(f"Latency matrix: {len(matrix)} nodes")
        return {"node_ids": node_ids, "matrix": matrix}, []
    else:
        return None, [{"file": "latency_matrix.txt", "error": "Could not parse matrix"}]


# =============================================================================
# CSV writers (for generate_report.sh backward compatibility)
# =============================================================================

def write_csv(filepath, fieldnames, rows):
    """Write a list of dicts as CSV."""
    if not rows:
        return
    with open(filepath, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    log(f"Wrote CSV: {filepath} ({len(rows)} rows)")


def write_idle_latency_csv(output_dir, data):
    if not data:
        return
    write_csv(
        os.path.join(output_dir, "results_mlc_idle_latency.csv"),
        ["NUMA Node", "Pattern", "Latency (ns)"],
        [{"NUMA Node": r["numa_node"], "Pattern": r["pattern"], "Latency (ns)": r["latency_ns"]} for r in data],
    )


def write_bandwidth_csv(output_dir, data):
    if not data:
        return
    write_csv(
        os.path.join(output_dir, "results_mlc_bandwidth.csv"),
        ["NUMA Node", "Access Pattern", "Traffic Type", "Bandwidth (MiB/s)", "Latency (ns)"],
        [{"NUMA Node": r["numa_node"], "Access Pattern": r["access_pattern"],
          "Traffic Type": r["traffic_type"], "Bandwidth (MiB/s)": r["bandwidth_mib_s"],
          "Latency (ns)": r.get("latency_ns", "")} for r in data],
    )


def write_ramp_csv(output_dir, data, filename):
    if not data:
        return
    fieldnames = list(data[0].keys())
    write_csv(os.path.join(output_dir, filename), fieldnames, data)


def write_latency_matrix_csv(output_dir, data):
    if not data:
        return
    matrix = data["matrix"]
    if not matrix:
        return
    fieldnames = list(matrix[0].keys())
    write_csv(os.path.join(output_dir, "results_mlc_latency_matrix.csv"), fieldnames, matrix)


# =============================================================================
# Main
# =============================================================================

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <mlc_output_dir>")
        sys.exit(1)

    output_dir = sys.argv[1]
    log(f"Parsing MLC results from: {output_dir}")

    all_errors = []

    # Parse each data type
    idle_lat_data, idle_lat_errors = parse_idle_latency(output_dir)
    all_errors.extend(idle_lat_errors)

    bw_data, bw_errors = parse_bandwidth(output_dir)
    all_errors.extend(bw_errors)

    ramp_data, ramp_errors = parse_ramp_csvs(output_dir, "bw_ramp.results.*.csv", "BW Ramp")
    all_errors.extend(ramp_errors)

    interleave_data, interleave_errors = parse_ramp_csvs(output_dir, "bw_ramp_interleave.results.*.csv", "BW Ramp Interleave")
    all_errors.extend(interleave_errors)

    latency_matrix, matrix_errors = parse_latency_matrix(output_dir)
    all_errors.extend(matrix_errors)

    # ----- Write JSON (primary output) -----
    json_output = {
        "benchmark": "intel-mlc",
        "parser_version": "1.0.0",
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source_dir": os.path.basename(output_dir),
        "idle_latency": idle_lat_data if idle_lat_data else None,
        "bandwidth": bw_data if bw_data else None,
        "bw_ramp": ramp_data if ramp_data else None,
        "bw_ramp_interleave": interleave_data if interleave_data else None,
        "latency_matrix": latency_matrix,
        "errors": all_errors if all_errors else None,
    }

    json_path = os.path.join(output_dir, "results_mlc.json")
    with open(json_path, "w") as f:
        json.dump(json_output, f, indent=2)
    log(f"Wrote JSON: {json_path}")

    # ----- Write CSVs (for generate_report.sh) -----
    write_idle_latency_csv(output_dir, idle_lat_data)
    write_bandwidth_csv(output_dir, bw_data)
    write_ramp_csv(output_dir, ramp_data, "results_mlc_bw_ramp.csv")
    write_ramp_csv(output_dir, interleave_data, "results_mlc_bw_ramp_interleave.csv")
    write_latency_matrix_csv(output_dir, latency_matrix)

    # Summary
    csvs = sorted(glob.glob(os.path.join(output_dir, "results_*.csv")))
    log(f"Produced: 1 JSON + {len(csvs)} CSV file(s)")


if __name__ == "__main__":
    main()
