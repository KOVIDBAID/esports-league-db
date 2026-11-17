"""The demo app: every page runs, and the demo's steps work end to end.

Streamlit's own test runner (AppTest) runs each page headlessly, the way a browser would.
The pages write through autocommit, so these tests use their own freshly seeded database,
esports_app_test, and leave the shared test database untouched.
"""
import datetime
import importlib
import sys
from pathlib import Path

import psycopg
import pytest

import load_seed
import rebuild

APP = Path(__file__).resolve().parent.parent / "app"
sys.path.insert(0, str(APP))
pytest.importorskip("streamlit")
from streamlit.testing.v1 import AppTest  # noqa: E402

PAGES = ["Home.py"] + sorted(f"pages/{p.name}" for p in (APP / "pages").glob("*.py"))
APP_DB = "esports_app_test"


@pytest.fixture(scope="module")
def app_db():
    """A fresh, fully seeded database for the app, and the app pointed at it."""
    patch = pytest.MonkeyPatch()
    cfg = dict(rebuild.settings(), dbname=APP_DB)
    rebuild.recreate_database(cfg)
    with rebuild.connect(cfg) as conn:
        rebuild.run_sql_files(conn, lambda *_: None)
        load_seed.load_all(conn, lambda *_: None)
    patch.setenv("PGDATABASE", APP_DB)
    app_module = importlib.import_module("db")
    app_module.conn.clear()                          # drop any cached connection to another database
    yield cfg
    app_module.conn.clear()
    patch.undo()
    with psycopg.connect(**dict(cfg, dbname="postgres"), autocommit=True) as admin:
        admin.execute(f"DROP DATABASE IF EXISTS {APP_DB} WITH (FORCE)")


def page(name: str) -> AppTest:
    at = AppTest.from_file(str(APP / name), default_timeout=60)
    at.run()
    assert not at.exception, f"{name} raised: {[e.value for e in at.exception]}"
    return at


def sql(cfg, query, params=None):
    with rebuild.connect(cfg) as conn:
        return conn.execute(query, params).fetchall()


@pytest.mark.parametrize("name", PAGES)
def test_every_page_opens(app_db, name):
    page(name)


def test_the_demo_runs_end_to_end(app_db):
    # 1. Bracket: Major 2 is the default; the seeds follow season points
    at = page("pages/4_Bracket.py")
    assert at.selectbox[0].value == "CDL 2026 Major 2"
    seeds = at.dataframe[0].value
    assert list(seeds.team_name[:4]) == ["Paris Gentle Mates", "OpTic Texas", "FaZe Vegas", "G2 Minnesota"]
    at.button[0].click().run()
    assert not at.exception and "14 matches" in at.success[0].value
    assert len(at.dataframe[0].value) == 14

    # 2. Record series: the first match, with the lineups on the default day (27 March)
    at = page("pages/6_Record_series.py")
    first = at.selectbox(key="rs_match").value
    assert at.date_input[0].value == datetime.date(2026, 3, 27)
    lineups = [m for m in at.multiselect if m.label.startswith("Lineup")]
    assert [len(m.value) for m in lineups] == [4, 4]
    at.button[0].click().run()
    assert at.success and "won match" in at.success[0].value, [e.value for e in at.error]
    first_id = int(first.split(":")[0].split()[1])
    assert sql(app_db, "SELECT status FROM match WHERE match_id = %s", (first_id,)) == [("completed",)]
    moved = sql(app_db, """SELECT count(*) FROM competes_in c JOIN match m USING (match_id)
                           WHERE m.match_id IN (SELECT winner_to_match_id FROM match WHERE match_id = %s
                                                UNION SELECT loser_to_match_id FROM match WHERE match_id = %s)""",
                (first_id, first_id))
    assert moved == [(2,)]                           # winner and loser both moved on

    # 3. The planned failure: a player from another team in a lineup
    at = page("pages/6_Record_series.py")
    match_label = at.selectbox(key="rs_match").value
    match_id = int(match_label.split(":")[0].split()[1])
    lineup = [m for m in at.multiselect if m.label.startswith("Lineup")][0]
    ringer = next(o for o in lineup.options if o.startswith("Shotzzy"))
    if ringer in lineup.value:                       # OpTic itself: borrow a FaZe player instead
        ringer = next(o for o in lineup.options if o.startswith("Simp"))
    lineup.set_value(lineup.value[:3] + [ringer]).run()
    at.button[0].click().run()
    assert at.error and at.error[0].value.startswith("R0012")
    assert "Nothing was saved" in at.info[0].value
    assert sql(app_db, "SELECT status, (SELECT count(*) FROM game WHERE match_id = %s) FROM match WHERE match_id = %s",
               (match_id, match_id)) == [("scheduled", 0)]

    # 4. Error log: exactly that refusal
    at = page("pages/3_Error_log.py")
    log = at.dataframe[0].value
    assert list(log.function_name) == ["record_series_result"] and list(log.sqlstate) == ["R0012"]

    # 5. Rebrand, then Team history keeps the old name on the old results
    at = page("pages/2_Operations.py")
    at.selectbox(key="rb_team").select("OpTic Texas")
    at.date_input(key="rb_date").set_value(datetime.date(2026, 4, 1))
    at.text_input(key="rb_name").input("OpTic Dallas")
    at.button[0].click().run()
    assert at.success and "OpTic Dallas" in at.success[0].value
    at = page("pages/7_Team_history.py")
    at.selectbox(key="th_team").select("OpTic Dallas").run()
    names, results = at.dataframe[0].value, at.dataframe[1].value
    assert list(names.team_name) == ["OpTic Texas", "OpTic Dallas"]
    assert set(results.played_as) == {"OpTic Texas"}           # every result so far predates the rebrand

    # 6. Disputes: upheld with a forfeit to the loser; the bracket follows
    winner_to, loser_to, loser = sql(app_db, """
        SELECT m.winner_to_match_id, m.loser_to_match_id, c.team_id FROM match m
        JOIN competes_in c ON c.match_id = m.match_id
        JOIN v_match_winner w ON w.match_id = m.match_id AND w.team_id <> c.team_id
        WHERE m.match_id = %s""", (first_id,))[0]
    at = page("pages/5_Disputes.py")
    at.selectbox(key="rd_match").select(next(o for o in at.selectbox(key="rd_match").options
                                             if o.startswith(f"Match {first_id}:"))).run()
    loser_name = sql(app_db, "SELECT team_name FROM v_team_current_name WHERE team_id = %s", (loser,))[0][0]
    at.selectbox(key="rd_team").select(loser_name)
    at.text_input(key="rd_reason").input("Opponent used a banned weapon")
    at.button[0].click().run()
    assert at.success
    at = page("pages/5_Disputes.py")
    at.text_input(key="rs_text").input("Upheld: the match is awarded to the other team")
    at.selectbox(key="rs_awarded").select(loser_name)
    at.button[1].click().run()
    assert at.success and "resolved" in at.success[0].value
    assert sql(app_db, "SELECT team_id FROM competes_in WHERE match_id = %s AND team_id = %s",
               (winner_to, loser)) == [(loser,)]                # the old loser now moves up instead

    # 7. Standings lists every team
    at = page("pages/1_Standings.py")
    assert len(at.dataframe[0].value) == 12
