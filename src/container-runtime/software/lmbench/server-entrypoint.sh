#!/usr/bin/env bash
# =============================================================================
# LMCache Server Entrypoint
#
# 1. Selects a pre-baked lmcache config from /opt/server/configs/
# 2. Substitutes env vars into it (host, port, etc.)
# 3. Patches LMCache for CPU platform support (if needed)
# 4. Starts vLLM on port 30080, waits for readiness
# =============================================================================
set -e

DEVICE="${LMBENCH_DEVICE:-cpu}"
BACKEND="${LMCACHE_BACKEND:-cpu_offload}"
MODEL="${LMBENCH_MODEL_URL:-meta-llama/Llama-3.1-8B-Instruct}"
MAX_LEN="${VLLM_MAX_MODEL_LEN:-4096}"
PORT=30080

echo "============================================="
echo "  LMCache Server"
echo "============================================="
echo "  Device:   ${DEVICE}"
echo "  Backend:  ${BACKEND}"
echo "  Model:    ${MODEL}"
echo "  MaxLen:   ${MAX_LEN}"
echo "============================================="

# -------------------------------------------------------------------------
# 1. Resolve LMCache config
# -------------------------------------------------------------------------
CONFIGS_DIR="/opt/server/configs"
RUNTIME_CONFIG="/opt/server/lmcache_config.yaml"

if [ "${BACKEND}" = "none" ]; then
    echo "[SERVER] Backend=none — plain vLLM, no LMCache"
    rm -f "${RUNTIME_CONFIG}"

elif [ "${BACKEND}" = "custom" ]; then
    if [ -n "${LMCACHE_CONFIG_FILE_CONTENT:-}" ]; then
        echo "${LMCACHE_CONFIG_FILE_CONTENT}" | base64 -d > "${RUNTIME_CONFIG}"
        echo "[SERVER] Using custom config from LMCACHE_CONFIG_FILE_CONTENT"
    elif [ -f "/opt/server/custom_config.yaml" ]; then
        cp /opt/server/custom_config.yaml "${RUNTIME_CONFIG}"
        echo "[SERVER] Using mounted custom_config.yaml"
    else
        echo "[SERVER] ERROR: LMCACHE_BACKEND=custom but no config provided"
        exit 1
    fi

else
    TEMPLATE="${CONFIGS_DIR}/${BACKEND}.yaml"
    if [ ! -f "${TEMPLATE}" ]; then
        echo "[SERVER] ERROR: No config for backend '${BACKEND}'"
        echo "[SERVER] Available backends:"
        ls "${CONFIGS_DIR}"/*.yaml 2>/dev/null | xargs -n1 basename | sed 's/.yaml$//'
        exit 1
    fi

    export LMCACHE_REMOTE_HOST="${LMCACHE_REMOTE_HOST:-localhost}"
    export LMCACHE_REMOTE_PORT="${LMCACHE_REMOTE_PORT:-6379}"
    export LMCACHE_MOONCAKE_METADATA_SERVER="${LMCACHE_MOONCAKE_METADATA_SERVER:-http://${LMCACHE_REMOTE_HOST}:8080/metadata}"
    export LMCACHE_MOONCAKE_PROTOCOL="${LMCACHE_MOONCAKE_PROTOCOL:-tcp}"
    export HOSTNAME="${HOSTNAME:-$(hostname)}"
    export LMCACHE_MARU_HOST="${LMCACHE_MARU_HOST:-localhost}"
    export LMCACHE_MARU_PORT="${LMCACHE_MARU_PORT:-5555}"
    export LMCACHE_MARU_POOL_SIZE="${LMCACHE_MARU_POOL_SIZE:-4}"

    envsubst < "${TEMPLATE}" > "${RUNTIME_CONFIG}"
    echo "[SERVER] Backend config: ${BACKEND}"
    cat "${RUNTIME_CONFIG}"
fi

# InfiniStore device append
if [ "${BACKEND}" = "infinistore" ] && [ -n "${LMCACHE_INFINISTORE_DEVICE:-}" ]; then
    sed -i "s|infinistore://\([^\"]*\)\"|infinistore://\1/?device=${LMCACHE_INFINISTORE_DEVICE}\"|" "${RUNTIME_CONFIG}"
fi

# Maru package check
if [ "${BACKEND}" = "maru" ]; then
    if python3 -c "import maru" 2>/dev/null; then
        echo "[SERVER] Maru packages: found"
    else
        echo "[SERVER] WARNING: 'import maru' failed inside container."
        echo "[SERVER] Continuing — vLLM+LMCache will fail if packages are missing."
    fi
fi

# -------------------------------------------------------------------------
# 2. Extra packages
# -------------------------------------------------------------------------
if [ -n "${EXTRA_PIP_PACKAGES:-}" ]; then
    pip install ${EXTRA_PIP_PACKAGES} || true
fi

# -------------------------------------------------------------------------
# 3. CPU mode setup
# -------------------------------------------------------------------------
if [ "${DEVICE}" = "cpu" ]; then
    _tcmalloc=$(find /usr/lib -name "libtcmalloc_minimal*" 2>/dev/null | head -1)
    [ -n "${_tcmalloc}" ] && export LD_PRELOAD="${_tcmalloc}:${LD_PRELOAD:-}"
    _iomp=$(find /opt/server-venv -name "libiomp5.so" 2>/dev/null | head -1)
    [ -n "${_iomp}" ] && export LD_PRELOAD="${_iomp}:${LD_PRELOAD:-}"
    export VLLM_TARGET_DEVICE=cpu
    export VLLM_CPU_KVCACHE_SPACE="${VLLM_CPU_KVCACHE_SPACE:-4}"
    export VLLM_CPU_OMP_THREADS_BIND="${VLLM_CPU_OMP_THREADS_BIND:-auto}"
fi

# -------------------------------------------------------------------------
# 4. Patch LMCache for CPU platform support
# -------------------------------------------------------------------------
# LMCache only knows CUDA/XPU/HPU — no CPU path. We patch two files:
#   a) utils.py: get_vllm_torch_dev() — add CPU device detection
#   b) gpu_connector/__init__.py: CreateGPUConnector() — use MockGPUConnector on CPU
if [ "${DEVICE}" = "cpu" ] && [ "${BACKEND}" != "none" ]; then

    # Patch a) get_vllm_torch_dev — add CPU elif branch
    UTILS_FILE=$(find /opt/server-venv -path "*/lmcache/integration/vllm/utils.py" | head -1)
    if [ -n "${UTILS_FILE}" ]; then
        python3 << 'PATCHEOF'
import os
f = os.popen("find /opt/server-venv -path '*/lmcache/integration/vllm/utils.py'").read().strip()
t = open(f).read()
old = '    else:\n        raise RuntimeError("Unsupported device platform for LMCache engine.")'
new = '    elif current_platform.is_cpu():\n        logger.info("CPU device detected. Using CPU for LMCache engine.")\n        import types\n        cpu_mod = types.ModuleType("torch_cpu_dev")\n        cpu_mod.current_device = lambda: 0\n        cpu_mod.device_count = lambda: 1\n        cpu_mod.set_device = lambda x: None\n        cpu_mod.is_available = lambda: True\n        cpu_mod.mem_get_info = lambda device=None: (0, 0)\n        cpu_mod.synchronize = lambda device=None: None\n        torch_dev = cpu_mod\n        dev_name = "cpu"\n    else:\n        raise RuntimeError("Unsupported device platform for LMCache engine.")'
if old in t:
    open(f, 'w').write(t.replace(old, new))
    print("[SERVER] Patched LMCache utils.py for CPU platform support")
else:
    print("[SERVER] LMCache utils.py patch target not found (already patched or different version)")
PATCHEOF
    fi

    # Patch b) CreateGPUConnector — use MockGPUConnector on CPU
    CONNECTOR_FILE=$(find /opt/server-venv -path "*/lmcache/v1/gpu_connector/__init__.py" | head -1)
    if [ -n "${CONNECTOR_FILE}" ]; then
        python3 << 'CONNPATCH'
import os
f = os.popen("find /opt/server-venv -path '*/lmcache/v1/gpu_connector/__init__.py'").read().strip()
t = open(f).read()
old = '        else:\n            raise RuntimeError("No supported connector found for the current platform.")'
new = '        elif dev_name == "cpu":\n            kv_shape = metadata.kv_shape\n            return MockGPUConnector(kv_shape=kv_shape)\n        else:\n            raise RuntimeError("No supported connector found for the current platform.")'
if old in t:
    open(f, 'w').write(t.replace(old, new))
    print("[SERVER] Patched gpu_connector/__init__.py — using MockGPUConnector for CPU")
else:
    print("[SERVER] GPU connector patch target not found (already patched or different version)")
CONNPATCH
    fi
fi

# -------------------------------------------------------------------------
# 5. HuggingFace auth
# -------------------------------------------------------------------------
export HF_TOKEN="${HF_TOKEN:-}"
export HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}"

# -------------------------------------------------------------------------
# 6. Build vllm serve command
# -------------------------------------------------------------------------
export LMCACHE_USE_EXPERIMENTAL=True

VLLM_ARGS=(serve "${MODEL}" --port "${PORT}" --max-model-len "${MAX_LEN}")

if [ "${DEVICE}" = "cpu" ]; then
    # vllm-cpu does not accept --device cpu flag
    VLLM_ARGS+=(--dtype "${VLLM_CPU_DTYPE:-auto}")
    TP="${VLLM_CPU_TP:-1}"
    [ "${TP}" -gt 1 ] 2>/dev/null && \
        VLLM_ARGS+=(--tensor-parallel-size "${TP}" --distributed-executor-backend mp)
else
    VLLM_ARGS+=(--gpu-memory-utilization "${VLLM_GPU_MEMORY_UTILIZATION:-0.8}")
fi

# LMCache integration
if [ "${BACKEND}" != "none" ] && [ -f "${RUNTIME_CONFIG}" ]; then
    export LMCACHE_CONFIG_FILE="${RUNTIME_CONFIG}"
    VLLM_ARGS+=(--kv-transfer-config '{"kv_connector":"LMCacheConnectorV1", "kv_role":"kv_both"}')
fi

echo "[SERVER] Starting: vllm ${VLLM_ARGS[*]}"

# -------------------------------------------------------------------------
# 7. Launch and wait for readiness
# -------------------------------------------------------------------------
vllm "${VLLM_ARGS[@]}" &
VLLM_PID=$!

TIMEOUT=900
ELAPSED=0
while [ ${ELAPSED} -lt ${TIMEOUT} ]; do
    if curl -s "http://localhost:${PORT}/v1/models" > /dev/null 2>&1; then
        echo "[SERVER] Ready (${ELAPSED}s)"
        break
    fi
    kill -0 ${VLLM_PID} 2>/dev/null || { echo "[SERVER] vLLM died"; exit 1; }
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    [ $((ELAPSED % 30)) -eq 0 ] && echo "[SERVER] Waiting... (${ELAPSED}s)"
done

[ ${ELAPSED} -ge ${TIMEOUT} ] && { echo "[SERVER] Timeout"; kill ${VLLM_PID}; exit 1; }

wait ${VLLM_PID}
