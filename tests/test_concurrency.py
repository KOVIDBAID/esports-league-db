"""Two sessions at once: the row lock in check_r27 stops both taking the last place.

This test commits, so it runs in its own scratch database (built and dropped here) and
leaves the shared test database untouched.

Without the lock, both sessions would count the teams before either commits, both would
see room for one more, and the tournament would end up over max_teams.
"""
import threading
import time

import psycopg
import pytest

import load_seed
import rebuild
from conftest import new_cup, new_team, one


@pytest.fixture
def scratch_cfg():
    cfg = dict(rebuild.settings(), dbname="esports_concurrency_test")
    rebuild.recreate_database(cfg)
    with rebuild.connect(cfg) as conn:
        rebuild.run_sql_files(conn, lambda *_: None)
        load_seed.load_all(conn, lambda *_: None)
    yield cfg
    with psycopg.connect(**dict(cfg, dbname="postgres"), autocommit=True) as admin:
        admin.execute("DROP DATABASE IF EXISTS esports_concurrency_test WITH (FORCE)")


def test_r27_two_sessions_cannot_both_take_the_last_place(scratch_cfg):
    with rebuild.connect(scratch_cfg) as setup:
        cup = new_cup(setup, "Last Place Cup", teams=2, max_teams=3)
        late_x, late_y = new_team(setup, "Late X"), new_team(setup, "Late Y")
        setup.commit()
    t = cup["tournament_id"]

    first = rebuild.connect(scratch_cfg)
    second = rebuild.connect(scratch_cfg)
    outcome = {}

    def second_session():
        try:
            second.execute("INSERT INTO participates_in (team_id, tournament_id) VALUES (%s, %s)", (late_y, t))
            second.commit()
            outcome["result"] = "committed"
        except psycopg.Error as exc:
            second.rollback()
            outcome["result"] = exc.sqlstate

    try:
        # Session 1 takes the third and last place, and holds the tournament lock until it commits.
        first.execute("INSERT INTO participates_in (team_id, tournament_id) VALUES (%s, %s)", (late_x, t))

        worker = threading.Thread(target=second_session)
        worker.start()
        time.sleep(0.5)
        assert worker.is_alive(), "session 2 should be waiting for session 1's lock on the tournament"

        first.commit()
        worker.join(timeout=10)
        assert outcome["result"] == "R0027"
    finally:
        first.close()
        second.close()

    with rebuild.connect(scratch_cfg) as check:
        assert one(check, "SELECT count(*) FROM participates_in WHERE tournament_id = %s", (t,)) == 3


def test_r26_a_registration_cannot_vanish_under_a_new_entry(scratch_cfg):
    """Session 1 deletes a team's season registration while session 2 enters the team in
    a season tournament. check_r26 locks the registration it relies on (FOR KEY SHARE, as a
    foreign key would), so session 2 waits, sees the registration gone, and is refused."""
    from conftest import new_league

    with rebuild.connect(scratch_cfg) as setup:
        league = new_league(setup)
        cup = new_cup(setup, "Season Cup", league=league)
        late = new_team(setup, "Late Entry")
        setup.execute("INSERT INTO registered_in (team_id, league_id, season_year) VALUES (%s, %s, 2026)",
                      (late, league["league_id"]))
        setup.commit()

    first = rebuild.connect(scratch_cfg)
    second = rebuild.connect(scratch_cfg)
    outcome = {}

    def second_session():
        try:
            second.execute("INSERT INTO participates_in (team_id, tournament_id) VALUES (%s, %s)",
                           (late, cup["tournament_id"]))
            second.commit()
            outcome["result"] = "committed"
        except psycopg.Error as exc:
            second.rollback()
            outcome["result"] = exc.sqlstate

    try:
        first.execute("DELETE FROM registered_in WHERE team_id = %s", (late,))   # no entries yet: allowed
        worker = threading.Thread(target=second_session)
        worker.start()
        time.sleep(0.5)
        assert worker.is_alive(), "session 2 should wait for the registration row"
        first.commit()
        worker.join(timeout=10)
        assert outcome["result"] == "R0026"
    finally:
        first.close()
        second.close()


def test_two_officials_record_the_same_match_at_once(scratch_cfg):
    """The plan's concurrency test: one call succeeds; the other waits for the match lock,
    then fails with FN001 and writes nothing but its error_log row."""
    from psycopg.types.json import Jsonb
    from conftest import call, new_match
    from test_functions_matches import series

    with rebuild.connect(scratch_cfg) as setup:
        cup = new_cup(setup, "Race Cup", teams=2)
        a, b = cup["teams"]
        match_id = new_match(setup, cup, [a, b])
        setup.commit()
    payload = series(cup, [a, b], [a, a, a])

    first = rebuild.connect(scratch_cfg)
    second = rebuild.connect(scratch_cfg)
    outcome = {}

    def second_session():
        outcome["result"] = call(second, "record_series_result", p_match_id=match_id, p_series=Jsonb(payload))
        second.commit()

    try:
        assert call(first, "record_series_result", p_match_id=match_id, p_series=Jsonb(payload))["ok"]
        worker = threading.Thread(target=second_session)
        worker.start()
        time.sleep(0.5)
        assert worker.is_alive(), "the second call should wait for the first call's lock on the match"
        first.commit()
        worker.join(timeout=10)
        assert outcome["result"]["code"] == "FN001"
    finally:
        first.close()
        second.close()

    with rebuild.connect(scratch_cfg) as check:
        assert one(check, "SELECT count(*) FROM game WHERE match_id = %s", (match_id,)) == 3
        assert one(check, "SELECT count(*) FROM error_log WHERE function_name = 'record_series_result'") == 1
