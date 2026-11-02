"""Phase 2 tests: the schema matches the report, and the declarative rules hold.

Each failing insert runs inside conn.transaction() (a savepoint), so the test's
outer transaction stays usable after the expected error.
"""
import psycopg
import pytest
from psycopg import errors

from conftest import DEN, HP, OVR, RAID, SCAR, SND, new_team, one, play_game

EXPECTED_TABLES = {
    # Events and structure
    "organization", "event", "hosted_by", "league", "season", "stage", "registered_in", "venue",
    "region", "tournament", "format", "phase", "placement_reward", "participates_in",
    # Competitive settings
    "map", "game_mode", "map_pool", "pool_entry", "series_layout", "series_slot",
    # Matches and games
    "match", "competes_in", "officiates", "game", "team_result", "map_veto",
    # Teams and people
    "person", "person_phone", "player", "coach", "official", "team", "team_identity", "roster",
    # Player stats
    "match_player", "player_game_stats", "hardpoint_stats", "snd_stats", "control_stats", "overload_stats",
    # Operations
    "dispute", "penalty",
}
SUPPORT_TABLES = {"error_log"}
EXPECTED_VIEWS = {
    "v_person_age", "v_team_current_name", "v_roster_current", "v_coaching_since", "v_previous_team",
    "v_game_winner", "v_series_score", "v_match_winner", "v_map_picked_by", "v_player_kd",
    "v_tournament_prize_pool", "v_team_prize", "v_team_season_points", "v_player_season_points",
    "v_team_season_stats", "v_player_season_stats",
}


def fails(conn, error, query, params=None):
    """Assert that a statement fails with the given error class, without aborting the test."""
    with pytest.raises(error):
        with conn.transaction():
            conn.execute(query, params)


# ---------------------------------------------------------------- structure

def test_all_42_relations_exist(db):
    tables = {r[0] for r in db.execute(
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_schema = 'public' AND table_type = 'BASE TABLE'")}
    assert len(EXPECTED_TABLES) == 42
    assert tables == EXPECTED_TABLES | SUPPORT_TABLES


def test_all_16_views_exist(db):
    views = {r[0] for r in db.execute(
        "SELECT table_name FROM information_schema.views WHERE table_schema = 'public'")}
    assert views == EXPECTED_VIEWS


def test_reference_data_loaded(db):
    assert one(db, "SELECT count(*) FROM region") == 4
    assert one(db, "SELECT count(*) FROM game_mode") == 4
    assert one(db, "SELECT count(*) FROM pool_entry WHERE pool_id = 1") == 13
    assert one(db, "SELECT count(*) FROM series_slot WHERE layout_id = 1 AND best_of = 5") == 5


def test_raid_is_search_and_destroy_only_in_2026_pool(db):
    modes = {r[0] for r in db.execute("SELECT mode_id FROM pool_entry WHERE pool_id = 1 AND map_id = %s", (RAID,))}
    assert modes == {SND}


def test_identity_counters_continue_after_seed(db):
    new_id = one(db, "INSERT INTO map (map_name, game_title) VALUES ('Test Map', 'Test') RETURNING map_id")
    assert new_id > 7


# ---------------------------------------------------------------- domain and date checks

def test_coded_values_are_checked(db):
    fails(db, errors.CheckViolation, "INSERT INTO team (status) VALUES ('sleeping')")
    fails(db, errors.CheckViolation,
          "INSERT INTO organization (org_name, org_type) VALUES ('X', 'fan club')")


def test_periods_must_be_ordered_rule_29(db):
    event_id = one(db, "INSERT INTO event (event_name) VALUES ('E2') RETURNING event_id")
    fails(db, errors.CheckViolation,
          """INSERT INTO tournament (event_id, tournament_type, start_date, end_date, team_size)
             VALUES (%s, 'cup', '2026-05-02', '2026-05-01', 4)""", (event_id,))


def test_tournament_stage_columns_all_or_none(db):
    event_id = one(db, "INSERT INTO event (event_name) VALUES ('E3') RETURNING event_id")
    fails(db, errors.CheckViolation,
          """INSERT INTO tournament (event_id, tournament_type, team_size, league_id)
             VALUES (%s, 'cup', 4, 1)""", (event_id,))


# ---------------------------------------------------------------- EXCLUDE constraints

def test_team_identity_periods_cannot_overlap_rule_18(db):
    team = new_team(db, "Old Name", "2024-01-01")
    db.execute("UPDATE team_identity SET valid_to = '2025-06-01' WHERE team_id = %s", (team,))
    # Starting on the day the old identity ends is fine (half-open periods)...
    db.execute("INSERT INTO team_identity (team_id, valid_from, team_name) VALUES (%s, '2025-06-01', 'New')", (team,))
    # ...but an identity inside an existing period is rejected.
    fails(db, errors.ExclusionViolation,
          "INSERT INTO team_identity (team_id, valid_from, team_name) VALUES (%s, '2025-03-01', 'Clash')", (team,))


def test_same_team_stints_cannot_overlap_rule_14(db):
    team = new_team(db, "Roster FC")
    person = one(db, "INSERT INTO person (first_name, last_name) VALUES ('Sam', 'Lee') RETURNING person_id")
    db.execute("""INSERT INTO roster (person_id, team_id, start_date, roster_role, join_type)
                  VALUES (%s, %s, '2026-01-01', 'starter', 'signing')""", (person, team))
    fails(db, errors.ExclusionViolation,
          """INSERT INTO roster (person_id, team_id, start_date, roster_role, join_type)
             VALUES (%s, %s, '2026-02-01', 'substitute', 'signing')""", (person, team))


def test_reward_bands_cannot_overlap_rule_24(db, tiny_match):
    t = tiny_match["tournament_id"]
    db.execute("INSERT INTO placement_reward (tournament_id, placement_from, placement_to) VALUES (%s, 5, 6)", (t,))
    fails(db, errors.ExclusionViolation,
          "INSERT INTO placement_reward (tournament_id, placement_from, placement_to) VALUES (%s, 6, 8)", (t,))


# ---------------------------------------------------------------- composite keys to competes_in

def test_awarded_team_must_be_one_of_the_match_teams_rule_5(db, tiny_match):
    outsider = new_team(db, "Outsider")
    fails(db, errors.ForeignKeyViolation,
          "UPDATE match SET result_type = 'forfeit', awarded_team_id = %s WHERE match_id = %s",
          (outsider, tiny_match["match_id"]))


def test_awarded_team_only_on_forfeit_even_when_result_type_is_null_rule_5(db, tiny_match):
    fails(db, errors.CheckViolation,
          "UPDATE match SET awarded_team_id = %s WHERE match_id = %s",
          (tiny_match["team_a"], tiny_match["match_id"]))


def test_score_must_belong_to_a_team_in_the_match_rule_6(db, tiny_match):
    m, outsider = tiny_match["match_id"], new_team(db, "Outsider")
    db.execute("INSERT INTO game (match_id, game_number, map_id, mode_id) VALUES (%s, 1, %s, %s)", (m, DEN, HP))
    fails(db, errors.ForeignKeyViolation,
          "INSERT INTO team_result (match_id, game_number, team_id, score) VALUES (%s, 1, %s, 250)", (m, outsider))


def test_match_has_at_most_two_slots_rule_1(db, tiny_match):
    third = new_team(db, "Third")
    fails(db, errors.CheckViolation,
          "INSERT INTO competes_in (match_id, team_id, slot) VALUES (%s, %s, 3)", (tiny_match["match_id"], third))


def test_penalty_game_needs_its_match_rule_19(db):
    official = one(db, "INSERT INTO person (first_name, last_name) VALUES ('Ref', 'One') RETURNING person_id")
    db.execute("INSERT INTO official (person_id, official_type) VALUES (%s, 'referee')", (official,))
    team = new_team(db, "Penalized")
    fails(db, errors.CheckViolation,
          """INSERT INTO penalty (penalty_type, reason, issued_by, team_id, game_number)
             VALUES ('warning', 'test', %s, %s, 1)""", (official, team))


def test_penalty_names_someone_rule_20(db):
    official = one(db, "INSERT INTO person (first_name, last_name) VALUES ('Ref', 'Two') RETURNING person_id")
    db.execute("INSERT INTO official (person_id, official_type) VALUES (%s, 'referee')", (official,))
    fails(db, errors.CheckViolation,
          "INSERT INTO penalty (penalty_type, reason, issued_by) VALUES ('warning', 'nobody', %s)", (official,))


# ---------------------------------------------------------------- views

def test_winner_views_follow_the_scores(db, tiny_match):
    m, a, b = tiny_match["match_id"], tiny_match["team_a"], tiny_match["team_b"]
    play_game(db, m, 1, DEN, HP, {a: 250, b: 201})
    play_game(db, m, 2, SCAR, SND, {a: 4, b: 6})
    play_game(db, m, 3, DEN, OVR, {a: 8, b: 5})
    play_game(db, m, 4, SCAR, HP, {a: 250, b: 240})
    winners = dict(db.execute("SELECT game_number, team_id FROM v_game_winner WHERE match_id = %s", (m,)).fetchall())
    assert winners == {1: a, 2: b, 3: a, 4: a}
    score = dict(db.execute("SELECT team_id, games_won FROM v_series_score WHERE match_id = %s", (m,)).fetchall())
    assert score == {a: 3, b: 1}
    assert one(db, "SELECT team_id FROM v_match_winner WHERE match_id = %s", (m,)) == a


def test_forfeited_match_is_won_by_the_awarded_team(db, tiny_match):
    m, b = tiny_match["match_id"], tiny_match["team_b"]
    db.execute("UPDATE match SET result_type = 'forfeit', awarded_team_id = %s WHERE match_id = %s", (b, m))
    assert one(db, "SELECT team_id FROM v_match_winner WHERE match_id = %s", (m,)) == b


def test_prize_pool_counts_every_placement_in_a_band(db, tiny_match):
    t = tiny_match["tournament_id"]
    db.execute("""INSERT INTO placement_reward (tournament_id, placement_from, placement_to, prize_amount)
                  VALUES (%s, 1, 1, 1000), (%s, 2, 2, 500), (%s, 3, 4, 250)""", (t, t, t))
    assert one(db, "SELECT prize_pool FROM v_tournament_prize_pool WHERE tournament_id = %s", (t,)) == 2000


def test_current_name_follows_the_open_identity(db):
    team = new_team(db, "Before", "2024-01-01")
    db.execute("UPDATE team_identity SET valid_to = '2026-01-01' WHERE team_id = %s", (team,))
    db.execute("INSERT INTO team_identity (team_id, valid_from, team_name) VALUES (%s, '2026-01-01', 'After')", (team,))
    assert one(db, "SELECT team_name FROM v_team_current_name WHERE team_id = %s", (team,)) == "After"


# ---------------------------------------------------------------- support objects

def test_raise_rule_uses_the_rule_number_as_the_error_code(db):
    with pytest.raises(psycopg.Error) as info:
        with db.transaction():
            db.execute("SELECT raise_rule(12, 'player has no stint on the match date')")
    assert info.value.sqlstate == "R0012"
    assert str(info.value).startswith("R0012: player has no stint")


def test_fn_fail_writes_one_error_log_row(db):
    ok, code, message, data = db.execute(
        "SELECT * FROM fn_fail('demo_function', '{\"x\": 1}', 'R0007', 'R0007: map not in pool')").fetchone()
    assert (ok, code) == (False, "R0007")
    row = db.execute("SELECT function_name, rule_no FROM error_log WHERE log_id = %s", (data["log_id"],)).fetchone()
    assert row == ("demo_function", 7)
