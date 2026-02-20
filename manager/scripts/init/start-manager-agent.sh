#!/bin/bash
# start-manager-agent.sh - Initialize and start the Manager Agent
# This is the last component to start (priority 800).
# It waits for all dependencies, creates Matrix users, configures Higress,
# creates symlinks for host directory access, and launches OpenClaw.

source /opt/hiclaw/scripts/lib/base.sh

MATRIX_DOMAIN="${HICLAW_MATRIX_DOMAIN:-matrix-local.hiclaw.io:8080}"
AI_GATEWAY_DOMAIN="${HICLAW_AI_GATEWAY_DOMAIN:-llm-local.hiclaw.io}"

# ============================================================
# Create symlink for host directory access
# If /host-share is mounted, create a symlink using the original host's HOME path
# ============================================================
if [ -d "/host-share" ]; then
    # Determine the original host's home directory path for consistent access
    # The user can set HOST_ORIGINAL_HOME via environment variable if needed
    ORIGINAL_HOST_HOME="${HOST_ORIGINAL_HOME:-$HOME}"

    # Only create the symlink if it won't conflict with existing paths in the container
    if [ ! -e "${ORIGINAL_HOST_HOME}" ] && [ "${ORIGINAL_HOST_HOME}" != "/" ] && [ "${ORIGINAL_HOST_HOME}" != "/root" ] && [ "${ORIGINAL_HOST_HOME}" != "/data" ] && [ "${ORIGINAL_HOST_HOME}" != "/host-share" ]; then
        # Create parent directories if they don't exist
        mkdir -p "$(dirname "${ORIGINAL_HOST_HOME}")"

        # Create symlink from original host home path to the mounted host share
        ln -sfn /host-share "${ORIGINAL_HOST_HOME}"
        log "Created symlink: ${ORIGINAL_HOST_HOME} -> /host-share"
        log "Host files now accessible at: ${ORIGINAL_HOST_HOME}/"
    else
        log "Skipping symlink creation to avoid conflict with existing path: ${ORIGINAL_HOST_HOME}"
        # Create a fallback symlink with a different name
        ln -sfn /host-share /root/host-home
        log "Created fallback symlink: /root/host-home -> /host-share"
    fi
else
    log "Host share directory (/host-share) not found, skipping symlink creation"
fi

# Add local domains to /etc/hosts so they resolve inside the container
HOSTS_DOMAINS="${MATRIX_DOMAIN%%:*} ${HICLAW_MATRIX_CLIENT_DOMAIN:-matrix-client-local.hiclaw.io} ${AI_GATEWAY_DOMAIN} ${HICLAW_FS_DOMAIN:-fs-local.hiclaw.io}"
if ! grep -q "${AI_GATEWAY_DOMAIN}" /etc/hosts 2>/dev/null; then
    echo "127.0.0.1 ${HOSTS_DOMAINS}" >> /etc/hosts
    log "Added local domains to /etc/hosts"
fi

# ============================================================
# Auto-generate secrets if not provided via environment
# Persisted to /data so they survive container restart
# ============================================================
SECRETS_FILE="/data/hiclaw-secrets.env"
if [ -f "${SECRETS_FILE}" ]; then
    source "${SECRETS_FILE}"
    log "Loaded persisted secrets from ${SECRETS_FILE}"
fi

if [ -z "${HICLAW_MANAGER_GATEWAY_KEY}" ]; then
    export HICLAW_MANAGER_GATEWAY_KEY="$(generateKey 32)"
    log "Auto-generated HICLAW_MANAGER_GATEWAY_KEY"
fi
if [ -z "${HICLAW_MANAGER_PASSWORD}" ]; then
    export HICLAW_MANAGER_PASSWORD="$(generateKey 16)"
    log "Auto-generated HICLAW_MANAGER_PASSWORD"
fi

# Persist secrets so they survive supervisord restart
mkdir -p /data
cat > "${SECRETS_FILE}" <<EOF
export HICLAW_MANAGER_GATEWAY_KEY="${HICLAW_MANAGER_GATEWAY_KEY}"
export HICLAW_MANAGER_PASSWORD="${HICLAW_MANAGER_PASSWORD}"
EOF
chmod 600 "${SECRETS_FILE}"

# ============================================================
# Wait for all dependencies
# ============================================================
waitForService "Higress Gateway" "127.0.0.1" 8080 180
waitForService "Higress Console" "127.0.0.1" 8001 180
waitForService "Tuwunel" "127.0.0.1" 6167 120
waitForService "MinIO" "127.0.0.1" 9000 120

# Wait for mc mirror initialization
log "Waiting for MinIO storage initialization..."
while [ ! -f ~/hiclaw-fs/.initialized ]; do sleep 2; done
log "MinIO storage initialized"

# ============================================================
# Register Matrix users via Registration API (single-step, no UIAA)
# ============================================================
log "Registering human admin Matrix account..."
curl -sf -X POST http://127.0.0.1:6167/_matrix/client/v3/register \
    -H 'Content-Type: application/json' \
    -d '{
        "username": "'"${HICLAW_ADMIN_USER}"'",
        "password": "'"${HICLAW_ADMIN_PASSWORD}"'",
        "auth": {
            "type": "m.login.registration_token",
            "token": "'"${HICLAW_REGISTRATION_TOKEN}"'"
        }
    }' > /dev/null 2>&1 || log "Admin account may already exist"

log "Registering Manager Agent Matrix account..."
curl -sf -X POST http://127.0.0.1:6167/_matrix/client/v3/register \
    -H 'Content-Type: application/json' \
    -d '{
        "username": "manager",
        "password": "'"${HICLAW_MANAGER_PASSWORD}"'",
        "auth": {
            "type": "m.login.registration_token",
            "token": "'"${HICLAW_REGISTRATION_TOKEN}"'"
        }
    }' > /dev/null 2>&1 || log "Manager account may already exist"

# Get Manager Agent's Matrix access token
log "Obtaining Manager Matrix access token..."
MANAGER_TOKEN=$(curl -sf -X POST http://127.0.0.1:6167/_matrix/client/v3/login \
    -H 'Content-Type: application/json' \
    -d '{
        "type": "m.login.password",
        "identifier": {"type": "m.id.user", "user": "manager"},
        "password": "'"${HICLAW_MANAGER_PASSWORD}"'"
    }' | jq -r '.access_token')

if [ -z "${MANAGER_TOKEN}" ] || [ "${MANAGER_TOKEN}" = "null" ]; then
    log "ERROR: Failed to obtain Manager Matrix token"
    exit 1
fi
log "Manager Matrix token obtained"

# ============================================================
# Initialize Higress Console (Session Cookie auth)
# ============================================================
COOKIE_FILE="/tmp/higress-session-cookie"

# Wait for Higress Console Java app to be fully ready (not just port open)
# The Spring Boot app may take 10-30s after port opens to serve requests.
# On first boot: /system/init creates admin. On restart: init returns "already initialized".
# IMPORTANT: Always attempt /system/init first (idempotent), then login.
log "Waiting for Higress Console to be fully ready and initializing admin..."
INIT_DONE=false
for i in $(seq 1 90); do
    INIT_RESULT=$(curl -s -X POST http://127.0.0.1:8001/system/init \
        -H 'Content-Type: application/json' \
        -d '{"adminUser":{"name":"'"${HICLAW_ADMIN_USER}"'","password":"'"${HICLAW_ADMIN_PASSWORD}"'","displayName":"'"${HICLAW_ADMIN_USER}"'"}}' 2>/dev/null) || true
    if echo "${INIT_RESULT}" | grep -qE '"success":true|already.?init' 2>/dev/null; then
        INIT_DONE=true
        break
    fi
    if echo "${INIT_RESULT}" | grep -q '"name"' 2>/dev/null; then
        INIT_DONE=true
        break
    fi
    sleep 2
done

if [ "${INIT_DONE}" != "true" ]; then
    log "ERROR: Higress Console did not become ready within 180s"
    exit 1
fi
log "Higress Console init done"

# Login: init uses "name", login uses "username"
log "Logging into Higress Console..."
LOGIN_OK=false
for i in $(seq 1 10); do
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8001/session/login \
        -H 'Content-Type: application/json' \
        -c "${COOKIE_FILE}" \
        -d '{"username":"'"${HICLAW_ADMIN_USER}"'","password":"'"${HICLAW_ADMIN_PASSWORD}"'"}' 2>/dev/null) || true
    if { [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "201" ]; } && [ -f "${COOKIE_FILE}" ] && [ -s "${COOKIE_FILE}" ]; then
        LOGIN_OK=true
        break
    fi
    log "Login attempt $i (HTTP ${HTTP_CODE}), retrying in 3s..."
    sleep 3
done

if [ "${LOGIN_OK}" != "true" ]; then
    log "ERROR: Could not login to Higress Console after retries"
    exit 1
fi
log "Higress Console login successful"

# Verify cookie is valid by calling an API endpoint
VERIFY_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8001/v1/consumers -b "${COOKIE_FILE}" 2>/dev/null) || true
if [ "${VERIFY_CODE}" = "200" ]; then
    log "Console session verified (cookie valid)"
else
    log "WARNING: Console session may be invalid (verify returned HTTP ${VERIFY_CODE})"
    # Try re-login with a fresh cookie file
    rm -f "${COOKIE_FILE}"
    for i in $(seq 1 5); do
        curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8001/session/login \
            -H 'Content-Type: application/json' \
            -c "${COOKIE_FILE}" \
            -d '{"username":"'"${HICLAW_ADMIN_USER}"'","password":"'"${HICLAW_ADMIN_PASSWORD}"'"}' 2>/dev/null
        VERIFY2=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8001/v1/consumers -b "${COOKIE_FILE}" 2>/dev/null) || true
        if [ "${VERIFY2}" = "200" ]; then
            log "Re-login successful, session verified"
            break
        fi
        sleep 2
    done
fi

export HIGRESS_COOKIE_FILE="${COOKIE_FILE}"

# ============================================================
# Configure Higress routes, consumers, MCP servers
# ============================================================
/opt/hiclaw/scripts/init/setup-higress.sh

# ============================================================
# Generate Manager Agent openclaw.json from template
# ============================================================
log "Generating Manager openclaw.json..."
export MANAGER_MATRIX_TOKEN="${MANAGER_TOKEN}"
export MANAGER_GATEWAY_KEY="${HICLAW_MANAGER_GATEWAY_KEY}"

# Resolve model parameters based on model name
MODEL_NAME="${HICLAW_DEFAULT_MODEL:-qwen3.5-plus}"
case "${MODEL_NAME}" in
    gpt-5.3-codex|gpt-5-mini|gpt-5-nano)
        export MODEL_CONTEXT_WINDOW=400000 MODEL_MAX_TOKENS=128000 ;;
    claude-opus-4-6)
        export MODEL_CONTEXT_WINDOW=1000000 MODEL_MAX_TOKENS=128000 ;;
    claude-sonnet-4-5)
        export MODEL_CONTEXT_WINDOW=1000000 MODEL_MAX_TOKENS=64000 ;;
    claude-haiku-4-5)
        export MODEL_CONTEXT_WINDOW=200000 MODEL_MAX_TOKENS=64000 ;;
    qwen3.5-plus)
        export MODEL_CONTEXT_WINDOW=960000 MODEL_MAX_TOKENS=64000 ;;
    deepseek-chat|deepseek-reasoner|kimi-k2.5)
        export MODEL_CONTEXT_WINDOW=256000 MODEL_MAX_TOKENS=128000 ;;
    glm-5|MiniMax-M2.5)
        export MODEL_CONTEXT_WINDOW=200000 MODEL_MAX_TOKENS=128000 ;;
    *)
        export MODEL_CONTEXT_WINDOW=200000 MODEL_MAX_TOKENS=128000 ;;
esac
export MODEL_REASONING=true
log "Model: ${MODEL_NAME} (context=${MODEL_CONTEXT_WINDOW}, maxTokens=${MODEL_MAX_TOKENS}, reasoning=${MODEL_REASONING})"

envsubst < /opt/hiclaw/configs/manager-openclaw.json.tmpl > ~/hiclaw-fs/agents/manager/openclaw.json

# ============================================================
# Detect container runtime socket (for direct Worker creation)
# ============================================================
source /opt/hiclaw/scripts/lib/container-api.sh
if container_api_available; then
    log "Container runtime socket detected at ${CONTAINER_SOCKET} — direct Worker creation enabled"
    export HICLAW_CONTAINER_RUNTIME="socket"
else
    log "No container runtime socket found — Worker creation will output install commands"
    export HICLAW_CONTAINER_RUNTIME="none"
fi

# ============================================================
# Start OpenClaw Manager Agent
# ============================================================
log "Starting Manager Agent (OpenClaw)..."
export OPENCLAW_CONFIG_PATH=~/hiclaw-fs/agents/manager/openclaw.json

# Symlink to default OpenClaw config path so CLI commands find the config
mkdir -p /root/.openclaw
ln -sf ~/hiclaw-fs/agents/manager/openclaw.json /root/.openclaw/openclaw.json

exec openclaw gateway run --verbose --force
