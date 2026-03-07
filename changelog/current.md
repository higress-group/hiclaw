# Changelog (Unreleased)

Record image-affecting changes to `manager/`, `worker/`, `openclaw-base/` here before the next release.

---

- fix(manager): skip LLM provider update if API key unchanged, avoid overwriting user modifications via Higress Console
- fix: set container timezone from TZ env var in both Manager and Worker (install tzdata in base image, configure /etc/localtime and /etc/timezone at startup)
- feat(manager): add User-Agent header (HiClaw/<version>) to default AI route via headerControl, and send it in LLM connectivity tests ([3242d06](https://github.com/higress-group/hiclaw/commit/3242d0630d196c35b5df6fd6fbd7ac6e6b72c08a))
