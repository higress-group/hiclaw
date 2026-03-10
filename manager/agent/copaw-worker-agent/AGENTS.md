# CoPaw Worker Agent Workspace

This workspace is your home. Everything you need is here — config, skills, memory, and task files.

You are a **CoPaw Worker** — a Python-based agent. You may be running inside a container or as a pip-installed process on the host machine. Your workspace layout differs from OpenClaw workers.

## Workspace Layout

- **Your agent files:** `~/.copaw-worker/<your-name>/.copaw/` (config.json, providers.json, SOUL.md, AGENTS.md, active_skills/)
- **Shared space:** accessible via MinIO using `mc` CLI (tasks, knowledge, collaboration data)
- **MinIO alias:** `hiclaw` (pre-configured at startup)
- **MinIO bucket:** `hiclaw-storage`

There is **no** `~/hiclaw-fs/` directory. All shared files must be accessed via `mc` commands.

## Accessing Shared Files

To read a task spec or shared file, pull it from MinIO:

```bash
# Pull a specific task directory
mc mirror hiclaw/hiclaw-storage/shared/tasks/{task-id}/ ~/tasks/{task-id}/

# Pull a single file
mc cp hiclaw/hiclaw-storage/shared/tasks/{task-id}/spec.md ~/tasks/{task-id}/spec.md

# Push your results back
mc mirror ~/tasks/{task-id}/ hiclaw/hiclaw-storage/shared/tasks/{task-id}/ --overwrite --exclude "spec.md" --exclude "base/"
```

## Every Session

Before doing anything:

1. Read `SOUL.md` — your identity, role, and rules
2. Read `memory/YYYY-MM-DD.md` (today + yesterday) for recent context

## Memory

You wake up fresh each session. Files are your continuity:

- **Daily notes:** `~/.copaw-worker/<your-name>/.copaw/memory/YYYY-MM-DD.md`
- **Long-term:** `~/.copaw-worker/<your-name>/.copaw/MEMORY.md`

Push memory files to MinIO so they survive restarts:

```bash
mc cp ~/.copaw-worker/<your-name>/.copaw/memory/YYYY-MM-DD.md \
   hiclaw/hiclaw-storage/agents/<your-name>/memory/YYYY-MM-DD.md
```

## Skills

Your skills live in `~/.copaw-worker/<your-name>/.copaw/active_skills/`. Each skill directory contains a `SKILL.md` explaining how to use it.

The Manager assigns and updates skills. When notified of skill updates, use your `file-sync` skill to pull the latest.

## Communication

You live in one or more Matrix Rooms with the **Human admin** and the **Manager**:
- **Your Worker Room** (`Worker: <your-name>`): private 3-party room (Human + Manager + you)
- **Project Room** (`Project: <title>`): shared room with all project participants when you are part of a project

Always @mention the recipient when sending messages in a room.

## MinIO Access

Your MinIO credentials are set as environment variables at startup:
- `COPAW_MINIO_ENDPOINT` — MinIO endpoint (e.g., `http://fs-local.hiclaw.io:18080`)
- `COPAW_MINIO_ACCESS_KEY` — your worker name
- `COPAW_MINIO_SECRET_KEY` — your secret key
- `COPAW_MINIO_BUCKET` — bucket name (default: `hiclaw-storage`)

The `mc` alias `hiclaw` is pre-configured using these credentials.
