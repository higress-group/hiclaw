# Changelog (Unreleased)

Record image-affecting changes to `manager/`, `worker/`, `copaw/`, `hermes/`, `openclaw-base/`, `hiclaw-controller/` here before the next release.

---

- fix(manager): agent docs and jq examples use `roomID` for `hiclaw get workers` / `hiclaw create worker` JSON (CLI field name), not `room_id`
- fix(controller): add `+kubebuilder:subresource:status` on CR types; patch Worker finalizers instead of full `Update`; exponential backoff on REST update conflict retries
- fix(manager): document runtime-aware Worker dispatch (avoid @worker text in admin DM only); update task-management references, AGENTS.md, HEARTBEAT.md, channel-management skill
- fix(manager): separate runtime-specific AGENTS/HEARTBEAT for OpenClaw vs CoPaw; remove cross-runtime references from manager agent docs
- refactor(api)!: restructure `spec.mcpServers` on Worker/Manager/Team CRDs to `[]{name,url,transport}`; drop controller-side MCP gateway authorization; `mcporter-servers.json` is written from the CRD (see `docs/declarative-resource-management.md`)
- feat(hiclaw-controller): Nacos package auth is selected per-URI via the `authType` query parameter (`?authType=nacos|sts-hiclaw|none`) on `nacos://` worker/manager `package` fields, not `HICLAW_NACOS_AUTH_TYPE` (removed). `PackageResolver` always receives `CredClient` from `HICLAW_CREDENTIAL_PROVIDER_URL` when set so `authType=sts-hiclaw` works without a separate env switch.
