"""Phase 5 tests: the seed data (plan Section 6, "Checks after loading").

The session database is built with all five seed stages, so these tests read the loaded
season. Every other test rolls back, so nothing they do is visible here.
"""
import psycopg

import load_seed
import rebuild
from conftest import one

MAJOR_1, MAJOR_2 = 2, 3
REAL_MAJOR_1 = [  # esports.net: CDL 2026 Major 1 results
    (1, "Paris Gentle Mates"), (2, "OpTic Texas"), (3, "FaZe Vegas"), (4, "G2 Minnesota"),
    (5, "Los Angeles Thieves"), (5, "Miami Heretics"), (7, "Riyadh Falcons"), (7, "Vancouver Surge")]


def test_every_stage_loaded_the_expected_rows(db):
    counts = {t: one(db, f"SELECT count(*) FROM {t}") for t in
              ["team", "player", "official", "match", "competes_in", "map_veto", "player_game_stats"]}
    assert counts == {"team": 12, "player": 48, "official": 4, "match": 44, "competes_in": 88,
                      "map_veto": 440, "player_game_stats": 1328}
    played = one(db, "SELECT count(*) FROM game WHERE result_type = 'played'")
    assert played == 166 and one(db, "SELECT count(*) FROM player_game_stats") == played * 8


def test_major_1_placements_and_prizes_are_the_real_ones(db):
    rows = db.execute("""SELECT p.final_placement, n.team_name FROM participates_in p
                         JOIN v_team_current_name n USING (team_id)
                         WHERE p.tournament_id = %s AND p.final_placement <= 8
                         ORDER BY 1, 2""", (MAJOR_1,)).fetchall()
    assert rows == REAL_MAJOR_1
    assert one(db, "SELECT sum(prize) FROM v_team_prize WHERE tournament_id = %s", (MAJOR_1,)) == 365000


def test_every_completed_match_has_a_winner(db):
    assert one(db, """SELECT count(*) FROM match m WHERE status = 'completed'
                      AND NOT EXISTS (SELECT 1 FROM v_match_winner w WHERE w.match_id = m.match_id)""") == 0


def test_each_prize_pool_equals_the_sum_of_its_bands(db):
    for t in (MAJOR_1, MAJOR_2):
        bands = one(db, """SELECT sum(prize_amount * (placement_to - placement_from + 1))
                           FROM placement_reward WHERE tournament_id = %s""", (t,))
        assert one(db, "SELECT prize_pool FROM v_tournament_prize_pool WHERE tournament_id = %s", (t,)) == bands == 365000


def test_every_team_has_a_current_name(db):
    assert one(db, "SELECT count(*) FROM v_team_current_name") == 12


def test_every_stats_row_has_one_mode_row(db):
    modes = one(db, """SELECT (SELECT count(*) FROM hardpoint_stats) + (SELECT count(*) FROM snd_stats)
                            + (SELECT count(*) FROM control_stats) + (SELECT count(*) FROM overload_stats)""")
    assert modes == one(db, "SELECT count(*) FROM player_game_stats")


def test_the_rebrand_keeps_history_under_the_old_name(db):
    history = db.execute("""SELECT team_name, valid_from::text, valid_to::text FROM team_identity
                            WHERE team_id = (SELECT team_id FROM v_team_current_name
                                             WHERE team_name = 'G2 Minnesota')
                            ORDER BY valid_from""").fetchall()
    assert history == [("Minnesota RØKKR", "2025-10-01", "2025-10-21"), ("G2 Minnesota", "2025-10-21", None)]


def test_a_transfer_leaves_past_matches_with_the_old_team(db):
    mamba = one(db, "SELECT person_id FROM person WHERE gamertag = 'Mamba'")
    assert one(db, """SELECT n.team_name FROM v_roster_current r JOIN v_team_current_name n USING (team_id)
                      WHERE r.person_id = %s""", (mamba,)) == "Vancouver Surge"
    assert {r[0] for r in db.execute("""SELECT n.team_name FROM match_player mp
                                       JOIN v_team_current_name n USING (team_id)
                                       WHERE mp.person_id = %s""", (mamba,))} == {"G2 Minnesota"}


def test_the_disputes_carry_no_penalty(db):
    assert db.execute("SELECT status FROM dispute ORDER BY match_id").fetchall() == [("rejected",), ("resolved",)]
    assert one(db, "SELECT count(*) FROM penalty") == 0


def test_the_demo_starts_with_major_2_created_but_not_set_up(db):
    assert one(db, "SELECT phase_name FROM phase WHERE tournament_id = %s", (MAJOR_2,)) == "Playoffs"
    assert one(db, "SELECT count(*) FROM match WHERE tournament_id = %s", (MAJOR_2,)) == 0
    assert one(db, "SELECT count(*) FROM registered_in") == 12


def test_seeding_logged_no_errors(db):
    assert one(db, "SELECT count(*) FROM error_log") == 0


def test_every_rebuild_produces_the_same_data():
    """The plan: stats come from a fixed random seed, so every rebuild is identical."""
    fingerprint = """SELECT md5(string_agg(concat_ws(',', person_id, match_id, game_number, kills, deaths,
                                                    assists, damage), ';'
                                          ORDER BY person_id, match_id, game_number))
                     FROM player_game_stats"""
    cfg = dict(rebuild.settings(), dbname="esports_seed_check")
    prints = []
    for _ in range(2):
        rebuild.recreate_database(cfg)
        with rebuild.connect(cfg) as conn:
            rebuild.run_sql_files(conn, lambda *_: None)
            load_seed.load_all(conn, lambda *_: None)
            prints.append(conn.execute(fingerprint).fetchone()[0])
    with psycopg.connect(**dict(cfg, dbname="postgres"), autocommit=True) as admin:
        admin.execute("DROP DATABASE IF EXISTS esports_seed_check WITH (FORCE)")
    assert prints[0] == prints[1]
