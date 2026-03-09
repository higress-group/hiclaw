---
name: task-management
description: Assign and track tasks for Worker Agents. Use when the human admin gives a task to delegate, when a Worker reports completion, or when managing recurring scheduled tasks.
---

# Task Management

## Step 0: Worker Availability Check (when no Worker is explicitly specified)

**Trigger**: Admin gives a task without naming a Worker.

1. Check existing Workers and workload: `cat ~/workers-registry.json && cat ~/state.json`
2. Present options to admin:
   - **Option A** — Assign to an idle existing Worker (list name + role + status)
   - **Option B** — Create a new Worker (suggest name/role/skills/model based on task type; ask about find-skills, see Step 4)
   - **Option C** — Handle it yourself (note: broader system access than Workers; use isolated Worker for untrusted inputs)
3. Act on choice: A → container check then assign; B → create Worker then assign; C → work directly (no task directory needed)

**Skip Step 0 when**: admin explicitly names a Worker, says "do it yourself", or it's a heartbeat-triggered infinite task. In YOLO mode, decide autonomously.

**Step 4 — Find-Skills (only when creating a new Worker):**

Check default: `echo "${HICLAW_SKILLS_API_URL:-https://skills.sh}"`

Ask admin: enable find-skills (recommended) or disable; optionally provide custom registry URL. Pass to `create-worker.sh` via `--find-skills` / `--skills-api-url`.

---

## Before Assigning Tasks: Container Status Check

1. Check status: `bash -c 'source /opt/hiclaw/scripts/lib/container-api.sh && container_status_worker "<name>"'`
2. **stopped** → wake up: `lifecycle-worker.sh --action start --worker <name>`, wait 30s, then assign
3. **not_found** → notify admin, Worker must be recreated via `create-worker.sh`
4. **running** or no container API → assign directly

---

## Assigning a Finite Task

1. Generate task ID: `task-YYYYMMDD-HHMMSS`
2. Create task directory and write files:
   ```bash
   mkdir -p /root/hiclaw-fs/shared/tasks/{task-id}
   # meta.json
   {
     "task_id": "task-YYYYMMDD-HHMMSS",
     "type": "finite",
     "assigned_to": "<worker-name>",
     "room_id": "<room-id>",
     "status": "assigned",
     "assigned_at": "<ISO-8601>",
     "completed_at": null
   }
   # spec.md — complete requirements, acceptance criteria, context
   ```
3. Notify Worker in their Room:
   ```
   @{worker}:{domain} New task [{task-id}]: {title}. Use your file-sync skill to pull the spec: hiclaw/hiclaw-storage/shared/tasks/{task-id}/spec.md. @mention me when complete.
   ```
   - If Worker has `find-skills` skill (`test -d /root/hiclaw-fs/agents/{worker}/skills/find-skills`), add: `💡 Run \`skills find <keyword>\` if you need additional capabilities.`
4. Add to `state.json` `active_tasks`
5. On completion: update `meta.json` status=completed + completed_at, remove from `state.json`, log to `memory/YYYY-MM-DD.md`

**Task directory layout:**
```
shared/tasks/{task-id}/
├── meta.json     # Manager-maintained
├── spec.md       # Manager-written
├── base/         # Manager-maintained reference files (Workers must not overwrite)
├── plan.md       # Worker-written execution plan
├── result.md     # Worker-written final result
└── *             # Intermediate artifacts
```

---

## Infinite Task Workflow

For recurring/scheduled tasks:

1. Create task directory and write files:
   ```bash
   # meta.json
   {
     "task_id": "task-YYYYMMDD-HHMMSS",
     "type": "infinite",
     "assigned_to": "<worker-name>",
     "room_id": "<room-id>",
     "status": "active",
     "schedule": "0 9 * * *",
     "timezone": "Asia/Shanghai",
     "assigned_at": "<ISO-8601>"
   }
   # spec.md — task spec including per-run execution guidelines
   ```
   - `status` is always `"active"`, never `"completed"`
   - `schedule`: standard 5-field cron; `timezone`: tz database name
2. Add to `state.json` with scheduling fields
3. Heartbeat triggers when `now > next_scheduled_at + 30min` and `last_executed_at < next_scheduled_at`
4. Trigger message: `@{worker}:{domain} Execute recurring task {task-id}: {title}. Report back with "executed" when done.`
5. On execution: update `last_executed_at`, recalculate `next_scheduled_at` in `state.json`

---

## State File (state.json)

Path: `~/state.json`

Single source of truth for active tasks. Heartbeat reads this instead of scanning all meta.json files.

### Structure

```json
{
  "active_tasks": [
    {
      "task_id": "task-20260219-120000",
      "type": "finite",
      "assigned_to": "alice",
      "room_id": "!xxx:matrix-domain"
    },
    {
      "task_id": "task-20260219-130000",
      "type": "infinite",
      "assigned_to": "bob",
      "room_id": "!yyy:matrix-domain",
      "schedule": "0 9 * * *",
      "timezone": "Asia/Shanghai",
      "last_executed_at": null,
      "next_scheduled_at": "2026-02-20T01:00:00Z"
    }
  ],
  "updated_at": "2026-02-19T15:00:00Z"
}
```

### Maintenance Rules

| When | Action |
|------|--------|
| Assign a finite task | Add entry to `active_tasks` (type=finite) |
| Create an infinite task | Add entry to `active_tasks` (type=infinite, with schedule/timezone/next_scheduled_at) |
| Finite task completed | Remove the task_id from `active_tasks` |
| Infinite task executed | Update `last_executed_at`, recalculate `next_scheduled_at` |
| After every write | Update `updated_at` (no sync needed — local only) |

If `~/state.json` does not exist yet, create it with `{"active_tasks": [], "updated_at": "<ISO-8601>"}`.
