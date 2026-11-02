"""Load the seed data in stages (implementation plan, Section 6).

Each stage is one transaction: if any row fails, the whole stage rolls back and
the loader reports the file, line and the error.

Stage 1 (reference data) is loaded from CSV files in seed/reference/.
Later stages are added as the project reaches them:
    stage 2  people and teams          (CSV)
    stage 3  competition structure     (CSV)
    stage 4  season history            (calls to our own functions)
    stage 5  demo starting point       (calls to our own functions)
"""
from __future__ import annotations

import csv
from pathlib import Path

import psycopg
from psycopg import sql

ROOT = Path(__file__).resolve().parent.parent
SEED = ROOT / "seed"

# (stage name, [table, ...]) in foreign key order; each table reads seed/<folder>/<table>.csv
STAGES: list[tuple[str, str, list[str]]] = [
    ("reference", "reference", [
        "region", "game_mode", "format", "map", "map_pool", "pool_entry",
        "series_layout", "series_slot",
    ]),
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


def load_stage(conn: psycopg.Connection, folder: str, tables: list[str]) -> dict[str, int]:
    counts: dict[str, int] = {}
    with conn.transaction():
        for table in tables:
            path = SEED / folder / f"{table}.csv"
            try:
                counts[table] = copy_csv(conn, table, path)
            except psycopg.Error as exc:
                raise SeedError(f"{path.relative_to(ROOT)}: {exc.diag.message_primary} "
                                f"{exc.diag.context or ''}".strip()) from exc
        reset_identities(conn, tables)
        conn.execute("SET CONSTRAINTS ALL IMMEDIATE")   # run any commit-time checks now
    return counts


def load_all(conn: psycopg.Connection, say=print) -> dict[str, int]:
    counts: dict[str, int] = {}
    for name, folder, tables in STAGES:
        stage_counts = load_stage(conn, folder, tables)
        say(f"  stage '{name}': {sum(stage_counts.values())} rows")
        counts.update(stage_counts)
    return counts
