#!/usr/bin/env python3
"""
OCP SRV CMS - AIPerf Results Parser (parse_results.py)

AIPerf writes profile_export_aiperf.json with per-metric statistics
(avg, min, max, p50, p90, p99, std, etc.). This parser reads that
output and emits CMS-format JSON + CSV for the OCP report renderer.

Input layout (under <results_dir>/aiperf_results/):
    <model>-<endpoint_type>-<mode><N>/
        profile_export_aiperf.json
        profile_export_aiperf.csv
        profile_export.jsonl          (per-request detail)

Output:
    results_aiperf_<suite_name>.json   (combined, structured)
    results_aiperf_<suite_name>.csv    (flat table for HTML report)

Usage:
    python3 parse_results.py <results_dir> <suite_name>
"""

import csv
import glob
import json
import os
import sys
from datetime import datetime, timezone


def log(msg):
    print(f"[PARSER] {msg}")


def _safe_get(data, *keys, default=None):
    """Safely traverse nested dicts."""
    current = data
    for k in keys:
        if isinstance(current, dict) and k in current:
            current = current[k]
        else:
            return default
    return current


def _extract_metric(data, metric_tag):
    """Extract a metric dict from the aiperf JSON by tag name."""
    return data.get(metric_tag, None)


def _parse_aiperf_json(json_path):
    """
    Parse a single profile_export_aiperf.json file into a CMS record.

    AIPerf JSON structure (schema v1.1+):
    {
        "schema_version": "1.1",
        "aiperf_version": "0.8.0",
        "benchmark_id": "...",
        "input_config": { ... },
        "start_time": "2025-...",
        "end_time": "2025-...",
        "time_to_first_token": { "unit": "ms", "avg": ..., "p50": ..., "p99": ..., ... },
        "inter_token_latency": { ... },
        "request_latency": { ... },
        "output_token_throughput_per_request": { ... },
        "request_throughput": { ... },
        ...
    }
    """
    with open(json_path) as f:
        data = json.load(f)

    # Extract input config for metadata
    config = data.get("input_config", {})
    model = config.get("model", "unknown")
    endpoint_type = config.get("endpoint_type", "unknown")

    # Timing
    start_time = data.get("start_time")
    end_time = data.get("end_time")
    duration_s = None
    if start_time and end_time:
        try:
            t0 = datetime.fromisoformat(start_time)
            t1 = datetime.fromisoformat(end_time)
            duration_s = (t1 - t0).total_seconds()
        except (ValueError, TypeError):
            pass

    # Core metrics
    ttft = _extract_metric(data, "time_to_first_token")
    itl = _extract_metric(data, "inter_token_latency")
    req_lat = _extract_metric(data, "request_latency")
    req_tp = _extract_metric(data, "request_throughput")
    out_tp = _extract_metric(data, "output_token_throughput_per_request")
    osl = _extract_metric(data, "output_sequence_length")
    isl = _extract_metric(data, "input_sequence_length")

    # Total throughput metrics (may or may not be present)
    total_out_tp = _extract_metric(data, "output_token_throughput")
    total_in_tp = _extract_metric(data, "input_token_throughput")

    # Request count from output_sequence_length.count or config
    request_count = None
    if osl and osl.get("count"):
        request_count = osl["count"]
    elif config.get("request_count"):
        request_count = config["request_count"]

    # Concurrency / request rate
    concurrency = config.get("concurrency")
    request_rate = config.get("request_rate")

    def _get_stat(metric, stat, default=None):
        if metric is None:
            return default
        return metric.get(stat, default)

    record = {
        "source_file": os.path.relpath(json_path),
        "suite_name": "",  # filled by caller
        "timestamp": datetime.fromtimestamp(
            os.path.getmtime(json_path), tz=timezone.utc,
        ).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "model": model,
        "endpoint_type": endpoint_type,
        "concurrency": concurrency,
        "request_rate": request_rate,
        "successful_requests": request_count,
        "benchmark_duration_s": duration_s,

        # Request throughput
        "request_throughput_req_per_s": _get_stat(req_tp, "avg"),

        # Token throughput
        "output_token_throughput_tok_per_s": _get_stat(total_out_tp, "avg"),
        "input_token_throughput_tok_per_s": _get_stat(total_in_tp, "avg"),

        # TTFT (ms)
        "ttft_avg_ms": _get_stat(ttft, "avg"),
        "ttft_p50_ms": _get_stat(ttft, "p50"),
        "ttft_p90_ms": _get_stat(ttft, "p90"),
        "ttft_p99_ms": _get_stat(ttft, "p99"),
        "ttft_min_ms": _get_stat(ttft, "min"),
        "ttft_max_ms": _get_stat(ttft, "max"),

        # Inter-token latency (ms)
        "itl_avg_ms": _get_stat(itl, "avg"),
        "itl_p50_ms": _get_stat(itl, "p50"),
        "itl_p90_ms": _get_stat(itl, "p90"),
        "itl_p99_ms": _get_stat(itl, "p99"),

        # Request latency (ms)
        "req_latency_avg_ms": _get_stat(req_lat, "avg"),
        "req_latency_p50_ms": _get_stat(req_lat, "p50"),
        "req_latency_p90_ms": _get_stat(req_lat, "p90"),
        "req_latency_p99_ms": _get_stat(req_lat, "p99"),

        # Sequence lengths
        "avg_input_tokens": _get_stat(isl, "avg"),
        "avg_output_tokens": _get_stat(osl, "avg"),

        # AIPerf metadata
        "aiperf_version": data.get("aiperf_version"),
        "schema_version": data.get("schema_version"),
    }

    return record


def parse_aiperf_results(results_dir, suite_name):
    errors = []
    results = []

    # AIPerf writes to <artifact_dir>/<model>-<endpoint>-<mode><N>/
    # We search for all profile_export_aiperf.json files recursively
    json_pattern = os.path.join(
        results_dir, "aiperf_results", "**", "profile_export_aiperf.json"
    )
    json_files = sorted(set(glob.glob(json_pattern, recursive=True)))

    if not json_files:
        errors.append({"error": "No AIPerf profile_export_aiperf.json files found"})
        log("WARNING: No AIPerf result JSON files found")
        log(f"  Searched: {json_pattern}")
        all_json = glob.glob(
            os.path.join(results_dir, "**", "*.json"), recursive=True
        )
        if all_json:
            log(f"  Found {len(all_json)} JSON files total:")
            for f in all_json[:10]:
                log(f"    {os.path.relpath(f, results_dir)}")
    else:
        log(f"Found {len(json_files)} AIPerf result file(s)")

    for json_path in json_files:
        relpath = os.path.relpath(json_path, results_dir)
        log(f"  Parsing: {relpath}")

        try:
            record = _parse_aiperf_json(json_path)
            record["suite_name"] = suite_name
            record["baseline_type"] = "Flat"
            record["baseline_key"] = record.get("model", "unknown")
            results.append(record)
        except Exception as e:
            errors.append({"file": relpath, "error": str(e)})
            log(f"  ERROR parsing {relpath}: {e}")
            continue

    results.sort(key=lambda x: (
        str(x.get("model", "")),
        str(x.get("concurrency", "")),
        str(x.get("request_rate", "")),
    ))

    log(f"Parsed {len(results)} result record(s) with {len(errors)} error(s)")

    # -- Write JSON output --
    json_output = {
        "benchmark": "aiperf",
        "test": suite_name,
        "parser_version": "1.0.0",
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

    # Promote single-result metrics to top level for report header
    if len(results) == 1:
        promoted = (
            "model", "concurrency", "request_rate",
            "successful_requests", "benchmark_duration_s",
            "request_throughput_req_per_s",
            "output_token_throughput_tok_per_s",
            "ttft_avg_ms", "ttft_p50_ms", "ttft_p99_ms",
            "itl_avg_ms", "itl_p50_ms", "itl_p99_ms",
            "req_latency_avg_ms", "req_latency_p50_ms", "req_latency_p99_ms",
        )
        for k in promoted:
            v = results[0].get(k)
            if v is not None:
                json_output[k] = v

    json_output["results"] = results if results else None
    json_output["errors"] = errors if errors else None

    json_path_out = os.path.join(results_dir, f"results_aiperf_{suite_name}.json")
    with open(json_path_out, "w") as f:
        json.dump(json_output, f, indent=2)
    log(f"Wrote JSON: {json_path_out}")

    # -- Write CSV output --
    if results:
        csv_path = os.path.join(results_dir, f"results_aiperf_{suite_name}.csv")
        fieldnames = [
            "Model", "Concurrency", "Request Rate",
            "Requests", "Duration (s)",
            "Req Throughput (req/s)",
            "Output Tok Throughput (tok/s)",
            "TTFT Avg (ms)", "TTFT P50 (ms)", "TTFT P90 (ms)", "TTFT P99 (ms)",
            "ITL Avg (ms)", "ITL P50 (ms)", "ITL P90 (ms)", "ITL P99 (ms)",
            "Req Latency Avg (ms)", "Req Latency P50 (ms)", "Req Latency P99 (ms)",
            "Avg Input Tokens", "Avg Output Tokens",
        ]
        with open(csv_path, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            for r in results:
                writer.writerow({
                    "Model": r.get("model", ""),
                    "Concurrency": r.get("concurrency", ""),
                    "Request Rate": r.get("request_rate", ""),
                    "Requests": r.get("successful_requests", ""),
                    "Duration (s)": _fmt(r.get("benchmark_duration_s")),
                    "Req Throughput (req/s)": _fmt(r.get("request_throughput_req_per_s")),
                    "Output Tok Throughput (tok/s)": _fmt(r.get("output_token_throughput_tok_per_s")),
                    "TTFT Avg (ms)": _fmt(r.get("ttft_avg_ms")),
                    "TTFT P50 (ms)": _fmt(r.get("ttft_p50_ms")),
                    "TTFT P90 (ms)": _fmt(r.get("ttft_p90_ms")),
                    "TTFT P99 (ms)": _fmt(r.get("ttft_p99_ms")),
                    "ITL Avg (ms)": _fmt(r.get("itl_avg_ms")),
                    "ITL P50 (ms)": _fmt(r.get("itl_p50_ms")),
                    "ITL P90 (ms)": _fmt(r.get("itl_p90_ms")),
                    "ITL P99 (ms)": _fmt(r.get("itl_p99_ms")),
                    "Req Latency Avg (ms)": _fmt(r.get("req_latency_avg_ms")),
                    "Req Latency P50 (ms)": _fmt(r.get("req_latency_p50_ms")),
                    "Req Latency P99 (ms)": _fmt(r.get("req_latency_p99_ms")),
                    "Avg Input Tokens": _fmt(r.get("avg_input_tokens")),
                    "Avg Output Tokens": _fmt(r.get("avg_output_tokens")),
                })
        log(f"Wrote CSV: {csv_path} ({len(results)} rows)")


def _fmt(val):
    """Format a numeric value for CSV, rounding floats to 2 decimal places."""
    if val is None:
        return ""
    if isinstance(val, float):
        return f"{val:.2f}"
    return str(val)


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <results_dir> <suite_name>")
        sys.exit(1)

    results_dir = sys.argv[1]
    suite_name = sys.argv[2]

    log(f"Parsing AIPerf results: suite={suite_name}")
    log(f"Results directory: {results_dir}")

    parse_aiperf_results(results_dir, suite_name)

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
