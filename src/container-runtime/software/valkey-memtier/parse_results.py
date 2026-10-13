#!/usr/bin/env python3
"""
OCP SRV CMS - Memtier Results Parser (parse_results.py)

Parses the per-phase output of run_valkey_memtier.sh and normalizes it into:
  - JSON (primary) — per-phase throughput, latency percentiles, server memory/CPU,
                     and per-NUMA-node memory placement of the server process
  - CSV (secondary) — summary and NUMA placement tables, plus per-second time series

Inputs (per phase, where phase is fill / read / mixed):
  memtier_<phase>.json   memtier_benchmark --json-out-file output
  server_info_<phase>.txt  INFO all snapshot taken after the phase (plus "baseline")
  numastat_<phase>.txt   numastat -p <server pid> taken after the phase (plus "baseline")
  versions.txt           resolved build tags and binary version strings

Usage:
    python3 parse_results.py <results_dir> [benchmark_name]

JSON output:  results_<benchmark_name>.json
CSV output:   results_<benchmark_name>.csv (summary), results_<benchmark_name>_numa.csv (placement),
              timeseries_<benchmark_name>_<phase>.csv (per-second Totals; not rendered in the report)
"""

import csv
import glob
import json
import os
import re
import sys
from datetime import datetime, timezone

PARSER_VERSION = "1.0.0"
PHASE_ORDER = ["fill", "read", "mixed"]
OP_TYPES = ["Sets", "Gets", "Waits"]

# memtier "configuration" keys worth carrying into the results
CONFIG_KEYS = [
    "server", "port", "protocol", "test_time", "requests", "clients", "threads", "pipeline",
    "data_size", "ratio", "key_pattern", "key_minimum", "key_maximum", "rate_limit",
    "run_count",
]

# INFO fields reported per snapshot
INFO_KEYS = [
    "redis_version", "valkey_version", "used_memory", "used_memory_rss", "used_memory_peak",
    "mem_fragmentation_ratio", "maxmemory", "maxmemory_policy", "evicted_keys", "expired_keys",
    "keyspace_hits", "keyspace_misses", "total_commands_processed", "aof_enabled",
    "io_threads_active", "used_cpu_sys", "used_cpu_user",
]


def log(msg):
    print(f"[PARSER] {msg}")


def _safe_float(val, default=None):
    try:
        return float(val)
    except (ValueError, TypeError):
        return default


def _num(val):
    """Convert a string to int or float where possible, else return it unchanged."""
    if isinstance(val, str):
        if re.fullmatch(r"-?\d+", val):
            return int(val)
        f = _safe_float(val)
        if f is not None:
            return f
    return val


# =============================================================================
# memtier JSON
# =============================================================================

def load_memtier_json(path):
    """Load memtier JSON, tolerating nan/inf values that some versions emit."""
    with open(path) as f:
        text = f.read()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        text = re.sub(r"(?<=[:\s\[,])-?(nan|inf)(?=[\s,}\]])", "null", text, flags=re.IGNORECASE)
        return json.loads(text)


def _find_stats_section(data):
    """Return the results section: ALL STATS for a single run, else the aggregated average."""
    if "ALL STATS" in data:
        return data["ALL STATS"]
    for key, val in data.items():
        if key.startswith("AGGREGATED AVERAGE RESULTS"):
            return val
    return None


def _percentiles(section):
    """Extract {"p50": .., "p99.9": ..} from a 'Percentile Latencies' block.

    memtier writes keys like "p50.00" / "p99.90" (truncated to a fixed width),
    so keys are matched by numeric value rather than exact string.
    """
    out = {}
    for key, val in (section or {}).items():
        m = re.fullmatch(r"p(\d+(?:\.\d+)?)", key)
        if m and isinstance(val, (int, float)):
            out[f"p{float(m.group(1)):g}"] = val
    return out


def _op_metrics(op):
    """Summarize one op-type block (Sets / Gets / Waits / Totals)."""
    return {
        "count": op.get("Count"),
        "ops_sec": op.get("Ops/sec"),
        "hits_sec": op.get("Hits/sec"),
        "misses_sec": op.get("Misses/sec"),
        "kb_sec": op.get("KB/sec"),
        "connection_errors": op.get("Connection Errors"),
        "latency_ms": {
            "avg": op.get("Average Latency", op.get("Latency")),
            "min": op.get("Min Latency"),
            "max": op.get("Max Latency"),
            **_percentiles(op.get("Percentile Latencies")),
        },
    }


def parse_memtier(data):
    stats = _find_stats_section(data)
    if stats is None:
        return None, None, None

    totals = stats.get("Totals", {})
    summary = _op_metrics(totals)
    per_op = {}
    for op_name in OP_TYPES:
        op = stats.get(op_name)
        if op and (op.get("Count") or 0) > 0:
            per_op[op_name.lower()] = _op_metrics(op)

    runtime = stats.get("Runtime", {})
    summary["duration_s"] = (runtime.get("Total duration") or 0) / 1000.0 or None
    summary["interrupted"] = runtime.get("Interrupted")

    # memtier times requests with the wall clock (gettimeofday). If the clock steps backwards
    # mid-request (e.g. VM time sync), the negative latency wraps to ~2^32 us and corrupts the
    # average and max. Percentiles come from an HDR histogram and are not affected. A latency
    # longer than the whole phase is impossible, so use that to flag the artifact.
    max_lat = summary["latency_ms"].get("max")
    if summary["duration_s"] and isinstance(max_lat, (int, float)) and max_lat > summary["duration_s"] * 1000:
        summary["latency_artifact"] = ("max latency exceeds phase duration (wall-clock step during the run); "
                                       "avg/max latency are unreliable, use percentiles")

    timeseries = totals.get("Time-Serie") or {}
    return summary, per_op, timeseries


def parse_memtier_config(data):
    cfg = data.get("configuration") or {}
    return {k: cfg[k] for k in CONFIG_KEYS if k in cfg} or None


# =============================================================================
# Server INFO snapshot
# =============================================================================

def parse_info(path):
    if not os.path.isfile(path):
        return None
    fields = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or ":" not in line:
                continue
            key, val = line.split(":", 1)
            fields[key] = val

    info = {k: _num(fields[k]) for k in INFO_KEYS if k in fields}
    # db0:keys=100000,expires=0,avg_ttl=0
    if "db0" in fields:
        for part in fields["db0"].split(","):
            if part.startswith("keys="):
                info["db0_keys"] = _num(part[5:])
    else:
        info["db0_keys"] = 0
    return info or None


# =============================================================================
# numastat -p snapshot
# =============================================================================

def parse_numastat(path):
    """Parse the Total row of `numastat -p <pid>` into {"Node 0": MB, ..., "Total": MB}."""
    if not os.path.isfile(path):
        return None
    columns = None
    with open(path) as f:
        for line in f:
            if columns is None and re.search(r"\bNode \d+", line):
                columns = re.findall(r"Node \d+|Total", line)
                continue
            if columns and line.startswith("Total"):
                values = [_safe_float(v) for v in line.split()[1:]]
                if len(values) == len(columns):
                    placement = dict(zip(columns, values))
                    total = placement.get("Total") or 0
                    if total > 0:
                        placement["share_pct"] = {
                            c: round(100.0 * v / total, 2)
                            for c, v in placement.items() if c.startswith("Node")
                        }
                    return placement
    return None


# =============================================================================
# Metadata
# =============================================================================

def parse_versions(results_dir):
    path = os.path.join(results_dir, "versions.txt")
    if not os.path.isfile(path):
        return None
    versions = {}
    with open(path) as f:
        for line in f:
            if "=" in line:
                key, val = line.strip().split("=", 1)
                versions[key] = val
    return versions or None


def parse_run_metadata(results_dir):
    """Read the results.csv written by the run script for test metadata."""
    path = os.path.join(results_dir, "results.csv")
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        rows = [{k.strip(): v.strip().strip('"') for k, v in row.items() if k and v}
                for row in csv.DictReader(f)]
    return [r for r in rows if r] or None


def discover_phases(results_dir):
    """Phases that produced memtier output, in the order they ran (by file mtime)."""
    found = []
    for path in glob.glob(os.path.join(results_dir, "memtier_*.json")):
        phase = os.path.basename(path)[len("memtier_"):-len(".json")]
        found.append((os.path.getmtime(path), phase))
    found.sort()
    phases = [p for _, p in found]
    unknown = [p for p in phases if p not in PHASE_ORDER]
    if unknown:
        log(f"WARNING: unexpected phase name(s): {unknown}")
    return phases


# =============================================================================
# CSV writers
# =============================================================================

def write_summary_csv(results_dir, bench, phases):
    pct_keys = []
    for p in phases.values():
        for row in [p.get("summary")] + list((p.get("per_op") or {}).values()):
            for k in (row or {}).get("latency_ms", {}):
                if k.startswith("p") and k not in pct_keys:
                    pct_keys.append(k)
    pct_keys.sort(key=lambda k: float(k[1:]))

    fieldnames = (["Phase", "Operation", "Ops/sec", "Hits/sec", "Misses/sec", "KB/sec",
                   "Avg Latency (ms)"]
                  + [f"{k} Latency (ms)" for k in pct_keys]
                  + ["Max Latency (ms)", "Server CPU (us/command)", "Server RSS (MB)"])

    rows = []
    for phase, p in phases.items():
        server = p.get("server") or {}
        rss = server.get("used_memory_rss")
        ops = [("TOTALS", p.get("summary"))] + [(k.upper(), v) for k, v in (p.get("per_op") or {}).items()]
        for op_name, m in ops:
            if not m:
                continue
            lat = m.get("latency_ms", {})
            row = {
                "Phase": phase,
                "Operation": op_name,
                "Ops/sec": m.get("ops_sec", ""),
                "Hits/sec": m.get("hits_sec", ""),
                "Misses/sec": m.get("misses_sec", ""),
                "KB/sec": m.get("kb_sec", ""),
                "Avg Latency (ms)": lat.get("avg", ""),
                "Max Latency (ms)": lat.get("max", ""),
                "Server CPU (us/command)": p.get("server_cpu_us_per_command", "") if op_name == "TOTALS" else "",
                "Server RSS (MB)": round(rss / 1048576, 1) if isinstance(rss, (int, float)) and op_name == "TOTALS" else "",
            }
            for k in pct_keys:
                row[f"{k} Latency (ms)"] = lat.get(k, "")
            rows.append(row)

    if rows:
        dst = os.path.join(results_dir, f"results_{bench}.csv")
        with open(dst, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)
        log(f"Wrote CSV: {dst} ({len(rows)} rows)")


def write_numa_csv(results_dir, bench, snapshots):
    nodes = sorted({c for s in snapshots.values() if s for c in s if c.startswith("Node")},
                   key=lambda c: int(c.split()[1]))
    if not nodes:
        return
    dst = os.path.join(results_dir, f"results_{bench}_numa.csv")
    with open(dst, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["Snapshot"] + [f"{n} (MB)" for n in nodes] + ["Total (MB)"]
                        + [f"{n} (%)" for n in nodes])
        for tag, s in snapshots.items():
            if not s:
                continue
            share = s.get("share_pct", {})
            writer.writerow([tag] + [s.get(n, "") for n in nodes] + [s.get("Total", "")]
                            + [share.get(n, "") for n in nodes])
    log(f"Wrote CSV: {dst}")


def write_timeseries_csv(results_dir, bench, phase, timeseries):
    if not timeseries:
        return
    seconds = sorted(timeseries, key=lambda s: _safe_float(s, 0))
    pct_keys = sorted({k for s in seconds for k in timeseries[s] if re.fullmatch(r"p\d+(\.\d+)?", k)},
                      key=lambda k: float(k[1:]))
    fieldnames = ["second", "ops", "avg_latency_ms", "min_latency_ms", "max_latency_ms"] \
        + [f"p{float(k[1:]):g}_latency_ms" for k in pct_keys] + ["bytes_rx", "bytes_tx"]
    dst = os.path.join(results_dir, f"timeseries_{bench}_{phase}.csv")
    with open(dst, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(fieldnames)
        for s in seconds:
            e = timeseries[s]
            writer.writerow([s, e.get("Count", ""), e.get("Average Latency", ""),
                             e.get("Min Latency", ""), e.get("Max Latency", "")]
                            + [e.get(k, "") for k in pct_keys]
                            + [e.get("Bytes RX", ""), e.get("Bytes TX", "")])
    log(f"Wrote CSV: {dst} ({len(seconds)} rows)")


# =============================================================================
# Main
# =============================================================================

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <results_dir> [benchmark_name]")
        sys.exit(1)

    results_dir = sys.argv[1]
    bench = sys.argv[2] if len(sys.argv) > 2 else "valkey_memtier"
    log(f"Parsing {bench} results from: {results_dir}")

    errors = []
    phases = {}
    numa_snapshots = {"baseline": parse_numastat(os.path.join(results_dir, "numastat_baseline.txt"))}
    prev_info = parse_info(os.path.join(results_dir, "server_info_baseline.txt"))
    baseline_info = prev_info

    phase_names = discover_phases(results_dir)
    if not phase_names:
        log("WARNING: no memtier_<phase>.json files found")
        errors.append({"error": "no memtier_<phase>.json files found"})

    for phase in phase_names:
        entry = {}
        try:
            data = load_memtier_json(os.path.join(results_dir, f"memtier_{phase}.json"))
            summary, per_op, timeseries = parse_memtier(data)
            entry["memtier_config"] = parse_memtier_config(data)
            entry["summary"] = summary
            entry["per_op"] = per_op or None
            if summary is None:
                errors.append({"phase": phase, "error": "no ALL STATS section in memtier JSON"})
            elif summary.get("latency_artifact"):
                log(f"WARNING: phase {phase}: {summary['latency_artifact']}")
                errors.append({"phase": phase, "warning": summary["latency_artifact"]})
            write_timeseries_csv(results_dir, bench, phase, timeseries)
        except (OSError, json.JSONDecodeError) as e:
            log(f"WARNING: could not parse memtier_{phase}.json: {e}")
            errors.append({"phase": phase, "error": f"memtier JSON: {e}"})

        info = parse_info(os.path.join(results_dir, f"server_info_{phase}.txt"))
        entry["server"] = info
        # Server CPU cost per command over this phase, from INFO deltas
        if info and prev_info:
            try:
                cpu = (info["used_cpu_user"] + info["used_cpu_sys"]
                       - prev_info["used_cpu_user"] - prev_info["used_cpu_sys"])
                cmds = info["total_commands_processed"] - prev_info["total_commands_processed"]
                entry["server_cpu_seconds"] = round(cpu, 3)
                if cmds > 0:
                    entry["server_cpu_us_per_command"] = round(1e6 * cpu / cmds, 3)
            except (KeyError, TypeError):
                pass
        prev_info = info or prev_info

        placement = parse_numastat(os.path.join(results_dir, f"numastat_{phase}.txt"))
        entry["numa_placement_mb"] = placement
        numa_snapshots[phase] = placement

        if entry.get("summary"):
            s = entry["summary"]
            log(f"Phase {phase}: {s.get('ops_sec')} ops/sec, "
                f"avg {s['latency_ms'].get('avg')} ms, p99 {s['latency_ms'].get('p99')} ms")
        phases[phase] = entry

    # ----- Write JSON (primary output) -----
    json_output = {
        "benchmark": bench,
        "parser_version": PARSER_VERSION,
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source_dir": os.path.basename(os.path.abspath(results_dir)),
        "versions": parse_versions(results_dir),
        "baseline": {
            "server": baseline_info,
            "numa_placement_mb": numa_snapshots.get("baseline"),
        },
        "phases": phases or None,
        "run_metadata": parse_run_metadata(results_dir),
        "errors": errors or None,
    }

    json_path = os.path.join(results_dir, f"results_{bench}.json")
    with open(json_path, "w") as f:
        json.dump(json_output, f, indent=2)
    log(f"Wrote JSON: {json_path}")

    # ----- Write CSVs -----
    write_summary_csv(results_dir, bench, phases)
    write_numa_csv(results_dir, bench, numa_snapshots)

    jsons = sorted(glob.glob(os.path.join(results_dir, "results_*.json")))
    csvs = sorted(glob.glob(os.path.join(results_dir, "results_*.csv")))
    log(f"Produced: {len(jsons)} JSON + {len(csvs)} CSV file(s)")

    sys.exit(1 if not phases else 0)


if __name__ == "__main__":
    main()
