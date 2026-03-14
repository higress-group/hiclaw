# Changelog (Unreleased)

Record image-affecting changes to `manager/`, `worker/`, `openclaw-base/` here before the next release.

---

- fix(manager): clean orphaned session write locks before starting OpenClaw to prevent "session file locked (timeout)" after SIGKILL or crash
- fix(worker): Remote->Local sync pulls Manager-managed files only (allowlist) to avoid overwriting Worker-generated content (e.g. .openclaw sessions, memory)
- fix(copaw): align sync ownership with OpenClaw worker (AGENTS.md/SOUL.md Worker-managed, push but never pull; allowlist for Remote->Local)
- fix(manager): switch Matrix room preset from `private_chat` back to `trusted_private_chat` so Workers are auto-joined without needing to accept invites; use `power_level_content_override` to keep Workers at power level 0
- feat(manager): add unified `setup-mcp-server.sh` script to mcp-server-management skill for runtime MCP server creation/update (GitHub as special case with DNS service source); simplify SKILL.md to script-first approach
- refactor(manager): remove `credential-key` positional arg from `setup-mcp-server.sh` — use unified `accessToken` key for all YAML configs
- feat(manager): `setup-mcp-server.sh` now generates Manager's own mcporter-servers.json, creates Worker mcporter config if missing, reads Worker gateway key from creds file instead of registry; pushes to MinIO via `mc cp`
- fix(worker): always set MCPORTER_CONFIG env var in worker-entrypoint.sh (even if file not yet present) so mcporter works after file-sync pulls config
- feat(manager): add `--no-reasoning` flag to model-switch and worker-model-switch scripts to allow disabling reasoning; patch `reasoning` field in openclaw.json during model switch
- refactor(manager): remove Local->Remote background sync from start-mc-mirror.sh; all writes now push to MinIO explicitly via mc cp/mirror in skill scripts
- refactor(manager): add explicit `mc cp` push steps to task-management and project-management SKILL.md after writing task files locally
- refactor(manager): add on-demand `mc mirror` pull in task/project completion flows so Manager reads fresh Worker results from MinIO
- docs(manager,worker,copaw): unify file sync design principle comments — writer pushes and notifies via Matrix, receiver pulls on demand, 5-min periodic pull as fallback only

