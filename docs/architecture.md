# HiClaw Architecture

## System Overview

HiClaw is an Agent Teams system that enables multiple AI Agents to collaborate via instant messaging (Matrix protocol) with human oversight.

```mermaid
graph TB
    subgraph Manager Container
        HG[Higress AI Gateway<br/>:8080 internal]
        HC[Higress Console<br/>:8001 internal]
        TW[Tuwunel Matrix Server<br/>:6167 internal]
        EW[Element Web / Nginx<br/>:8088 internal]
        MO[MinIO<br/>:9000 / :9001 internal]
        MA[Manager Agent<br/>OpenClaw]
        MC[mc mirror]
    end

    subgraph Worker Container - Alice
        WA[Worker Agent<br/>OpenClaw]
        WMC[mc]
        WMP[mcporter]
    end

    subgraph Worker Container - Bob
        WB[Worker Agent<br/>OpenClaw]
        WMC2[mc]
        WMP2[mcporter]
    end

    Human[Human Admin<br/>Browser] -->|Element Web| HG
    Human -->|IM| TW
    
    HG -->|Matrix| TW
    HG -->|Files| MO
    HG -->|LLM API| LLM[LLM Provider]
    HG -->|MCP| GitHub[GitHub API]
    
    MA -->|Matrix| TW
    MA -->|Higress API| HC
    MC <-->|sync| MO

    WA -->|Matrix via Gateway| HG
    WMC <-->|file sync| MO
    WMP -->|MCP tools| HG
    
    WB -->|Matrix via Gateway| HG
    WMC2 <-->|file sync| MO
    WMP2 -->|MCP tools| HG
```

## Component Details

### AI Gateway (Higress)

Higress serves as the unified entry point for all external access:

| Port | Service | Purpose |
|------|---------|---------|
| 8080 | Gateway | Reverse proxy for all domain-based routing (exposed as 18080 by default) |
| 8001 | Console | Management API (Session Cookie auth, exposed as 18001 by default) |

**Routes configured:**
- `matrix-local.hiclaw.io` -> Tuwunel (port 6167) - Matrix Homeserver
- `matrix-client-local.hiclaw.io` -> Element Web (port 8088) - IM web client
- `fs-local.hiclaw.io` -> MinIO (port 9000) - HTTP file system (auth required)
- `aigw-local.hiclaw.io` -> AI Gateway - LLM proxy + MCP servers (auth required)

> All domain-based routes go through the gateway on port 8080 (host: 18080). Element Web is also directly accessible on host port 18088 (maps to container port 8088).

### Matrix Homeserver (Tuwunel)

Tuwunel is a high-performance Matrix Homeserver (conduwuit fork):
- Runs on port 6167
- Manages all IM communication between Human, Manager, and Workers
- Uses `CONDUWUIT_` environment variable prefix
- Single-step registration with token (no UIAA flow)

### HTTP File System (MinIO)

MinIO provides centralized file storage accessible via HTTP:
- Port 9000 (API) and 9001 (Console)
- `mc mirror --watch` provides real-time local<->remote sync
- All Agent configs, task briefs, and results stored here

### Manager Agent (OpenClaw)

The Manager Agent coordinates the entire team:
- Receives tasks from human via Matrix DM **or any other configured channel** (Discord, Feishu, Telegram, etc.)
- Creates Workers (Matrix accounts + Higress consumers + config files)
- Assigns and tracks tasks
- Runs heartbeat checks (triggered by OpenClaw's built-in heartbeat mechanism)
- Manages credentials and access control
- Automatically stops idle Worker containers and restarts them on task assignment
- Routes daily notifications to the admin's **primary channel** (with Matrix DM fallback)
- Supports **cross-channel escalation**: sends urgent questions to the admin's primary channel and routes replies back to originating Matrix rooms

### Worker Agent (OpenClaw)

Workers are lightweight, stateless containers:
- Pull all config from MinIO on startup
- Communicate via Matrix Rooms (Human + Manager + Worker in each Room)
- Use mcporter CLI to call MCP Server tools (GitHub, etc.)
- Can be destroyed and recreated without losing state
- Manager can create Workers directly via the host container runtime socket (Docker/Podman), or provide a `docker run` command for manual/remote deployment

## Security Model

```
┌──────────────────────────────────────┐
│            Higress Gateway           │
│   Consumer key-auth (BEARER token)   │
│                                      │
│  manager: full access                │
│  worker-alice: AI + FS + MCP(github) │
│  worker-bob:   AI + FS              │
└──────────────────────────────────────┘
```

- Each Worker has a unique Consumer with key-auth BEARER token
- Manager controls which routes and MCP Servers each Worker can access
- External API credentials (GitHub PAT, etc.) stored centrally in MCP Server config
- Workers never see external API credentials directly

## Communication Model

All communication happens in Matrix Rooms with Human-in-the-Loop:

```
Room: "Worker: Alice"
├── Members: @admin, @manager, @alice
├── Manager assigns task -> visible to all
├── Alice reports progress -> visible to all
├── Human can intervene anytime -> visible to all
└── No hidden communication between Manager and Worker
```

## File System Layout

### Manager Workspace (local only, host-mountable)

The Manager's own working directory lives on the host and is bind-mounted into the container. It is never synced to MinIO.

- **Default host path**: `~/hiclaw-manager` (configurable via `HICLAW_WORKSPACE_DIR` at install time)
- **Container path**: `/root/manager-workspace` (set as `HOME` for the Manager Agent process, so `~` resolves here)

```
~/hiclaw-manager/            # Host path (bind-mounted to /root/manager-workspace in container, which is the agent's HOME)
├── SOUL.md                  # Manager identity (copied from image on first boot)
├── AGENTS.md                # Workspace guide
├── HEARTBEAT.md             # Heartbeat checklist
├── openclaw.json            # Generated config (regenerated each boot)
├── skills/                  # Manager's own skills
├── worker-skills/           # Worker skill definitions (pushed to workers via mc cp)
├── workers-registry.json    # Worker skill assignments and room IDs
├── state.json               # Active task state
├── worker-lifecycle.json    # Worker container status and idle tracking
├── primary-channel.json     # Admin's preferred primary channel for proactive notifications
├── trusted-contacts.json    # Non-admin contacts allowed to converse with the Manager
├── coding-cli-config.json   # Coding CLI delegation config (enabled, cli tool name)
├── yolo-mode                # If present, enables YOLO mode (autonomous decisions, no admin prompts)
├── .session-scan-last-run   # Timestamp of last Matrix session expiry scan
└── memory/                  # Manager's memory files (MEMORY.md, YYYY-MM-DD.md)
```

### MinIO Object Storage (shared between Manager and Workers)

Synced to `~/hiclaw-fs/` locally on the Manager side via `mc mirror`.

```
MinIO bucket: hiclaw-storage/   (mirrored to ~/hiclaw-fs/ on Manager)
├── agents/
│   ├── alice/           # Worker Alice config
│   │   ├── SOUL.md
│   │   ├── openclaw.json
│   │   ├── skills/
│   │   └── mcporter-servers.json
│   └── bob/             # Worker Bob config
├── shared/
│   ├── tasks/           # Task specs, metadata, and results
│   │   └── task-{id}/
│   │       ├── meta.json    # Task metadata (assigned_to, status, timestamps)
│   │       ├── spec.md      # Complete task spec (written by Manager)
│   │       ├── base/        # Manager-maintained reference files (codebase, docs, etc.)
│   │       └── result.md    # Task result (written by Worker)
│   └── knowledge/       # Shared reference materials
└── workers/             # Worker work products
```
