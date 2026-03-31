#!/usr/bin/env bash

#################################################################################################
# OCP SRV CMS - Report Generator (generate_report.sh)
#
# Generates summary output files from benchmark results. Called after a benchmark completes
# to produce the deliverables described in the container-runtime README:
#   - CSV summary
#   - HTML report (with ALL collected sysinfo data, organized by collapsible category)
#   - Tarball of all raw output
#
# Usage:
#   ./generate_report.sh <results_dir> <benchmark_name> [csv_file]
#   ./generate_report.sh --dry-run <path/to/sysinfo.json> [benchmark_name]
#
# Dry-run mode:
#   Feed a standalone sysinfo.json (or any per-category JSON) to test the HTML renderer
#   without needing a full benchmark results directory.
#   Example: ./generate_report.sh --dry-run ./sysinfo_sample.json stream
#
# The report renders ALL sysinfo data organized into collapsible categories:
#   1. BIOS / Firmware / Baseboard    7. Storage
#   2. CPU                             8. Kernel / OS
#   3. Memory (DRAM)                   9. Packages / Software BOM
#   4. NUMA Topology & CXL Devices    10. Container Runtime
#   5. PCI Devices                    11. GPU
#   6. Network                        12. Power / Thermal
#################################################################################################

REPORT_VERSION="0.4.0"

#################################################################################################
# Argument parsing
#################################################################################################
DRY_RUN=false
DRY_RUN_JSON=""

if [ "$1" = "--dry-run" ]; then
    DRY_RUN=true
    DRY_RUN_JSON="${2:?Usage: $0 --dry-run <path/to/sysinfo.json> [benchmark_name]}"
    BENCHMARK_NAME="${3:-dry-run}"
    RESULTS_DIR="$(mktemp -d)"
    mkdir -p "${RESULTS_DIR}/sysinfo"
    CSV_FILE=""
    echo "[REPORT] Dry-run mode: rendering from ${DRY_RUN_JSON}"
else
    RESULTS_DIR="${1:-.}"
    BENCHMARK_NAME="${2:-unknown}"
    CSV_FILE="${3:-${RESULTS_DIR}/results.csv}"
fi

RESULTS_DIR_ABS="$(cd "${RESULTS_DIR}" 2>/dev/null && pwd)" || RESULTS_DIR_ABS="${RESULTS_DIR}"
HTML_FILE="${RESULTS_DIR_ABS}/${BENCHMARK_NAME}_report.html"
TARBALL_NAME="${BENCHMARK_NAME}_results.tar.gz"
TARBALL_TMP="$(dirname "${RESULTS_DIR_ABS}")/${TARBALL_NAME}"
TARBALL_FINAL="${RESULTS_DIR_ABS}/${TARBALL_NAME}"

if ! ${DRY_RUN} && [ ! -d "${RESULTS_DIR}" ]; then
    echo "[ERROR] Results directory not found: ${RESULTS_DIR}"
    exit 1
fi

echo "[REPORT] Generating report for: ${BENCHMARK_NAME}"
echo "[REPORT] Results directory: ${RESULTS_DIR}"

SYSINFO_DIR="${RESULTS_DIR}/sysinfo"

_HAS_PYTHON=false
command -v python3 &>/dev/null && _HAS_PYTHON=true

#################################################################################################
# HTML-escape helper
#################################################################################################
_html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}

#################################################################################################
# JSON-to-HTML renderer (python3)
#################################################################################################
_render_json_category() {
    local json_file="$1"
    local title="$2"
    local default_open="${3:-}"

    [ -f "${json_file}" ] || return 1

    local open_attr=""
    [ "${default_open}" = "open" ] && open_attr=" open"

    if ${_HAS_PYTHON}; then
        python3 - "${json_file}" "${title}" "${open_attr}" >> "${HTML_FILE}" << 'PYEOF'
import json, sys, html

json_file = sys.argv[1]
title = sys.argv[2]
open_attr = sys.argv[3]

try:
    with open(json_file, 'r') as f:
        data = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    sys.exit(1)

if not data or not isinstance(data, dict):
    sys.exit(1)

def is_null_or_empty(v):
    if v is None:
        return True
    if isinstance(v, str) and (
        v.strip() == '' or
        v.strip().startswith('# Command not found') or
        v.strip().startswith('# Not available') or
        v.strip().startswith('# Empty') or
        v.strip().startswith('# Directory not available')
    ):
        return True
    if isinstance(v, (dict, list)) and len(v) == 0:
        return True
    return False

def all_null(d):
    if not isinstance(d, dict):
        return False
    return all(is_null_or_empty(v) for v in d.values())

def humanize_key(k):
    return k.replace('_', ' ').replace('.', ' ').title()

def render_value_cell(v):
    if isinstance(v, bool):
        return html.escape(str(v).lower())
    if isinstance(v, (int, float)):
        return html.escape(str(v))
    if isinstance(v, dict):
        if 'value' in v and 'unit' in v:
            return html.escape(f"{v['value']} {v['unit']}")
        parts = [f"{dk}: {dv}" for dk, dv in v.items() if not is_null_or_empty(dv)]
        return html.escape(', '.join(parts)) if parts else ''
    return html.escape(str(v))

def is_multiline(v):
    if not isinstance(v, str):
        return False
    return '\n' in v or len(v) > 200

def render_kv_table(d, out):
    simple = [(k, v) for k, v in d.items()
              if not is_null_or_empty(v)
              and not isinstance(v, (dict, list))
              and not is_multiline(v)]
    if not simple:
        return
    out.append('        <table>')
    out.append('          <tr><th>Property</th><th>Value</th></tr>')
    for k, v in simple:
        out.append(f'          <tr><td>{html.escape(humanize_key(k))}</td><td>{render_value_cell(v)}</td></tr>')
    out.append('        </table>')

def render_dict(d, out, depth=0):
    if all_null(d):
        return
    render_kv_table(d, out)
    for k, v in d.items():
        if is_null_or_empty(v):
            continue
        if isinstance(v, str) and is_multiline(v):
            label = humanize_key(k)
            out.append(f'        <div class="file-block">')
            out.append(f'          <div class="file-label">{html.escape(label)}</div>')
            out.append(f'          <pre>{html.escape(v)}</pre>')
            out.append(f'        </div>')
    for k, v in d.items():
        if is_null_or_empty(v):
            continue
        if isinstance(v, dict) and not ('value' in v and 'unit' in v):
            if all_null(v):
                continue
            label = humanize_key(k)
            out.append(f'        <details class="subcategory">')
            out.append(f'          <summary>{html.escape(label)}</summary>')
            out.append(f'          <div class="category-content">')
            render_dict(v, out, depth + 1)
            out.append(f'          </div>')
            out.append(f'        </details>')
    for k, v in d.items():
        if is_null_or_empty(v):
            continue
        if isinstance(v, list):
            label = humanize_key(k)
            out.append(f'        <details class="subcategory">')
            out.append(f'          <summary>{html.escape(label)} ({len(v)} items)</summary>')
            out.append(f'          <div class="category-content">')
            if v and isinstance(v[0], dict):
                all_keys = []
                for item in v:
                    for ik in item.keys():
                        if ik not in all_keys:
                            all_keys.append(ik)
                out.append('            <table>')
                out.append('              <tr>' + ''.join(f'<th>{html.escape(humanize_key(ak))}</th>' for ak in all_keys) + '</tr>')
                for item in v:
                    cells = ''.join(f'<td>{render_value_cell(item.get(ak))}</td>' for ak in all_keys)
                    out.append(f'              <tr>{cells}</tr>')
                out.append('            </table>')
            else:
                text = '\n'.join(str(item) for item in v)
                out.append(f'            <pre>{html.escape(text)}</pre>')
            out.append(f'          </div>')
            out.append(f'        </details>')

lines = []
lines.append(f'    <details class="category"{open_attr}>')
lines.append(f'      <summary>{html.escape(title)}</summary>')
lines.append(f'      <div class="category-content">')
render_dict(data, lines)
lines.append(f'      </div>')
lines.append(f'    </details>')
print('\n'.join(lines))
PYEOF
        return $?
    fi
    return 1
}

#################################################################################################
# Dry-run: render a combined sysinfo.json by splitting into per-category temp files
#################################################################################################
_render_dry_run() {
    local json_file="$1"

    if ! ${_HAS_PYTHON}; then
        echo "[ERROR] --dry-run requires python3"
        exit 1
    fi

    # Check if this is a combined sysinfo.json (has top-level category keys)
    # or a single-category file
    local is_combined
    is_combined=$(python3 -c "
import json, sys
with open('${json_file}') as f:
    d = json.load(f)
cats = ['bios_firmware','cpu','memory','numa_cxl','pci_devices','network','storage','kernel_os','packages','runtime','gpu','power']
found = [c for c in cats if c in d and isinstance(d[c], dict)]
print('combined' if len(found) >= 3 else 'single')
" 2>/dev/null)

    if [ "${is_combined}" = "combined" ]; then
        echo "[REPORT] Detected combined sysinfo.json — splitting into categories"
        # Extract each category into its own temp JSON file
        python3 - "${json_file}" "${SYSINFO_DIR}" << 'PYEOF'
import json, sys, os
json_file = sys.argv[1]
outdir = sys.argv[2]
with open(json_file) as f:
    data = json.load(f)
cats = ['bios_firmware','cpu','memory','numa_cxl','pci_devices','network','storage','kernel_os','packages','runtime','gpu','power']
# Write metadata
meta = {k: v for k, v in data.items() if k not in cats}
if meta:
    with open(os.path.join(outdir, 'collection_metadata.json'), 'w') as f:
        json.dump(meta, f, indent=2)
for cat in cats:
    if cat in data and isinstance(data[cat], dict):
        catdir = os.path.join(outdir, cat)
        os.makedirs(catdir, exist_ok=True)
        with open(os.path.join(catdir, f'{cat}.json'), 'w') as f:
            json.dump(data[cat], f, indent=2)
PYEOF
    else
        echo "[REPORT] Detected single-category JSON — rendering as-is"
        _render_json_category "${json_file}" "System Information" "open"
        return
    fi

    # Now render normally — the per-category files are in place
}

#################################################################################################
# Fallback: render .txt files
#################################################################################################
_emit_file_block() {
    local filepath="$1"
    local label="$2"
    [[ "${filepath}" != /* ]] && filepath="${SYSINFO_DIR}/${filepath}"
    if [ -f "${filepath}" ] && [ -s "${filepath}" ]; then
        local content
        content=$(cat "${filepath}" 2>/dev/null)
        echo "${content}" | grep -qE '^#\s*(Not available|Command not found|Empty|Unreadable|Directory not available)' && return
        content=$(_html_escape "${content}")
        cat >> "${HTML_FILE}" << EOF
            <div class="file-block">
                <div class="file-label">${label}</div>
                <pre>${content}</pre>
            </div>
EOF
    fi
}

_emit_txt_category() {
    local subdir="$1" title="$2" default_state="${3:-}"
    local dirpath="${SYSINFO_DIR}/${subdir}"
    [ -d "${dirpath}" ] || return
    local has_content=false
    while IFS= read -r -d '' f; do
        [ "${f##*.}" = "json" ] && continue
        if [ -s "${f}" ] && ! head -1 "${f}" 2>/dev/null | grep -qE '^#\s*(Not available|Command not found|Empty|Unreadable|Directory not available)'; then
            has_content=true; break
        fi
    done < <(find "${dirpath}" -type f -print0 2>/dev/null)
    ${has_content} || return
    local open_attr=""
    [ "${default_state}" = "open" ] && open_attr=" open"
    echo "    <details class=\"category\"${open_attr}><summary>${title}</summary><div class=\"category-content\">" >> "${HTML_FILE}"
    while IFS= read -r -d '' f; do
        [ "${f##*.}" = "json" ] && continue
        local bn; bn=$(basename "${f}")
        local label; label=$(echo "${bn}" | sed 's/\.txt$//; s/_/ /g; s/\./ /g')
        _emit_file_block "${f}" "${label}"
    done < <(find "${dirpath}" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
    while IFS= read -r -d '' sub; do
        local sn sh=false; sn=$(basename "${sub}")
        while IFS= read -r -d '' sf; do
            [ "${sf##*.}" = "json" ] && continue
            if [ -s "${sf}" ] && ! head -1 "${sf}" 2>/dev/null | grep -qE '^#\s*(Not available|Command not found|Empty|Unreadable|Directory not available)'; then
                sh=true; break; fi
        done < <(find "${sub}" -maxdepth 1 -type f -print0 2>/dev/null)
        if ${sh}; then
            echo "        <details class=\"subcategory\"><summary>${sn}</summary><div class=\"category-content\">" >> "${HTML_FILE}"
            while IFS= read -r -d '' sf; do
                [ "${sf##*.}" = "json" ] && continue
                local sfb sfl; sfb=$(basename "${sf}"); sfl=$(echo "${sfb}" | sed 's/\.txt$//; s/_/ /g; s/\./ /g')
                _emit_file_block "${sf}" "${sfl}"
            done < <(find "${sub}" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
            echo "    </div></details>" >> "${HTML_FILE}"
        fi
    done < <(find "${dirpath}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
    echo "    </div></details>" >> "${HTML_FILE}"
}

#################################################################################################
# Unified category renderer
#################################################################################################
_render_category() {
    local subdir="$1" title="$2" default_open="${3:-}"
    local json_file="${SYSINFO_DIR}/${subdir}/${subdir}.json"
    if ${_HAS_PYTHON} && [ -f "${json_file}" ]; then
        _render_json_category "${json_file}" "${title}" "${default_open}" && return 0
    fi
    _emit_txt_category "${subdir}" "${title}" "${default_open}"
}

#################################################################################################
# 1. HTML Report
#################################################################################################

echo "[REPORT] Generating HTML report..."
${_HAS_PYTHON} && echo "[REPORT] Using JSON-driven rendering" || echo "[REPORT] Falling back to txt-based rendering"

# Handle dry-run: split combined JSON into per-category files
if ${DRY_RUN}; then
    _render_dry_run "${DRY_RUN_JSON}"
fi

CSV_CONTENT=""
if [ -n "${CSV_FILE}" ] && [ -f "${CSV_FILE}" ]; then
    CSV_CONTENT=$(cat "${CSV_FILE}" 2>/dev/null)
fi

# ---- OCP-branded color scheme and typography ----
# Colors from OCP brand guidelines:
#   Nav/header: #5F6062 (OCP gray)
#   Primary accent: #8DC141 (OCP green)
#   Secondary accent: #AFE646 (OCP bright green)
#   Hover/active: #6E9A2E (darker green)
#   Background: #F7F8FA (cool off-white)
#   Card background: #FFFFFF
#   Text primary: #1E293B (slate-900)
#   Text secondary: #64748B (slate-500)
#   Borders: #E2E8F0 (slate-200)
#   Table alt row: #F1F5F9 (slate-50)
#   Pre/code bg: #1E293B (matches text color — dark slate)
#   Font stack: Inter (OCP uses Inter/system sans-serif)
cat > "${HTML_FILE}" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>OCP CMS Benchmark Report</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
    <style>
        :root {
            --ocp-gray: #5F6062;
            --ocp-green: #8DC141;
            --ocp-green-light: #AFE646;
            --ocp-green-hover: #6E9A2E;
            --ocp-green-subtle: #F0F8E0;
            --bg: #F7F8FA;
            --bg-card: #FFFFFF;
            --text: #1E293B;
            --text-secondary: #64748B;
            --border: #E2E8F0;
            --row-alt: #F1F5F9;
            --pre-bg: #1E293B;
            --pre-text: #E2E8F0;
        }
#	@media (prefers-color-scheme: dark) {
#    	:root {
#            --ocp-gray: #9EA0A2;
#            --ocp-green: #8DC141;
#            --ocp-green-light: #A8D94A;
#            --ocp-green-hover: #9FCC38;
#            --ocp-green-subtle: #1A2A10;
#            --bg: #0F1117;
#            --bg-card: #1A1D24;
#            --text: #E2E8F0;
#            --text-secondary: #94A3B8;
#            --border: #2D3343;
#            --row-alt: #1F2330;
#            --pre-bg: #12141A;
#            --pre-text: #CBD5E1;
#        }
#	}
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            max-width: 1200px;
            margin: 0 auto;
            padding: 0;
            background: var(--bg);
            color: var(--text);
            line-height: 1.6;
            font-size: 14px;
        }

        /* ---- OCP Header Banner ---- */
        .ocp-header {
            background: var(--ocp-gray);
            color: white;
            padding: 28px 32px 24px;
            margin-bottom: 0;
        }
        .ocp-header .ocp-brand {
            font-size: 12px;
            font-weight: 500;
            letter-spacing: 2px;
            text-transform: uppercase;
            color: var(--ocp-green-light);
            margin-bottom: 8px;
        }
        .ocp-header h1 {
            font-size: 26px;
            font-weight: 700;
            color: white;
            margin: 0;
            letter-spacing: -0.3px;
        }

        /* ---- Meta Bar ---- */
        .meta-bar {
            background: var(--ocp-green);
            color: white;
            padding: 12px 32px;
            font-size: 13px;
            display: flex;
            gap: 32px;
            flex-wrap: wrap;
        }
        .meta-bar span { opacity: 0.9; }
        .meta-bar strong { font-weight: 600; opacity: 1; }

        /* ---- Content Area ---- */
        .content {
            padding: 24px 32px 40px;
        }
        h2 {
            color: var(--ocp-gray);
            font-size: 18px;
            font-weight: 700;
            margin: 28px 0 14px 0;
            padding-bottom: 8px;
            border-bottom: 2px solid var(--ocp-green);
        }

        /* ---- Tables ---- */
        table {
            border-collapse: collapse;
            width: 100%;
            margin: 12px 0;
            font-size: 13px;
        }
        th, td {
            border: 1px solid var(--border);
            padding: 8px 12px;
            text-align: left;
        }
        th {
            background: var(--ocp-gray);
            color: white;
            font-weight: 600;
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        tr:nth-child(even) { background: var(--row-alt); }
        tr:hover { background: var(--ocp-green-subtle); }

        /* ---- Pre / Code blocks ---- */
        pre {
            background: var(--pre-bg);
            color: var(--pre-text);
            padding: 14px 16px;
            border-radius: 4px;
            overflow-x: auto;
            font-family: 'JetBrains Mono', 'Fira Code', 'Cascadia Code', 'Consolas', monospace;
            font-size: 12px;
            line-height: 1.5;
            margin: 6px 0 14px 0;
            white-space: pre-wrap;
            word-wrap: break-word;
            border-left: 3px solid var(--ocp-green);
        }

        /* ---- Collapsible Category Sections ---- */
        details.category {
            background: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: 6px;
            margin: 10px 0;
            overflow: hidden;
            box-shadow: 0 1px 3px rgba(0,0,0,0.04);
        }
        details.category > summary {
            background: var(--ocp-gray);
            color: white;
            padding: 12px 18px;
            font-size: 14px;
            font-weight: 600;
            cursor: pointer;
            user-select: none;
            list-style: none;
            display: flex;
            align-items: center;
            transition: background 0.15s;
        }
        details.category > summary::-webkit-details-marker { display: none; }
        details.category > summary::before {
            content: "\25b6";
            display: inline-block;
            margin-right: 10px;
            font-size: 10px;
            transition: transform 0.2s ease;
            color: var(--ocp-green-light);
        }
        details.category[open] > summary::before {
            transform: rotate(90deg);
        }
        details.category > summary:hover {
            background: #4A4C4E;
        }
        .category-content {
            padding: 16px 18px;
        }

        /* ---- Subcategory ---- */
        details.subcategory {
            background: var(--row-alt);
            border: 1px solid var(--border);
            border-radius: 4px;
            margin: 8px 0;
        }
        details.subcategory > summary {
            background: linear-gradient(135deg, var(--ocp-green-subtle) 0%, #f0f4f8 100%);
            color: var(--ocp-gray);
            padding: 8px 14px;
            font-size: 13px;
            font-weight: 600;
            cursor: pointer;
            user-select: none;
            list-style: none;
            display: flex;
            align-items: center;
            border-bottom: 1px solid var(--border);
        }
        details.subcategory > summary::-webkit-details-marker { display: none; }
        details.subcategory > summary::before {
            content: "\25b6";
            display: inline-block;
            margin-right: 8px;
            font-size: 9px;
            transition: transform 0.2s ease;
            color: var(--ocp-green);
        }
        details.subcategory[open] > summary::before {
            transform: rotate(90deg);
        }
        details.subcategory > summary:hover {
            background: var(--ocp-green-subtle);
        }

        /* ---- File blocks ---- */
        .file-block { margin-bottom: 14px; }
        .file-label {
            font-weight: 600;
            font-size: 12px;
            color: var(--ocp-green-hover);
            text-transform: capitalize;
            margin-bottom: 3px;
            padding-left: 2px;
            letter-spacing: 0.3px;
        }

        /* ---- Controls ---- */
        .controls {
            margin: 14px 0;
            display: flex;
            gap: 8px;
        }
        .controls button {
            background: var(--ocp-green);
            color: white;
            border: none;
            padding: 7px 16px;
            border-radius: 4px;
            cursor: pointer;
            font-family: 'Inter', sans-serif;
            font-size: 12px;
            font-weight: 600;
            letter-spacing: 0.3px;
            transition: background 0.15s;
        }
        .controls button:hover {
            background: var(--ocp-green-hover);
        }

        /* ---- Footer ---- */
        .ocp-footer {
            background: var(--ocp-gray);
            color: var(--text-secondary);
            font-size: 11px;
            padding: 16px 32px;
            text-align: center;
            letter-spacing: 0.3px;
        }
        .ocp-footer a {
            color: var(--ocp-green-light);
            text-decoration: none;
        }
    </style>
</head>
<body>
HTMLEOF

# Inject dynamic header
cat >> "${HTML_FILE}" << EOF
    <div class="ocp-header">
        <div class="ocp-brand">Open Compute Project</div>
        <h1>CMS Benchmark Report &mdash; ${BENCHMARK_NAME}</h1>
    </div>
    <div class="meta-bar">
        <span><strong>Generated:</strong> $(date -u '+%Y-%m-%dT%H:%M:%SZ')</span>
        <span><strong>Hostname:</strong> $(hostname 2>/dev/null || echo 'N/A')</span>
        <span><strong>Report Generator:</strong> v${REPORT_VERSION}</span>
    </div>
    <div class="content">
EOF

# ----- Benchmark Results (CSV) -----
if [ -n "${CSV_CONTENT}" ]; then
    echo "    <h2>Benchmark Results</h2>" >> "${HTML_FILE}"
    echo "    <table>" >> "${HTML_FILE}"
    first_line=true
    while IFS= read -r line; do
        [ -z "${line}" ] && continue
        echo "        <tr>" >> "${HTML_FILE}"
        IFS=',' read -ra cells <<< "${line}"
        for cell in "${cells[@]}"; do
            cell=$(echo "${cell}" | sed 's/^"//;s/"$//')
            cell=$(_html_escape "${cell}")
            if ${first_line}; then
                echo "            <th>${cell}</th>" >> "${HTML_FILE}"
            else
                echo "            <td>${cell}</td>" >> "${HTML_FILE}"
            fi
        done
        echo "        </tr>" >> "${HTML_FILE}"
        first_line=false
    done < "${CSV_FILE}"
    echo "    </table>" >> "${HTML_FILE}"
fi

# ----- System Information -----
if [ -d "${SYSINFO_DIR}" ]; then
    cat >> "${HTML_FILE}" << 'EOF'
    <h2>System Information</h2>
    <div class="controls">
        <button onclick="document.querySelectorAll('details.category').forEach(d=>d.open=true)">Expand All</button>
        <button onclick="document.querySelectorAll('details.category, details.subcategory').forEach(d=>d.open=false)">Collapse All</button>
    </div>
EOF

    # Collection metadata
    _json_meta="${SYSINFO_DIR}/collection_metadata.json"
    _txt_meta="${SYSINFO_DIR}/collection_metadata.txt"
    if ${_HAS_PYTHON} && [ -f "${_json_meta}" ]; then
        _render_json_category "${_json_meta}" "Collection Metadata" "open"
    elif [ -f "${_txt_meta}" ]; then
        _mc=$(_html_escape "$(cat "${_txt_meta}" 2>/dev/null)")
        echo "    <details class=\"category\" open><summary>Collection Metadata</summary><div class=\"category-content\"><pre>${_mc}</pre></div></details>" >> "${HTML_FILE}"
    fi

    # System Summary
    if [ -f "${SYSINFO_DIR}/SUMMARY.txt" ]; then
        _sc=$(_html_escape "$(cat "${SYSINFO_DIR}/SUMMARY.txt" 2>/dev/null)")
        echo "    <details class=\"category\" open><summary>System Summary (Overview)</summary><div class=\"category-content\"><pre>${_sc}</pre></div></details>" >> "${HTML_FILE}"
    fi

    # All 12 categories
    _render_category "bios_firmware"   "1. BIOS / Firmware / Baseboard"
    _render_category "cpu"             "2. CPU"
    _render_category "memory"          "3. Memory (DRAM)"
    _render_category "numa_cxl"        "4. NUMA Topology &amp; CXL Devices"
    _render_category "pci_devices"     "5. PCI Devices"
    _render_category "network"         "6. Network"
    _render_category "storage"         "7. Storage"
    _render_category "kernel_os"       "8. Kernel / OS"
    _render_category "packages"        "9. Packages / Software BOM"
    _render_category "runtime"         "10. Container Runtime"
    _render_category "gpu"             "11. GPU"
    _render_category "power"           "12. Power / Thermal"
fi

# ----- Raw output file listing -----
if ! ${DRY_RUN}; then
    echo "    <h2>Raw Output Files</h2>" >> "${HTML_FILE}"
    echo "    <details class=\"category\"><summary>File Listing</summary><div class=\"category-content\"><pre>" >> "${HTML_FILE}"
    find "${RESULTS_DIR}" -type f | sort | while read -r f; do
        relpath="${f#${RESULTS_DIR}/}"
        size=$(stat -c%s "${f}" 2>/dev/null || echo "?")
        printf "%-60s %10s bytes\n" "${relpath}" "${size}" >> "${HTML_FILE}"
    done
    echo "</pre></div></details>" >> "${HTML_FILE}"
fi

# Close content div and add footer
cat >> "${HTML_FILE}" << 'EOF'
    </div>
    <div class="ocp-footer">
        OCP SRV CMS Benchmark Suite &bull;
        <a href="https://www.opencompute.org" target="_blank">Open Compute Project</a> &bull;
        Report generated by generate_report.sh
    </div>
</body>
</html>
EOF

echo "[REPORT] HTML report: ${HTML_FILE}"

#################################################################################################
# 2. Results Tarball (skip in dry-run)
#################################################################################################

if ! ${DRY_RUN}; then
    echo "[REPORT] Creating results tarball..."
    rm -f "${TARBALL_TMP}" 2>/dev/null
    tar czf "${TARBALL_TMP}" \
        -C "$(dirname "${RESULTS_DIR_ABS}")" \
        "$(basename "${RESULTS_DIR_ABS}")" \
        2>/dev/null || echo "[WARN] Could not create tarball"
    if [ -f "${TARBALL_TMP}" ]; then
        mv "${TARBALL_TMP}" "${TARBALL_FINAL}" 2>/dev/null || true
    fi
    echo "[REPORT] Tarball: ${TARBALL_FINAL}"
fi

#################################################################################################
# Done
#################################################################################################

echo "[REPORT] Report generation complete."
echo "[REPORT]   HTML:    ${HTML_FILE}"
[ -n "${CSV_FILE}" ] && echo "[REPORT]   CSV:     ${CSV_FILE}"
${DRY_RUN} || echo "[REPORT]   Tarball: ${TARBALL_FINAL}"

# In dry-run mode, copy the HTML out of the temp dir to a known location
if ${DRY_RUN}; then
    _dry_out="./${BENCHMARK_NAME}_report.html"
    cp "${HTML_FILE}" "${_dry_out}" 2>/dev/null
    echo "[REPORT] Dry-run output copied to: ${_dry_out}"
    rm -rf "${RESULTS_DIR}"
fi
