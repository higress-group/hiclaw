# Changelog (Unreleased)

Record image-affecting changes to `manager/`, `worker/`, `openclaw-base/` here before the next release.

---

- fix(manager): allow unstable room versions in Tuwunel to fix room version 11 error
- feat(manager): reduce default context windows (qwen3.5-plus: 960k→200k, unknown models: 200k→150k) and support `--context-window` override for unknown models in model-switch skills
- feat(manager): switch group session reset from idle (2880min) to daily at 04:00, matching DM sessions; remove keepalive mechanism (session-keepalive.sh, notify-admin-keepalive.sh, HEARTBEAT step 7, AGENTS.md keepalive response section)
