#!/bin/bash
# copaw-worker-entrypoint.sh - CoPaw Worker Agent container startup
# Reads config from environment variables and launches copaw-worker.
#
# Environment variables (set by container_create_worker in container-api.sh):
#   HICLAW_WORKER_NAME  - Worker name (required)
#   HICLAW_FS_ENDPOINT  - MinIO endpoint (required)
#   HICLAW_FS_ACCESS_KEY - MinIO access key (required)
#   HICLAW_FS_SECRET_KEY - MinIO secret key (required)
#   HICLAW_CONSOLE_PORT  - CoPaw web console port (optional, costs ~500MB RAM)
#   TZ                   - Timezone (optional)

set -e

WORKER_NAME="${HICLAW_WORKER_NAME:?HICLAW_WORKER_NAME is required}"
FS_ENDPOINT="${HICLAW_FS_ENDPOINT:?HICLAW_FS_ENDPOINT is required}"
FS_ACCESS_KEY="${HICLAW_FS_ACCESS_KEY:?HICLAW_FS_ACCESS_KEY is required}"
FS_SECRET_KEY="${HICLAW_FS_SECRET_KEY:?HICLAW_FS_SECRET_KEY is required}"

INSTALL_DIR="/root/.copaw-worker"
CONSOLE_PORT="${HICLAW_CONSOLE_PORT:-}"

log() {
    echo "[hiclaw-copaw-worker $(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Set timezone from TZ env var
if [ -n "${TZ}" ] && [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
    log "Timezone set to ${TZ}"
fi

log "Starting CoPaw Worker: ${WORKER_NAME}"
log "  FS endpoint: ${FS_ENDPOINT}"
log "  Install dir: ${INSTALL_DIR}"

CMD=(copaw-worker
    --name "${WORKER_NAME}"
    --fs "${FS_ENDPOINT}"
    --fs-key "${FS_ACCESS_KEY}"
    --fs-secret "${FS_SECRET_KEY}"
    --install-dir "${INSTALL_DIR}"
)

if [ -n "${CONSOLE_PORT}" ]; then
    CMD+=(--console-port "${CONSOLE_PORT}")
    log "  Console port: ${CONSOLE_PORT}"
fi

exec "${CMD[@]}"
