---
name: file-sync
description: Sync files with centralized storage. Use when Manager or another Worker notifies you of file updates (config changes, task files, shared data, collaboration artifacts).
---

# File Sync

When the Manager or another Worker notifies you that files have been updated in centralized storage, run:

```bash
hiclaw-sync
```

This mirrors MinIO to your local workspace:

| MinIO path | Local path |
|---|---|
| `hiclaw/hiclaw-storage/agents/<your-name>/` | `/root/hiclaw-fs/agents/<your-name>/` |
| `hiclaw/hiclaw-storage/shared/` | `/root/hiclaw-fs/shared/` |

So when the Manager gives you a MinIO path like `hiclaw/hiclaw-storage/shared/tasks/{task-id}/spec.md`, after running `hiclaw-sync` you can read it at `/root/hiclaw-fs/shared/tasks/{task-id}/spec.md`.

OpenClaw automatically detects config changes and hot-reloads within ~300ms.

**Always confirm** to the sender after sync completes.
