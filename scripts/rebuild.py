"""Rebuild the database from scratch.

Steps: drop and recreate the database, run every SQL file in db/ in order,
then db/functions/, then load the seed data, then print row counts.

Usage (from the repository root):
    python scripts/rebuild.py              full rebuild
    python scripts/rebuild.py --no-seed    schema only, no data
    python scripts/rebuild.py --quiet      fewer messages (used by the tests)

Connection settings come from environment variables, or from .env:
    PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE
"""
from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

import psycopg
from psycopg import sql

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import load_seed  # noqa: E402  (needs the sys.path line above)


def load_env(path: Path = ROOT / ".env") -> None:
    """Read KEY=VALUE lines from .env without overriding variables already set."""
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


def settings() -> dict:
    load_env()
    return {
        "host": os.environ.get("PGHOST", "localhost"),
        "port": int(os.environ.get("PGPORT", "5433")),
        "user": os.environ.get("PGUSER", "esports"),
        "password": os.environ.get("PGPASSWORD", "esports_dev"),
        "dbname": os.environ.get("PGDATABASE", "esports"),
    }


def connect(cfg: dict | None = None, **kwargs) -> psycopg.Connection:
    """Open a connection to the project database (used by the tests and the app too)."""
    return psycopg.connect(**(cfg or settings()), **kwargs)


def sql_files() -> list[Path]:
    """db/NN_*.sql in numeric order, then every file in db/functions/ in name order."""
    files = sorted((ROOT / "db").glob("[0-9][0-9]_*.sql"))
    files += sorted((ROOT / "db" / "functions").glob("*.sql"))
    return files


def recreate_database(cfg: dict) -> None:
    admin = dict(cfg, dbname="postgres")
    with psycopg.connect(**admin, autocommit=True) as conn:
        name = sql.Identifier(cfg["dbname"])
        conn.execute(sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(name))
        conn.execute(sql.SQL("CREATE DATABASE {}").format(name))


def run_sql_files(conn: psycopg.Connection, say) -> None:
    for path in sql_files():
        text = path.read_text(encoding="utf-8")
        try:
            with conn.transaction():
                conn.execute(text)  # no parameters, so several statements per file are allowed
        except psycopg.Error as exc:
            diag = exc.diag
            where = f" (at character {diag.statement_position})" if diag.statement_position else ""
            raise SystemExit(f"FAILED in {path.relative_to(ROOT)}{where}: {diag.message_primary or exc}")
        say(f"  ran {path.relative_to(ROOT)}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--no-seed", action="store_true", help="build the schema only")
    parser.add_argument("--quiet", action="store_true", help="print only errors and the final line")
    args = parser.parse_args(argv)
    say = (lambda *_: None) if args.quiet else print

    cfg = settings()
    started = time.time()
    say(f"Rebuilding database '{cfg['dbname']}' on {cfg['host']}:{cfg['port']}")
    recreate_database(cfg)

    with connect(cfg) as conn:
        run_sql_files(conn, say)
        if not args.no_seed:
            counts = load_seed.load_all(conn, say)
            say("Rows loaded: " + ", ".join(f"{t} {n}" for t, n in counts.items()))
        version = conn.execute("SHOW server_version").fetchone()[0]

    print(f"Rebuild finished in {time.time() - started:.1f}s on PostgreSQL {version}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
