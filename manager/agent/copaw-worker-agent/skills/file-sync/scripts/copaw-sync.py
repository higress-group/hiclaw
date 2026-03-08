#!/usr/bin/env python3
"""
copaw-sync - Manual sync trigger for CoPaw Worker

Reads MinIO credentials from environment variables and triggers an immediate
sync of config files (openclaw.json, SOUL.md, AGENTS.md, skills) from MinIO.

Environment variables required:
- COPAW_WORKER_NAME: Worker name
- COPAW_MINIO_ENDPOINT: MinIO endpoint (e.g., http://fs-local.hiclaw.io:18080)
- COPAW_MINIO_ACCESS_KEY: MinIO access key (worker name)
- COPAW_MINIO_SECRET_KEY: MinIO secret key
- COPAW_MINIO_BUCKET: MinIO bucket (default: hiclaw-storage)
- COPAW_WORKING_DIR: CoPaw working directory (default: ~/.copaw-worker/<worker_name>/.copaw)
"""
import os
import sys
from pathlib import Path

# Try to import copaw_worker - it should be installed via pip
try:
    from copaw_worker.sync import FileSync
    from copaw_worker.bridge import bridge_openclaw_to_copaw
except ImportError:
    # If not installed, try to add source path (for development)
    src_path = Path(__file__).parent.parent.parent.parent / "src"
    if src_path.exists():
        sys.path.insert(0, str(src_path))
        try:
            from copaw_worker.sync import FileSync
            from copaw_worker.bridge import bridge_openclaw_to_copaw
        except ImportError as e:
            print(f"Error: copaw-worker package not found. Please install it with: pip install copaw-worker", file=sys.stderr)
            print(f"Import error: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        print(f"Error: copaw-worker package not found. Please install it with: pip install copaw-worker", file=sys.stderr)
        sys.exit(1)


def main():
    # Read environment variables
    worker_name = os.getenv("COPAW_WORKER_NAME")
    minio_endpoint = os.getenv("COPAW_MINIO_ENDPOINT")
    minio_access_key = os.getenv("COPAW_MINIO_ACCESS_KEY")
    minio_secret_key = os.getenv("COPAW_MINIO_SECRET_KEY")
    minio_bucket = os.getenv("COPAW_MINIO_BUCKET", "hiclaw-storage")
    working_dir = os.getenv("COPAW_WORKING_DIR")

    if not all([worker_name, minio_endpoint, minio_access_key, minio_secret_key]):
        print("Error: Missing required environment variables", file=sys.stderr)
        print("Required: COPAW_WORKER_NAME, COPAW_MINIO_ENDPOINT, COPAW_MINIO_ACCESS_KEY, COPAW_MINIO_SECRET_KEY", file=sys.stderr)
        sys.exit(1)

    if not working_dir:
        working_dir = Path.home() / ".copaw-worker" / worker_name / ".copaw"
    else:
        working_dir = Path(working_dir)

    print(f"Syncing files for worker: {worker_name}")
    print(f"MinIO endpoint: {minio_endpoint}")
    print(f"Working directory: {working_dir}")

    # Initialize FileSync
    sync = FileSync(
        endpoint=minio_endpoint,
        access_key=minio_access_key,
        secret_key=minio_secret_key,
        bucket=minio_bucket,
        worker_name=worker_name,
        secure=minio_endpoint.startswith("https://"),
        local_dir=working_dir.parent,
    )

    # Pull all files
    try:
        changed = sync.pull_all()
        if changed:
            print(f"✓ Synced {len(changed)} file(s): {', '.join(changed)}")
            
            # Re-bridge config if openclaw.json changed
            if any("openclaw.json" in f for f in changed):
                print("Re-bridging openclaw.json to CoPaw config...")
                openclaw_cfg = sync.get_config()
                soul = sync.get_soul()
                agents = sync.get_agents_md()
                
                if soul:
                    (working_dir / "SOUL.md").write_text(soul)
                if agents:
                    (working_dir / "AGENTS.md").write_text(agents)
                
                bridge_openclaw_to_copaw(openclaw_cfg, working_dir)
                print("✓ Config re-bridged. CoPaw will hot-reload automatically.")
        else:
            print("✓ No changes detected. All files are up to date.")
    except Exception as exc:
        print(f"✗ Sync failed: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
