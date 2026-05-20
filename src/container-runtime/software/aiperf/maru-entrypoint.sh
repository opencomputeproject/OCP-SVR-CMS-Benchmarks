#!/usr/bin/env bash
# =============================================================================
# Maru Entrypoint — Resource Manager + Metadata Server
#
# 1. Starts maru-resource-manager (C++ binary, port 9850)
# 2. Waits for resource manager to accept connections
# 3. Starts maru-server (Python metadata server, port 5555)
# 4. Waits for both, exits if either dies
# =============================================================================
set -e

MARU_RM_HOST="${MARU_RM_HOST:-127.0.0.1}"
MARU_RM_PORT="${MARU_RM_PORT:-9850}"
MARU_SERVER_HOST="${MARU_SERVER_HOST:-0.0.0.0}"
MARU_SERVER_PORT="${MARU_SERVER_PORT:-5555}"
MARU_LOG_LEVEL="${MARU_LOG_LEVEL:-INFO}"
MARU_STATE_DIR="${MARU_STATE_DIR:-/var/lib/maru-resourced}"

echo "============================================="
echo "  Maru — CXL Shared Memory KV Cache Engine"
echo "============================================="
echo "  Resource Manager : ${MARU_RM_HOST}:${MARU_RM_PORT}"
echo "  Metadata Server  : ${MARU_SERVER_HOST}:${MARU_SERVER_PORT}"
echo "  Log Level        : ${MARU_LOG_LEVEL}"
echo "  State Dir        : ${MARU_STATE_DIR}"
echo "============================================="

# -- Verify DAX devices exist --------------------------------------------------
DAX_DEVICES=$(ls /dev/dax* 2>/dev/null || true)
if [ -z "${DAX_DEVICES}" ]; then
    echo "[MARU] ERROR: No /dev/dax* devices found in container."
    echo "[MARU] CXL DAX devices must be mapped via docker-compose devices: section."
    echo "[MARU] Example:"
    echo "[MARU]   devices:"
    echo "[MARU]     - /dev/dax0.0:/dev/dax0.0"
    exit 1
fi
echo "[MARU] DAX devices found:"
for dev in ${DAX_DEVICES}; do
    echo "[MARU]   ${dev}"
done

# -- Start maru-resource-manager -----------------------------------------------
echo "[MARU] Starting resource manager..."
mkdir -p "${MARU_STATE_DIR}"

maru-resource-manager \
    --host "${MARU_RM_HOST}" \
    --port "${MARU_RM_PORT}" \
    --state-dir "${MARU_STATE_DIR}" \
    --log-level "$(echo "${MARU_LOG_LEVEL}" | tr '[:upper:]' '[:lower:]')" \
    &
RM_PID=$!

# Wait for resource manager to accept TCP connections
TIMEOUT=60
ELAPSED=0
echo "[MARU] Waiting for resource manager on ${MARU_RM_HOST}:${MARU_RM_PORT}..."
while [ ${ELAPSED} -lt ${TIMEOUT} ]; do
    if bash -c "echo > /dev/tcp/${MARU_RM_HOST}/${MARU_RM_PORT}" 2>/dev/null; then
        echo "[MARU] Resource manager ready (${ELAPSED}s)"
        break
    fi
    kill -0 ${RM_PID} 2>/dev/null || { echo "[MARU] Resource manager died"; exit 1; }
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

if [ ${ELAPSED} -ge ${TIMEOUT} ]; then
    echo "[MARU] ERROR: Resource manager did not start within ${TIMEOUT}s"
    kill ${RM_PID} 2>/dev/null || true
    exit 1
fi

# -- Start maru-server (metadata server) ---------------------------------------
echo "[MARU] Starting metadata server..."

maru-server \
    --host "${MARU_SERVER_HOST}" \
    --port "${MARU_SERVER_PORT}" \
    --rm-address "${MARU_RM_HOST}:${MARU_RM_PORT}" \
    --log-level "${MARU_LOG_LEVEL}" \
    &
SERVER_PID=$!

# Wait for metadata server to accept ZMQ connections
ELAPSED=0
echo "[MARU] Waiting for metadata server on port ${MARU_SERVER_PORT}..."
while [ ${ELAPSED} -lt ${TIMEOUT} ]; do
    # maru-server uses ZMQ (not HTTP), so we just probe the TCP port
    if bash -c "echo > /dev/tcp/${MARU_RM_HOST}/${MARU_SERVER_PORT}" 2>/dev/null; then
        echo "[MARU] Metadata server ready (${ELAPSED}s)"
        break
    fi
    kill -0 ${SERVER_PID} 2>/dev/null || { echo "[MARU] Metadata server died"; exit 1; }
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

if [ ${ELAPSED} -ge ${TIMEOUT} ]; then
    echo "[MARU] ERROR: Metadata server did not start within ${TIMEOUT}s"
    kill ${SERVER_PID} 2>/dev/null || true
    kill ${RM_PID} 2>/dev/null || true
    exit 1
fi

echo "[MARU] ============================================="
echo "[MARU] Maru fully operational"
echo "[MARU]   Resource Manager : pid=${RM_PID}"
echo "[MARU]   Metadata Server  : pid=${SERVER_PID}"
echo "[MARU] ============================================="

# -- Wait for either process to exit -------------------------------------------
# If either dies, kill the other and exit with failure
_cleanup() {
    echo "[MARU] Shutting down..."
    kill ${SERVER_PID} 2>/dev/null || true
    kill ${RM_PID} 2>/dev/null || true
    wait ${SERVER_PID} 2>/dev/null || true
    wait ${RM_PID} 2>/dev/null || true
}

trap _cleanup SIGINT SIGTERM

# Wait for either process — if one exits, the other should too
while true; do
    if ! kill -0 ${RM_PID} 2>/dev/null; then
        echo "[MARU] Resource manager exited"
        kill ${SERVER_PID} 2>/dev/null || true
        wait ${RM_PID}
        exit $?
    fi
    if ! kill -0 ${SERVER_PID} 2>/dev/null; then
        echo "[MARU] Metadata server exited"
        kill ${RM_PID} 2>/dev/null || true
        wait ${SERVER_PID}
        exit $?
    fi
    sleep 5
done
