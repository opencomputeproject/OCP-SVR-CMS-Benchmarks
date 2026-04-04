#!/usr/bin/env bash
# =============================================================================
# setup_env.sh - Generate heimdall configuration files from environment vars
#
# Heimdall expects two .env files:
#   1. self.env              - user credentials (sudo password, Slack, etc.)
#   2. $(hostname).env       - machine hardware configuration
#
# In a container running as root, these are synthesized from the
# environment variables passed in via docker-compose.
#
# NOTE: No `set -euo pipefail` — env vars may legitimately be empty.
# =============================================================================

# Use CMS logging if available, else plain echo
if type cms_log_info &>/dev/null; then
    _log() { cms_log_info "$*"; }
else
    _log() { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
fi

ENV_DIR="/opt/heimdall/benchmark/basic_performance/env_files"
HOSTNAME=$(hostname)
export HEIMDALL_HOSTNAME="${HOSTNAME}"

_log "Generating heimdall environment files (hostname: ${HOSTNAME})"

# -------------------------------------------------------------------------
# 1. self.env  (credentials / notifications)
# -------------------------------------------------------------------------
cat > "${ENV_DIR}/self.env" <<EOF
Slack=0
SlackURL=
HOSTNAME=${HOSTNAME}
USER_PASSWORD=rootpassword
EOF
_log "Created: ${ENV_DIR}/self.env"

# -------------------------------------------------------------------------
# 2. $(hostname).env  (machine hardware config)
# -------------------------------------------------------------------------
DISABLE_PREFETCH="${DISABLE_PREFETCH:-True}"
BOOST_CPU="${BOOST_CPU:-True}"
SOCKET_NUMBER="${SOCKET_NUMBER:-2}"
SNC_MODE="${SNC_MODE:-1}"
DIMM_PHYSICAL_START_ADDR="${DIMM_PHYSICAL_START_ADDR:-0x800000000}"
CXL_PHYSICAL_START_ADDR="${CXL_PHYSICAL_START_ADDR:-0x4080000000}"
TEST_SIZE="${TEST_SIZE:-0x840000000}"

cat > "${ENV_DIR}/${HOSTNAME}.env" <<EOF
disable_prefetch=${DISABLE_PREFETCH}
boost_cpu=${BOOST_CPU}
socket_number=${SOCKET_NUMBER}
snc_mode=${SNC_MODE}

# for cache analysis
dimm_physical_start_addr=${DIMM_PHYSICAL_START_ADDR}
cxl_physical_start_addr=${CXL_PHYSICAL_START_ADDR}
test_size=${TEST_SIZE}
EOF
_log "Created: ${ENV_DIR}/${HOSTNAME}.env"

# -------------------------------------------------------------------------
# 3. Generate custom batch YAML for basic_performance (if params provided)
# -------------------------------------------------------------------------
BATCH_DIR="/opt/heimdall/benchmark/basic_performance/scripts/batch"

# Only generate a custom BW-vs-latency YAML if the user set BW_ params
if [ -n "${BW_THREAD_NUM_TYPE:-}" ]; then
    _log "Generating custom bw_vs_latency YAML from env vars"

    BW_THREAD_NUM_ARRAY="${BW_THREAD_NUM_ARRAY:-1,2,4,8,16}"
    THREAD_ARRAY_YAML=$(echo "${BW_THREAD_NUM_ARRAY}" | sed 's/,/, /g')

    BW_PATTERN_ITERATION="${BW_PATTERN_ITERATION:-2}"
    PAT_ITER_YAML=$(echo "${BW_PATTERN_ITERATION}" | sed 's/,/, /g')

    BW_BUFFER_SIZE_MB="${BW_BUFFER_SIZE_MB:-512}"
    BUF_YAML=$(echo "${BW_BUFFER_SIZE_MB}" | sed 's/,/, /g')

    BW_CORE_SOCKET_ARRAY="${BW_CORE_SOCKET_ARRAY:-0,1}"
    SOCKET_YAML=$(echo "${BW_CORE_SOCKET_ARRAY}" | sed 's/,/, /g')

    BW_NUMA_NODE_ARRAY="${BW_NUMA_NODE_ARRAY:-0,1}"
    NUMA_YAML=$(echo "${BW_NUMA_NODE_ARRAY}" | sed 's/,/, /g')

    BW_DELAY_ARRAY="${BW_DELAY_ARRAY:-0}"
    BW_LATENCY_STRIDE="${BW_LATENCY_STRIDE:-64}"
    BW_LATENCY_BLOCK="${BW_LATENCY_BLOCK:-64}"
    BW_LATENCY_ACCESS="${BW_LATENCY_ACCESS:-1048576}"
    BW_LOAD_BLOCK="${BW_LOAD_BLOCK:-256}"
    BW_STORE_BLOCK="${BW_STORE_BLOCK:-256}"

    BW_LOADSTORE_ARRAY="${BW_LOADSTORE_ARRAY:-0,1}"
    BW_MEM_ALLOC_ARRAY="${BW_MEM_ALLOC_ARRAY:-1}"
    BW_LATENCY_PATTERN="${BW_LATENCY_PATTERN:-1}"
    BW_BANDWIDTH_PATTERN="${BW_BANDWIDTH_PATTERN:-1}"

    cat > "${BATCH_DIR}/100_bw_vs_latency.yaml" <<YAMLEOF
job_id: 100

thread_num_type: ${BW_THREAD_NUM_TYPE}

thread_num_array: [${THREAD_ARRAY_YAML}]

pattern_iteration_array: [${PAT_ITER_YAML}]

thread_buffer_size array_megabyte: [${BUF_YAML}]

core_socket_array: [${SOCKET_YAML}]

numa_node_array: [${NUMA_YAML}]

delay_array:
$(echo "${BW_DELAY_ARRAY}" | tr ',' '\n' | sed 's/^/  - /')

loadstore_array:
$(echo "${BW_LOADSTORE_ARRAY}" | tr ',' '\n' | sed 's/^/  - /')

mem_alloc_type_array:
$(echo "${BW_MEM_ALLOC_ARRAY}" | tr ',' '\n' | sed 's/^/  - /')

latency_pattern_array:
$(echo "${BW_LATENCY_PATTERN}" | tr ',' '\n' | sed 's/^/  - /')

latency_pattern_stride_size_array_byte:
  - ${BW_LATENCY_STRIDE}

latency_pattern_block_size_array_byte:
  - ${BW_LATENCY_BLOCK}

latency_pattern_access_size_array_byte:
  - ${BW_LATENCY_ACCESS}

bandwidth_pattern_array:
$(echo "${BW_BANDWIDTH_PATTERN}" | tr ',' '\n' | sed 's/^/  - /')

bandwidth_load_pattern_block_size: [${BW_LOAD_BLOCK}]

bandwidth_store_pattern_block_size: [${BW_STORE_BLOCK}]
YAMLEOF

    _log "Created: ${BATCH_DIR}/100_bw_vs_latency.yaml"
fi

# Generate custom cache heatmap YAML if user set CACHE_ params
if [ -n "${CACHE_REPEAT:-}" ]; then
    _log "Generating custom cache_heatmap YAML from env vars"

    CACHE_TEST_TYPE="${CACHE_TEST_TYPE:-0}"
    CACHE_USE_FLUSH="${CACHE_USE_FLUSH:-0}"
    CACHE_FLUSH_TYPE="${CACHE_FLUSH_TYPE:-0}"
    CACHE_LDST_TYPE="${CACHE_LDST_TYPE:-0}"
    CACHE_CORE_ID="${CACHE_CORE_ID:-0,20}"
    CACHE_NODE_ID="${CACHE_NODE_ID:-2}"
    CACHE_ACCESS_ORDER="${CACHE_ACCESS_ORDER:-0}"
    CACHE_STRIDE_SIZES="${CACHE_STRIDE_SIZES:-0x40,0x80,0x100,0x200,0x400,0x800,0x1000,0x2000,0x4000,0x8000,0x10000,0x20000,0x40000,0x80000,0x100000,0x200000,0x400000,0x800000,0x1000000,0x2000000,0x4000000}"
    CACHE_BLOCK_NUMS="${CACHE_BLOCK_NUMS:-0x1,0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800,0x1000,0x2000,0x4000,0x8000,0x10000,0x20000,0x40000,0x80000,0x100000}"

    cat > "${BATCH_DIR}/200_cache_heatmap.yaml" <<YAMLEOF
job_id: 200
repeat: ${CACHE_REPEAT}
test_type: ${CACHE_TEST_TYPE}
use_flush: ${CACHE_USE_FLUSH}
flush_type: [$(echo "${CACHE_FLUSH_TYPE}" | sed 's/,/, /g')]
ldst_type: [$(echo "${CACHE_LDST_TYPE}" | sed 's/,/, /g')]
core_id: [$(echo "${CACHE_CORE_ID}" | sed 's/,/, /g')]
node_id: [$(echo "${CACHE_NODE_ID}" | sed 's/,/, /g')]
access_order: [$(echo "${CACHE_ACCESS_ORDER}" | sed 's/,/, /g')]
stride_size_array: [$(echo "${CACHE_STRIDE_SIZES}" | sed 's/,/, /g')]
block_num_array: [$(echo "${CACHE_BLOCK_NUMS}" | sed 's/,/, /g')]
YAMLEOF

    _log "Created: ${BATCH_DIR}/200_cache_heatmap.yaml"
fi

# -------------------------------------------------------------------------
# 4. Detect AVX-512 and patch heimdall if not available
#
# Heimdall's x86 LdStPattern uses inline asm with ZMM registers
# (vmovntdqa/vmovntdq) which cause SIGILL on non-AVX512 CPUs.
# The PointerChaseLdStPattern class uses only basic mov/clflush/mfence
# and works fine everywhere.
#
# If AVX-512 is not available, we:
#   a) Patch CMakeLists.txt to remove -mavx512f
#   b) Replace the ZMM bandwidth functions with portable memcpy equivalents
#      while preserving PointerChaseLdStPattern untouched
# -------------------------------------------------------------------------

_HOST_ARCH=$(uname -m 2>/dev/null || echo "unknown")

if [ "${_HOST_ARCH}" = "x86_64" ] || [ "${_HOST_ARCH}" = "amd64" ]; then

_AVX512_COUNT="0"
if grep -qi avx512 /proc/cpuinfo 2>/dev/null; then
    _AVX512_COUNT="1"
fi

if [ "${_AVX512_COUNT}" -eq 0 ]; then
    _log "CPU does NOT support AVX-512 — patching heimdall for portable x86 build"

    # (a) Patch CMakeLists.txt: remove -mavx512f, use -march=native
    CMAKEFILE="/opt/heimdall/benchmark/basic_performance/build/bw_latency_test/CMakeLists.txt"
    if [ -f "${CMAKEFILE}" ]; then
        sed -i 's/set(CMAKE_CXX_FLAGS_RELEASE "-mavx512f")/set(CMAKE_CXX_FLAGS_RELEASE "-march=native")/' "${CMAKEFILE}"
        _log "Patched CMakeLists.txt: -mavx512f -> -march=native"
    fi

    # (b) Replace ldst_pattern_x86.h bandwidth functions with portable memcpy
    #     Keep PointerChaseLdStPattern (uses mov/clflush/mfence, no AVX-512)
    X86_LDST="/opt/heimdall/benchmark/basic_performance/src/machine/x86/ld_st/ldst_pattern_x86.h"
    if [ -f "${X86_LDST}" ]; then
        cp "${X86_LDST}" "${X86_LDST}.avx512.bak"
        cat > "${X86_LDST}" << 'PATCHEOF'
/*
 * AUTO-PATCHED by OCP CMS container setup_env.sh
 * Original AVX-512 (ZMM register) implementations replaced with portable
 * memcpy equivalents because this CPU does not support AVX-512.
 * PointerChaseLdStPattern is preserved unchanged (uses basic x86 only).
 *
 * Original file backed up as ldst_pattern_x86.h.avx512.bak
 */

#ifndef CXL_PERF_APP_ACCESS_PATTERN_X86_H
#define CXL_PERF_APP_ACCESS_PATTERN_X86_H
#include <core/system_define.h>
#include <cstring>
#include <functional>
#include <machine/x86/ld_st/mem_utils_x86.h>
#include <unordered_map>
#include <utils/timer.h>
using LdStPatternFunc = std::function<void(uint8_t *addr, uint64_t size)>;

class LdStPattern {
public:
  LdStPattern() {
    _ld_func_map[BwPatternSize::SIZE_64B] = load_64B;
    _ld_func_map[BwPatternSize::SIZE_128B] = load_128B;
    _ld_func_map[BwPatternSize::SIZE_256B] = load_256B;
    _ld_func_map[BwPatternSize::SIZE_512B] = load_512B;
    _st_func_map[BwPatternSize::SIZE_64B] = store_64B;
    _st_func_map[BwPatternSize::SIZE_128B] = store_128B;
    _st_func_map[BwPatternSize::SIZE_256B] = store_256B;
    _st_func_map[BwPatternSize::SIZE_512B] = store_512B;
  }
  ~LdStPattern() = default;

  LdStPatternFunc get_load_func(BwPatternSize type) {
    auto it = _ld_func_map.find(type);
    if (it == _ld_func_map.end()) {
      std::cerr << "Can not find the function for the given type" << std::endl;
    }
    return it->second;
  }

  LdStPatternFunc get_store_func(BwPatternSize type) {
    auto it = _st_func_map.find(type);
    if (it == _st_func_map.end()) {
      std::cerr << "Can not find the function for the given type" << std::endl;
    }
    return it->second;
  }

  /* --- Portable load functions (memcpy-based, replacing AVX-512 ZMM asm) --- */

  static inline void load_64B(uint8_t *addr, uint64_t size) {
    long size_cnt = 0;
    volatile char buffer[64];
    while (size_cnt < (long)size) {
      std::memcpy((void *)buffer, (void *)(addr + size_cnt), sizeof(buffer));
      size_cnt += sizeof(buffer);
    }
  }

  static inline void load_128B(uint8_t *addr, uint64_t size) {
    long size_cnt = 0;
    volatile char buffer[128];
    while (size_cnt < (long)size) {
      std::memcpy((void *)buffer, (void *)(addr + size_cnt), sizeof(buffer));
      size_cnt += sizeof(buffer);
    }
  }

  static inline void load_256B(uint8_t *addr, uint64_t size) {
    long size_cnt = 0;
    volatile char buffer[256];
    while (size_cnt < (long)size) {
      std::memcpy((void *)buffer, (void *)(addr + size_cnt), sizeof(buffer));
      size_cnt += sizeof(buffer);
    }
  }

  static inline void load_512B(uint8_t *addr, uint64_t size) {
    long size_cnt = 0;
    volatile char buffer[512];
    while (size_cnt < (long)size) {
      std::memcpy((void *)buffer, (void *)(addr + size_cnt), sizeof(buffer));
      size_cnt += sizeof(buffer);
    }
  }

  static inline void load_with_flush(uint8_t *addr, uint64_t size,
                                     uint64_t *time_log, Timer &timer) {
    long size_cnt = 0;
    volatile char buffer[64];
    while (size_cnt < (long)size) {
      timer.start();
      std::memcpy((void *)buffer, (void *)(addr + size_cnt), sizeof(buffer));
      *time_log += timer.elapsed();
      std::memset((void *)(addr + size_cnt), 0, sizeof(buffer));
      size_cnt += sizeof(buffer);
    }
  }

  /* --- Portable store functions (memcpy-based, replacing AVX-512 ZMM asm) --- */

  static inline void store_64B(uint8_t *addr, uint64_t size) {
    long size_cnt = 0;
    volatile char buffer[64] = {0};
    while (size_cnt < (long)size) {
      std::memcpy((void *)(addr + size_cnt), (void *)buffer, sizeof(buffer));
      size_cnt += sizeof(buffer);
    }
  }

  static inline void store_128B(uint8_t *addr, uint64_t size) {
    long size_cnt = 0;
    volatile char buffer[128] = {0};
    while (size_cnt < (long)size) {
      std::memcpy((void *)(addr + size_cnt), (void *)buffer, sizeof(buffer));
      size_cnt += sizeof(buffer);
    }
  }

  static inline void store_256B(uint8_t *addr, uint64_t size) {
    long size_cnt = 0;
    volatile char buffer[256] = {0};
    while (size_cnt < (long)size) {
      std::memcpy((void *)(addr + size_cnt), (void *)buffer, sizeof(buffer));
      size_cnt += sizeof(buffer);
    }
  }

  static inline void store_512B(uint8_t *addr, uint64_t size) {
    long size_cnt = 0;
    volatile char buffer[512] = {0};
    while (size_cnt < (long)size) {
      std::memcpy((void *)(addr + size_cnt), (void *)buffer, sizeof(buffer));
      size_cnt += sizeof(buffer);
    }
  }

  static inline void store_with_flush(uint8_t *addr, uint64_t size,
                                      uint64_t *time_log, Timer &timer) {
    long size_cnt = 0;
    volatile char buffer[64] = {0};
    while (size_cnt < (long)size) {
      timer.start();
      std::memcpy((void *)(addr + size_cnt), (void *)buffer, sizeof(buffer));
      *time_log += timer.elapsed();
      std::memset((void *)(addr + size_cnt), 0, sizeof(buffer));
      size_cnt += sizeof(buffer);
    }
  }

private:
  std::unordered_map<BwPatternSize, LdStPatternFunc> _ld_func_map;
  std::unordered_map<BwPatternSize, LdStPatternFunc> _st_func_map;
};

/*
 * PointerChaseLdStPattern — UNCHANGED from original.
 * Uses only basic x86 instructions (mov, clflush, mfence) — no AVX-512.
 */
class PointerChaseLdStPattern {
public:
  PointerChaseLdStPattern() = default;
  ~PointerChaseLdStPattern() = default;
#pragma GCC push_options
#pragma GCC optimize("O0")
  static inline void load_64B(uint64_t *base_addr, uint64_t region_size,
                              uint64_t stride_size, uint64_t block_size,
                              uint64_t *time_log, Timer &timer) {
    uint64_t scanned_size = 0;
    uint64_t curr_pos = 0;
    uint64_t next_pos = 0;
    *time_log = 0;
    MemUtils util;
    while (scanned_size < region_size) {
      uint64_t *curr_addr =
          base_addr + curr_pos * stride_size / sizeof(uint64_t);
      asm volatile("clflush 0(%0)" ::"r"(curr_addr) : "memory");
      asm volatile("mfence" ::: "memory");
      timer.start();
      asm volatile("mov (%1), %0\n\t"
                   : "=r"(next_pos)
                   : "r"(curr_addr)
                   : "memory");
      asm volatile("mfence" ::: "memory");
      *time_log += timer.elapsed();
      curr_pos = next_pos;
      scanned_size += block_size;
    }
  }
#pragma GCC pop_options

#pragma GCC push_options
#pragma GCC optimize("O0")
  static inline void store_64B(uint64_t *base_addr, uint64_t region_size,
                               uint64_t stride_size, uint64_t block_size,
                               uint64_t *cindex, uint64_t *time_log,
                               Timer &timer) {
    uint64_t scanned_size = 0;
    uint64_t curr_pos = 0;
    uint64_t next_pos = 0;
    *time_log = 0;
    MemUtils util;
    while (scanned_size < region_size) {
      uint64_t *curr_addr =
          base_addr + curr_pos * stride_size / sizeof(uint64_t);
      asm volatile("clflush 0(%0)" ::"r"(curr_addr) : "memory");
      asm volatile("mfence" ::: "memory");
      next_pos = cindex[curr_pos];
      timer.start();
      asm volatile("mov %1, (%0)\n\t"
                   :
                   : "r"(curr_addr), "r"(next_pos)
                   : "memory");
      asm volatile("mfence" ::: "memory");
      *time_log += timer.elapsed();
      asm volatile("clflush 0(%0)" ::"r"(curr_addr) : "memory");
      asm volatile("mfence" ::: "memory");
      curr_pos = next_pos;
      scanned_size += block_size;
    }
  }
#pragma GCC pop_options
};

#endif // CXL_PERF_APP_ACCESS_PATTERN_X86_H
PATCHEOF
        _log "Patched ldst_pattern_x86.h: replaced AVX-512 asm with portable memcpy"
    fi
else
    _log "CPU supports AVX-512 — using native ZMM instructions"
fi

else
    _log "Non-x86 architecture (${_HOST_ARCH}) — AVX-512 patch not applicable"
fi

_log "Environment setup complete"
