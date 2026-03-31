#!/bin/bash
#################################################################################################
# Patches for libmemcached 1.0.18 to build memaslap on modern compilers (gcc 11+)
#
# Three issues:
#   1. clients/memflush.cc: bool comparison with NULL pointer (compiler error)
#   2. clients/memaslap.c: missing global variable definitions (linker error)
#   3. clients/ms_memslap.h: declarations need 'extern' since definitions move to memaslap.c
#
# Usage: ./patch_libmemcached.sh <path-to-libmemcached-1.0.18>
#################################################################################################

set -e

SRCDIR="${1:?Usage: $0 <path-to-libmemcached-source>}"

if [ ! -d "${SRCDIR}/clients" ]; then
    echo "ERROR: ${SRCDIR}/clients not found. Is this the libmemcached source directory?"
    exit 1
fi

echo "[PATCH] Patching libmemcached at ${SRCDIR}"

#################################################################################################
# Patch 1: clients/memflush.cc - fix NULL pointer checks
#################################################################################################

MEMFLUSH="${SRCDIR}/clients/memflush.cc"
if [ -f "${MEMFLUSH}" ]; then
    echo "[PATCH] Patching memflush.cc..."
    sed -i 's/if (opt_servers == false)/if (!opt_servers)/g' "${MEMFLUSH}"
    # Verify
    if grep -q 'opt_servers == false' "${MEMFLUSH}"; then
        echo "[WARN] memflush.cc patch may not have fully applied"
    else
        echo "[PATCH] memflush.cc patched successfully"
    fi
else
    echo "[WARN] memflush.cc not found, skipping"
fi

#################################################################################################
# Patch 2: clients/memaslap.c - add global variable definitions
#
# These symbols are declared in ms_memslap.h but never defined in any .c file.
# We add the definitions to memaslap.c (the main translation unit).
# We write them near the top, after the includes.
#################################################################################################

MEMASLAP="${SRCDIR}/clients/memaslap.c"
if [ -f "${MEMASLAP}" ]; then
    echo "[PATCH] Patching memaslap.c..."

    # Check if already patched (idempotent)
    if grep -q 'ms_global_t ms_global;' "${MEMASLAP}"; then
        echo "[PATCH] memaslap.c already has global definitions, skipping"
    else
        # Find the right insertion point: after the last #include
        # We'll append the definitions after the line containing '#include "ms_memslap.h"'
        # If that specific include isn't found, append after the last #include line
        if grep -q '#include "ms_memslap.h"' "${MEMASLAP}"; then
            ANCHOR='#include "ms_memslap.h"'
        else
            # Fallback: find the last #include line number and insert after it
            ANCHOR=$(grep -n '^#include' "${MEMASLAP}" | tail -1 | cut -d: -f1)
            if [ -z "${ANCHOR}" ]; then
                echo "[ERROR] Cannot find any #include in memaslap.c"
                exit 1
            fi
            # Use line number based insertion
            sed -i "${ANCHOR}a\\
\\
/* Patched: global variable definitions for memaslap */\\
ms_global_t ms_global;\\
ms_stats_t ms_stats;\\
ms_statistic_t ms_statistic;" "${MEMASLAP}"

            # Verify and skip the anchor-based path below
            if grep -q 'ms_global_t ms_global;' "${MEMASLAP}"; then
                echo "[PATCH] memaslap.c patched successfully (line-number method)"
            else
                echo "[ERROR] memaslap.c patch failed"
                exit 1
            fi
            ANCHOR=""  # skip the sed below
        fi

        if [ -n "${ANCHOR}" ]; then
            # Use a temp file approach instead of sed -i with multi-line insert
            # This is more reliable across sed versions
            awk -v anchor="${ANCHOR}" '
            {
                print
                if (index($0, anchor) > 0 && !done) {
                    print ""
                    print "/* Patched: global variable definitions for memaslap */"
                    print "ms_global_t ms_global;"
                    print "ms_stats_t ms_stats;"
                    print "ms_statistic_t ms_statistic;"
                    done = 1
                }
            }' "${MEMASLAP}" > "${MEMASLAP}.patched"
            mv "${MEMASLAP}.patched" "${MEMASLAP}"
        fi

        # Verify
        if grep -q 'ms_global_t ms_global;' "${MEMASLAP}"; then
            echo "[PATCH] memaslap.c patched successfully"
        else
            echo "[ERROR] memaslap.c patch failed - global definitions not found after patching"
            exit 1
        fi
    fi
else
    echo "[ERROR] memaslap.c not found at ${MEMASLAP}"
    exit 1
fi

#################################################################################################
# Patch 3: clients/ms_memslap.h - add 'extern' to global variable declarations
#
# The header declares these variables. Since we now define them in memaslap.c,
# the header declarations must be 'extern' to avoid duplicate symbol errors.
# We need to handle both cases:
#   - The declarations exist without 'extern' (add it)
#   - The declarations already have 'extern' (leave them alone)
#   - The declarations don't exist (add them with extern)
#################################################################################################

MEMSLAP_H="${SRCDIR}/clients/ms_memslap.h"
if [ -f "${MEMSLAP_H}" ]; then
    echo "[PATCH] Patching ms_memslap.h..."

    for vartype_var in "ms_global_t ms_global" "ms_stats_t ms_stats" "ms_statistic_t ms_statistic"; do
        vartype=$(echo "${vartype_var}" | cut -d' ' -f1)
        varname=$(echo "${vartype_var}" | cut -d' ' -f2)

        if grep -q "extern ${vartype} ${varname};" "${MEMSLAP_H}"; then
            echo "[PATCH]   ${varname}: already extern, skipping"
        elif grep -q "${vartype} ${varname};" "${MEMSLAP_H}"; then
            # Add extern to the existing declaration (handle possible leading whitespace)
            sed -i "s/\(^[[:space:]]*\)${vartype} ${varname};/\1extern ${vartype} ${varname};/" "${MEMSLAP_H}"
            echo "[PATCH]   ${varname}: added extern"
        else
            echo "[WARN]   ${varname}: declaration not found in ms_memslap.h, skipping"
        fi
    done

    echo "[PATCH] ms_memslap.h patched successfully"
else
    echo "[ERROR] ms_memslap.h not found at ${MEMSLAP_H}"
    exit 1
fi

echo "[PATCH] All patches applied successfully"
