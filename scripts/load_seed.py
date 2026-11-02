"""Load the seed data in stages (implementation plan, Section 6).

Each stage is one transaction: if any row or call fails, the whole stage rolls back and
the loader reports the file (or function call) and the error.

    stage 1  reference data          CSV in seed/reference/
    stage 2  people and teams        CSV in seed/people/
    stage 3  competition structure   CSV in seed/structure/
    stage 4  season history          calls to our own functions (scripts/seed_season.py)
    stage 5  demo starting point     calls to our own functions (scripts/seed_season.py)

The order follows the foreign keys: no stage refers to a row that a later stage creates.
"""
from __future__ import annotations

import csv
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import psycopg
from psycopg import sql

import seed_season

ROOT = Path(__file__).resolve().parent.parent
SEED = ROOT / "seed"


@dataclass
class Stage:
    name: str
    folder: str | None = None                       # CSV stages: seed/<folder>/<table>.csv
    tables: list[str] = field(default_factory=list)  # in foreign key order
    script: Callable | None = None                   # function stages: script(conn) -> summary


STAGES: list[Stage] = [
    Stage("reference", "reference", [
        "region", "organization", "venue", "game_mode", "format", "map", "map_pool", "pool_entry",
        "series_layout", "series_slot"]),
    Stage("people and teams", "people", [
        "team", "team_identity", "person", "person_phone", "player", "official", "roster"]),
    Stage("competition structure", "structure", [
        "event", "hosted_by", "league", "season", "stage", "registered_in", "tournament", "phase",
        "placement_reward"]),
    Stage("season history", script=seed_season.season_history),
    Stage("demo starting point", script=seed_season.demo_starting_point),
]


class SeedError(Exception):
    pass


def copy_csv(conn: psycopg.Connection, table: str, path: Path) -> int:
    """COPY one CSV file (with a header row naming the columns) into a table."""
    with path.open(newline="", encoding="utf-8") as fh:
        header = next(csv.reader(fh))
        fh.seek(0)
        stmt = sql.SQL("COPY {} ({}) FROM STDIN WITH (FORMAT csv, HEADER true)").format(
            sql.Identifier(table), sql.SQL(", ").join(map(sql.Identifier, header)))
        with conn.cursor() as cur:
            with cur.copy(stmt) as copy:
                copy.write(fh.read())
            return cur.rowcount


def reset_identities(conn: psycopg.Connection, tables: list[str]) -> None:
    """Move each identity counter past the highest id loaded, so new rows get fresh ids."""
    rows = conn.execute(
        """SELECT table_name, column_name FROM information_schema.columns
           WHERE table_schema = 'public' AND is_identity = 'YES' AND table_name = ANY(%s)""",
        (tables,)).fetchall()
    for table, column in rows:
        conn.execute(sql.SQL(
            "SELECT setval(pg_get_serial_sequence({t}, {c}), GREATEST((SELECT max({col}) FROM {tab}), 1))"
        ).format(t=sql.Literal(table), c=sql.Literal(column),
                 col=sql.Identifier(column), tab=sql.Identifier(table)))


def load_stage(conn: psycopg.Connection, stage: Stage) -> dict:
    """Run one stage in one transaction; return what it loaded."""
    summary: dict = {}
    try:
        with conn.transaction():
            if stage.script is None:
                for table in stage.tables:
                    path = SEED / stage.folder / f"{table}.csv"
                    try:
                        summary[table] = copy_csv(conn, table, path)
                    except psycopg.Error as exc:
                        raise SeedError(f"{path.relative_to(ROOT)}: {exc.diag.message_primary} "
                                        f"{exc.diag.context or ''}".strip()) from exc
                reset_identities(conn, stage.tables)
            else:
                summary = stage.script(conn)
            conn.execute("SET CONSTRAINTS ALL IMMEDIATE")   # every commit-time check, now
    except SeedError:
        raise
    except (psycopg.Error, seed_season.SeedCallError) as exc:
        raise SeedError(f"stage '{stage.name}': {exc}") from exc
    return summary


def load_all(conn: psycopg.Connection, say=print, upto: str | None = None) -> dict:
    """Load every stage in order, or the stages up to and including `upto`."""
    loaded: dict = {}
    for stage in STAGES:
        summary = load_stage(conn, stage)
        detail = ", ".join(f"{k} {v}" for k, v in summary.items())
        say(f"  stage '{stage.name}': {detail}")
        loaded[stage.name] = summary
        if stage.name == upto:
            break
    return loaded
