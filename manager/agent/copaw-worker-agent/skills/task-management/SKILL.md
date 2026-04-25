---
name: task-management
description: Use when executing an assigned Worker task, tracking progress, or reporting completion.
---

# Task Management

You are a Worker. Execute only your assigned task.

## Task Directory

All work for a task stays under:

```text
shared/tasks/{task-id}/
```

Your coordinator owns:

```text
shared/tasks/{task-id}/spec.md
shared/tasks/{task-id}/meta.json
shared/tasks/{task-id}/base/
```

You own:

```text
shared/tasks/{task-id}/plan.md
shared/tasks/{task-id}/result.md
shared/tasks/{task-id}/workspace/
shared/tasks/{task-id}/progress/
shared/tasks/{task-id}/<deliverables>
```

Do not edit project-level `shared/projects/{project-id}/plan.md` or `meta.json` unless the task spec explicitly tells you to.

## Execution Flow

1. Run `copaw-sync` with the `file-sharing` skill. This is mandatory whenever the task references `shared/...`; do it before checking whether `spec.md` exists.
2. Read `shared/tasks/{task-id}/spec.md`.
3. Create `shared/tasks/{task-id}/plan.md`.
4. Execute the task.
5. Keep deliverables inside `shared/tasks/{task-id}/`.
6. Push after meaningful updates:

   ```bash
   bash ./skills/file-sharing/scripts/push-shared.sh tasks/{task-id}/ --exclude "spec.md" --exclude "base/"
   ```

7. Write `shared/tasks/{task-id}/result.md`.
8. Final push.
9. @mention your coordinator with completion:

   ```text
   @coordinator:domain TASK_COMPLETED: {task-id} - <short outcome>. Result: shared/tasks/{task-id}/result.md
   ```

## Blocked

If blocked, stop and @mention your coordinator:

```text
@coordinator:domain BLOCKED: {task-id} - <what is blocking you>
```

Do not invent missing task files, project plans, or shared directories.

## Progress

Progress notes are optional unless the task spec asks for them. If you write progress, put it under:

```text
shared/tasks/{task-id}/progress/YYYY-MM-DD.md
```

Progress updates that require no decision should not @mention anyone.
