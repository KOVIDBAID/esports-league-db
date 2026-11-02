"""Save and restore the demo starting point (plan Section 6, "Resetting between rehearsals").

    python scripts/snapshot.py save    [file]   dump the database to a file (default demo.dump)
    python scripts/snapshot.py restore [file]   recreate the database from that file

Rebuilding from scratch also gives the same data (the seed is fixed), but a restore is the
safety net for demo day: it needs no Python packages beyond psycopg and takes seconds.

When the Docker container is running (docker compose up -d), pg_dump and pg_restore run
inside it, so nothing else needs installing on Windows. Otherwise the pg_dump and
pg_restore on PATH are used, with the connection settings from .env.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

import rebuild

CONTAINER = "esports-db"


def container_running() -> bool:
    if not shutil.which("docker"):
        return False
    result = subprocess.run(["docker", "inspect", "-f", "{{.State.Running}}", CONTAINER],
                            capture_output=True, text=True)
    return result.returncode == 0 and result.stdout.strip() == "true"


def tool(name: str, cfg: dict, docker: bool) -> list[str]:
    if docker:
        return ["docker", "exec", "-i", "-e", f"PGPASSWORD={cfg['password']}", CONTAINER, name, "-U", cfg["user"]]
    return [name, "-h", cfg["host"], "-p", str(cfg["port"]), "-U", cfg["user"]]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["save", "restore"])
    parser.add_argument("file", nargs="?", default=str(rebuild.ROOT / "demo.dump"))
    args = parser.parse_args(argv)

    cfg = rebuild.settings()
    docker = container_running()
    env = dict(os.environ, PGPASSWORD=cfg["password"])
    path = Path(args.file)

    if args.action == "save":
        with path.open("wb") as out:
            subprocess.run(tool("pg_dump", cfg, docker) + ["-Fc", "-d", cfg["dbname"]],
                           stdout=out, env=env, check=True)
        print(f"Saved '{cfg['dbname']}' to {path} ({path.stat().st_size // 1024} KB).")
    else:
        if not path.exists():
            raise SystemExit(f"No snapshot at {path}; run 'python scripts/snapshot.py save' first.")
        rebuild.recreate_database(cfg)
        with path.open("rb") as dump:
            subprocess.run(tool("pg_restore", cfg, docker) + ["--no-owner", "-d", cfg["dbname"]],
                           stdin=dump, env=env, check=True)
        print(f"Restored '{cfg['dbname']}' from {path}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
