#!/usr/bin/env python3
"""
OCP SRV CMS - LMBench Results Parser (parse_results.py)

LMBench's multi-round-qa.py writes one CSV per workload run with raw
per-request data (one row per request). This parser aggregates each CSV
into summary metrics and emits CMS-format JSON + CSV.

Input layout (under <results_dir>/lmbench_results/):
    <model_org>/<model_short>_<workload>_output_<qps>.csv
        columns: prompt_tokens, generation_tokens, ttft, generation_time,
                 user_id, question_id, launch_time, finish_time
        TTFT and generation_time are in seconds.

Output:
    results_lmbench_<suite_name>.json   (combined, structured)
    results_lmbench_<suite_name>.csv    (flat table for HTML report)

Usage:
    python3 parse_results.py <results_dir> <suite_name>
"""

import csv
import glob
import json
import os
import re
import sys
from datetime import datetime, timezone
from statistics import mean, median


KNOWN_WORKLOADS = (
    "synthetic", "sharegpt", "agentic", "random", "strict",
    "strictsynthetic", "trace", "vllmbench", "vllm-bench",
)


def log(msg):
    print(f"[PARSER] {msg}")


def _percentile(values, pct):
    if not values:
        return None
    s = sorted(values)
    k = (len(s) - 1) * (pct / 100.0)
    lo = int(k)
    hi = min(lo + 1, len(s) - 1)
    frac = k - lo
    return s[lo] + (s[hi] - s[lo]) * frac


def _parse_filename(basename):
    """
    Parse '<model>_<workload>_output_<qps>.csv' into (model_short, workload, qps).
    Falls back to ('unknown', 'unknown', None) if pattern doesn't match.
    """
    m = re.match(r"^(?P<prefix>.+)_output_(?P<qps>[\d.]+)\.csv$", basename)
    if not m:
        return "unknown", "unknown", None
    prefix = m.group("prefix")
    qps = m.group("qps")
    for w in KNOWN_WORKLOADS:
        suffix = "_" + w
        if prefix.lower().endswith(suffix):
            return prefix[: -len(suffix)], w, qps
    parts = prefix.rsplit("_", 1)
    if len(parts) == 2:
        return parts[0], parts[1], qps
    return prefix, "unknown", qps


def _row_floats(row, *keys):
    out = {}
    for k in keys:
        try:
            out[k] = float(row[k])
        except (KeyError, ValueError, TypeError):
            out[k] = None
    return out


def _aggregate_csv(csv_path):
    rows = []
    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)

    if not rows:
        return None

    ttft_s, gen_s, prompt_tok, gen_tok, launch, finish, tpot_s = [], [], [], [], [], [], []
    for r in rows:
        v = _row_floats(
            r, "ttft", "generation_time", "prompt_tokens",
            "generation_tokens", "launch_time", "finish_time",
        )
        if v["ttft"] is not None:
            ttft_s.append(v["ttft"])
        if v["generation_time"] is not None:
            gen_s.append(v["generation_time"])
        if v["prompt_tokens"] is not None:
            prompt_tok.append(v["prompt_tokens"])
        if v["generation_tokens"] is not None:
            gen_tok.append(v["generation_tokens"])
        if v["launch_time"] is not None:
            launch.append(v["launch_time"])
        if v["finish_time"] is not None:
            finish.append(v["finish_time"])
        if v["generation_time"] is not None and v["generation_tokens"] and v["generation_tokens"] > 1:
            tpot_s.append(v["generation_time"] / (v["generation_tokens"] - 1))

    duration_s = (max(finish) - min(launch)) if launch and finish else None

    def to_ms_stats(seconds_list):
        if not seconds_list:
            return {"mean": None, "median": None, "p99": None}
        ms = [s * 1000.0 for s in seconds_list]
        return {
            "mean": mean(ms),
            "median": median(ms),
            "p99": _percentile(ms, 99),
        }

    successful = len(rows)
    total_in = sum(prompt_tok) if prompt_tok else 0
    total_out = sum(gen_tok) if gen_tok else 0

    return {
        "successful_requests": successful,
        "benchmark_duration_s": duration_s,
        "request_throughput_req_per_s": (successful / duration_s) if duration_s else None,
        "input_token_throughput_tok_per_s": (total_in / duration_s) if duration_s else None,
        "output_token_throughput_tok_per_s": (total_out / duration_s) if duration_s else None,
        "total_token_throughput_tok_per_s": ((total_in + total_out) / duration_s) if duration_s else None,
        "total_input_tokens": int(total_in),
        "total_generated_tokens": int(total_out),
        "ttft_ms": to_ms_stats(ttft_s),
        "tpot_ms": to_ms_stats(tpot_s),
        "itl_ms": to_ms_stats(tpot_s),
    }


def parse_lmbench_results(results_dir, suite_name):
    errors = []
    results = []

    csv_pattern = os.path.join(results_dir, "lmbench_results", "**", "*_output_*.csv")
    csv_files = sorted(set(glob.glob(csv_pattern, recursive=True)))

    if not csv_files:
        errors.append({"error": "No LMBench CSV result files found"})
        log("WARNING: No LMBench result CSV files found")
        log(f"  Searched: {results_dir}/lmbench_results/**/*_output_*.csv")
        all_csv = glob.glob(os.path.join(results_dir, "**", "*.csv"), recursive=True)
        if all_csv:
            log(f"  Found {len(all_csv)} CSV files total (may not be result files):")
            for f in all_csv[:10]:
                log(f"    {os.path.relpath(f, results_dir)}")
    else:
        log(f"Found {len(csv_files)} LMBench result CSV file(s)")

    for csv_path in csv_files:
        relpath = os.path.relpath(csv_path, results_dir)
        log(f"  Parsing: {relpath}")

        basename = os.path.basename(csv_path)
        model_short, workload, qps = _parse_filename(basename)

        try:
            agg = _aggregate_csv(csv_path)
        except Exception as e:
            errors.append({"file": relpath, "error": str(e)})
            continue

        if agg is None:
            errors.append({"file": relpath, "error": "empty CSV"})
            continue

        record = {
            "source_file": relpath,
            "suite_name": suite_name,
            "session_id": "",
            "timestamp": datetime.fromtimestamp(
                os.path.getmtime(csv_path), tz=timezone.utc,
            ).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "baseline_type": "Flat",
            "baseline_key": model_short,
            "model_url": model_short,
            "workload_type": workload,
            "qps": qps,
            "successful_requests": agg["successful_requests"],
            "benchmark_duration_s": agg["benchmark_duration_s"],
            "request_throughput_req_per_s": agg["request_throughput_req_per_s"],
            "output_token_throughput_tok_per_s": agg["output_token_throughput_tok_per_s"],
            "input_token_throughput_tok_per_s": agg["input_token_throughput_tok_per_s"],
            "total_token_throughput_tok_per_s": agg["total_token_throughput_tok_per_s"],
            "total_input_tokens": agg["total_input_tokens"],
            "total_generated_tokens": agg["total_generated_tokens"],
            "ttft_mean_ms": agg["ttft_ms"]["mean"],
            "ttft_median_ms": agg["ttft_ms"]["median"],
            "ttft_p99_ms": agg["ttft_ms"]["p99"],
            "tpot_mean_ms": agg["tpot_ms"]["mean"],
            "tpot_median_ms": agg["tpot_ms"]["median"],
            "tpot_p99_ms": agg["tpot_ms"]["p99"],
            "itl_mean_ms": agg["itl_ms"]["mean"],
            "itl_median_ms": agg["itl_ms"]["median"],
            "itl_p99_ms": agg["itl_ms"]["p99"],
        }
        results.append(record)

    results.sort(key=lambda x: (
        str(x.get("baseline_key", "")),
        str(x.get("workload_type", "")),
        str(x.get("qps", "")),
    ))

    log(f"Parsed {len(results)} result record(s) with {len(errors)} error(s)")

    json_output = {
        "benchmark": "lmbench",
        "test": suite_name,
        "parser_version": "2.0.0",
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

    # When there's a single workload result, also promote its metrics to the
    # top level so the report renderer surfaces them in the section header
    # Property/Value table (vs. an unreadable 26-column wide table).
    if len(results) == 1:
        promoted = (
            "baseline_key", "workload_type", "qps",
            "successful_requests", "benchmark_duration_s",
            "request_throughput_req_per_s",
            "input_token_throughput_tok_per_s",
            "output_token_throughput_tok_per_s",
            "total_token_throughput_tok_per_s",
            "ttft_mean_ms", "ttft_median_ms", "ttft_p99_ms",
            "tpot_mean_ms", "tpot_median_ms", "tpot_p99_ms",
        )
        for k in promoted:
            v = results[0].get(k)
            if v is not None:
                json_output[k] = v

    json_output["results"] = results if results else None
    json_output["errors"] = errors if errors else None

    json_path = os.path.join(results_dir, f"results_lmbench_{suite_name}.json")
    with open(json_path, "w") as f:
        json.dump(json_output, f, indent=2)
    log(f"Wrote JSON: {json_path}")

    if results:
        csv_path = os.path.join(results_dir, f"results_lmbench_{suite_name}.csv")
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
                    "Req Throughput (req/s)": r.get("request_throughput_req_per_s", ""),
                    "Output Tok Throughput (tok/s)": r.get("output_token_throughput_tok_per_s", ""),
                    "Total Tok Throughput (tok/s)": r.get("total_token_throughput_tok_per_s", ""),
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


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <results_dir> <suite_name>")
        sys.exit(1)

    results_dir = sys.argv[1]
    suite_name = sys.argv[2]

    log(f"Parsing LMBench results: suite={suite_name}")
    log(f"Results directory: {results_dir}")

    parse_lmbench_results(results_dir, suite_name)

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
