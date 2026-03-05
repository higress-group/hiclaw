# Changelog (Unreleased)

Record image-affecting changes to `manager/`, `worker/`, `openclaw-base/` here before the next release.

---

- feat(manager): add model-switch skill with `update-manager-model.sh` script for runtime model switching
- feat(manager): add task-management skill (extracted from AGENTS.md) covering task workflow and state file spec
- feat(manager): add `manager/scripts/lib/builtin-merge.sh` — shared library for idempotent builtin section merging
- fix(manager): fix `upgrade-builtins.sh` duplicate-insertion bug — awk now uses exact line match instead of substring, preventing repeated marker injection on re-run
- fix(manager): detect and auto-repair corrupted AGENTS.md (wrong marker count) by force-rewriting builtin section while preserving user content
- feat(manager): expand worker-management skill and `lifecycle-worker.sh` with improved worker lifecycle handling
- fix(manager): `setup-higress.sh` — multiple route/consumer/MCP init fixes
- fix(manager): `start-manager-agent.sh` — wait for Tuwunel Matrix API ready before proceeding, add detailed logging for token acquisition
- fix(manager): support Podman by replacing hardcoded `docker` commands with runtime detection; fix `jq` availability inside container; fix provider switch menu text
