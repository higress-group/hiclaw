# Manager Guide

Detailed guide for setting up and configuring the HiClaw Manager.

## Installation

See [quickstart.md](quickstart.md) Step 1 for basic installation.

## Configuration

The Manager is configured via environment variables set during installation. The installer generates a `.env` file with all settings.

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `HICLAW_LLM_API_KEY` | Yes | - | LLM API key |
| `HICLAW_LLM_PROVIDER` | No | `qwen` | LLM provider name (qwen, openai, etc.) |
| `HICLAW_DEFAULT_MODEL` | No | `qwen3.5-plus` | Default model ID |
| `HICLAW_ADMIN_USER` | No | `admin` | Human admin Matrix username |
| `HICLAW_ADMIN_PASSWORD` | No | (auto-generated) | Human admin password |
| `HICLAW_MATRIX_DOMAIN` | No | `matrix-local.hiclaw.io:8080` | Matrix server domain |
| `HICLAW_MATRIX_CLIENT_DOMAIN` | No | `matrix-client-local.hiclaw.io` | Element Web domain |
| `HICLAW_AI_GATEWAY_DOMAIN` | No | `llm-local.hiclaw.io` | AI Gateway domain |
| `HICLAW_FS_DOMAIN` | No | `fs-local.hiclaw.io` | File system domain |
| `HICLAW_GITHUB_TOKEN` | No | - | GitHub PAT for MCP Server |
| `HICLAW_WORKER_IMAGE` | No | `hiclaw/worker-agent:latest` | Worker Docker image for direct creation |

### Customizing the Manager Agent

The Manager Agent's behavior is defined by three files in MinIO:

1. **SOUL.md** - Agent identity, security rules, communication model
2. **HEARTBEAT.md** - Periodic check routine (every 15 minutes)
3. **AGENTS.md** - Available skills and task workflow

To customize, edit these files in MinIO Console (http://localhost:9001) under `hiclaw-storage/agents/manager/`.

### Adding Skills

Skills are self-contained SKILL.md files placed in `agents/manager/skills/<skill-name>/SKILL.md`. OpenClaw auto-discovers skills from this directory.

To add a new skill:
1. Create directory: `agents/manager/skills/<your-skill-name>/`
2. Write `SKILL.md` with complete API reference and examples
3. The Manager Agent will discover it automatically (~300ms)

### Managing MCP Servers

To add a new MCP Server (e.g., GitLab, Jira):

1. Configure the MCP Server in Higress Console
2. Add the MCP Server entry via Higress API: `PUT /v1/mcpServer`
3. Authorize consumers: `PUT /v1/mcpServer/consumers`
4. Create a skill for Workers that documents the available tools

## Monitoring

### Logs

```bash
# All component logs (combined stdout/stderr)
docker logs hiclaw-manager -f

# Specific component logs (inside container)
docker exec hiclaw-manager cat /var/log/hiclaw/manager-agent.log
docker exec hiclaw-manager cat /var/log/hiclaw/tuwunel.log
docker exec hiclaw-manager cat /var/log/hiclaw/higress-console.log

# OpenClaw runtime log (agent events, tool calls, LLM interactions)
docker exec hiclaw-manager bash -c 'cat /tmp/openclaw/openclaw-*.log' | jq .
```

### Replay Conversation Logs

After running `make replay`, conversation logs are saved automatically:

```bash
# View the latest replay log
make replay-log

# Logs are stored in logs/replay/replay-{timestamp}.log
```

### Health Checks

```bash
# Check individual services
curl -s http://127.0.0.1:6167/_matrix/client/versions   # Matrix
curl -s http://127.0.0.1:9000/minio/health/live          # MinIO
curl -s http://127.0.0.1:8001/                            # Higress Console
```

### Consoles

- **Higress Console**: http://localhost:8001 - Gateway management, routes, consumers
- **MinIO Console**: http://localhost:9001 - File system browsing, agent configs
- **Element Web**: http://matrix-client-local.hiclaw.io:8080 - IM interface

## Backup and Recovery

### Data Volume

All persistent data is stored in the `hiclaw-data` Docker volume:
- Tuwunel database (Matrix history)
- MinIO storage (Agent configs, task data)
- Higress configuration

Additionally, the user's home directory can be shared with agents for file access:

#### Home Directory Sharing (Optional)
You can optionally share the user's home directory with agents:
- By default, `$HOME` is available at `/host-share` inside the container
- A symlink is created from the original host home path (e.g., `/home/zhangty`) to `/host-share`
- Agents can access and manipulate files using the same paths as on the host
- This enables seamless file access between host and agents using consistent paths
- To enable this feature, the installer will prompt for the directory to share (default: $HOME)

### Backup

```bash
docker run --rm -v hiclaw-data:/data -v $(pwd):/backup ubuntu \
  tar czf /backup/hiclaw-backup-$(date +%Y%m%d).tar.gz /data
```

### Restore

```bash
docker run --rm -v hiclaw-data:/data -v $(pwd):/backup ubuntu \
  tar xzf /backup/hiclaw-backup-YYYYMMDD.tar.gz -C /
```

### Directory Structure

The system maintains the Docker volume for persistent storage and can optionally share the host directory:

- `hiclaw-data` Docker volume: Contains all persistent system data
- Host `$HOME` directory: Optionally shared to container at `/host-share`
- Inside container: Original host path (e.g., `/home/zhangty`) via symlink to `/host-share` when available
- This provides consistent file paths between host and container environments when sharing is enabled

This allows agents to directly read and write files from the host system using identical paths when directory sharing is enabled,
facilitating file transfer and processing workflows with path consistency.

### Example Usage

```bash
# Example 1: Install with home directory sharing (recommended)
HICLAW_LLM_API_KEY=your-key-here ./install/hiclaw-install.sh manager

# Example 2: Place files in home directory for agent access
mkdir -p ~/project-inputs/
echo "Sample data" > ~/project-inputs/sample.txt

# Example 3: Agent can access files at the same path in container as on host
# Host path: /home/zhangty/project-inputs/sample.txt
# Container path: /home/zhangty/project-inputs/sample.txt (via symlink)

# Example 4: Use in agent configuration to access host files
# In agent configuration, refer to files using the same path as host:
# Host: /home/zhangty/data/input.txt
# Container: /home/zhangty/data/input.txt (identical path via symlink)
```
