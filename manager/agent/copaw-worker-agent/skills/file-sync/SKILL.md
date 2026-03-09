---
name: file-sync
description: Sync files with centralized storage. Use when Manager or another Worker notifies you of file updates (config changes, task files, shared data, collaboration artifacts).
---

# File Sync (CoPaw Worker)

## Sync agent config files

When the Manager notifies you that your config has been updated (e.g., model switch, skill update), trigger an immediate sync:

```bash
python3 /opt/hiclaw/agent/copaw-worker-agent/skills/file-sync/scripts/copaw-sync.py
```

This pulls `openclaw.json`, `SOUL.md`, `AGENTS.md`, and skills from MinIO and re-bridges the config. CoPaw automatically hot-reloads config changes within ~2 seconds.

**Automatic background sync:**
- Background sync also runs every 300 seconds (5 minutes) as a fallback
- Config changes are automatically detected and hot-reloaded

## Sync task / shared files

There is no `~/hiclaw-fs/` directory. Access shared files directly via `mc`. The MinIO path the Manager gives you maps to a local path you choose — by convention use `~/tasks/`:

| MinIO path | Local path (convention) |
|---|---|
| `hiclaw/hiclaw-storage/shared/tasks/{task-id}/` | `~/tasks/{task-id}/` |
| `hiclaw/hiclaw-storage/shared/projects/{project-id}/` | `~/projects/{project-id}/` |

```bash
# Pull a task directory from MinIO
mc mirror hiclaw/hiclaw-storage/shared/tasks/{task-id}/ ~/tasks/{task-id}/

# Read the spec
cat ~/tasks/{task-id}/spec.md

# Push your results back to MinIO
mc mirror ~/tasks/{task-id}/ hiclaw/hiclaw-storage/shared/tasks/{task-id}/ \
  --overwrite --exclude "spec.md" --exclude "base/"
```

**When to use:**
- When assigned a task: pull the task spec from MinIO before reading it
- When told files have been updated: pull the relevant path
- When you finish work: push results back to MinIO

Always confirm to the sender after sync completes.

**Example workflow:**
```bash
# Manager assigns task: "New task [task-20260309-120000]. Pull spec from MinIO."
mc mirror hiclaw/hiclaw-storage/shared/tasks/task-20260309-120000/ ~/tasks/task-20260309-120000/
cat ~/tasks/task-20260309-120000/spec.md

# ... do the work ...

# Push results
mc mirror ~/tasks/task-20260309-120000/ \
  hiclaw/hiclaw-storage/shared/tasks/task-20260309-120000/ \
  --overwrite --exclude "spec.md" --exclude "base/"

# Confirm to Manager
"Task complete. Results pushed to MinIO."
```