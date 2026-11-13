"""Shared test setup.

* The session starts by rebuilding the database from scratch (scripts/rebuild.py), so
  every run sees exactly the schema and seed data in the repository.
* Each test gets its own connection inside a transaction that is rolled back at the end,
  so tests never see each other's rows and nothing is ever committed.
* The builders below create data that passes every rule, including the ones checked at
  commit. A test builds a valid world, then makes one change that should be refused.
* Checks that wait for commit are run inside the test with at_commit(), which does what
  COMMIT would do (SET CONSTRAINTS ALL IMMEDIATE) without ending the transaction.
"""
from __future__ import annotations

import itertools
import os
import sys
from pathlib import Path

import psycopg
import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

# The tests rebuild their database from scratch, so they must never run on the working
# one (the demo, the app). They use their own database; set TEST_PGDATABASE to change it.
os.environ["PGDATABASE"] = os.environ.get("TEST_PGDATABASE", "esports_test")

import rebuild  # noqa: E402

# Reference ids from seed/reference/
HP, SND, CTL, OVR = 1, 2, 3, 4
BLACKHEART, COLOSSUS, DEN, EXPOSURE, RAID, SCAR, RAID_BO2 = 1, 2, 3, 4, 5, 6, 7
POOL_2026, LAYOUT_2026, DOUBLE_ELIM = 1, 1, 2
NA, EU = 1, 2
MODE_TABLE = {HP: "hardpoint_stats", SND: "snd_stats", CTL: "control_stats", OVR: "overload_stats"}

_serial = itertools.count(1)


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


# ---------------------------------------------------------------- running checks

def one(conn: psycopg.Connection, query: str, params=None):
    """Run a query and return the first column of the first row."""
    return conn.execute(query, params).fetchone()[0]


def at_commit(conn: psycopg.Connection) -> None:
    """Run every check that waits for commit now, then go back to waiting."""
    conn.execute("SET CONSTRAINTS ALL IMMEDIATE")
    conn.execute("SET CONSTRAINTS ALL DEFERRED")


def rejects(conn: psycopg.Connection, code: str, query: str, params=None) -> str:
    """Assert that a statement fails with this SQLSTATE; return the error message.
    The statement runs in a savepoint, so the test can carry on afterwards."""
    with pytest.raises(psycopg.Error) as info:
        with conn.transaction():
            conn.execute(query, params)
    assert info.value.sqlstate == code, f"expected {code}, got {info.value.sqlstate}: {info.value}"
    return str(info.value)


def rejects_at_commit(conn: psycopg.Connection, code: str) -> str:
    """Assert that the checks run at commit fail with this SQLSTATE."""
    with pytest.raises(psycopg.Error) as info:
        with conn.transaction():
            conn.execute("SET CONSTRAINTS ALL IMMEDIATE")
    assert info.value.sqlstate == code, f"expected {code}, got {info.value.sqlstate}: {info.value}"
    return str(info.value)


# ---------------------------------------------------------------- builders

def new_org(conn, name: str = "Test Org", org_type: str = "tournament organizer") -> int:
    return one(conn, "INSERT INTO organization (org_name, org_type) VALUES (%s, %s) RETURNING org_id",
               (name, org_type))


def new_event(conn, name: str, org_id: int | None = None) -> int:
    """An event with its host (T2). The caller adds the league or tournament row (T3)."""
    event_id = one(conn, "INSERT INTO event (event_name) VALUES (%s) RETURNING event_id", (name,))
    conn.execute("INSERT INTO hosted_by (event_id, org_id, host_role) VALUES (%s, %s, 'organizer')",
                 (event_id, org_id or new_org(conn)))
    return event_id


def new_team(conn, name: str, valid_from: str = "2025-01-01") -> int:
    """A team with its first identity (T1)."""
    team_id = one(conn, "INSERT INTO team (founded_date) VALUES (%s) RETURNING team_id", (valid_from,))
    conn.execute("INSERT INTO team_identity (team_id, valid_from, team_name) VALUES (%s, %s, %s)",
                 (team_id, valid_from, name))
    return team_id


def new_person(conn, gamertag: str, dob: str | None = "2000-01-01") -> int:
    return one(conn, """INSERT INTO person (first_name, last_name, gamertag, date_of_birth)
                        VALUES ('Test', %s, %s, %s) RETURNING person_id""", (gamertag, gamertag, dob))


def new_player(conn, gamertag: str, team_id: int | None = None, *, role: str = "starter",
               start: str = "2026-01-01", end: str | None = None, dob: str | None = "2000-01-01",
               region_id: int | None = None) -> int:
    """A Player, with a stint on team_id if given."""
    person_id = new_person(conn, gamertag, dob)
    conn.execute("""INSERT INTO player (person_id, activision_id, primary_role, region_id)
                    VALUES (%s, %s, 'AR', %s)""", (person_id, f"ATVI-{next(_serial)}", region_id))
    if team_id is not None:
        add_stint(conn, person_id, team_id, role=role, start=start, end=end)
    return person_id


def add_stint(conn, person_id: int, team_id: int, *, role: str = "starter",
              start: str = "2026-01-01", end: str | None = None) -> None:
    conn.execute("""INSERT INTO roster (person_id, team_id, start_date, end_date, roster_role, join_type)
                    VALUES (%s, %s, %s, %s, %s, 'signing')""", (person_id, team_id, start, end, role))


def new_official(conn) -> int:
    person_id = new_person(conn, f"ref{next(_serial)}", None)
    conn.execute("INSERT INTO official (person_id, official_type) VALUES (%s, 'referee')", (person_id,))
    return person_id


def new_league(conn, *, min_age: int | None = 18, game_title: str = "Black Ops 7") -> dict:
    """A league with its 2026 season (Jan to Dec) and stage 1 (Jan to Jun)."""
    league_id = new_event(conn, "Test League")
    conn.execute("""INSERT INTO league (event_id, abbreviation, competition_level, min_age, points_awarded_to)
                    VALUES (%s, %s, 'professional', %s, 'team')""", (league_id, f"TL{next(_serial)}", min_age))
    conn.execute("""INSERT INTO season (league_id, season_year, game_title, start_date, end_date)
                    VALUES (%s, 2026, %s, '2026-01-01', '2026-12-31')""", (league_id, game_title))
    conn.execute("""INSERT INTO stage (league_id, season_year, stage_number, stage_name, start_date, end_date)
                    VALUES (%s, 2026, 1, 'Stage 1', '2026-01-01', '2026-06-30')""", (league_id,))
    return {"league_id": league_id, "season_year": 2026, "stage_number": 1}


def new_cup(conn, name: str = "Test Cup", *, teams: int = 2, max_teams: int = 8, team_size: int = 4,
            region_id: int | None = None, league: dict | None = None,
            start: str = "2026-03-01", end: str = "2026-03-02") -> dict:
    """A tournament with phase 1 (2026 pool, Bo5 layout) and `teams` teams of team_size
    starters each. With `league`, the cup belongs to its stage and the teams are registered."""
    stage = (league or {}).get
    event_id = new_event(conn, name)
    conn.execute("""INSERT INTO tournament (event_id, tournament_type, start_date, end_date, max_teams,
                                            team_size, league_id, season_year, stage_number, region_id)
                    VALUES (%s, 'cup', %s, %s, %s, %s, %s, %s, %s, %s)""",
                 (event_id, start, end, max_teams, team_size,
                  stage("league_id"), stage("season_year"), stage("stage_number"), region_id))
    conn.execute("""INSERT INTO phase (tournament_id, phase_number, phase_name, default_best_of,
                                       format_id, pool_id, layout_id)
                    VALUES (%s, 1, 'Playoffs', 5, %s, %s, %s)""", (event_id, DOUBLE_ELIM, POOL_2026, LAYOUT_2026))
    cup = {"tournament_id": event_id, "teams": [], "players": {}, "team_size": team_size}
    for i in range(teams):
        team_name = f"{name} Team {chr(65 + i)}"
        team_id = new_team(conn, team_name)
        if league:
            conn.execute("INSERT INTO registered_in (team_id, league_id, season_year) VALUES (%s, %s, %s)",
                         (team_id, league["league_id"], league["season_year"]))
        conn.execute("INSERT INTO participates_in (team_id, tournament_id) VALUES (%s, %s)", (team_id, event_id))
        cup["teams"].append(team_id)
        cup["players"][team_id] = [new_player(conn, f"{team_name} P{j + 1}", team_id, region_id=region_id)
                                   for j in range(team_size)]
    return cup


def new_match(conn, cup: dict, teams: list[int], *, match_number: int = 1, best_of: int = 5,
              scheduled: str = "2026-03-01 18:00+00") -> int:
    match_id = one(conn, """INSERT INTO match (tournament_id, phase_number, match_number, best_of, scheduled_at)
                            VALUES (%s, 1, %s, %s, %s) RETURNING match_id""",
                   (cup["tournament_id"], match_number, best_of, scheduled))
    for slot, team_id in enumerate(teams, start=1):
        conn.execute("INSERT INTO competes_in (match_id, team_id, slot) VALUES (%s, %s, %s)",
                     (match_id, team_id, slot))
    return match_id


def list_players(conn, match_id: int, cup: dict, teams: list[int]) -> None:
    """played_for: list every rostered player of each team for the match."""
    for team_id in teams:
        for person_id in cup["players"][team_id]:
            conn.execute("INSERT INTO match_player (person_id, match_id, team_id) VALUES (%s, %s, %s)",
                         (person_id, match_id, team_id))


def play_game(conn, match_id: int, game_number: int, map_id: int, mode_id: int,
              scores: dict[int, int], players: dict[int, list[int]] | None = None) -> None:
    """A played game with a score for each team in `scores`. With `players`, also one
    stats row and one mode stats row for each listed player (rules 11 and T4)."""
    conn.execute("""INSERT INTO game (match_id, game_number, status, result_type, map_id, mode_id)
                    VALUES (%s, %s, 'completed', 'played', %s, %s)""", (match_id, game_number, map_id, mode_id))
    for team_id, score in scores.items():
        conn.execute("INSERT INTO team_result (match_id, game_number, team_id, score) VALUES (%s, %s, %s, %s)",
                     (match_id, game_number, team_id, score))
    for person_ids in (players or {}).values():
        for person_id in person_ids:
            add_stats(conn, person_id, match_id, game_number, mode_id)


def add_stats(conn, person_id: int, match_id: int, game_number: int, mode_id: int | None) -> None:
    """One player_game_stats row, plus its mode row unless mode_id is None."""
    conn.execute("""INSERT INTO player_game_stats (person_id, match_id, game_number, kills, deaths)
                    VALUES (%s, %s, %s, 20, 18)""", (person_id, match_id, game_number))
    if mode_id is not None:
        conn.execute(f"INSERT INTO {MODE_TABLE[mode_id]} (person_id, match_id, game_number) VALUES (%s, %s, %s)",
                     (person_id, match_id, game_number))


@pytest.fixture
def tiny_match(db):
    """A standalone cup with teams A and B (four starters each) and match 1 between them,
    scheduled 1 March 2026. Players are rostered but not yet listed for the match."""
    cup = new_cup(db)
    team_a, team_b = cup["teams"]
    match_id = new_match(db, cup, [team_a, team_b])
    return {"cup": cup, "tournament_id": cup["tournament_id"], "match_id": match_id,
            "team_a": team_a, "team_b": team_b,
            "players_a": cup["players"][team_a], "players_b": cup["players"][team_b]}


# ---------------------------------------------------------------- calling the functions

def call(conn, function: str, **params) -> dict:
    """Call one of our functions with named parameters; return its fn_result as a dict.
    A dict is sent as JSON; a list is sent as an SQL array (wrap it in Jsonb() for JSON)."""
    from psycopg import sql as _sql
    from psycopg.types.json import Jsonb
    args = _sql.SQL(", ").join(
        _sql.SQL("{} => {}").format(_sql.Identifier(name), _sql.Placeholder()) for name in params)
    query = _sql.SQL("SELECT * FROM {}({})").format(_sql.Identifier(function), args)
    values = [Jsonb(v) if isinstance(v, dict) else v for v in params.values()]
    ok, code, message, data = conn.execute(query, values).fetchone()
    return {"ok": ok, "code": code, "message": message, "data": data}


def succeeds(conn, function: str, **params) -> dict:
    result = call(conn, function, **params)
    assert result["ok"], f"{function} failed: {result['code']} {result['message']}"
    return result


def row_counts(conn, tables) -> dict:
    return {t: one(conn, f"SELECT count(*) FROM {t}") for t in tables}


def fails_cleanly(conn, code: str, tables, function: str, **params) -> dict:
    """The plan's failure test: the call returns ok = false with this code, every table it
    touches has the same row count as before, and error_log holds exactly one new row
    with that code."""
    before = row_counts(conn, tables)
    last_log = one(conn, "SELECT COALESCE(max(log_id), 0) FROM error_log")
    result = call(conn, function, **params)
    assert not result["ok"], f"{function} should have failed with {code}"
    assert result["code"] == code, f"expected {code}, got {result['code']}: {result['message']}"
    assert row_counts(conn, tables) == before, "a failed call must leave every table unchanged"
    logs = conn.execute("SELECT function_name, sqlstate FROM error_log WHERE log_id > %s", (last_log,)).fetchall()
    assert logs == [(function, code)]
    assert result["data"]["log_id"] > last_log
    return result
