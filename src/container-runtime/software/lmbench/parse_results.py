#!/usr/bin/env python3
"""
OCP SRV CMS - LMBench Results Parser (parse_results.py)

Benchmark-specific adapter that finds LMBench's raw JSON output files and
normalizes them into:
  - JSON (primary) — structured data with metadata, config, results, and errors
  - CSV (secondary) — for generate_report.sh HTML table rendering (fallback)

LMBench produces per-run JSON files in 4-latest-results/<suite-name>/ with
the naming convention:
    {baseline_key}_{workload}_{qps}_{timestamp}.json

Each JSON contains:
    - name, lmbench-session-id, timestamp
    - results: throughput, TTFT, TPOT, ITL stats (mean/median/p99)
    - infra, serving, workload configuration

This parser collects all such files, extracts performance metrics, and
produces normalized CMS output.

Usage:
    python3 parse_results.py <results_dir> <suite_name>

JSON output:  results_lmbench_<suite_name>.json  (single combined file)
CSV output:   results_lmbench_<suite_name>.csv   (flat table for report)
"""

import csv
import glob
import json
import os
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


def _extract_nested(data, *keys, default=None):
    """Safely extract nested dict value."""
    current = data
    for key in keys:
        if isinstance(current, dict):
            current = current.get(key)
        else:
            return default
    return current if current is not None else default


def parse_lmbench_results(results_dir, suite_name):
    """
    Find all LMBench JSON result files and normalize into CMS format.

    LMBench outputs JSON files in:
        results_dir/lmbench_results/<suite_name>/*.json
    or directly in:
        results_dir/lmbench_results/**/*.json
    """
    errors = []
    results = []

    # Search for LMBench JSON output files
    search_paths = [
        os.path.join(results_dir, "lmbench_results", suite_name, "*.json"),
        os.path.join(results_dir, "lmbench_results", "**", "*.json"),
        os.path.join(results_dir, "lmbench_results", "*.json"),
    ]

    json_files = set()
    for pattern in search_paths:
        for f in glob.glob(pattern, recursive=True):
            # Skip post-processing and non-result files
            basename = os.path.basename(f)
            if basename.startswith("results_") or basename.startswith("."):
                continue
            json_files.add(f)

    json_files = sorted(json_files)

    if not json_files:
        errors.append({"error": "No LMBench JSON result files found"})
        log("WARNING: No LMBench result JSON files found")
        log(f"  Searched: {results_dir}/lmbench_results/")

        # Check if there are any files at all
        all_files = glob.glob(os.path.join(results_dir, "**", "*.json"), recursive=True)
        if all_files:
            log(f"  Found {len(all_files)} JSON files total (may not be result files):")
            for f in all_files[:10]:
                log(f"    {os.path.relpath(f, results_dir)}")
    else:
        log(f"Found {len(json_files)} LMBench result file(s)")

    for json_path in json_files:
        relpath = os.path.relpath(json_path, results_dir)
        log(f"  Parsing: {relpath}")

        try:
            with open(json_path) as f:
                data = json.load(f)
        except (json.JSONDecodeError, FileNotFoundError) as e:
            errors.append({"file": relpath, "error": str(e)})
            continue

        # Extract the standardized results block
        raw_results = data.get("results", {})

        # Check for error results (benchmark failure)
        if "error" in raw_results:
            errors.append({
                "file": relpath,
                "error": raw_results.get("error", "Unknown error"),
                "message": raw_results.get("message", ""),
            })
            continue

        # Extract serving baseline info
        serving = data.get("serving", {})
        baseline_type = serving.get("baseline_type", "unknown")
        baseline_key = serving.get("baseline_key", os.path.basename(json_path).split("_")[0])

        # Extract workload info
        workload = data.get("workload", {})
        workload_type = workload.get("WORKLOAD_TYPE", "unknown")
        qps = workload.get("QPS", workload.get("REQUEST_RATE", "unknown"))

        # Build normalized result record
        record = {
            # Identity
            "source_file": relpath,
            "suite_name": data.get("name", suite_name),
            "session_id": data.get("lmbench-session-id", ""),
            "timestamp": data.get("timestamp", ""),

            # Baseline
            "baseline_type": baseline_type,
            "baseline_key": baseline_key,
            "model_url": serving.get("model_url", ""),

            # Workload
            "workload_type": workload_type,
            "qps": qps,

            # Throughput
            "successful_requests": _safe_int(
                raw_results.get("successful_requests")),
            "benchmark_duration_s": _safe_float(
                raw_results.get("benchmark_duration_s")),
            "request_throughput_req_per_s": _safe_float(
                raw_results.get("request_throughput_req_per_s")),
            "output_token_throughput_tok_per_s": _safe_float(
                raw_results.get("output_token_throughput_tok_per_s")),
            "input_token_throughput_tok_per_s": _safe_float(
                raw_results.get("input_token_throughput_tok_per_s")),
            "total_token_throughput_tok_per_s": _safe_float(
                raw_results.get("total_token_throughput_tok_per_s")),
            "total_input_tokens": _safe_int(
                raw_results.get("total_input_tokens")),
            "total_generated_tokens": _safe_int(
                raw_results.get("total_generated_tokens")),

            # TTFT (Time To First Token) — milliseconds
            "ttft_mean_ms": _safe_float(
                _extract_nested(raw_results, "ttft_ms", "mean")),
            "ttft_median_ms": _safe_float(
                _extract_nested(raw_results, "ttft_ms", "median")),
            "ttft_p99_ms": _safe_float(
                _extract_nested(raw_results, "ttft_ms", "p99")),

            # TPOT (Time Per Output Token) — milliseconds
            "tpot_mean_ms": _safe_float(
                _extract_nested(raw_results, "tpot_ms", "mean")),
            "tpot_median_ms": _safe_float(
                _extract_nested(raw_results, "tpot_ms", "median")),
            "tpot_p99_ms": _safe_float(
                _extract_nested(raw_results, "tpot_ms", "p99")),

            # ITL (Inter-Token Latency) — milliseconds
            "itl_mean_ms": _safe_float(
                _extract_nested(raw_results, "itl_ms", "mean")),
            "itl_median_ms": _safe_float(
                _extract_nested(raw_results, "itl_ms", "median")),
            "itl_p99_ms": _safe_float(
                _extract_nested(raw_results, "itl_ms", "p99")),
        }

        results.append(record)

    # Sort by baseline, workload, QPS
    results.sort(key=lambda x: (
        str(x.get("baseline_key", "")),
        str(x.get("workload_type", "")),
        str(x.get("qps", "")),
    ))

    log(f"Parsed {len(results)} result record(s) with {len(errors)} error(s)")

    # -------------------------------------------------------------------------
    # Write JSON output (primary — structured, for generate_report.sh)
    # -------------------------------------------------------------------------
    json_output = {
        "benchmark": "lmbench",
        "test": suite_name,
        "parser_version": "1.0.0",
        "timestamp_utc": datetime.now(timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"),
        "results": results if results else None,
        "errors": errors if errors else None,
    }

    json_path = os.path.join(results_dir, f"results_lmbench_{suite_name}.json")
    with open(json_path, "w") as f:
        json.dump(json_output, f, indent=2)
    log(f"Wrote JSON: {json_path}")

    # -------------------------------------------------------------------------
    # Write CSV output (secondary — flat table for report HTML)
    # -------------------------------------------------------------------------
    if results:
        csv_path = os.path.join(
            results_dir, f"results_lmbench_{suite_name}.csv")
        fieldnames = [
            "Baseline", "Workload", "QPS",
            "Requests", "Duration (s)",
            "Req Throughput (req/s)",
            "Output Tok Throughput (tok/s)",
            "Total Tok Throughput (tok/s)",
            "TTFT Mean (ms)", "TTFT Median (ms)", "TTFT P99 (ms)",
            "TPOT Mean (ms)", "TPOT Median (ms)", "TPOT P99 (ms)",
            "ITL Mean (ms)", "ITL Median (ms)", "ITL P99 (ms)",
        ]

        with open(csv_path, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            for r in results:
                writer.writerow({
                    "Baseline": r.get("baseline_key", ""),
                    "Workload": r.get("workload_type", ""),
                    "QPS": r.get("qps", ""),
                    "Requests": r.get("successful_requests", ""),
                    "Duration (s)": r.get("benchmark_duration_s", ""),
                    "Req Throughput (req/s)": r.get(
                        "request_throughput_req_per_s", ""),
                    "Output Tok Throughput (tok/s)": r.get(
                        "output_token_throughput_tok_per_s", ""),
                    "Total Tok Throughput (tok/s)": r.get(
                        "total_token_throughput_tok_per_s", ""),
                    "TTFT Mean (ms)": r.get("ttft_mean_ms", ""),
                    "TTFT Median (ms)": r.get("ttft_median_ms", ""),
                    "TTFT P99 (ms)": r.get("ttft_p99_ms", ""),
                    "TPOT Mean (ms)": r.get("tpot_mean_ms", ""),
                    "TPOT Median (ms)": r.get("tpot_median_ms", ""),
                    "TPOT P99 (ms)": r.get("tpot_p99_ms", ""),
                    "ITL Mean (ms)": r.get("itl_mean_ms", ""),
                    "ITL Median (ms)": r.get("itl_median_ms", ""),
                    "ITL P99 (ms)": r.get("itl_p99_ms", ""),
                })

        log(f"Wrote CSV: {csv_path} ({len(results)} rows)")


# =============================================================================
# Main
# =============================================================================

def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <results_dir> <suite_name>")
        sys.exit(1)

    results_dir = sys.argv[1]
    suite_name = sys.argv[2]

    log(f"Parsing LMBench results: suite={suite_name}")
    log(f"Results directory: {results_dir}")

    parse_lmbench_results(results_dir, suite_name)

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
