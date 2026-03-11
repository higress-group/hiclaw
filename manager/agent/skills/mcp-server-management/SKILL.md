---
name: mcp-server-management
description: Manage MCP Servers on the Higress AI Gateway -- create, update, list, delete servers, and control consumer access. Use when configuring MCP tool servers (e.g., GitHub, Amap) or granting/revoking worker access to MCP tools.
---

# MCP Server Management

## Overview

This skill allows you to manage MCP (Model Context Protocol) Servers on the Higress AI Gateway. MCP Servers expose REST APIs as MCP tools that agents can invoke. The Higress gateway acts as a proxy, translating MCP tool calls into REST API requests based on the server's YAML configuration.

Pre-configured MCP server YAML templates are stored in `/opt/hiclaw/agent/skills/mcp-server-management/references/mcp-*.yaml`. These templates define the server metadata, credentials placeholder, and all available tools.

## Environment Variables

These environment variables are pre-configured in the Manager container:

```bash
# Core configuration (set by hiclaw-install.sh)
HICLAW_AI_GATEWAY_DOMAIN  # AI Gateway domain (e.g., aigw-local.hiclaw.io)
HIGRESS_COOKIE_FILE       # Path to session cookie file

# Optional credentials (may be empty if not configured)
HICLAW_GITHUB_TOKEN       # GitHub Personal Access Token for mcp-github
```

No need to set defaults - these are always available in the container environment.

## Authentication

Use the session cookie file at `${HIGRESS_COOKIE_FILE}`:

```bash
curl -b "${HIGRESS_COOKIE_FILE}" ...
```

## Understanding rawConfigurations

The Higress Console API requires MCP server tool definitions to be passed as a **YAML string** in the `rawConfigurations` field of the JSON body. This YAML defines:

### Structure

```yaml
server:
  name: <server-name>        # Internal server name
  config:                     # Server-level config (credentials, etc.)
    accessToken: "<token>"    # Example: GitHub PAT

tools:
- name: <tool-name>
  description: "<what the tool does>"
  args:
  - name: <arg-name>
    type: string              # string | number | integer | boolean | array | object
    required: true
    description: "<arg description>"
  requestTemplate:
    url: "https://api.example.com/..."   # Supports Go templates: {{.args.name}}, {{.config.key}}
    method: GET                          # GET | POST | PUT | DELETE | PATCH
    headers:
    - key: Authorization
      value: "Bearer {{.config.accessToken}}"
    body: |                              # Optional, for POST/PUT/PATCH
      {"key": "{{.args.value}}"}
  responseTemplate:                      # Optional, transform response
    body: |
      {{.fieldName}}
```

### Template Variables

- `{{.args.<argName>}}` -- Reference tool arguments
- `{{.config.<key>}}` -- Reference server config values (e.g., accessToken)
- `{{.args.<array> | toJson}}` -- Serialize array/object args to JSON
- `{{.args.<str> | b64enc}}` -- Base64-encode a string argument

## Create / Update MCP Server

Use `PUT /v1/mcpServer` with the full server definition. This is an **upsert** operation.

### Using a Pre-configured Template

For servers with YAML templates in `/opt/hiclaw/agent/skills/mcp-server-management/references/`:

```bash
# 1. Read the YAML template and substitute credentials
MCP_YAML=$(sed 's|accessToken: ""|accessToken: "'"${HICLAW_GITHUB_TOKEN}"'"|' /opt/hiclaw/agent/skills/mcp-server-management/references/mcp-github.yaml)

# 2. Convert YAML to JSON-escaped string
RAW_CONFIG=$(printf '%s' "${MCP_YAML}" | jq -Rs .)

# 3. Create the MCP Server with rawConfigurations
curl -X PUT http://127.0.0.1:8001/v1/mcpServer \
  -b "${HIGRESS_COOKIE_FILE}" \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "mcp-github",
    "description": "GitHub MCP Server",
    "type": "OPEN_API",
    "rawConfigurations": '"${RAW_CONFIG}"',
    "mcpServerName": "mcp-github",
    "domains": ["${HICLAW_AI_GATEWAY_DOMAIN}"],
    "services": [{"name": "11.static", "port": 80, "version": null, "weight": 100}],
    "consumerAuthInfo": {
      "type": "key-auth",
      "enable": true,
      "allowedConsumers": ["manager"]
    }
  }'
```

### Available Templates

| Template File | Server Name | Config Key | Description |
|---|---|---|---|
| `mcp-github.yaml` | `mcp-github` | `accessToken` (GitHub PAT) | GitHub operations: repos, issues, PRs, code search |

### Creating a Custom MCP Server (No Template)

For ad-hoc MCP servers, write the YAML inline:

```bash
# Build a minimal YAML for a custom REST API
MCP_YAML='server:
  name: my-api-server
  config:
    apiKey: "my-secret-key"
tools:
- name: get_status
  description: "Get system status"
  args: []
  requestTemplate:
    url: "https://api.example.com/status"
    method: GET
    headers:
    - key: X-API-Key
      value: "{{.config.apiKey}}"'

RAW_CONFIG=$(printf '%s' "${MCP_YAML}" | jq -Rs .)

curl -X PUT http://127.0.0.1:8001/v1/mcpServer \
  -b "${HIGRESS_COOKIE_FILE}" \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "my-api",
    "description": "My Custom API",
    "type": "OPEN_API",
    "rawConfigurations": '"${RAW_CONFIG}"',
    "mcpServerName": "my-api",
    "domains": ["${HICLAW_AI_GATEWAY_DOMAIN}"],
    "services": [{"name": "11.static", "port": 80, "version": null, "weight": 100}],
    "consumerAuthInfo": {
      "type": "key-auth",
      "enable": true,
      "allowedConsumers": ["manager"]
    }
  }'
```

## Required Fields for PUT /v1/mcpServer

| Field | Type | Description |
|---|---|---|
| `name` | string | Unique MCP server name |
| `description` | string | Human-readable description |
| `type` | string | Always `"OPEN_API"` for REST-to-MCP servers |
| `rawConfigurations` | string | **YAML string** containing `server` and `tools` definitions |
| `mcpServerName` | string | Must match `name` |
| `domains` | array | Domain list (use `["${HICLAW_AI_GATEWAY_DOMAIN}"]` - AI Gateway serves both LLM and MCP) |
| `services` | array | Service backend (use `[{"name":"11.static","port":80,"version":null,"weight":100}]` as placeholder) |
| `consumerAuthInfo` | object | Auth config: `{"type":"key-auth","enable":true,"allowedConsumers":["manager"]}` |

## List MCP Servers

```bash
curl -s http://127.0.0.1:8001/v1/mcpServers -b "${HIGRESS_COOKIE_FILE}" | jq
```

## Get MCP Server Details

```bash
curl -s "http://127.0.0.1:8001/v1/mcpServer?name=mcp-github" -b "${HIGRESS_COOKIE_FILE}" | jq
```

## Delete MCP Server

```bash
curl -X DELETE "http://127.0.0.1:8001/v1/mcpServer?name=mcp-github" -b "${HIGRESS_COOKIE_FILE}"
```

## Consumer Authorization

### Authorize Consumers for an MCP Server

```bash
curl -X PUT http://127.0.0.1:8001/v1/mcpServer/consumers \
  -b "${HIGRESS_COOKIE_FILE}" \
  -H 'Content-Type: application/json' \
  -d '{
    "mcpServerName": "mcp-github",
    "consumers": ["manager", "worker-alice"]
  }'
```

**IMPORTANT**: This is a **replace** operation, not append. Always include ALL consumers that should have access.

### Revoke a Consumer's Access to One Server

Remove the consumer from the list and PUT the updated list:

```bash
# Keep only manager, revoke worker-alice
curl -X PUT http://127.0.0.1:8001/v1/mcpServer/consumers \
  -b "${HIGRESS_COOKIE_FILE}" \
  -H 'Content-Type: application/json' \
  -d '{
    "mcpServerName": "mcp-github",
    "consumers": ["manager"]
  }'
```

### Revoke a Consumer from ALL MCP Servers

```bash
curl -X DELETE "http://127.0.0.1:8001/v1/mcpServer/consumers?consumer=worker-alice" \
  -b "${HIGRESS_COOKIE_FILE}"
```

## Tool-Level Access Control

Use `allowTools` in the YAML to restrict which tools a server exposes:

```yaml
server:
  name: github-mcp-server
  config:
    accessToken: "..."
  allowTools:
    - search_repositories
    - get_file_contents
    - list_issues
```

When `allowTools` is specified, only the listed tools are available. If omitted, all tools defined in the `tools` array are exposed.

To update tool-level permissions, modify the `allowTools` section in the YAML and re-PUT the server with the updated `rawConfigurations`.

## Worker MCP Server Config File

When granting a Worker access to MCP servers, you also need to create a `mcporter-servers.json` config file so the Worker's agent runtime knows how to connect. Write this file to MinIO:

```bash
cat > ~/hiclaw-fs/agents/<WORKER_NAME>/mcporter-servers.json <<'EOF'
{
  "mcpServers": {
    "mcp-github": {
      "url": "http://<HIGRESS_GATEWAY>:8080/mcp-servers/mcp-github",
      "transport": "http",
      "headers": {
        "Authorization": "Bearer <WORKER_GATEWAY_KEY>"
      }
    }
  }
}
EOF
```

## Important Notes

- **rawConfigurations is required**: Without it, the MCP server has no tools and is an empty shell
- **YAML → JSON escaping**: Always use `jq -Rs .` to properly escape newlines, quotes, and special characters in the YAML before embedding in JSON
- **Auth plugin activation**: First MCP server creation takes ~40s for the auth plugin to activate; subsequent changes ~10s
- **SSE endpoint**: MCP Server SSE endpoint (`/mcp/<name>/sse`) always returns 200; auth is checked on `POST /mcp/<name>/message`
- **Template re-use**: To add a new MCP server type, add its YAML to `/opt/hiclaw/agent/skills/mcp-server-management/references/mcp-<name>.yaml` and follow the same pattern
- **Token substitution**: Use `sed` to substitute credential placeholders in YAML templates before converting to rawConfigurations

