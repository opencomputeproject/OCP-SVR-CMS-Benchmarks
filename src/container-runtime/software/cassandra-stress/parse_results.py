#!/usr/bin/env python3
"""
OCP SRV CMS - cassandra-stress Results Parser (parse_results.py)

Parses the per-phase output of run_cassandra_stress.sh and normalizes it into:
  - JSON (primary) — per-phase throughput, latency percentiles, read hit rate, server CPU and GC,
                     table state, and per-NUMA-node memory placement of the Cassandra JVM
  - CSV (secondary) — summary and NUMA placement tables, plus per-interval time series

Inputs (per phase, where phase is populate / a / b / c):
  stress_<phase>.txt              cassandra-stress output (progress lines + Results block)
  proc_stat_<phase>_start.txt     /proc/<server pid>/stat just before the phase
  proc_stat_<phase>.txt           /proc/<server pid>/stat just after the phase
  numastat_<phase>.txt            numastat -p <server pid> after the phase (plus "baseline")
  nodetool_info_<phase>.txt       nodetool info after the phase (plus "baseline")
  nodetool_tablestats_<phase>.txt nodetool tablestats stresscql.blogposts after the phase
  disk_usage_<phase>.txt          du -sb of the data and commitlog directories after the phase
  phase_times.csv                 phase start/end wall-clock times and cassandra-stress exit codes
  versions.txt                    resolved Cassandra release and Java version

Usage:
    python3 parse_results.py <results_dir> [benchmark_name]

JSON output:  results_<benchmark_name>.json
CSV output:   results_<benchmark_name>.csv (summary), results_<benchmark_name>_numa.csv (placement),
              timeseries_<benchmark_name>_<phase>.csv (per-interval progress; not rendered in the report)
"""

import csv
import glob
import json
import os
import re
import sys
from datetime import datetime, timezone

PARSER_VERSION = "1.0.0"
PHASE_ORDER = ["populate", "a", "b", "c"]
READ_OPS = ["singlepost", "timeline"]

# Results block line label -> (JSON key, has per-op breakdown)
RESULT_LINES = {
    "Op rate": ("op_rate", True),
    "Partition rate": ("partition_rate", True),
    "Row rate": ("row_rate", True),
    "Latency mean": ("latency_mean_ms", True),
    "Latency median": ("latency_median_ms", True),
    "Latency 95th percentile": ("latency_p95_ms", True),
    "Latency 99th percentile": ("latency_p99_ms", True),
    "Latency 99.9th percentile": ("latency_p99.9_ms", True),
    "Latency max": ("latency_max_ms", True),
    "Total partitions": ("total_partitions", True),
    "Total errors": ("total_errors", True),
    "Total GC count": ("gc_count", False),
    "Total GC memory": ("gc_memory", False),
    "Total GC time": ("gc_time_s", False),
    "Avg GC time": ("gc_avg_ms", False),
    "StdDev GC time": ("gc_stddev_ms", False),
    "Total operation time": ("operation_time_s", False),
}

# Progress line columns (after the leading op name)
PROGRESS_COLUMNS = [
    "total_ops", "op_s", "pk_s", "row_s", "mean_ms", "median_ms", "p95_ms", "p99_ms", "p99.9_ms",
    "max_ms", "time_s", "stderr", "errors", "gc_count", "gc_max_ms", "gc_sum_ms", "gc_sdv_ms", "gc_mb",
]

# nodetool tablestats fields reported per snapshot (table section)
TABLESTATS_KEYS = {
    "SSTable count": "sstable_count",
    "SSTables in each level": "sstables_per_level",
    "Space used (live)": "space_used_live_bytes",
    "Space used (total)": "space_used_total_bytes",
    "SSTable Compression Ratio": "compression_ratio",
    "Number of partitions (estimate)": "partitions_estimate",
    "Memtable switch count": "memtable_switch_count",
    "Local read count": "local_read_count",
    "Local read latency": "local_read_latency_ms",
    "Local write count": "local_write_count",
    "Local write latency": "local_write_latency_ms",
    "Bloom filter false ratio": "bloom_filter_false_ratio",
    "Compacted partition maximum bytes": "compacted_partition_max_bytes",
    "Compacted partition mean bytes": "compacted_partition_mean_bytes",
}


def log(msg):
    print(f"[PARSER] {msg}")


def _safe_float(val, default=None):
    try:
        return float(val)
    except (ValueError, TypeError):
        return default


def _num(val):
    """Convert a string such as '1,048,525', '0.6' or 'NaN' to int/float/None where possible."""
    if not isinstance(val, str):
        return val
    v = val.strip().replace(",", "")
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    if v.lower() == "nan":
        return None
    f = _safe_float(v)
    return f if f is not None else val.strip()


# =============================================================================
# cassandra-stress output
# =============================================================================

def _value_and_unit(text):
    """'  72.009 GiB' -> (72.009, 'GiB'); '00:01:00' -> (60, 's')."""
    text = text.strip()
    m = re.fullmatch(r"(\d+):(\d+):(\d+)", text)
    if m:
        h, mi, s = (int(x) for x in m.groups())
        return h * 3600 + mi * 60 + s, "s"
    parts = text.split(None, 1)
    if not parts:
        return None, None
    return _num(parts[0]), (parts[1] if len(parts) > 1 else None)


_GC_MEMORY_UNITS = {"B": 1, "KiB": 1024, "MiB": 1024 ** 2, "GiB": 1024 ** 3, "TiB": 1024 ** 4}


def parse_results_block(lines):
    """Parse the 'Results:' block into totals and per-op values.

    Lines look like:
      Op rate                   :   17,360 op/s  [insert: 10,435 op/s, singlepost: 6,925 op/s]
      Total GC memory           : 72.009 GiB
    """
    totals, per_op = {}, {}
    for line in lines:
        if ":" not in line:
            continue
        label, rest = line.split(":", 1)
        label = label.strip()
        if label not in RESULT_LINES:
            continue
        key, has_ops = RESULT_LINES[label]
        bracket = None
        if has_ops and "[" in rest:
            rest, bracket = rest.split("[", 1)
            bracket = bracket.rstrip().rstrip("]")
        value, unit = _value_and_unit(rest)
        if key == "gc_memory" and isinstance(value, (int, float)) and unit in _GC_MEMORY_UNITS:
            totals["gc_memory_mb"] = round(value * _GC_MEMORY_UNITS[unit] / 1048576, 1)
        else:
            totals[key] = value
        if bracket:
            # Values carry thousands separators ("insert: 10,435 op/s"), so split only on commas
            # that start the next "<op>:" entry
            for item in re.split(r",\s*(?=[A-Za-z_][\w.-]*:)", bracket):
                if ":" not in item:
                    continue
                op, val = item.split(":", 1)
                per_op.setdefault(op.strip(), {})[key] = _value_and_unit(val)[0]
    return totals, per_op


def parse_stress(path):
    """Return (totals, per_op, progress rows, settings, warnings) from stress_<phase>.txt."""
    with open(path, errors="replace") as f:
        lines = f.read().splitlines()

    progress = []
    results_start = None
    warnings = []
    for i, line in enumerate(lines):
        if line.startswith("Results:"):
            results_start = i
            break
        # Progress lines: "<op>,  <total ops>, <op/s>, ..." (skip the header and driver WARN lines)
        m = re.match(r"^([A-Za-z_][\w.-]*),\s+(\d.*)$", line)
        if m and m.group(1) != "type":
            values = [v.strip() for v in m.group(2).split(",")]
            if len(values) == len(PROGRESS_COLUMNS):
                progress.append({"op": m.group(1), **dict(zip(PROGRESS_COLUMNS, (_num(v) for v in values)))})

    totals, per_op = ({}, {})
    if results_start is not None:
        totals, per_op = parse_results_block(lines[results_start + 1:])
    else:
        warnings.append("no Results block (cassandra-stress did not finish)")

    # A few settings worth carrying into the results
    settings = {}
    for key, pattern in [
        ("count", r"^\s+Count:\s+(.+)$"),
        ("duration", r"^\s+Duration:\s+(.+)$"),
        ("consistency_level", r"^\s+Consistency Level:\s+(.+)$"),
        ("command_ratios", r"^\s+Command Ratios:\s+(.+)$"),
        ("threads", r"^\s+Thread Count:\s+(.+)$"),
        ("ops_per_sec_limit", r"^\s+OpsPer Sec:\s+(.+)$"),
        ("population", r"^\s+(?:Distribution|Sequence):\s+(.+)$"),
    ]:
        for line in lines[:results_start or len(lines)]:
            m = re.match(pattern, line)
            if m:
                settings[key] = _num(m.group(1))
                break

    # Errors cassandra-stress printed that are not counted in the Results block
    fatal = [l for l in lines if re.search(r"(?i)\b(exception|error):", l) and "WARN" not in l]
    if fatal:
        warnings.append(f"stress output contains errors, first: {fatal[0].strip()[:200]}")
    return totals, per_op, progress, settings or None, warnings


# =============================================================================
# Server snapshots
# =============================================================================

def parse_proc_stat(path):
    """Return utime+stime clock ticks from /proc/<pid>/stat (fields 14 and 15)."""
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        text = f.read().strip()
    if ")" not in text:
        return None
    # Field 2 (comm) can contain spaces, so split after its closing parenthesis; field 3 is index 0
    fields = text.rsplit(")", 1)[1].split()
    try:
        return int(fields[11]) + int(fields[12])
    except (IndexError, ValueError):
        return None


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


def parse_nodetool_info(path):
    if not os.path.isfile(path):
        return None
    info = {}
    with open(path) as f:
        for line in f:
            if ":" not in line:
                continue
            key, val = (s.strip() for s in line.split(":", 1))
            if key == "Heap Memory (MB)":
                used, _, total = val.partition("/")
                info["heap_used_mb"] = _num(used)
                info["heap_max_mb"] = _num(total)
            elif key == "Off Heap Memory (MB)":
                info["off_heap_mb"] = _num(val)
            elif key == "Load":
                info["load"] = val
            elif key == "Key Cache":
                m = re.search(r"([\d.]+|NaN) recent hit rate", val)
                if m:
                    info["key_cache_hit_rate"] = _num(m.group(1))
                m = re.search(r"size ([^,]+), capacity ([^,]+)", val)
                if m:
                    info["key_cache_size"], info["key_cache_capacity"] = m.group(1), m.group(2)
            elif key == "Exceptions":
                info["exceptions"] = _num(val)
    return info or None


def parse_tablestats(path):
    """Parse the table section of `nodetool tablestats <ks>.<table>`."""
    if not os.path.isfile(path):
        return None
    stats, in_table = {}, False
    with open(path) as f:
        for line in f:
            s = line.strip()
            if s.startswith("Table:"):
                in_table = True
                continue
            if not in_table or ":" not in s:
                continue
            key, val = (x.strip() for x in s.split(":", 1))
            if key in TABLESTATS_KEYS:
                val = re.sub(r"\s*ms$", "", val)
                stats[TABLESTATS_KEYS[key]] = val if val.startswith("[") else _num(val)
    return stats or None


def parse_disk_usage(path):
    if not os.path.isfile(path):
        return None
    usage = {}
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2 and parts[0].isdigit():
                usage[f"{os.path.basename(parts[1])}_bytes"] = int(parts[0])
    return usage or None


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


def parse_phase_times(results_dir):
    """Return {phase: {"start": epoch, "end": epoch, "exit_code": int}} in run order."""
    path = os.path.join(results_dir, "phase_times.csv")
    times = {}
    if os.path.isfile(path):
        with open(path) as f:
            for row in csv.DictReader(f):
                times[row["phase"]] = {
                    "start": _safe_float(row.get("start_epoch")),
                    "end": _safe_float(row.get("end_epoch")),
                    "exit_code": _num(row.get("exit_code", "")),
                }
    return times


def discover_phases(results_dir, phase_times):
    """Phases in the order they ran: phase_times.csv, else stress_<phase>.txt by mtime."""
    phases = [p for p in phase_times
              if os.path.isfile(os.path.join(results_dir, f"stress_{p}.txt"))]
    if not phases:
        found = []
        for path in glob.glob(os.path.join(results_dir, "stress_*.txt")):
            phase = os.path.basename(path)[len("stress_"):-len(".txt")]
            found.append((os.path.getmtime(path), phase))
        phases = [p for _, p in sorted(found)]
    unknown = [p for p in phases if p not in PHASE_ORDER]
    if unknown:
        log(f"WARNING: unexpected phase name(s): {unknown}")
    return phases


def clk_tck(versions):
    try:
        return int((versions or {}).get("clk_tck", 100))
    except ValueError:
        return 100


# =============================================================================
# CSV writers
# =============================================================================

SUMMARY_FIELDS = [
    ("Phase", None), ("Operation", None),
    ("Op rate (op/s)", "op_rate"), ("Partition rate (pk/s)", "partition_rate"),
    ("Row rate (row/s)", "row_rate"),
    ("Mean Latency (ms)", "latency_mean_ms"), ("Median Latency (ms)", "latency_median_ms"),
    ("p95 Latency (ms)", "latency_p95_ms"), ("p99 Latency (ms)", "latency_p99_ms"),
    ("p99.9 Latency (ms)", "latency_p99.9_ms"), ("Max Latency (ms)", "latency_max_ms"),
    ("Errors", "total_errors"), ("Read Hit (%)", "read_hit_pct"),
    ("Server CPU (cores)", "server_cpu_cores"), ("Server CPU (us/op)", "server_cpu_us_per_op"),
    ("Server GC Count", "gc_count"), ("Server GC Time (s)", "gc_time_s"),
]


def write_summary_csv(results_dir, bench, phases):
    rows = []
    for phase, p in phases.items():
        summary = dict(p.get("summary") or {})
        summary.update({k: p[k] for k in ("server_cpu_cores", "server_cpu_us_per_op") if k in p})
        ops = [("TOTAL", summary)] + [(op.upper(), m) for op, m in (p.get("per_op") or {}).items()]
        for op_name, m in ops:
            if not m:
                continue
            row = {}
            for col, key in SUMMARY_FIELDS:
                if key is None:
                    continue
                val = m.get(key, "")
                row[col] = "" if val is None else val
            row["Phase"], row["Operation"] = phase, op_name
            rows.append(row)

    if rows:
        dst = os.path.join(results_dir, f"results_{bench}.csv")
        with open(dst, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=[c for c, _ in SUMMARY_FIELDS])
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


def write_timeseries_csv(results_dir, bench, phase, progress):
    if not progress:
        return
    dst = os.path.join(results_dir, f"timeseries_{bench}_{phase}.csv")
    with open(dst, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["op"] + PROGRESS_COLUMNS)
        writer.writeheader()
        writer.writerows(progress)
    log(f"Wrote CSV: {dst} ({len(progress)} rows)")


# =============================================================================
# Main
# =============================================================================

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <results_dir> [benchmark_name]")
        sys.exit(1)

    results_dir = sys.argv[1]
    bench = sys.argv[2] if len(sys.argv) > 2 else "cassandra_stress"
    log(f"Parsing {bench} results from: {results_dir}")

    def path(name):
        return os.path.join(results_dir, name)

    versions = parse_versions(results_dir)
    ticks = clk_tck(versions)
    phase_times = parse_phase_times(results_dir)

    errors = []
    phases = {}
    numa_snapshots = {"baseline": parse_numastat(path("numastat_baseline.txt"))}

    phase_names = discover_phases(results_dir, phase_times)
    if not phase_names:
        log("WARNING: no stress_<phase>.txt files found")
        errors.append({"error": "no stress_<phase>.txt files found"})

    for phase in phase_names:
        entry = {}
        try:
            totals, per_op, progress, settings, warnings = parse_stress(path(f"stress_{phase}.txt"))
        except OSError as e:
            log(f"WARNING: could not read stress_{phase}.txt: {e}")
            errors.append({"phase": phase, "error": f"stress output: {e}"})
            continue
        for w in warnings:
            log(f"WARNING: phase {phase}: {w}")
            errors.append({"phase": phase, "warning": w})

        # Total operations completed, from the last cumulative progress line
        total_lines = [r for r in progress if r["op"] == "total"]
        if total_lines:
            totals["total_ops"] = total_lines[-1]["total_ops"]

        # Read hit rate: a singlepost/timeline that finds its domain returns one partition, a miss
        # returns none, so partitions/s over ops/s is the share of reads that found data.
        for op in READ_OPS:
            m = per_op.get(op)
            if m and m.get("op_rate"):
                m["read_hit_pct"] = round(100.0 * (m.get("partition_rate") or 0) / m["op_rate"], 2)
                if phase != "populate" and m["read_hit_pct"] < 99.0:
                    msg = (f"{op} found data for only {m['read_hit_pct']}% of reads "
                           "(domains not populated, or populate skipped)")
                    log(f"WARNING: phase {phase}: {msg}")
                    errors.append({"phase": phase, "warning": msg})

        if (totals.get("total_errors") or 0) > 0:
            msg = f"{totals['total_errors']} operation errors (ignored by -errors ignore)"
            log(f"WARNING: phase {phase}: {msg}")
            errors.append({"phase": phase, "warning": msg})

        timing = phase_times.get(phase) or {}
        if timing.get("exit_code") not in (None, 0):
            errors.append({"phase": phase, "error": f"cassandra-stress exit code {timing['exit_code']}"})

        entry["settings"] = settings
        entry["summary"] = totals or None
        entry["per_op"] = per_op or None
        if timing.get("start") and timing.get("end"):
            entry["wall_time_s"] = round(timing["end"] - timing["start"], 3)

        # Server CPU over the stress run only (snapshots taken immediately before and after)
        t0 = parse_proc_stat(path(f"proc_stat_{phase}_start.txt"))
        t1 = parse_proc_stat(path(f"proc_stat_{phase}.txt"))
        if t0 is not None and t1 is not None and t1 >= t0:
            cpu_s = (t1 - t0) / ticks
            entry["server_cpu_seconds"] = round(cpu_s, 2)
            if entry.get("wall_time_s"):
                entry["server_cpu_cores"] = round(cpu_s / entry["wall_time_s"], 2)
            if totals.get("total_ops"):
                entry["server_cpu_us_per_op"] = round(1e6 * cpu_s / totals["total_ops"], 2)

        entry["server"] = parse_nodetool_info(path(f"nodetool_info_{phase}.txt"))
        entry["table"] = parse_tablestats(path(f"nodetool_tablestats_{phase}.txt"))
        entry["disk_usage"] = parse_disk_usage(path(f"disk_usage_{phase}.txt"))
        placement = parse_numastat(path(f"numastat_{phase}.txt"))
        entry["numa_placement_mb"] = placement
        numa_snapshots[phase] = placement

        write_timeseries_csv(results_dir, bench, phase, progress)

        log(f"Phase {phase}: {totals.get('op_rate')} op/s, p99 {totals.get('latency_p99_ms')} ms, "
            f"server {entry.get('server_cpu_cores', '?')} cores, {totals.get('total_errors', '?')} errors")
        phases[phase] = entry

    settled = parse_tablestats(path("nodetool_tablestats_populate_settled.txt"))

    # ----- Write JSON (primary output) -----
    json_output = {
        "benchmark": bench,
        "parser_version": PARSER_VERSION,
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source_dir": os.path.basename(os.path.abspath(results_dir)),
        "versions": versions,
        "baseline": {
            "server": parse_nodetool_info(path("nodetool_info_baseline.txt")),
            "numa_placement_mb": numa_snapshots.get("baseline"),
        },
        "populate_settled_table": settled,
        "phases": phases or None,
        "run_metadata": parse_run_metadata(results_dir),
        "errors": errors or None,
    }

    json_path = path(f"results_{bench}.json")
    with open(json_path, "w") as f:
        json.dump(json_output, f, indent=2)
    log(f"Wrote JSON: {json_path}")

    # ----- Write CSVs -----
    write_summary_csv(results_dir, bench, phases)
    write_numa_csv(results_dir, bench, numa_snapshots)

    jsons = sorted(glob.glob(path("results_*.json")))
    csvs = sorted(glob.glob(path("results_*.csv")))
    log(f"Produced: {len(jsons)} JSON + {len(csvs)} CSV file(s)")

    sys.exit(1 if not phases else 0)


if __name__ == "__main__":
    main()
