---
name: file-sharing
description: Use immediately when a task mentions shared files, shared/tasks paths, file-sync, missing specs, or pushing task results.
---

# File Sharing

Use local shared paths only. Do not expose storage internals.

## Local Paths

Use:

- `shared/tasks/{task-id}/`
- `shared/projects/{project-id}/` only for read-only project context

Do not use in chat, task outputs, or normal reasoning:

- `hiclaw/hiclaw-storage/...`
- `teams/{team}/shared/...`
- `/root/hiclaw-fs/...`
- `/root/.hiclaw-worker/...`

## Pull Latest Files

When your coordinator assigns a task or mentions any `shared/...` path, run this before reading files:

```bash
copaw-sync
```

Then read local paths. For a task, the first file to read is always:

```bash
cat shared/tasks/{task-id}/spec.md
```

Do not decide that `shared/` or `spec.md` is missing until after `copaw-sync` finishes.

## Push Task Results

After meaningful updates, push only your task directory:

```bash
bash ./skills/file-sharing/scripts/push-shared.sh tasks/{task-id}/ --exclude "spec.md" --exclude "base/"
```

The helper detects team vs standalone storage and publishes to the correct remote path.

## If You Cannot Find Files

1. Run `copaw-sync`.
2. Check `pwd`, then check the local relative path from the task message:

   ```bash
   pwd
   ls -la
   ls -la shared/tasks/{task-id}/
   ```

3. If still missing, @mention your coordinator with the sync command outcome and the exact local path you checked:

```text
@coordinator:domain BLOCKED: I ran file-sync but cannot find shared/tasks/{task-id}/spec.md.
```

Do not search random container absolute paths or create the missing task directory yourself.
