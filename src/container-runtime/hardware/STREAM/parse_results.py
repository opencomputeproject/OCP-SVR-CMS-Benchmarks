#!/usr/bin/env python3
"""
OCP SRV CMS - STREAM Results Parser (parse_results.py)

Parses STREAM benchmark output and normalizes into:
  - JSON (primary) — structured data with metadata, config, results, and errors
  - CSV (secondary) — for generate_report.sh HTML table rendering

Handles two modes:
  - Single STREAM run (raw_results.txt)
  - STREAM scaling (stream_N.log files from run-stream-scaling.sh)

Usage:
    python3 parse_results.py <results_dir>

JSON output:  results_stream.json  (single combined file)
CSV output:   results_stream.csv and/or results_stream_scaling.csv
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
# STREAM output parser (shared between single-run and scaling)
# =============================================================================

def parse_stream_output(text):
    """
    Extract Copy/Scale/Add/Triad results from standard STREAM output.

    OCP CMS STREAM format (with Direction column):
        Function     Direction    BestRateMBs     AvgTime      MinTime      MaxTime
        Copy:        0->0            313592.8     0.000053     0.000051     0.000060
        Scale:       0->0            325771.2     0.000050     0.000049     0.000053
        Add:         0->0            370085.6     0.000067     0.000065     0.000078
        Triad:       0->0            381300.4     0.000077     0.000063     0.000113

    Standard STREAM format (no Direction column):
        Function    Best Rate MB/s  Avg time     Min time     Max time
        Copy:           17253.7       0.093121     0.092723     0.093590
    """
    results = []

    # Pattern with Direction column (e.g. "0->0", "0->2", "interleave")
    pattern_with_dir = re.compile(
        r"^(Copy|Scale|Add|Triad):\s+"
        r"(\S+)\s+"           # direction (e.g. 0->0)
        r"([\d.]+)\s+"        # best rate
        r"([\d.]+)\s+"        # avg time
        r"([\d.]+)\s+"        # min time
        r"([\d.]+)",          # max time
        re.MULTILINE,
    )

    # Pattern without Direction column (standard STREAM)
    pattern_no_dir = re.compile(
        r"^(Copy|Scale|Add|Triad):\s+"
        r"([\d.]+)\s+"        # best rate
        r"([\d.]+)\s+"        # avg time
        r"([\d.]+)\s+"        # min time
        r"([\d.]+)",          # max time
        re.MULTILINE,
    )

    # Try with-direction first (more specific)
    for m in pattern_with_dir.finditer(text):
        direction = m.group(2)
        # Verify it's actually a direction and not a number
        # Directions look like "0->0", "0->2", etc.
        if "->" in direction or not re.match(r"^[\d.]+$", direction):
            results.append({
                "function": m.group(1),
                "direction": direction,
                "best_rate_mb_s": _safe_float(m.group(3)),
                "avg_time_s": _safe_float(m.group(4)),
                "min_time_s": _safe_float(m.group(5)),
                "max_time_s": _safe_float(m.group(6)),
            })

    # Fall back to no-direction pattern if nothing found
    if not results:
        for m in pattern_no_dir.finditer(text):
            results.append({
                "function": m.group(1),
                "best_rate_mb_s": _safe_float(m.group(2)),
                "avg_time_s": _safe_float(m.group(3)),
                "min_time_s": _safe_float(m.group(4)),
                "max_time_s": _safe_float(m.group(5)),
            })

    return results


def parse_stream_config(text):
    """Extract STREAM configuration from output header."""
    config = {}

    array_size = re.search(r"Array size\s*=\s*(\d+)", text)
    if array_size:
        config["array_size"] = _safe_int(array_size.group(1))

    mem_per_array = re.search(r"Memory per array\s*=\s*([\d.]+)\s*(\w+)", text)
    if mem_per_array:
        config["memory_per_array"] = f"{mem_per_array.group(1)} {mem_per_array.group(2)}"

    total_mem = re.search(r"Total memory required\s*=\s*([\d.]+)\s*(\w+)", text)
    if total_mem:
        config["total_memory_required"] = f"{total_mem.group(1)} {total_mem.group(2)}"

    threads = re.search(r"Number of Threads requested\s*=\s*(\d+)", text)
    if threads:
        config["threads_requested"] = _safe_int(threads.group(1))

    threads_counted = re.search(r"Number of Threads counted\s*=\s*(\d+)", text)
    if threads_counted:
        config["threads_counted"] = _safe_int(threads_counted.group(1))

    return config if config else None


# =============================================================================
# Single STREAM run
# =============================================================================

def parse_single_run(results_dir):
    """Parse raw_results.txt from a single STREAM run."""
    raw_file = os.path.join(results_dir, "raw_results.txt")
    if not os.path.isfile(raw_file):
        log("No raw_results.txt found — skipping single-run parse")
        return None, None, []

    with open(raw_file) as f:
        content = f.read()

    config = parse_stream_config(content)
    results = parse_stream_output(content)
    errors = []

    if not results:
        errors.append({"file": "raw_results.txt", "error": "No STREAM results found in output"})
        log("WARNING: No STREAM results found in raw_results.txt")
        return config, None, errors

    log(f"Single run: {len(results)} results")
    return config, results, errors


# =============================================================================
# STREAM scaling
# =============================================================================

def parse_scaling(results_dir):
    """Parse stream_N.log files from STREAM scaling runs."""
    log_files = sorted(glob.glob(os.path.join(results_dir, "**/stream_*.log"), recursive=True))
    if not log_files:
        log("No stream_*.log scaling files found — skipping scaling parse")
        return None, []

    log(f"Found {len(log_files)} scaling log file(s)")

    all_results = []
    errors = []

    for lf in log_files:
        basename = os.path.basename(lf)
        m = re.match(r"stream_(\d+)\.log", basename)
        if not m:
            continue
        threads = int(m.group(1))

        with open(lf) as f:
            content = f.read()

        rows = parse_stream_output(content)
        if rows:
            for row in rows:
                row["threads"] = threads
                all_results.append(row)
        else:
            errors.append({"file": basename, "error": "No STREAM results found"})

    if all_results:
        # Sort by thread count, then function order
        func_order = {"Copy": 0, "Scale": 1, "Add": 2, "Triad": 3}
        all_results.sort(key=lambda r: (r["threads"], func_order.get(r["function"], 99)))
        log(f"Scaling: {len(all_results)} results across {len(log_files)} thread counts")

    return all_results if all_results else None, errors


# =============================================================================
# CSV writers (for generate_report.sh backward compatibility)
# =============================================================================

def write_single_csv(results_dir, data):
    if not data:
        return
    dst = os.path.join(results_dir, "results_stream.csv")
    has_direction = any("direction" in r for r in data)
    if has_direction:
        fieldnames = ["Function", "Direction", "Best Rate (MB/s)", "Avg Time (s)", "Min Time (s)", "Max Time (s)"]
    else:
        fieldnames = ["Function", "Best Rate (MB/s)", "Avg Time (s)", "Min Time (s)", "Max Time (s)"]
    with open(dst, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for r in data:
            row = {
                "Function": r["function"],
                "Best Rate (MB/s)": r["best_rate_mb_s"],
                "Avg Time (s)": r["avg_time_s"],
                "Min Time (s)": r["min_time_s"],
                "Max Time (s)": r["max_time_s"],
            }
            if has_direction:
                row["Direction"] = r.get("direction", "")
            writer.writerow(row)
    log(f"Wrote CSV: {dst} ({len(data)} rows)")


def write_scaling_csv(results_dir, data):
    if not data:
        return
    dst = os.path.join(results_dir, "results_stream_scaling.csv")
    has_direction = any("direction" in r for r in data)
    if has_direction:
        fieldnames = ["Threads", "Function", "Direction", "Best Rate (MB/s)", "Avg Time (s)", "Min Time (s)", "Max Time (s)"]
    else:
        fieldnames = ["Threads", "Function", "Best Rate (MB/s)", "Avg Time (s)", "Min Time (s)", "Max Time (s)"]
    with open(dst, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for r in data:
            row = {
                "Threads": r["threads"],
                "Function": r["function"],
                "Best Rate (MB/s)": r["best_rate_mb_s"],
                "Avg Time (s)": r["avg_time_s"],
                "Min Time (s)": r["min_time_s"],
                "Max Time (s)": r["max_time_s"],
            }
            if has_direction:
                row["Direction"] = r.get("direction", "")
            writer.writerow(row)
    log(f"Wrote CSV: {dst} ({len(data)} rows)")


# =============================================================================
# Main
# =============================================================================

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <results_dir>")
        sys.exit(1)

    results_dir = sys.argv[1]
    log(f"Parsing STREAM results from: {results_dir}")

    all_errors = []

    # Parse single run
    single_config, single_data, single_errors = parse_single_run(results_dir)
    all_errors.extend(single_errors)

    # Parse scaling
    scaling_data, scaling_errors = parse_scaling(results_dir)
    all_errors.extend(scaling_errors)

    # ----- Write JSON (primary output) -----
    json_output = {
        "benchmark": "stream",
        "parser_version": "1.0.0",
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source_dir": os.path.basename(results_dir),
        "configuration": single_config,
        "single_run": single_data,
        "scaling": scaling_data,
        "errors": all_errors if all_errors else None,
    }

    json_path = os.path.join(results_dir, "results_stream.json")
    with open(json_path, "w") as f:
        json.dump(json_output, f, indent=2)
    log(f"Wrote JSON: {json_path}")

    # ----- Write CSVs (for generate_report.sh) -----
    write_single_csv(results_dir, single_data)
    write_scaling_csv(results_dir, scaling_data)

    # Summary
    csvs = sorted(glob.glob(os.path.join(results_dir, "results_*.csv")))
    log(f"Produced: 1 JSON + {len(csvs)} CSV file(s)")


if __name__ == "__main__":
    main()
