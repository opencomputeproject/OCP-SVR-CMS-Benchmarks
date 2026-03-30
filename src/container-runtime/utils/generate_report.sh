#!/usr/bin/env bash

#################################################################################################
# OCP SRV CMS - Report Generator (generate_report.sh)
#
# Generates summary output files from benchmark results. Called after a benchmark completes
# to produce the deliverables described in the container-runtime README:
#   - CSV summary
#   - HTML report
#   - Tarball of all raw output
#
# Usage: ./generate_report.sh <results_dir> <benchmark_name> [csv_file]
#
# This script expects:
#   - A sysinfo/ directory (from collect_sysinfo.sh)
#   - Raw benchmark output files in the results directory
#   - An optional CSV results file to embed in the HTML report
#
# The script is intentionally simple. Individual benchmarks may extend it or call
# it as a base and then append benchmark-specific report sections.
#################################################################################################

REPORT_VERSION="0.1.0"

RESULTS_DIR="${1:-.}"
BENCHMARK_NAME="${2:-unknown}"
CSV_FILE="${3:-${RESULTS_DIR}/results.csv}"

# Resolve to absolute path so tar works correctly
RESULTS_DIR_ABS="$(cd "${RESULTS_DIR}" 2>/dev/null && pwd)" || RESULTS_DIR_ABS="${RESULTS_DIR}"

HTML_FILE="${RESULTS_DIR_ABS}/${BENCHMARK_NAME}_report.html"

# Build tarball in the parent directory first, then move it in.
# This avoids "file changed as we read it" when tar archives a directory
# that contains the tarball it's writing to.
TARBALL_NAME="${BENCHMARK_NAME}_results.tar.gz"
TARBALL_TMP="$(dirname "${RESULTS_DIR_ABS}")/${TARBALL_NAME}"
TARBALL_FINAL="${RESULTS_DIR_ABS}/${TARBALL_NAME}"

if [ ! -d "${RESULTS_DIR}" ]; then
    echo "[ERROR] Results directory not found: ${RESULTS_DIR}"
    exit 1
fi

echo "[REPORT] Generating report for: ${BENCHMARK_NAME}"
echo "[REPORT] Results directory: ${RESULTS_DIR}"

#################################################################################################
# 1. HTML Report
#################################################################################################

echo "[REPORT] Generating HTML report..."

# Pull summary data if available
SUMMARY_FILE="${RESULTS_DIR}/sysinfo/SUMMARY.txt"
SUMMARY_CONTENT=""
if [ -f "${SUMMARY_FILE}" ]; then
    SUMMARY_CONTENT=$(cat "${SUMMARY_FILE}" 2>/dev/null)
fi

# Pull CSV data if available
CSV_CONTENT=""
if [ -f "${CSV_FILE}" ]; then
    CSV_CONTENT=$(cat "${CSV_FILE}" 2>/dev/null)
fi

cat > "${HTML_FILE}" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>OCP CMS Benchmark Report</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
            background: #f5f5f5;
            color: #333;
        }
        h1 { color: #1a1a2e; border-bottom: 3px solid #16213e; padding-bottom: 10px; }
        h2 { color: #16213e; margin-top: 30px; }
        .meta { background: #e8e8e8; padding: 15px; border-radius: 5px; margin: 15px 0; }
        pre {
            background: #1a1a2e;
            color: #e0e0e0;
            padding: 15px;
            border-radius: 5px;
            overflow-x: auto;
            font-size: 13px;
            line-height: 1.4;
        }
        table {
            border-collapse: collapse;
            width: 100%;
            margin: 15px 0;
        }
        th, td {
            border: 1px solid #ddd;
            padding: 8px 12px;
            text-align: left;
        }
        th { background: #16213e; color: white; }
        tr:nth-child(even) { background: #f2f2f2; }
        .footer { margin-top: 40px; color: #666; font-size: 12px; border-top: 1px solid #ddd; padding-top: 10px; }
    </style>
</head>
<body>
HTMLEOF

# Inject dynamic content
cat >> "${HTML_FILE}" << EOF
    <h1>OCP SRV CMS - ${BENCHMARK_NAME} Benchmark Report</h1>
    <div class="meta">
        <strong>Generated:</strong> $(date -u '+%Y-%m-%dT%H:%M:%SZ')<br>
        <strong>Hostname:</strong> $(hostname 2>/dev/null)<br>
        <strong>Report Generator:</strong> v${REPORT_VERSION}
    </div>
EOF

# System information section
if [ -n "${SUMMARY_CONTENT}" ]; then
    cat >> "${HTML_FILE}" << EOF
    <h2>System Information</h2>
    <pre>${SUMMARY_CONTENT}</pre>
EOF
fi

# Results section
if [ -n "${CSV_CONTENT}" ]; then
    # Convert CSV to HTML table
    echo "    <h2>Benchmark Results</h2>" >> "${HTML_FILE}"
    echo "    <table>" >> "${HTML_FILE}"
    first_line=true
    while IFS= read -r line; do
        if [ -z "${line}" ]; then continue; fi
        echo "        <tr>" >> "${HTML_FILE}"
        IFS=',' read -ra cells <<< "${line}"
        for cell in "${cells[@]}"; do
            # Strip surrounding quotes
            cell=$(echo "${cell}" | sed 's/^"//;s/"$//')
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

# Raw output section - list files
echo "    <h2>Raw Output Files</h2>" >> "${HTML_FILE}"
echo "    <pre>" >> "${HTML_FILE}"
find "${RESULTS_DIR}" -type f | sort | while read -r f; do
    # Show path relative to results dir
    relpath="${f#${RESULTS_DIR}/}"
    size=$(stat -c%s "${f}" 2>/dev/null || echo "?")
    printf "%-60s %10s bytes\n" "${relpath}" "${size}" >> "${HTML_FILE}"
done
echo "    </pre>" >> "${HTML_FILE}"

# Footer
cat >> "${HTML_FILE}" << 'EOF'
    <div class="footer">
        OCP SRV CMS Benchmark Suite &bull; Report generated by generate_report.sh
    </div>
</body>
</html>
EOF

echo "[REPORT] HTML report: ${HTML_FILE}"

#################################################################################################
# 2. Results Tarball
#################################################################################################

echo "[REPORT] Creating results tarball..."
rm -f "${TARBALL_TMP}" 2>/dev/null
tar czf "${TARBALL_TMP}" \
    -C "$(dirname "${RESULTS_DIR_ABS}")" \
    "$(basename "${RESULTS_DIR_ABS}")" \
    2>/dev/null || echo "[WARN] Could not create tarball"

# Move tarball into the results directory for the user
if [ -f "${TARBALL_TMP}" ]; then
    mv "${TARBALL_TMP}" "${TARBALL_FINAL}" 2>/dev/null || true
fi

echo "[REPORT] Tarball: ${TARBALL_FINAL}"

#################################################################################################
# Done
#################################################################################################

echo "[REPORT] Report generation complete."
echo "[REPORT]   HTML:    ${HTML_FILE}"
echo "[REPORT]   CSV:     ${CSV_FILE}"
echo "[REPORT]   Tarball: ${TARBALL_FINAL}"
