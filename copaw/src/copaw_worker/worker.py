"""
Worker main entry point.

Bootstrap flow:
1. Pull openclaw.json + SOUL.md + AGENTS.md from MinIO
2. Bridge openclaw.json -> CoPaw config.json + providers.json
3. Install MatrixChannel into CoPaw's custom_channels dir
4. Start CoPaw AgentRunner + ChannelManager (Matrix channel)
"""
from __future__ import annotations

import asyncio
import logging
import shutil
from pathlib import Path
from typing import Optional

from rich.console import Console
from rich.panel import Panel

from copaw_worker.config import WorkerConfig
from copaw_worker.sync import FileSync, sync_loop
from copaw_worker.bridge import bridge_openclaw_to_copaw

console = Console()
logger = logging.getLogger(__name__)


class Worker:
    def __init__(self, config: WorkerConfig) -> None:
        self.config = config
        self.worker_name = config.worker_name
        self.sync: Optional[FileSync] = None
        self._copaw_working_dir: Optional[Path] = None
        self._runner = None
        self._channel_manager = None

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def run(self) -> None:
        if not await self.start():
            return
        try:
            await self._run_copaw()
        except asyncio.CancelledError:
            pass
        finally:
            await self.stop()

    async def stop(self) -> None:
        console.print("[yellow]Stopping worker...[/yellow]")
        if self._channel_manager is not None:
            try:
                await self._channel_manager.stop_all()
            except Exception:
                pass
        if self._runner is not None:
            try:
                await self._runner.stop()
            except Exception:
                pass
        console.print("[green]Worker stopped.[/green]")

    # ------------------------------------------------------------------
    # Startup
    # ------------------------------------------------------------------

    async def start(self) -> bool:
        console.print(
            Panel.fit(
                f"[bold green]CoPaw Worker[/bold green]\n"
                f"Worker: [cyan]{self.worker_name}[/cyan]",
                title="Starting",
            )
        )

        # 1. Init file sync
        self.sync = FileSync(
            endpoint=self.config.minio_endpoint,
            access_key=self.config.minio_access_key,
            secret_key=self.config.minio_secret_key,
            bucket=self.config.minio_bucket,
            worker_name=self.worker_name,
            secure=self.config.minio_secure,
            local_dir=self.config.install_dir / self.worker_name,
        )

        # 2. Pull config from MinIO
        console.print("[yellow]Pulling configuration from MinIO...[/yellow]")
        try:
            openclaw_cfg = self.sync.get_config()
            soul_content = self.sync.get_soul()
            agents_content = self.sync.get_agents_md()
        except Exception as exc:
            console.print(f"[red]Failed to pull config: {exc}[/red]")
            return False

        # 3. Set up CoPaw working directory
        self._copaw_working_dir = self.config.install_dir / self.worker_name / ".copaw"
        self._copaw_working_dir.mkdir(parents=True, exist_ok=True)

        # Write SOUL.md / AGENTS.md into CoPaw working dir
        if soul_content:
            (self._copaw_working_dir / "SOUL.md").write_text(soul_content)
        if agents_content:
            (self._copaw_working_dir / "AGENTS.md").write_text(agents_content)

        # 4. Bridge openclaw.json -> CoPaw config.json + providers.json
        console.print("[yellow]Bridging configuration to CoPaw...[/yellow]")
        try:
            bridge_openclaw_to_copaw(openclaw_cfg, self._copaw_working_dir)
        except Exception as exc:
            console.print(f"[red]Config bridge failed: {exc}[/red]")
            return False

        # 5. Install MatrixChannel into CoPaw's custom_channels dir
        self._install_matrix_channel()

        # 6. Start background MinIO sync
        asyncio.create_task(
            sync_loop(
                self.sync,
                interval=self.config.sync_interval,
                on_pull=self._on_files_pulled,
            )
        )

        console.print("[bold green]Worker initialized.[/bold green]")
        return True

    # ------------------------------------------------------------------
    # CoPaw runner
    # ------------------------------------------------------------------

    async def _run_copaw(self) -> None:
        """Start CoPaw's AgentRunner + ChannelManager (no HTTP server)."""
        from copaw.app.runner.runner import AgentRunner
        from copaw.config.utils import load_config
        from copaw.app.channels.manager import ChannelManager
        from copaw.app.channels.utils import make_process_from_runner
        from copaw.app.channels.registry import clear_builtin_channel_cache

        # Force registry reload so newly installed matrix_channel.py is picked up
        clear_builtin_channel_cache()

        self._runner = AgentRunner()
        await self._runner.start()

        # load_config reads COPAW_WORKING_DIR/config.json (set by bridge.py)
        config = load_config()
        self._channel_manager = ChannelManager.from_config(
            process=make_process_from_runner(self._runner),
            config=config,
            on_last_dispatch=None,
        )
        await self._channel_manager.start_all()

        console.print("[bold green]CoPaw channels started. Worker is running.[/bold green]")

        try:
            while True:
                await asyncio.sleep(60)
        except asyncio.CancelledError:
            pass
        finally:
            await self._channel_manager.stop_all()
            await self._runner.stop()
            # Clear refs so stop() doesn't double-call
            self._channel_manager = None
            self._runner = None

    # ------------------------------------------------------------------
    # MatrixChannel installation
    # ------------------------------------------------------------------

    def _install_matrix_channel(self) -> None:
        """Copy matrix_channel.py into COPAW_WORKING_DIR/custom_channels/.

        CoPaw's CUSTOM_CHANNELS_DIR = WORKING_DIR / "custom_channels", and
        WORKING_DIR is read from COPAW_WORKING_DIR env var at import time.
        We set COPAW_WORKING_DIR in bridge.py before this runs, so the
        directory is already correct.
        """
        custom_channels_dir = self._copaw_working_dir / "custom_channels"
        custom_channels_dir.mkdir(parents=True, exist_ok=True)
        src = Path(__file__).parent / "matrix_channel.py"
        dst = custom_channels_dir / "matrix_channel.py"
        shutil.copy2(src, dst)
        logger.debug("MatrixChannel installed to %s", dst)

    # ------------------------------------------------------------------
    # File sync callback
    # ------------------------------------------------------------------

    async def _on_files_pulled(self, pulled_files: list[str]) -> None:
        """Re-bridge config when openclaw.json / SOUL.md / AGENTS.md change."""
        needs_rebridge = any(
            name in f
            for f in pulled_files
            for name in ("openclaw.json", "SOUL.md", "AGENTS.md")
        )
        if not needs_rebridge:
            return

        console.print("[yellow]Config changed, re-bridging...[/yellow]")
        try:
            openclaw_cfg = self.sync.get_config()
            soul = self.sync.get_soul()
            agents = self.sync.get_agents_md()

            if soul:
                (self._copaw_working_dir / "SOUL.md").write_text(soul)
            if agents:
                (self._copaw_working_dir / "AGENTS.md").write_text(agents)

            bridge_openclaw_to_copaw(openclaw_cfg, self._copaw_working_dir)
            console.print("[green]Config re-bridged.[/green]")
        except Exception as exc:
            console.print(f"[red]Re-bridge failed: {exc}[/red]")
