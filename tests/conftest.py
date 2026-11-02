"""Shared test setup.

* The session starts by rebuilding the database from scratch (scripts/rebuild.py),
  so every test run sees exactly the schema and seed data in the repository.
* Each test gets its own connection inside a transaction that is rolled back at the
  end, so tests never see each other's rows.
* tiny_match() builds the smallest valid tournament with one Bo5 match between two teams.
"""
from __future__ import annotations

import sys
from pathlib import Path

import psycopg
import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import rebuild  # noqa: E402

# Reference ids from seed/reference/
HP, SND, CTL, OVR = 1, 2, 3, 4
DEN, SCAR, RAID = 3, 6, 5
POOL_2026, LAYOUT_2026, DOUBLE_ELIM = 1, 1, 2


@pytest.fixture(scope="session", autouse=True)
def fresh_database():
    rebuild.main(["--quiet"])


@pytest.fixture
def db():
    conn = rebuild.connect()
    try:
        yield conn
    finally:
        conn.rollback()
        conn.close()


def one(conn: psycopg.Connection, query: str, params=None):
    """Run a query and return the first column of the first row."""
    return conn.execute(query, params).fetchone()[0]


def new_team(conn: psycopg.Connection, name: str, valid_from: str = "2025-01-01") -> int:
    team_id = one(conn, "INSERT INTO team (founded_date) VALUES (%s) RETURNING team_id", (valid_from,))
    conn.execute("INSERT INTO team_identity (team_id, valid_from, team_name) VALUES (%s, %s, %s)",
                 (team_id, valid_from, name))
    return team_id


@pytest.fixture
def tiny_match(db):
    """A standalone tournament, one phase, one Bo5 match, teams A (slot 1) and B (slot 2)."""
    event_id = one(db, "INSERT INTO event (event_name) VALUES ('Test Cup') RETURNING event_id")
    db.execute("""INSERT INTO tournament (event_id, tournament_type, start_date, end_date, max_teams, team_size)
                  VALUES (%s, 'cup', '2026-03-01', '2026-03-02', 8, 4)""", (event_id,))
    db.execute("""INSERT INTO phase (tournament_id, phase_number, phase_name, default_best_of,
                                     format_id, pool_id, layout_id)
                  VALUES (%s, 1, 'Playoffs', 5, %s, %s, %s)""", (event_id, DOUBLE_ELIM, POOL_2026, LAYOUT_2026))
    team_a, team_b = new_team(db, "Team A"), new_team(db, "Team B")
    match_id = one(db, """INSERT INTO match (tournament_id, phase_number, match_number, best_of)
                          VALUES (%s, 1, 1, 5) RETURNING match_id""", (event_id,))
    db.execute("INSERT INTO competes_in (match_id, team_id, slot) VALUES (%s, %s, 1), (%s, %s, 2)",
               (match_id, team_a, match_id, team_b))
    return {"tournament_id": event_id, "match_id": match_id, "team_a": team_a, "team_b": team_b}


def play_game(conn, match_id: int, game_number: int, map_id: int, mode_id: int, scores: dict[int, int]):
    """Insert a played game and its two team scores."""
    conn.execute("""INSERT INTO game (match_id, game_number, status, result_type, map_id, mode_id)
                    VALUES (%s, %s, 'completed', 'played', %s, %s)""", (match_id, game_number, map_id, mode_id))
    for team_id, score in scores.items():
        conn.execute("INSERT INTO team_result (match_id, game_number, team_id, score) VALUES (%s, %s, %s, %s)",
                     (match_id, game_number, team_id, score))
