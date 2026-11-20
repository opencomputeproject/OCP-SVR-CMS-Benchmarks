#!/usr/bin/env python3
"""Compare two mlc.sh summary_report.json files and highlight regressions.

Usage: gen_compare.py <run_A_dir_or_json> <run_B_dir_or_json> [options]

Stdlib only (json, argparse, pathlib, datetime) - no venv required, unlike
gen_plot.py/gen_excel.py. Meant for regression testing (run1 vs run2 on the
same box) or system-to-system comparisons (system A vs system B).
"""

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

# (json key, column label, "higher"|"lower" is better)
# Peak BW/Best Ratio can still reflect a low-core-count cache-residency
# artifact (see summary_report.md's Observations section); Sustained BW is
# the tail-of-ramp value and is the one to trust for real regressions -
# both are compared here so a report generated before this field existed
# (sustained_bw_mbs absent -> None -> rendered as "n/a", no crash) still
# compares cleanly against a newer one.
PEAK_METRICS = [
    ("idle_lat_seq_ns", "Idle Lat seq (ns)", "lower"),
    ("idle_lat_rand_ns", "Idle Lat rand (ns)", "lower"),
    ("peak_bw_mbs", "Peak BW (MB/s)", "higher"),
    ("lat_at_peak_ns", "Lat @ Peak (ns)", "lower"),
    ("sustained_bw_mbs", "Sustained BW (MB/s)", "higher"),
]

INTERLEAVE_METRICS = [
    ("peak_bw_mbs", "Peak BW (MB/s)", "higher"),
    ("lat_at_peak_ns", "Lat @ Peak (ns)", "lower"),
    ("sustained_bw_mbs", "Sustained BW (MB/s)", "higher"),
]

SYSTEM_FIELDS = [
    ("hostname", "Hostname"),
    ("platform", "Platform"),
    ("mlc_version", "MLC version"),
    ("mlc_sh_version", "mlc.sh version"),
    ("sockets_in_system", "Physical sockets"),
    ("cores_per_socket", "Cores per socket"),
    ("numa_nodes_in_system", "NUMA nodes"),
]


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def load_report(arg):
    path = Path(arg)
    if path.is_dir():
        json_path = path / "summary_report.json"
        if not json_path.is_file():
            die(
                f"'{path}' contains no summary_report.json - "
                f"run 'utils/gen_report.sh {path}' to generate it."
            )
    elif path.is_file():
        json_path = path
    else:
        die(f"'{arg}' does not exist")

    try:
        with open(json_path) as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        die(f"'{json_path}' is not valid JSON: {e}")

    data["_path"] = str(path)
    data["_json_path"] = str(json_path)
    return data


def label_for(report, override):
    if override:
        return override
    hostname = report.get("system", {}).get("hostname")
    if hostname:
        return hostname
    return Path(report["_path"]).name


def fmt(v):
    if v is None:
        return "n/a"
    if isinstance(v, bool):
        return str(v)
    if isinstance(v, int):
        return str(v)
    return str(round(v, 2))


def delta_pct(a, b):
    if a is None or b is None or a == 0:
        return None
    return (b - a) / a * 100.0


def marker_and_pct(a, b, direction, threshold):
    pct = delta_pct(a, b)
    if pct is None:
        return "n/a", None
    if abs(pct) <= threshold:
        return "~", pct
    improved = (direction == "higher" and pct > 0) or (direction == "lower" and pct < 0)
    return ("▲" if improved else "▼"), pct


def metric_cell(a, b, direction, threshold):
    marker, pct = marker_and_pct(a, b, direction, threshold)
    if pct is None:
        return f"{fmt(a)} → {fmt(b)} (n/a)"
    sign = "+" if pct >= 0 else ""
    return f"{fmt(a)} → {fmt(b)} ({sign}{pct:.1f}% {marker})"


def index_by(rows, key_fields):
    out = {}
    for row in rows:
        key = tuple(row.get(k) for k in key_fields)
        out[key] = row
    return out


def compare_rows(rows_a, rows_b, key_fields, metrics, threshold):
    """Returns (matched_keys_sorted, idx_a, idx_b, regressions)."""
    idx_a = index_by(rows_a, key_fields)
    idx_b = index_by(rows_b, key_fields)
    all_keys = sorted(set(idx_a) | set(idx_b))
    matched = [k for k in all_keys if k in idx_a and k in idx_b]
    only_a = [k for k in all_keys if k not in idx_b]
    only_b = [k for k in all_keys if k not in idx_a]

    regressions = []
    for key in matched:
        row_a, row_b = idx_a[key], idx_b[key]
        for mkey, label, direction in metrics:
            marker, pct = marker_and_pct(row_a.get(mkey), row_b.get(mkey), direction, threshold)
            if marker == "▼" and pct is not None:
                regressions.append(
                    {
                        "key": key,
                        "key_fields": key_fields,
                        "metric": label,
                        "a": row_a.get(mkey),
                        "b": row_b.get(mkey),
                        "pct": pct,
                    }
                )

    return matched, only_a, only_b, idx_a, idx_b, regressions


def render_key_desc(key, key_fields, row):
    if key_fields == ("socket", "node"):
        return f"Socket {key[0]} -> Node {key[1]} ({row.get('type', 'unknown')})"
    if key_fields == ("socket", "dram_node", "cxl_node", "traffic"):
        return f"Socket {key[0]} DRAM {key[1]} + CXL {key[2]} ({key[3]})"
    return str(key)


def build_peak_table(matched, idx_a, idx_b, threshold):
    lines = []
    header = ["Socket", "Node", "Type"] + [m[1] for m in PEAK_METRICS] + ["@ Cores (A/B)", "Max Cores (A/B)"]
    lines.append("| " + " | ".join(header) + " |")
    lines.append("|" + "|".join(["---"] * len(header)) + "|")
    for key in matched:
        row_a, row_b = idx_a[key], idx_b[key]
        sock, node = key
        node_type = row_a.get("type") or row_b.get("type") or "unknown"
        cells = [str(sock), str(node), node_type]
        for mkey, _, direction in PEAK_METRICS:
            cells.append(metric_cell(row_a.get(mkey), row_b.get(mkey), direction, threshold))
        cells.append(f"{fmt(row_a.get('at_cores'))}/{fmt(row_b.get('at_cores'))}")
        cells.append(f"{fmt(row_a.get('max_cores_tested'))}/{fmt(row_b.get('max_cores_tested'))}")
        lines.append("| " + " | ".join(cells) + " |")
    return lines


def build_interleave_table(matched, idx_a, idx_b, threshold):
    lines = []
    header = ["Socket", "DRAM Node", "CXL Node", "Traffic"] + [m[1] for m in INTERLEAVE_METRICS] + [
        "@ Cores (A/B)",
        "Best Ratio (A/B)",
        "Sustained Ratio (A/B)",
    ]
    lines.append("| " + " | ".join(header) + " |")
    lines.append("|" + "|".join(["---"] * len(header)) + "|")
    for key in matched:
        row_a, row_b = idx_a[key], idx_b[key]
        sock, dnode, cnode, wtype = key
        cells = [str(sock), str(dnode), str(cnode), wtype]
        for mkey, _, direction in INTERLEAVE_METRICS:
            cells.append(metric_cell(row_a.get(mkey), row_b.get(mkey), direction, threshold))
        cells.append(f"{fmt(row_a.get('at_cores'))}/{fmt(row_b.get('at_cores'))}")
        cells.append(f"{row_a.get('best_ratio', 'n/a')}/{row_b.get('best_ratio', 'n/a')}")
        cells.append(f"{row_a.get('sustained_ratio', 'n/a')}/{row_b.get('sustained_ratio', 'n/a')}")
        lines.append("| " + " | ".join(cells) + " |")
    return lines


def build_only_in_section(title, keys, idx, key_fields):
    if not keys:
        return []
    lines = [f"### {title}", ""]
    for key in keys:
        lines.append(f"- {render_key_desc(key, key_fields, idx[key])}")
    lines.append("")
    return lines


def main():
    parser = argparse.ArgumentParser(
        description="Compare two mlc.sh summary_report.json reports and highlight regressions."
    )
    parser.add_argument("run_a", help="Directory (containing summary_report.json) or a direct .json path")
    parser.add_argument("run_b", help="Directory (containing summary_report.json) or a direct .json path")
    parser.add_argument("-o", "--output", default="comparison_report.md", help="Output Markdown path (default: ./comparison_report.md)")
    parser.add_argument("-t", "--threshold", type=float, default=3.0, help="Percent change within which a metric is considered unchanged (default: 3)")
    parser.add_argument("--label-a", default=None, help="Display label for run A (default: its hostname)")
    parser.add_argument("--label-b", default=None, help="Display label for run B (default: its hostname)")
    args = parser.parse_args()

    report_a = load_report(args.run_a)
    report_b = load_report(args.run_b)
    label_a = label_for(report_a, args.label_a)
    label_b = label_for(report_b, args.label_b)
    threshold = args.threshold

    peak_matched, peak_only_a, peak_only_b, peak_idx_a, peak_idx_b, peak_regressions = compare_rows(
        report_a.get("peak_results", []), report_b.get("peak_results", []), ("socket", "node"), PEAK_METRICS, threshold
    )
    il_matched, il_only_a, il_only_b, il_idx_a, il_idx_b, il_regressions = compare_rows(
        report_a.get("interleave_peak_results", []),
        report_b.get("interleave_peak_results", []),
        ("socket", "dram_node", "cxl_node", "traffic"),
        INTERLEAVE_METRICS,
        threshold,
    )

    all_regressions = peak_regressions + il_regressions
    all_regressions.sort(key=lambda r: abs(r["pct"]), reverse=True)

    out = []
    out.append("# MLC Benchmark Comparison")
    out.append("")
    out.append(f"- **Generated:** {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S %Z')}")
    out.append(f"- **Run A:** {label_a} (`{report_a['_json_path']}`)")
    out.append(f"- **Run B:** {label_b} (`{report_b['_json_path']}`)")
    out.append(f"- **Threshold:** ±{threshold:g}% (changes within this band are marked `~`)")
    out.append("- **Markers:** `▲` better, `▼` worse, `~` no significant change")
    out.append("")

    out.append("## System Under Test")
    out.append("")
    out.append(f"| Field | {label_a} | {label_b} |")
    out.append("|---|---|---|")
    sys_a, sys_b = report_a.get("system", {}), report_b.get("system", {})
    for key, field_label in SYSTEM_FIELDS:
        out.append(f"| {field_label} | {sys_a.get(key) or 'n/a'} | {sys_b.get(key) or 'n/a'} |")
    out.append(f"| Run status | {report_a.get('run_status', 'n/a')} | {report_b.get('run_status', 'n/a')} |")
    out.append("")

    out.append("## Peak Results by Socket -> Node")
    out.append("")
    if peak_matched:
        out.extend(build_peak_table(peak_matched, peak_idx_a, peak_idx_b, threshold))
    else:
        out.append("No matching (socket, node) pairs found in both runs.")
    out.append("")
    out.extend(build_only_in_section(f"Only in {label_a}", peak_only_a, peak_idx_a, ("socket", "node")))
    out.extend(build_only_in_section(f"Only in {label_b}", peak_only_b, peak_idx_b, ("socket", "node")))

    if il_matched or il_only_a or il_only_b:
        out.append("## Interleave Peak Results (DRAM + CXL, seq)")
        out.append("")
        if il_matched:
            out.extend(build_interleave_table(il_matched, il_idx_a, il_idx_b, threshold))
        else:
            out.append("No matching interleave pairs found in both runs.")
        out.append("")
        out.extend(
            build_only_in_section(
                f"Only in {label_a}", il_only_a, il_idx_a, ("socket", "dram_node", "cxl_node", "traffic")
            )
        )
        out.extend(
            build_only_in_section(
                f"Only in {label_b}", il_only_b, il_idx_b, ("socket", "dram_node", "cxl_node", "traffic")
            )
        )

    out.append("## Regressions")
    out.append("")
    if all_regressions:
        for r in all_regressions:
            row = peak_idx_a.get(r["key"]) if r["key_fields"] == ("socket", "node") else il_idx_a.get(r["key"])
            desc = render_key_desc(r["key"], r["key_fields"], row or {})
            out.append(
                f"- {desc} - {r['metric']}: {fmt(r['a'])} → {fmt(r['b'])} ({r['pct']:+.1f}%)"
            )
    else:
        out.append(f"No regressions beyond the ±{threshold:g}% threshold.")
    out.append("")

    out.append("## Observations")
    out.append("")
    out.append(f"**{label_a}:**")
    obs_a = report_a.get("observations", [])
    out.extend([f"- {o}" for o in obs_a] if obs_a else ["- None recorded."])
    out.append("")
    out.append(f"**{label_b}:**")
    obs_b = report_b.get("observations", [])
    out.extend([f"- {o}" for o in obs_b] if obs_b else ["- None recorded."])
    out.append("")

    Path(args.output).write_text("\n".join(out) + "\n")
    print(f"Comparison report written to: {args.output}")
    if all_regressions:
        print(f"{len(all_regressions)} regression(s) found beyond the ±{threshold:g}% threshold.")


if __name__ == "__main__":
    main()
