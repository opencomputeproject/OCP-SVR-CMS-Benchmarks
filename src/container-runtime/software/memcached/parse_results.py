#!/usr/bin/env python3
"""
OCP SRV CMS - Memcached/Memaslap Results Parser (parse_results.py)

Parses memaslap benchmark output and normalizes into:
  - JSON (primary) — structured data with config, periodic stats, summary, errors
  - CSV (secondary) — for generate_report.sh HTML table rendering

Memaslap output format:
  1. Config header:  "servers : ...", "threads count: ...", etc.
  2. Periodic stats: "Get Statistics" / "Set Statistics" tables with
     Type, Time(s), Ops, TPS, Net, Get_miss, Min(us), Max(us), Avg(us), ...
  3. Final summary:  "Run time: 180.0s Ops: 17632652 TPS: 97959 Net_rate: 8.4M/s"

Usage:
    python3 parse_results.py <results_dir>

JSON output:  results_memcached.json
CSV output:   results_memcached.csv (summary) + results_memcached_stats.csv (periodic)
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
# Parse memaslap configuration header
# =============================================================================

def parse_config(text):
    """Extract configuration from memaslap output header."""
    config = {}

    patterns = {
        "servers": r"servers\s*:\s*(.+)",
        "threads_count": r"threads count:\s*(\d+)",
        "concurrency": r"concurrency:\s*(\d+)",
        "run_time": r"run time:\s*(\S+)",
        "windows_size": r"windows size:\s*(\S+)",
        "set_proportion": r"set proportion:\s*set_prop=([\d.]+)",
        "get_proportion": r"get proportion:\s*get_prop=([\d.]+)",
    }

    for key, pattern in patterns.items():
        m = re.search(pattern, text, re.IGNORECASE)
        if m:
            val = m.group(1).strip()
            int_val = _safe_int(val)
            float_val = _safe_float(val)
            if int_val is not None and str(int_val) == val:
                config[key] = int_val
            elif float_val is not None and key in ("set_proportion", "get_proportion"):
                config[key] = float_val
            else:
                config[key] = val

    return config if config else None


# =============================================================================
# Parse periodic statistics tables
# =============================================================================

def parse_statistics(text):
    """
    Extract Get/Set statistics blocks from memaslap output.

    Format:
        Get Statistics (or Set Statistics)
        Type     Time(s)  Ops       TPS(ops/s)  Net(M/s)  Get_miss  Min(us)  Max(us)  Avg(us)  Std_dev   Geo_dist
        Period    5       48870     9774.00     0.84      0         27       2198     326.57   ...
        Global    5       48870     9774.00     0.84      0         27       2198     326.57   ...
    """
    stats = {"get": [], "set": []}
    errors = []

    # Split into lines and walk through looking for stat blocks
    lines = text.split("\n")
    current_op = None  # "get" or "set"
    in_header = False

    for line in lines:
        stripped = line.strip()

        # Detect stat block headers
        if re.match(r"Get Statistics", stripped, re.IGNORECASE):
            current_op = "get"
            in_header = True
            continue
        elif re.match(r"Set Statistics", stripped, re.IGNORECASE):
            current_op = "set"
            in_header = True
            continue

        # Skip the column header line (starts with "Type")
        if in_header and stripped.lower().startswith("type"):
            in_header = False
            continue

        # Skip separator lines
        if stripped.startswith("---"):
            continue

        # Parse data lines (Period/Global)
        if current_op and stripped and (stripped.startswith("Period") or stripped.startswith("Global")):
            parts = stripped.split()
            if len(parts) >= 9:
                entry = {
                    "type": parts[0],  # Period or Global
                    "time_s": _safe_float(parts[1]),
                    "ops": _safe_int(parts[2]),
                    "tps": _safe_float(parts[3]),
                    "net_m_s": _safe_float(parts[4]),
                    "get_miss": _safe_int(parts[5]),
                    "min_us": _safe_float(parts[6]),
                    "max_us": _safe_float(parts[7]),
                    "avg_us": _safe_float(parts[8]),
                }
                if len(parts) >= 10:
                    entry["std_dev"] = _safe_float(parts[9])
                if len(parts) >= 11:
                    entry["geo_dist"] = _safe_float(parts[10])
                stats[current_op].append(entry)
            continue

        # Reset current_op on blank lines or new sections
        if not stripped:
            current_op = None
            in_header = False

    get_count = len(stats["get"])
    set_count = len(stats["set"])
    log(f"Periodic stats: {get_count} get entries, {set_count} set entries")

    return stats if (get_count > 0 or set_count > 0) else None, errors


# =============================================================================
# Parse final summary line
# =============================================================================

def parse_summary(text):
    """
    Extract the final summary line:
        Run time: 180.0s Ops: 17632652 TPS: 97959 Net_rate: 8.4M/s
    """
    summary = {}

    m = re.search(
        r"Run time:\s*([\d.]+)s\s+"
        r"Ops:\s*(\d+)\s+"
        r"TPS:\s*(\d+)\s+"
        r"Net_rate:\s*([\d.]+)(\S*)/s",
        text,
    )
    if m:
        summary["run_time_s"] = _safe_float(m.group(1))
        summary["total_ops"] = _safe_int(m.group(2))
        summary["tps"] = _safe_int(m.group(3))
        net_val = _safe_float(m.group(4))
        net_unit = m.group(5)
        if net_val is not None:
            summary["net_rate"] = f"{net_val}{net_unit}/s"
            summary["net_rate_value"] = net_val
            summary["net_rate_unit"] = f"{net_unit}/s"
        log(f"Summary: {summary['total_ops']} ops, {summary['tps']} TPS, {summary['run_time_s']}s")
        return summary

    log("WARNING: Could not parse final summary line")
    return None


# =============================================================================
# Parse the run_memcached.sh results.csv (test metadata)
# =============================================================================

def parse_run_metadata(results_dir):
    """Read the results.csv written by run_memcached.sh for test metadata."""
    csv_file = os.path.join(results_dir, "results.csv")
    if not os.path.isfile(csv_file):
        return None

    metadata = []
    with open(csv_file) as f:
        reader = csv.DictReader(f)
        for row in reader:
            entry = {}
            for k, v in row.items():
                if k and v:
                    k = k.strip()
                    v = v.strip().strip('"')
                    float_val = _safe_float(v)
                    if float_val is not None and "." in v:
                        entry[k] = float_val
                    else:
                        entry[k] = v
            if entry:
                metadata.append(entry)

    return metadata if metadata else None


# =============================================================================
# CSV writers
# =============================================================================

def write_summary_csv(results_dir, summary, config, metadata):
    """Write a summary CSV with the key metrics."""
    dst = os.path.join(results_dir, "results_memcached.csv")
    fieldnames = ["Run Time (s)", "Total Ops", "TPS (ops/s)", "Net Rate", "Threads", "Concurrency", "Test Note"]

    row = {
        "Run Time (s)": summary.get("run_time_s", "") if summary else "",
        "Total Ops": summary.get("total_ops", "") if summary else "",
        "TPS (ops/s)": summary.get("tps", "") if summary else "",
        "Net Rate": summary.get("net_rate", "") if summary else "",
        "Threads": config.get("threads_count", "") if config else "",
        "Concurrency": config.get("concurrency", "") if config else "",
        "Test Note": metadata[0].get("note", "") if metadata else "",
    }

    with open(dst, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerow(row)
    log(f"Wrote CSV: {dst}")


def write_stats_csv(results_dir, stats):
    """Write periodic statistics as CSV."""
    if not stats:
        return

    dst = os.path.join(results_dir, "results_memcached_stats.csv")
    fieldnames = ["Operation", "Type", "Time (s)", "Ops", "TPS (ops/s)",
                  "Net (M/s)", "Get Miss", "Min (us)", "Max (us)", "Avg (us)"]

    rows = []
    for op_type in ("get", "set"):
        for entry in stats.get(op_type, []):
            rows.append({
                "Operation": op_type.upper(),
                "Type": entry.get("type", ""),
                "Time (s)": entry.get("time_s", ""),
                "Ops": entry.get("ops", ""),
                "TPS (ops/s)": entry.get("tps", ""),
                "Net (M/s)": entry.get("net_m_s", ""),
                "Get Miss": entry.get("get_miss", ""),
                "Min (us)": entry.get("min_us", ""),
                "Max (us)": entry.get("max_us", ""),
                "Avg (us)": entry.get("avg_us", ""),
            })

    if rows:
        with open(dst, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)
        log(f"Wrote CSV: {dst} ({len(rows)} rows)")


# =============================================================================
# Main
# =============================================================================

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <results_dir>")
        sys.exit(1)

    results_dir = sys.argv[1]
    log(f"Parsing memcached results from: {results_dir}")

    errors = []

    # Find raw_results.txt
    raw_file = os.path.join(results_dir, "raw_results.txt")
    if not os.path.isfile(raw_file):
        log("WARNING: raw_results.txt not found")
        errors.append({"error": "raw_results.txt not found"})
        raw_content = ""
    else:
        with open(raw_file) as f:
            raw_content = f.read()

    # Parse each section
    config = parse_config(raw_content) if raw_content else None
    stats, stat_errors = parse_statistics(raw_content) if raw_content else (None, [])
    errors.extend(stat_errors)
    summary = parse_summary(raw_content) if raw_content else None
    metadata = parse_run_metadata(results_dir)

    # ----- Write JSON (primary output) -----
    json_output = {
        "benchmark": "memcached",
        "parser_version": "1.0.0",
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source_dir": os.path.basename(results_dir),
        "configuration": config,
        "summary": summary,
        "periodic_stats": stats,
        "run_metadata": metadata,
        "errors": errors if errors else None,
    }

    json_path = os.path.join(results_dir, "results_memcached.json")
    with open(json_path, "w") as f:
        json.dump(json_output, f, indent=2)
    log(f"Wrote JSON: {json_path}")

    # ----- Write CSVs (for generate_report.sh) -----
    if summary or config or metadata:
        write_summary_csv(results_dir, summary, config, metadata)
    write_stats_csv(results_dir, stats)

    # Summary
    jsons = sorted(glob.glob(os.path.join(results_dir, "results_*.json")))
    csvs = sorted(glob.glob(os.path.join(results_dir, "results_*.csv")))
    log(f"Produced: {len(jsons)} JSON + {len(csvs)} CSV file(s)")


if __name__ == "__main__":
    main()
