#!/usr/bin/env bash
# =============================================================================
# AIPerf LMCache Server Entrypoint
#
# 1. Selects a pre-baked lmcache config from /opt/server/configs/
# 2. Substitutes env vars into it (host, port, etc.)
# 3. Starts vLLM on port 30080, waits for readiness
# =============================================================================
set -e

BACKEND="${LMCACHE_BACKEND:-cpu_offload}"
MODEL="${AIPERF_MODEL:-meta-llama/Llama-3.1-8B-Instruct}"
MAX_LEN="${VLLM_MAX_MODEL_LEN:-4096}"
PORT=30080

echo "============================================="
echo "  AIPerf LMCache Server"
echo "============================================="
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
# 3. HuggingFace auth
# -------------------------------------------------------------------------
export HF_TOKEN="${HF_TOKEN:-}"
export HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}"

# -------------------------------------------------------------------------
# 4. Build vllm serve command
# -------------------------------------------------------------------------
export LMCACHE_USE_EXPERIMENTAL=True

VLLM_ARGS=(serve "${MODEL}" --port "${PORT}" --max-model-len "${MAX_LEN}")
VLLM_ARGS+=(--gpu-memory-utilization "${VLLM_GPU_MEMORY_UTILIZATION:-0.8}")

# LMCache integration
if [ "${BACKEND}" != "none" ] && [ -f "${RUNTIME_CONFIG}" ]; then
    export LMCACHE_CONFIG_FILE="${RUNTIME_CONFIG}"
    VLLM_ARGS+=(--kv-transfer-config '{"kv_connector":"LMCacheConnectorV1", "kv_role":"kv_both"}')
fi

echo "[SERVER] Starting: vllm ${VLLM_ARGS[*]}"

# -------------------------------------------------------------------------
# 5. Launch and wait for readiness
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
