---
name: file-sync
description: Sync files with centralized storage. Use when Manager or another Worker notifies you of file updates (config changes, task files, shared data, collaboration artifacts).
---

# File Sync (CoPaw Worker)

When the Manager or another Worker notifies you that files have been updated in centralized storage (e.g., config changes, task briefs, shared data, collaboration artifacts), trigger an immediate sync:

```bash
python3 /opt/hiclaw/copaw/agent/skills/file-sync/scripts/copaw-sync.py
```

This pulls the latest files from MinIO and re-bridges the config. CoPaw automatically hot-reloads config changes within ~2 seconds.

**Automatic background sync:**
- Background sync also runs every 300 seconds (5 minutes) as a fallback
- Config changes are automatically detected and hot-reloaded
- Skills are automatically re-synced when changed

**When to use:**
Any time you are told that new files are available, configs have changed, or another agent has written something you need to read.

Always confirm to the sender after sync completes.

**Example workflow:**
```bash
# Manager notifies: "Your config has been updated, please run hiclaw-sync"
python3 /opt/hiclaw/copaw/agent/skills/file-sync/scripts/copaw-sync.py
# Output: ✓ Synced 1 file(s): openclaw.json
#         ✓ Config re-bridged. CoPaw will hot-reload automatically.

# Confirm to Manager
"Config synced successfully! Using new settings now."
```
