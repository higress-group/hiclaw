#!/bin/bash
# hiclaw-install.sh - One-click installation for HiClaw Manager and Worker
#
# Usage:
#   ./hiclaw-install.sh manager                  # Interactive Manager setup
#   ./hiclaw-install.sh worker --name <name> ...  # Worker installation
#
# All interactive prompts can be pre-set via environment variables.
# Minimal install (only LLM key required):
#   HICLAW_LLM_API_KEY=sk-xxx ./hiclaw-install.sh manager
#
# Non-interactive mode (all defaults, no prompts):
#   HICLAW_NON_INTERACTIVE=1 HICLAW_LLM_API_KEY=sk-xxx ./hiclaw-install.sh manager
#
# Environment variables:
#   HICLAW_NON_INTERACTIVE    Skip all prompts, use defaults  (default: 0)
#   HICLAW_LLM_PROVIDER      LLM provider       (default: qwen)
#   HICLAW_DEFAULT_MODEL      Default model       (default: qwen3.5-plus)
#   HICLAW_LLM_API_KEY        LLM API key         (required)
#   HICLAW_ADMIN_USER         Admin username       (default: admin)
#   HICLAW_ADMIN_PASSWORD     Admin password       (auto-generated if not set)
#   HICLAW_MATRIX_DOMAIN      Matrix domain        (default: matrix-local.hiclaw.io:8080)
#   HICLAW_MOUNT_SOCKET       Mount container runtime socket (default: 1)
#   HICLAW_DATA_DIR           Host directory for persistent data (default: docker volume)
#   HICLAW_VERSION            Image tag            (default: latest)
#   HICLAW_PORT_GATEWAY       Host port for Higress gateway (default: 8080)
#   HICLAW_PORT_CONSOLE       Host port for Higress console (default: 8001)

set -e

HICLAW_VERSION="${HICLAW_VERSION:-latest}"
HICLAW_NON_INTERACTIVE="${HICLAW_NON_INTERACTIVE:-0}"
MANAGER_IMAGE="hiclaw/manager-agent:${HICLAW_VERSION}"
WORKER_IMAGE="hiclaw/worker-agent:${HICLAW_VERSION}"
HICLAW_MOUNT_SOCKET="${HICLAW_MOUNT_SOCKET:-1}"

# ============================================================
# Utility functions
# ============================================================

log() {
    echo -e "\033[36m[HiClaw]\033[0m $1"
}

error() {
    echo -e "\033[31m[HiClaw ERROR]\033[0m $1" >&2
    exit 1
}

# Prompt for a value interactively, but skip if env var is already set.
# In non-interactive mode, uses default or errors if required and no default.
# Usage: prompt VAR_NAME "Prompt text" "default" [true=secret]
prompt() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local is_secret="${4:-false}"

    # If the variable is already set in the environment, use it silently
    local current_value="${!var_name}"
    if [ -n "${current_value}" ]; then
        log "  ${var_name} = (pre-set via env)"
        return
    fi

    # Non-interactive: use default or error
    if [ "${HICLAW_NON_INTERACTIVE}" = "1" ]; then
        if [ -n "${default_value}" ]; then
            eval "export ${var_name}='${default_value}'"
            log "  ${var_name} = ${default_value} (default)"
            return
        else
            error "${var_name} is required (set via environment variable in non-interactive mode)"
        fi
    fi

    if [ -n "${default_value}" ]; then
        prompt_text="${prompt_text} [${default_value}]"
    fi

    if [ "${is_secret}" = "true" ]; then
        read -s -p "${prompt_text}: " value
        echo
    else
        read -p "${prompt_text}: " value
    fi

    value="${value:-${default_value}}"
    if [ -z "${value}" ]; then
        error "${var_name} is required"
    fi

    eval "export ${var_name}='${value}'"
}

# Prompt for an optional value (empty string is acceptable)
# Skips prompt if variable is already defined in environment (even if empty)
# In non-interactive mode, defaults to empty string.
prompt_optional() {
    local var_name="$1"
    local prompt_text="$2"
    local is_secret="${3:-false}"

    # Check if variable is defined (even if set to empty string)
    if [ -n "${!var_name+x}" ]; then
        log "  ${var_name} = (pre-set via env)"
        return
    fi

    # Non-interactive: skip, leave unset
    if [ "${HICLAW_NON_INTERACTIVE}" = "1" ]; then
        eval "export ${var_name}=''"
        return
    fi

    if [ "${is_secret}" = "true" ]; then
        read -s -p "${prompt_text}: " value
        echo
    else
        read -p "${prompt_text}: " value
    fi

    eval "export ${var_name}='${value}'"
}

generate_key() {
    openssl rand -hex 32
}

# Detect container runtime socket on the host
detect_socket() {
    if [ -S "/run/podman/podman.sock" ]; then
        echo "/run/podman/podman.sock"
    elif [ -S "/var/run/docker.sock" ]; then
        echo "/var/run/docker.sock"
    fi
}

# ============================================================
# Manager Installation (Interactive)
# ============================================================

install_manager() {
    log "=== HiClaw Manager Installation ==="
    log ""

    # LLM Configuration
    log "--- LLM Configuration ---"
    prompt HICLAW_LLM_PROVIDER "LLM Provider (e.g., qwen, openai)" "qwen"
    prompt HICLAW_DEFAULT_MODEL "Default Model ID" "qwen3.5-plus"
    prompt HICLAW_LLM_API_KEY "LLM API Key" "" "true"

    log ""

    # Admin Credentials (password auto-generated if not provided)
    log "--- Admin Credentials ---"
    prompt HICLAW_ADMIN_USER "Admin Username" "admin"
    if [ -z "${HICLAW_ADMIN_PASSWORD}" ]; then
        prompt_optional HICLAW_ADMIN_PASSWORD "Admin Password (leave empty to auto-generate)" "true"
        if [ -z "${HICLAW_ADMIN_PASSWORD}" ]; then
            HICLAW_ADMIN_PASSWORD="admin$(openssl rand -hex 6)"
            log "  Auto-generated admin password"
        fi
    else
        log "  HICLAW_ADMIN_PASSWORD = (pre-set via env)"
    fi

    log ""

    # Port Configuration (must come before Domain so MATRIX_DOMAIN default uses the correct port)
    log "--- Port Configuration (press Enter for defaults) ---"
    prompt HICLAW_PORT_GATEWAY "Host port for gateway (8080 inside container)" "8080"
    prompt HICLAW_PORT_CONSOLE "Host port for Higress console (8001 inside container)" "8001"

    log ""

    # Domain Configuration
    log "--- Domain Configuration (press Enter for defaults) ---"
    prompt HICLAW_MATRIX_DOMAIN "Matrix Domain" "matrix-local.hiclaw.io:${HICLAW_PORT_GATEWAY}"
    prompt HICLAW_MATRIX_CLIENT_DOMAIN "Element Web Domain" "matrix-client-local.hiclaw.io"
    prompt HICLAW_AI_GATEWAY_DOMAIN "AI Gateway Domain" "llm-local.hiclaw.io"
    prompt HICLAW_FS_DOMAIN "File System Domain" "fs-local.hiclaw.io"

    log ""

    # Optional: GitHub PAT
    log "--- GitHub Integration (optional, press Enter to skip) ---"
    prompt_optional HICLAW_GITHUB_TOKEN "GitHub Personal Access Token (optional)" "true"

    log ""

    # Data persistence
    log "--- Data Persistence ---"
    if [ "${HICLAW_NON_INTERACTIVE}" != "1" ] && [ -z "${HICLAW_DATA_DIR+x}" ]; then
        read -p "External data directory (leave empty for Docker volume): " HICLAW_DATA_DIR
        export HICLAW_DATA_DIR
    fi
    if [ -n "${HICLAW_DATA_DIR}" ]; then
        HICLAW_DATA_DIR="$(cd "${HICLAW_DATA_DIR}" 2>/dev/null && pwd || echo "${HICLAW_DATA_DIR}")"
        mkdir -p "${HICLAW_DATA_DIR}"
        log "  Data directory: ${HICLAW_DATA_DIR}"
    else
        log "  Using Docker volume: hiclaw-data"
    fi

    log ""

    # Generate secrets (only if not already set)
    log "Generating secrets..."
    HICLAW_MANAGER_PASSWORD="${HICLAW_MANAGER_PASSWORD:-$(generate_key)}"
    HICLAW_REGISTRATION_TOKEN="${HICLAW_REGISTRATION_TOKEN:-$(generate_key)}"
    HICLAW_MINIO_USER="${HICLAW_MINIO_USER:-${HICLAW_ADMIN_USER}}"
    HICLAW_MINIO_PASSWORD="${HICLAW_MINIO_PASSWORD:-${HICLAW_ADMIN_PASSWORD}}"
    HICLAW_MANAGER_GATEWAY_KEY="${HICLAW_MANAGER_GATEWAY_KEY:-$(generate_key)}"

    # Write .env file
    ENV_FILE="${HICLAW_ENV_FILE:-./hiclaw-manager.env}"
    cat > "${ENV_FILE}" << EOF
# HiClaw Manager Configuration
# Generated by hiclaw-install.sh on $(date)

# LLM
HICLAW_LLM_PROVIDER=${HICLAW_LLM_PROVIDER}
HICLAW_DEFAULT_MODEL=${HICLAW_DEFAULT_MODEL}
HICLAW_LLM_API_KEY=${HICLAW_LLM_API_KEY}

# Admin
HICLAW_ADMIN_USER=${HICLAW_ADMIN_USER}
HICLAW_ADMIN_PASSWORD=${HICLAW_ADMIN_PASSWORD}

# Matrix
HICLAW_MATRIX_DOMAIN=${HICLAW_MATRIX_DOMAIN}
HICLAW_MATRIX_CLIENT_DOMAIN=${HICLAW_MATRIX_CLIENT_DOMAIN}

# Gateway
HICLAW_AI_GATEWAY_DOMAIN=${HICLAW_AI_GATEWAY_DOMAIN}
HICLAW_MANAGER_GATEWAY_KEY=${HICLAW_MANAGER_GATEWAY_KEY}

# File System
HICLAW_FS_DOMAIN=${HICLAW_FS_DOMAIN}
HICLAW_MINIO_USER=${HICLAW_MINIO_USER}
HICLAW_MINIO_PASSWORD=${HICLAW_MINIO_PASSWORD}

# Internal
HICLAW_MANAGER_PASSWORD=${HICLAW_MANAGER_PASSWORD}
HICLAW_REGISTRATION_TOKEN=${HICLAW_REGISTRATION_TOKEN}

# GitHub (optional)
HICLAW_GITHUB_TOKEN=${HICLAW_GITHUB_TOKEN:-}

# Worker image (for direct container creation)
HICLAW_WORKER_IMAGE=hiclaw/worker-agent:${HICLAW_VERSION}

# Host ports
HICLAW_PORT_GATEWAY=${HICLAW_PORT_GATEWAY}
HICLAW_PORT_CONSOLE=${HICLAW_PORT_CONSOLE}

# Data persistence
HICLAW_DATA_DIR=${HICLAW_DATA_DIR:-}
# Host directory sharing
HICLAW_HOST_SHARE_DIR=${HICLAW_HOST_SHARE_DIR:-}
EOF

    chmod 600 "${ENV_FILE}"
    log "Configuration saved to ${ENV_FILE}"

    # Detect container runtime socket
    SOCKET_MOUNT_ARGS=""
    if [ "${HICLAW_MOUNT_SOCKET}" = "1" ]; then
        CONTAINER_SOCK=$(detect_socket)
        if [ -n "${CONTAINER_SOCK}" ]; then
            log "Container runtime socket: ${CONTAINER_SOCK} (direct Worker creation enabled)"
            SOCKET_MOUNT_ARGS="-v ${CONTAINER_SOCK}:/var/run/docker.sock --security-opt label=disable"
        else
            log "No container runtime socket found (Worker creation will output commands)"
        fi
    fi

    # Remove existing container if present
    if docker ps -a --format '{{.Names}}' | grep -q "^hiclaw-manager$"; then
        log "Removing existing hiclaw-manager container..."
        docker stop hiclaw-manager 2>/dev/null || true
        docker rm hiclaw-manager 2>/dev/null || true
    fi

    # Data mount: external directory or Docker volume
    if [ -n "${HICLAW_DATA_DIR}" ]; then
        DATA_MOUNT_ARGS="-v ${HICLAW_DATA_DIR}:/data"
    else
        DATA_MOUNT_ARGS="-v hiclaw-data:/data"
    fi

    # Host directory mount: for file sharing with agents (defaults to user's home)
    if [ "${HICLAW_NON_INTERACTIVE}" != "1" ] && [ -z "${HICLAW_HOST_SHARE_DIR+x}" ]; then
        read -p "Host directory to share with agents (default: $HOME): " HICLAW_HOST_SHARE_DIR
        HICLAW_HOST_SHARE_DIR="${HICLAW_HOST_SHARE_DIR:-$HOME}"
        export HICLAW_HOST_SHARE_DIR
    elif [ -z "${HICLAW_HOST_SHARE_DIR+x}" ]; then
        HICLAW_HOST_SHARE_DIR="$HOME"
        export HICLAW_HOST_SHARE_DIR
    fi

    if [ -d "${HICLAW_HOST_SHARE_DIR}" ]; then
        HOST_SHARE_MOUNT_ARGS="-v ${HICLAW_HOST_SHARE_DIR}:/host-share"
        log "Sharing host directory: ${HICLAW_HOST_SHARE_DIR} -> /host-share in container"
    else
        log "WARNING: Host directory ${HICLAW_HOST_SHARE_DIR} does not exist, using without validation"
        HOST_SHARE_MOUNT_ARGS="-v ${HICLAW_HOST_SHARE_DIR}:/host-share"
    fi

    # Run Manager container
    log "Starting Manager container..."
    docker run -d \
        --name hiclaw-manager \
        --env-file "${ENV_FILE}" \
        -e HOST_ORIGINAL_HOME="${HICLAW_HOST_SHARE_DIR}" \
        ${SOCKET_MOUNT_ARGS} \
        -p "${HICLAW_PORT_GATEWAY}:8080" \
        -p "${HICLAW_PORT_CONSOLE}:8001" \
        ${DATA_MOUNT_ARGS} \
        ${HOST_SHARE_MOUNT_ARGS} \
        --restart unless-stopped \
        "${MANAGER_IMAGE}"

    log ""
    log "=== HiClaw Manager Started! ==="
    log ""
    log "--- Unified Credentials (same for all consoles) ---"
    log "  Username: ${HICLAW_ADMIN_USER}"
    log "  Password: ${HICLAW_ADMIN_PASSWORD}"
    log ""
    log "--- Access URLs ---"
    log "  Element Web (IM Client): http://${HICLAW_MATRIX_CLIENT_DOMAIN}:${HICLAW_PORT_GATEWAY}"
    log "  Higress Console:         http://localhost:${HICLAW_PORT_CONSOLE}"
    log ""
    log "IMPORTANT: Add the following to your /etc/hosts file:"
    log "  127.0.0.1 ${HICLAW_MATRIX_DOMAIN%%:*} ${HICLAW_MATRIX_CLIENT_DOMAIN} ${HICLAW_AI_GATEWAY_DOMAIN} ${HICLAW_FS_DOMAIN}"
    log ""
    echo -e "\033[33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "\033[33m  ★ Login to Element Web and start chatting with the Manager!  ★\033[0m"
    echo -e "\033[33m    Tell it: \"Create a Worker named alice for frontend dev\"    \033[0m"
    echo -e "\033[33m    The Manager will handle everything automatically.           \033[0m"
    echo -e "\033[33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    log ""
    log "Tip: You can also configure LLM providers and API keys via Higress Console,"
    log "     or simply ask the Manager to do it for you in the chat."
    log ""
    log "Configuration file: ${ENV_FILE}"
    if [ -n "${HICLAW_DATA_DIR}" ]; then
        log "Data directory:     ${HICLAW_DATA_DIR}"
    else
        log "Data volume:        hiclaw-data (use HICLAW_DATA_DIR to persist externally)"
    fi
}

# ============================================================
# Worker Installation (One-Click)
# ============================================================

install_worker() {
    local WORKER_NAME=""
    local FS=""
    local FS_KEY=""
    local FS_SECRET=""
    local RESET=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)       WORKER_NAME="$2"; shift 2 ;;
            --fs)         FS="$2"; shift 2 ;;
            --fs-key)     FS_KEY="$2"; shift 2 ;;
            --fs-secret)  FS_SECRET="$2"; shift 2 ;;
            --reset)      RESET=true; shift ;;
            *)            error "Unknown option: $1" ;;
        esac
    done

    # Validate required params
    [ -z "${WORKER_NAME}" ] && error "--name is required"
    [ -z "${FS}" ] && error "--fs is required"
    [ -z "${FS_KEY}" ] && error "--fs-key is required"
    [ -z "${FS_SECRET}" ] && error "--fs-secret is required"

    local CONTAINER_NAME="hiclaw-worker-${WORKER_NAME}"

    # Handle reset
    if [ "${RESET}" = true ]; then
        log "Resetting Worker: ${WORKER_NAME}..."
        docker stop "${CONTAINER_NAME}" 2>/dev/null || true
        docker rm "${CONTAINER_NAME}" 2>/dev/null || true
    fi

    # Check for existing container
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        error "Container '${CONTAINER_NAME}' already exists. Use --reset to recreate."
    fi

    log "Starting Worker: ${WORKER_NAME}..."
    docker run -d \
        --name "${CONTAINER_NAME}" \
        -e "HICLAW_WORKER_NAME=${WORKER_NAME}" \
        -e "HICLAW_FS_ENDPOINT=${FS}" \
        -e "HICLAW_FS_ACCESS_KEY=${FS_KEY}" \
        -e "HICLAW_FS_SECRET_KEY=${FS_SECRET}" \
        --restart unless-stopped \
        "${WORKER_IMAGE}"

    log ""
    log "=== Worker ${WORKER_NAME} Started! ==="
    log "Container: ${CONTAINER_NAME}"
    log "View logs: docker logs -f ${CONTAINER_NAME}"
}

# ============================================================
# Main
# ============================================================

case "${1:-}" in
    manager)
        install_manager
        ;;
    worker)
        shift
        install_worker "$@"
        ;;
    *)
        echo "Usage: $0 {manager|worker [options]}"
        echo ""
        echo "Commands:"
        echo "  manager              Interactive Manager installation"
        echo "  worker               Worker installation (requires --name and connection params)"
        echo ""
        echo "All manager prompts can be pre-set via environment variables."
        echo "Minimal interactive install (only LLM key required):"
        echo "  HICLAW_LLM_API_KEY=sk-xxx $0 manager"
        echo ""
        echo "Non-interactive install (all defaults, no prompts):"
        echo "  HICLAW_NON_INTERACTIVE=1 HICLAW_LLM_API_KEY=sk-xxx $0 manager"
        echo ""
        echo "With external data directory:"
        echo "  HICLAW_DATA_DIR=~/hiclaw-data HICLAW_LLM_API_KEY=sk-xxx $0 manager"
        echo ""
        echo "Worker Options:"
        echo "  --name <name>        Worker name (required)"
        echo "  --fs <url>           MinIO endpoint URL (required)"
        echo "  --fs-key <key>       MinIO access key (required)"
        echo "  --fs-secret <secret> MinIO secret key (required)"
        echo "  --reset              Remove existing Worker container before creating"
        exit 1
        ;;
esac
