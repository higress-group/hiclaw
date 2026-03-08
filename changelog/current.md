# Changelog (Unreleased)

Record image-affecting changes to `manager/`, `worker/`, `openclaw-base/` here before the next release.

---

- fix: set container timezone from TZ env var in both Manager and Worker (install tzdata in base image, configure /etc/localtime and /etc/timezone at startup)
- feat(manager): add User-Agent header (HiClaw/<version>) to default AI route via headerControl, and send it in LLM connectivity tests ([3242d06](https://github.com/higress-group/hiclaw/commit/3242d0630d196c35b5df6fd6fbd7ac6e6b72c08a))
- feat(openclaw-base): install cron package in base image, start crond in Manager (supervisord) and Worker (entrypoint)
- feat(manager): add `--runtime copaw` support to `create-worker.sh`; copaw workers are pip-installed Python processes (not containers), registry tracks `runtime` field, lifecycle scripts skip copaw workers automatically
- feat(copaw): add `copaw/` package — HiClaw's CoPaw Worker runtime (`copaw-worker` CLI) that bridges openclaw.json → CoPaw config, implements MatrixChannel, and syncs config from MinIO
- fix(manager): copaw install command now uses `HICLAW_PORT_GATEWAY` (external port) instead of internal `:8080` so the command works on the host machine
