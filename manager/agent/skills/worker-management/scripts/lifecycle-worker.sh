#!/bin/bash
# lifecycle-worker.sh - Worker container lifecycle management
#
# Manages automatic stop/start of Worker containers based on idle time.
# State is persisted in ~/worker-lifecycle.json.
#
# Usage:
#   lifecycle-worker.sh --action sync-status
#   lifecycle-worker.sh --action check-idle
#   lifecycle-worker.sh --action stop --worker <name>
#   lifecycle-worker.sh --action start --worker <name>

set -euo pipefail

source /opt/hiclaw/scripts/lib/container-api.sh

LIFECYCLE_FILE="${HOME}/worker-lifecycle.json"
REGISTRY_FILE="${HOME}/workers-registry.json"
STATE_FILE="${HOME}/state.json"

_ts() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

_log() {
    echo "[lifecycle $(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Read a field from the lifecycle JSON for a specific worker
# Usage: _get_worker_field <worker> <field>
_get_worker_field() {
    local worker="$1"
    local field="$2"
    jq -r --arg w "$worker" --arg f "$field" '.workers[$w][$f] // empty' "$LIFECYCLE_FILE" 2>/dev/null
}

# Update a field in the lifecycle JSON for a specific worker
# Usage: _set_worker_field <worker> <field> <value>
_set_worker_field() {
    local worker="$1"
    local field="$2"
    local value="$3"
    local tmp
    tmp=$(mktemp)
    jq --arg w "$worker" --arg f "$field" --arg v "$value" \
        '.workers[$w][$f] = $v | .updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' \
        "$LIFECYCLE_FILE" > "$tmp" && mv "$tmp" "$LIFECYCLE_FILE"
}

# Initialize lifecycle file if it doesn't exist
_init_lifecycle_file() {
    if [ ! -f "$LIFECYCLE_FILE" ]; then
        _log "Initializing $LIFECYCLE_FILE"
        cat > "$LIFECYCLE_FILE" << 'EOF'
{
  "version": 1,
  "idle_timeout_minutes": 30,
  "updated_at": "",
  "workers": {}
}
EOF
        _set_worker_field "__init__" "__discard__" "" 2>/dev/null || true
        # Re-initialize cleanly
        cat > "$LIFECYCLE_FILE" << EOF
{
  "version": 1,
  "idle_timeout_minutes": 30,
  "updated_at": "$(_ts)",
  "workers": {}
}
EOF
    fi
}

# Ensure a worker entry exists in lifecycle file
_ensure_worker_entry() {
    local worker="$1"
    local exists
    exists=$(jq -r --arg w "$worker" '.workers | has($w)' "$LIFECYCLE_FILE" 2>/dev/null)
    if [ "$exists" != "true" ]; then
        local tmp
        tmp=$(mktemp)
        jq --arg w "$worker" --arg ts "$(_ts)" \
            '.workers[$w] = {
                "container_status": "unknown",
                "idle_since": null,
                "auto_stopped_at": null,
                "last_started_at": null
            } | .updated_at = $ts' \
            "$LIFECYCLE_FILE" > "$tmp" && mv "$tmp" "$LIFECYCLE_FILE"
    fi
}

# Get list of all worker names from workers-registry.json
_get_all_workers() {
    if [ ! -f "$REGISTRY_FILE" ]; then
        _log "WARNING: $REGISTRY_FILE not found"
        return
    fi
    jq -r '.workers | keys[]' "$REGISTRY_FILE" 2>/dev/null
}

# Check if a worker has any active finite tasks in state.json
# Returns 0 if worker has active finite tasks, 1 otherwise
_worker_has_finite_tasks() {
    local worker="$1"
    if [ ! -f "$STATE_FILE" ]; then
        return 1
    fi
    local count
    count=$(jq -r --arg w "$worker" \
        '[.active_tasks[] | select(.assigned_to == $w and .type == "finite")] | length' \
        "$STATE_FILE" 2>/dev/null || echo "0")
    [ "$count" -gt 0 ]
}

# ─── Actions ─────────────────────────────────────────────────────────────────

# Sync container status from Docker API into lifecycle file
action_sync_status() {
    _init_lifecycle_file

    if ! container_api_available; then
        _log "Container API not available — marking all workers as remote"
        local workers
        workers=$(_get_all_workers)
        for worker in $workers; do
            _ensure_worker_entry "$worker"
            _set_worker_field "$worker" "container_status" "remote"
        done
        return 0
    fi

    local workers
    workers=$(_get_all_workers)
    if [ -z "$workers" ]; then
        _log "No workers found in registry"
        return 0
    fi

    for worker in $workers; do
        _ensure_worker_entry "$worker"
        local status
        status=$(container_status_worker "$worker")
        _log "Worker $worker: container_status=$status"
        local tmp
        tmp=$(mktemp)
        jq --arg w "$worker" --arg s "$status" --arg ts "$(_ts)" \
            '.workers[$w].container_status = $s | .updated_at = $ts' \
            "$LIFECYCLE_FILE" > "$tmp" && mv "$tmp" "$LIFECYCLE_FILE"
    done

    _log "Status sync complete"
}

# Check for idle workers and update idle_since timestamps
# Also auto-stops workers that have exceeded idle_timeout_minutes
action_check_idle() {
    _init_lifecycle_file

    local idle_timeout
    idle_timeout=$(jq -r '.idle_timeout_minutes // 30' "$LIFECYCLE_FILE")
    local now_epoch
    now_epoch=$(date -u +%s)

    local workers
    workers=$(_get_all_workers)
    if [ -z "$workers" ]; then
        return 0
    fi

    for worker in $workers; do
        _ensure_worker_entry "$worker"

        local container_status
        container_status=$(_get_worker_field "$worker" "container_status")

        # Skip remote workers and non-running containers
        if [ "$container_status" = "remote" ] || [ "$container_status" = "not_found" ]; then
            continue
        fi

        if _worker_has_finite_tasks "$worker"; then
            # Worker is active — clear idle_since
            local current_idle
            current_idle=$(_get_worker_field "$worker" "idle_since")
            if [ -n "$current_idle" ] && [ "$current_idle" != "null" ]; then
                _log "Worker $worker has active finite tasks — clearing idle_since"
                local tmp
                tmp=$(mktemp)
                jq --arg w "$worker" --arg ts "$(_ts)" \
                    '.workers[$w].idle_since = null | .updated_at = $ts' \
                    "$LIFECYCLE_FILE" > "$tmp" && mv "$tmp" "$LIFECYCLE_FILE"
            fi
        else
            # Worker has no finite tasks
            if [ "$container_status" != "running" ]; then
                continue
            fi

            local idle_since
            idle_since=$(_get_worker_field "$worker" "idle_since")

            if [ -z "$idle_since" ] || [ "$idle_since" = "null" ]; then
                # Start counting idle time
                _log "Worker $worker is idle — setting idle_since"
                local tmp
                tmp=$(mktemp)
                jq --arg w "$worker" --arg ts "$(_ts)" \
                    '.workers[$w].idle_since = $ts | .updated_at = $ts' \
                    "$LIFECYCLE_FILE" > "$tmp" && mv "$tmp" "$LIFECYCLE_FILE"
            else
                # Check if idle timeout exceeded
                local idle_epoch
                idle_epoch=$(date -u -d "$idle_since" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$idle_since" +%s 2>/dev/null)
                local idle_seconds=$(( now_epoch - idle_epoch ))
                local timeout_seconds=$(( idle_timeout * 60 ))

                if [ "$idle_seconds" -ge "$timeout_seconds" ]; then
                    _log "Worker $worker idle for ${idle_seconds}s (timeout: ${timeout_seconds}s) — auto-stopping"
                    action_stop "$worker"
                fi
            fi
        fi
    done
}

# Stop a worker container
action_stop() {
    local worker="$1"
    _init_lifecycle_file
    _ensure_worker_entry "$worker"

    if ! container_api_available; then
        _log "ERROR: Container API not available"
        return 1
    fi

    _log "Stopping worker $worker"
    if container_stop_worker "$worker"; then
        local tmp
        tmp=$(mktemp)
        jq --arg w "$worker" --arg ts "$(_ts)" \
            '.workers[$w].container_status = "stopped"
            | .workers[$w].auto_stopped_at = $ts
            | .updated_at = $ts' \
            "$LIFECYCLE_FILE" > "$tmp" && mv "$tmp" "$LIFECYCLE_FILE"
        _log "Worker $worker stopped and lifecycle file updated"
    else
        _log "ERROR: Failed to stop worker $worker"
        return 1
    fi
}

# Resolve context window and max tokens for a given model name
# Usage: _resolve_model_params <model_name> -> sets CTX and MAX
_resolve_model_params() {
    local model="$1"
    case "${model}" in
        gpt-5.3-codex|gpt-5-mini|gpt-5-nano)
            CTX=400000; MAX=128000 ;;
        claude-opus-4-6)
            CTX=1000000; MAX=128000 ;;
        claude-sonnet-4-6)
            CTX=1000000; MAX=64000 ;;
        claude-haiku-4-5)
            CTX=200000; MAX=64000 ;;
        qwen3.5-plus)
            CTX=960000; MAX=64000 ;;
        deepseek-chat|deepseek-reasoner|kimi-k2.5)
            CTX=256000; MAX=128000 ;;
        glm-5|MiniMax-M2.5)
            CTX=200000; MAX=128000 ;;
        *)
            CTX=200000; MAX=128000 ;;
    esac
}

# Update the model for a worker: patches openclaw.json in MinIO and notifies the worker
action_update_model() {
    local worker="$1"
    local new_model="$2"
    # Strip provider prefix if caller passed "hiclaw-gateway/<model>" by mistake
    new_model="${new_model#hiclaw-gateway/}"

    if [ -z "${worker}" ] || [ -z "${new_model}" ]; then
        _log "ERROR: --worker and --model are required for action 'update-model'"
        return 1
    fi

    if [ ! -f "$REGISTRY_FILE" ]; then
        _log "ERROR: $REGISTRY_FILE not found"
        return 1
    fi

    local exists
    exists=$(jq -r --arg w "$worker" '.workers | has($w)' "$REGISTRY_FILE" 2>/dev/null)
    if [ "$exists" != "true" ]; then
        _log "ERROR: Worker '$worker' not found in registry"
        return 1
    fi

    local CTX MAX
    _resolve_model_params "${new_model}"
    _log "Updating worker $worker model to ${new_model} (ctx=${CTX}, max=${MAX})"

    # ── Pre-flight: verify the model is reachable via AI Gateway ─────────────
    local gateway_url="http://${HICLAW_AI_GATEWAY_DOMAIN:-aigw-local.hiclaw.io}:8080/v1/chat/completions"
    local gateway_key="${HICLAW_MANAGER_GATEWAY_KEY:-}"
    if [ -z "${gateway_key}" ] && [ -f "/data/hiclaw-secrets.env" ]; then
        source /data/hiclaw-secrets.env
        gateway_key="${HICLAW_MANAGER_GATEWAY_KEY:-}"
    fi
    _log "Testing model reachability: ${gateway_url} (model=${new_model})..."
    local http_code
    http_code=$(curl -s -o /tmp/model-test-resp-${worker}.json -w '%{http_code}' \
        -X POST "${gateway_url}" \
        -H "Authorization: Bearer ${gateway_key}" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${new_model}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" \
        --connect-timeout 10 --max-time 30 2>/dev/null) || http_code="000"
    if [ "${http_code}" != "200" ]; then
        local resp_body
        resp_body=$(cat /tmp/model-test-resp-${worker}.json 2>/dev/null | head -c 300 || true)
        rm -f /tmp/model-test-resp-${worker}.json
        _log "ERROR: Model test failed (HTTP ${http_code}): ${resp_body}"
        _log "The model '${new_model}' is not reachable via the AI Gateway."
        _log "Please check the Higress Console to confirm the AI route is configured for this model:"
        _log "  http://<manager-host>:8001  →  AI Routes → verify provider and model mapping"
        return 1
    fi
    rm -f /tmp/model-test-resp-${worker}.json
    _log "Model test passed (HTTP 200)"
    # ─────────────────────────────────────────────────────────────────────────

    # Pull openclaw.json from MinIO
    local minio_path="hiclaw/hiclaw-storage/agents/${worker}/openclaw.json"
    local tmp_in="/tmp/openclaw-${worker}-model-update-in.json"
    local tmp_out="/tmp/openclaw-${worker}-model-update-out.json"

    if ! mc cp "${minio_path}" "${tmp_in}" 2>/dev/null; then
        _log "ERROR: Could not pull openclaw.json for ${worker} from MinIO"
        return 1
    fi

    # Patch model id, name, contextWindow, maxTokens (preserves other fields like input, reasoning)
    jq --arg model "${new_model}" \
       --argjson ctx "${CTX}" \
       --argjson max "${MAX}" \
       '(.models.providers["hiclaw-gateway"].models[0]) |= (. + {
           "id": $model,
           "name": $model,
           "contextWindow": $ctx,
           "maxTokens": $max
         })
        | .agents.defaults.model.primary = ("hiclaw-gateway/" + $model)' \
       "${tmp_in}" > "${tmp_out}"

    if ! mc cp "${tmp_out}" "${minio_path}" 2>/dev/null; then
        _log "ERROR: Failed to push updated openclaw.json for ${worker} to MinIO"
        rm -f "${tmp_in}" "${tmp_out}"
        return 1
    fi
    rm -f "${tmp_in}" "${tmp_out}"
    _log "openclaw.json updated in MinIO for ${worker}"

    # Update workers-registry.json with model field
    local tmp_reg
    tmp_reg=$(mktemp)
    jq --arg w "$worker" --arg m "${new_model}" --arg ts "$(_ts)" \
        '.workers[$w].model = $m | .updated_at = $ts' \
        "$REGISTRY_FILE" > "$tmp_reg" && mv "$tmp_reg" "$REGISTRY_FILE"
    _log "Registry updated: ${worker}.model = ${new_model}"

    # Notify worker to run hiclaw-sync
    local room_id
    room_id=$(jq -r --arg w "$worker" '.workers[$w].room_id // empty' "$REGISTRY_FILE" 2>/dev/null)
    local matrix_domain="${HICLAW_MATRIX_DOMAIN:-matrix-local.hiclaw.io:8080}"
    local manager_token="${MANAGER_MATRIX_TOKEN:-}"

    # Try to get token from secrets file if not in env
    if [ -z "${manager_token}" ] && [ -f "/data/hiclaw-secrets.env" ]; then
        source /data/hiclaw-secrets.env
        manager_token="${MANAGER_MATRIX_TOKEN:-}"
    fi

    if [ -n "${room_id}" ] && [ -n "${manager_token}" ]; then
        local txn_id
        txn_id=$(openssl rand -hex 8)
        curl -sf -X PUT \
            "http://127.0.0.1:6167/_matrix/client/v3/rooms/${room_id}/send/m.room.message/${txn_id}" \
            -H "Authorization: Bearer ${manager_token}" \
            -H 'Content-Type: application/json' \
            -d "{\"msgtype\":\"m.text\",\"body\":\"@${worker}:${matrix_domain} Your model has been updated to \`${new_model}\`. Please run: hiclaw-sync\",\"m.mentions\":{\"user_ids\":[\"@${worker}:${matrix_domain}\"]}}" \
            > /dev/null 2>&1 \
            && _log "Notified @${worker} to run hiclaw-sync" \
            || _log "WARNING: Failed to notify @${worker} (container may be stopped)"
    else
        _log "WARNING: Could not send Matrix notification (missing room_id or token)"
    fi

    _log "Model update complete for ${worker}: ${new_model} (ctx=${CTX}, max=${MAX})"
}

# Start (wake up) a stopped worker container
action_start() {
    local worker="$1"
    _init_lifecycle_file
    _ensure_worker_entry "$worker"

    if ! container_api_available; then
        _log "ERROR: Container API not available"
        return 1
    fi

    _log "Starting worker $worker"
    if container_start_worker "$worker"; then
        local tmp
        tmp=$(mktemp)
        jq --arg w "$worker" --arg ts "$(_ts)" \
            '.workers[$w].container_status = "running"
            | .workers[$w].idle_since = null
            | .workers[$w].last_started_at = $ts
            | .updated_at = $ts' \
            "$LIFECYCLE_FILE" > "$tmp" && mv "$tmp" "$LIFECYCLE_FILE"
        _log "Worker $worker started and lifecycle file updated"
    else
        _log "ERROR: Failed to start worker $worker"
        return 1
    fi
}

# ─── Argument parsing ─────────────────────────────────────────────────────────

ACTION=""
WORKER=""
MODEL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --action)
            ACTION="$2"
            shift 2
            ;;
        --worker)
            WORKER="$2"
            shift 2
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [ -z "$ACTION" ]; then
    echo "Usage: $0 --action <sync-status|check-idle|stop|start|update-model> [--worker <name>] [--model <model-id>]" >&2
    exit 1
fi

case "$ACTION" in
    sync-status)
        action_sync_status
        ;;
    check-idle)
        action_check_idle
        ;;
    stop)
        if [ -z "$WORKER" ]; then
            echo "ERROR: --worker required for action 'stop'" >&2
            exit 1
        fi
        action_stop "$WORKER"
        ;;
    start)
        if [ -z "$WORKER" ]; then
            echo "ERROR: --worker required for action 'start'" >&2
            exit 1
        fi
        action_start "$WORKER"
        ;;
    update-model)
        if [ -z "$WORKER" ] || [ -z "$MODEL" ]; then
            echo "ERROR: --worker and --model required for action 'update-model'" >&2
            exit 1
        fi
        action_update_model "$WORKER" "$MODEL"
        ;;
    *)
        echo "ERROR: Unknown action '$ACTION'. Use: sync-status, check-idle, stop, start, update-model" >&2
        exit 1
        ;;
esac
