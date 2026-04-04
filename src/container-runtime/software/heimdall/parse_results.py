#!/usr/bin/env python3
"""
OCP SRV CMS - Heimdall Results Parser (parse_results.py)

Benchmark-specific adapter that finds heimdall's raw output and normalizes
it into:
  - JSON (primary) — structured data with metadata, config, results, and errors
  - CSV (secondary) — for generate_report.sh HTML table rendering (fallback)

Usage:
    python3 parse_results.py <results_dir> <benchmark> <config>

JSON output:  results_<benchmark>_<config>.json  (single combined file)
CSV output:   results_<benchmark>_<config>.csv   (flat table, fallback)
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
# 1. Basic Performance: BW vs Latency (job 100)
# =============================================================================

def parse_bw_latency(results_dir):
    """Parse result.log files into JSON and CSV."""
    errors = []

    # Always parse result.log files directly
    log("Parsing result.log files...")
    results = _parse_result_logs(results_dir, errors)

    # Fallback: read heimdall's own CSV if no result.log data
    if not results:
        existing = sorted(glob.glob(
            os.path.join(results_dir, "**", "parsed_result_logs.csv"),
            recursive=True
        ))
        for src in reversed(existing):
            line_count = sum(1 for _ in open(src)) - 1
            if line_count > 0:
                log(f"Falling back to heimdall CSV: {src} ({line_count} rows)")
                results = _read_csv_as_dicts(src)
                break
            else:
                log(f"Skipping empty CSV: {src}")

    if not results:
        errors.append({"error": "No bw_latency result.log data found"})
        log("WARNING: No result.log data found to parse")

    # Write JSON
    json_output = {
        "benchmark": "heimdall",
        "test": "bw_vs_latency",
        "parser_version": "1.0.0",
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "results": results if results else None,
        "errors": errors if errors else None,
    }
    json_path = os.path.join(results_dir, "results_bw_latency.json")
    with open(json_path, "w") as f:
        json.dump(json_output, f, indent=2)
    log(f"Wrote JSON: {json_path}")

    # Write CSV (fallback for generate_report.sh)
    if results:
        _write_bw_latency_csv(results, os.path.join(results_dir, "results_bw_latency.csv"))


def _parse_result_logs(base_dir, errors):
    """Walk result.log files and extract test data."""
    results = []

    for root, _, files in os.walk(base_dir):
        if "result.log" not in files:
            continue
        log_path = os.path.join(root, "result.log")
        with open(log_path) as f:
            content = f.read()

        test_info = re.search(
            r"Test Information:\n"
            r"Buffer Size: (\d+MiB)\n"
            r"Number of Threads: (\d+)\n"
            r"Job Id: (\d+)\n"
            r"Access Type: (\w+)\n"
            r"LoadStore Type: (\w+)\n"
            r"Block Size: (\d+) bytes\n"
            r"Mem alloc Type: (\w+)\n"
            r"Latency Pattern: (\w+)\n"
            r"Bandwidth Pattern: (\w+)\n",
            content,
        )
        total_bw = re.search(r"Total Bandwidth : ([\d.]+) MiB/s", content)
        latency = re.search(r"Measured Latency : (\d+) ns", content)

        if test_info and total_bw and latency:
            (size, threads, job_id, access_type, ls_type,
             block_size, mem_alloc, lat_pattern, bw_pattern) = test_info.groups()
            results.append({
                "buffer_size": size,
                "threads": int(threads),
                "job_id": int(job_id),
                "access_type": access_type,
                "loadstore_type": ls_type,
                "block_size_bytes": int(block_size),
                "mem_alloc_type": mem_alloc,
                "latency_pattern": lat_pattern,
                "bandwidth_pattern": bw_pattern,
                "total_bandwidth_mib_s": float(total_bw.group(1)),
                "measured_latency_ns": int(latency.group(1)),
            })
        else:
            relpath = os.path.relpath(log_path, base_dir)
            errors.append({"file": relpath, "error": "Missing test info, bandwidth, or latency fields"})

    results.sort(key=lambda x: (x["access_type"], x["loadstore_type"], x["threads"]))
    log(f"Parsed {len(results)} result.log files")
    return results


def _read_csv_as_dicts(csv_path):
    """Read a CSV file into a list of dicts with normalized keys."""
    results = []
    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            results.append({
                "access_type": row.get("Access Type", ""),
                "loadstore_type": row.get("LoadStore Type", ""),
                "threads": _safe_int(row.get("Threads")),
                "block_size_bytes": _safe_int(row.get("Block Size (bytes)")),
                "total_bandwidth_mib_s": _safe_float(row.get("Total Bandwidth (MiB/s)")),
                "measured_latency_ns": _safe_int(row.get("Measured Latency (ns)")),
                "latency_pattern": row.get("Latency Pattern", ""),
                "bandwidth_pattern": row.get("Bandwidth Pattern", ""),
            })
    return results


def _write_bw_latency_csv(data, output_file):
    """Write parsed bw/latency data as CSV."""
    fieldnames = [
        "Access Type", "LoadStore Type", "Threads", "Block Size (bytes)",
        "Total Bandwidth (MiB/s)", "Measured Latency (ns)",
        "Latency Pattern", "Bandwidth Pattern",
    ]
    with open(output_file, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for r in data:
            writer.writerow({
                "Access Type": r.get("access_type", ""),
                "LoadStore Type": r.get("loadstore_type", ""),
                "Threads": r.get("threads", ""),
                "Block Size (bytes)": r.get("block_size_bytes", ""),
                "Total Bandwidth (MiB/s)": r.get("total_bandwidth_mib_s", ""),
                "Measured Latency (ns)": r.get("measured_latency_ns", ""),
                "Latency Pattern": r.get("latency_pattern", ""),
                "Bandwidth Pattern": r.get("bandwidth_pattern", ""),
            })
    log(f"Wrote CSV: {output_file} ({len(data)} rows)")


# =============================================================================
# 2. Basic Performance: Cache Heatmap (job 200)
# =============================================================================

def parse_cache(results_dir):
    """Cache test parser — placeholder."""
    log("Cache heatmap parsing not yet implemented (output is plot-only)")


# =============================================================================
# 3. LLM Bench
# =============================================================================

def parse_llm(results_dir, config):
    """Find and normalize LLM benchmark output into JSON and CSV."""
    errors = []

    log_dir_map = {
        "pytorch": "pytorch",
        "llamacpp": "llamacpp",
        "vllm_cpu": "vllm",
        "vllm_gpu": "vllm_gpu",
    }
    subdir = log_dir_map.get(config, config)

    # Find the summary CSV
    search_paths = [
        os.path.join(results_dir, "llm_bench_logs", subdir, "test_results.csv"),
        os.path.join(results_dir, "llm_bench_logs", "test_results.csv"),
    ]
    src = None
    for p in search_paths:
        if os.path.isfile(p):
            src = p
            break
    if src is None:
        found = glob.glob(os.path.join(results_dir, "**", "test_results.csv"), recursive=True)
        if found:
            src = found[0]

    summary_results = []
    if src:
        log(f"Found LLM results: {src}")
        with open(src) as infile:
            for line in infile:
                line = line.strip()
                if not line:
                    continue
                sep = "|" if "|" in line else ","
                fields = [f.strip() for f in line.split(sep)]
                if fields and fields[0].lower() in ("cpu", "cpu_bind"):
                    continue  # skip header
                if len(fields) >= 3:
                    summary_results.append({
                        "cpu_bind": fields[0],
                        "mem_bind": fields[1],
                        "tokens_per_sec": _safe_float(fields[2]),
                    })
    else:
        errors.append({"error": f"No test_results.csv found for llm/{config}"})

    # Extract per-run JSON details
    detail_results = []
    if src:
        json_files = sorted(glob.glob(os.path.join(os.path.dirname(src), "*.json")))
        for jf in json_files:
            try:
                with open(jf) as f:
                    data = json.load(f)
                entry = {"file": os.path.basename(jf)}
                for key in ["elapsed_time", "num_requests", "total_num_tokens",
                             "tokens_per_second", "requests_per_second"]:
                    if key in data:
                        entry[key] = data[key]
                detail_results.append(entry)
            except (json.JSONDecodeError, KeyError):
                errors.append({"file": os.path.basename(jf), "error": "Could not parse JSON"})

    # Write JSON
    json_output = {
        "benchmark": "heimdall",
        "test": f"llm_{config}",
        "parser_version": "1.0.0",
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": summary_results if summary_results else None,
        "detail": detail_results if detail_results else None,
        "errors": errors if errors else None,
    }
    json_path = os.path.join(results_dir, f"results_llm_{config}.json")
    with open(json_path, "w") as f:
        json.dump(json_output, f, indent=2)
    log(f"Wrote JSON: {json_path}")

    # Write CSV (fallback)
    if summary_results:
        dst = os.path.join(results_dir, f"results_llm_{config}.csv")
        with open(dst, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=["cpu_bind", "mem_bind", "tokens_per_sec"])
            writer.writeheader()
            writer.writerows(summary_results)
        log(f"Wrote CSV: {dst} ({len(summary_results)} rows)")


# =============================================================================
# 4. Lockfree Bench
# =============================================================================

def parse_lockfree(results_dir):
    """Convert lockfree JSON results into normalized JSON and CSV."""
    errors = []

    # Find the raw results JSON
    search_paths = [
        os.path.join(results_dir, "lockfree_bench_results"),
        results_dir,
    ]
    raw_file = None
    for base in search_paths:
        if not os.path.isdir(base):
            continue
        for f in sorted(os.listdir(base)):
            if f.startswith("res_") and not f.endswith((".csv", ".json")):
                candidate = os.path.join(base, f)
                if os.path.isfile(candidate):
                    raw_file = candidate
                    break
        if raw_file:
            break

    if raw_file is None:
        log("WARNING: No lockfree results found")
        return

    log(f"Found lockfree results: {raw_file}")

    try:
        with open(raw_file) as f:
            raw_data = json.load(f)
    except (json.JSONDecodeError, FileNotFoundError) as e:
        log(f"WARNING: Could not parse lockfree JSON: {e}")
        return

    # Flatten nested structure into a list of records
    results = []
    for category, ds_types in raw_data.items():
        if not isinstance(ds_types, dict):
            continue
        for ds_type, numa_configs in ds_types.items():
            if not isinstance(numa_configs, dict):
                continue
            for numa_config, sizes in numa_configs.items():
                if not isinstance(sizes, dict):
                    continue
                for size_mb, avg_ns in sorted(sizes.items(), key=lambda x: int(x[0])):
                    results.append({
                        "category": category,
                        "data_structure": ds_type,
                        "numa_config": numa_config,
                        "size_mb": int(size_mb),
                        "avg_time_ns": round(avg_ns, 2) if isinstance(avg_ns, float) else avg_ns,
                    })

    # Write JSON
    json_output = {
        "benchmark": "heimdall",
        "test": "lockfree",
        "parser_version": "1.0.0",
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "results": results if results else None,
        "raw_structure": raw_data,
        "errors": errors if errors else None,
    }
    json_path = os.path.join(results_dir, "results_lockfree.json")
    with open(json_path, "w") as f:
        json.dump(json_output, f, indent=2)
    log(f"Wrote JSON: {json_path}")

    # Write CSV (fallback)
    if results:
        dst = os.path.join(results_dir, "results_lockfree.csv")
        fieldnames = ["Category", "Data Structure", "NUMA Config", "Size (MB)", "Avg Time (ns)"]
        with open(dst, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            for r in results:
                writer.writerow({
                    "Category": r["category"],
                    "Data Structure": r["data_structure"],
                    "NUMA Config": r["numa_config"],
                    "Size (MB)": r["size_mb"],
                    "Avg Time (ns)": r["avg_time_ns"],
                })
        log(f"Wrote CSV: {dst} ({len(results)} rows)")


# =============================================================================
# Main
# =============================================================================

def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <results_dir> <benchmark> [config]")
        sys.exit(1)

    results_dir = sys.argv[1]
    benchmark = sys.argv[2]
    config = sys.argv[3] if len(sys.argv) > 3 else "all"

    log(f"Parsing results: benchmark={benchmark} config={config}")
    log(f"Results directory: {results_dir}")

    if benchmark == "basic":
        if config in ("bw", "all"):
            parse_bw_latency(results_dir)
        if config in ("cache", "all"):
            parse_cache(results_dir)
    elif benchmark == "llm":
        parse_llm(results_dir, config)
    elif benchmark == "lockfree":
        parse_lockfree(results_dir)
    else:
        log(f"WARNING: Unknown benchmark '{benchmark}' — no parser available")

    # Summary
    jsons = sorted(glob.glob(os.path.join(results_dir, "results_*.json")))
    csvs = sorted(glob.glob(os.path.join(results_dir, "results_*.csv")))
    log(f"Produced: {len(jsons)} JSON + {len(csvs)} CSV file(s)")
    for j in jsons:
        log(f"  {os.path.basename(j)}")
    for c in csvs:
        rows = sum(1 for _ in open(c)) - 1
        log(f"  {os.path.basename(c)} ({rows} data rows)")


if __name__ == "__main__":
    main()
