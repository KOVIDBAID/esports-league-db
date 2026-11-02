"""Phase 4, batch 1: transfer_player (3), rebrand_team (4), sign_new_player (8).

Each function has a success test (the expected rows exist and fn_result reports success)
and failure tests that use fails_cleanly(): the call reports the expected code, every table
it touches has the same row count as before, and error_log gains exactly one row.
"""
from conftest import (
    call, fails_cleanly, list_players, new_player, new_team, one, succeeds,
)

ROSTER = ["roster", "person", "player", "person_phone"]
IDENTITY = ["team_identity", "team"]


def stint(db, person_id, team_id):
    return db.execute("""SELECT start_date::text, end_date::text, roster_role, end_reason FROM roster
                         WHERE person_id = %s AND team_id = %s ORDER BY start_date""",
                      (person_id, team_id)).fetchall()


# ---------------------------------------------------------------- transfer_player

def test_transfer_closes_the_old_stint_and_opens_the_new_one(db, tiny_match):
    player, a, b = tiny_match["players_a"][0], tiny_match["team_a"], tiny_match["team_b"]
    result = succeeds(db, "transfer_player", p_person_id=player, p_from_team=a, p_to_team=b,
                      p_date="2026-04-01", p_role="substitute", p_fee=150000)
    assert result["data"] == {"person_id": player, "from_team": a, "to_team": b, "date": "2026-04-01"}
    assert stint(db, player, a) == [("2026-01-01", "2026-04-01", "starter", "transferred")]
    assert stint(db, player, b) == [("2026-04-01", None, "substitute", None)]
    assert one(db, "SELECT team_id FROM v_roster_current WHERE person_id = %s", (player,)) == b


def test_transfer_needs_an_open_stint_with_the_old_team(db, tiny_match):
    result = fails_cleanly(db, "FN002", ROSTER, "transfer_player", p_person_id=tiny_match["players_a"][0],
                           p_from_team=tiny_match["team_b"], p_to_team=tiny_match["team_a"], p_date="2026-04-01")
    assert "has no open stint with" in result["message"]


def test_transfer_to_a_team_with_two_two_way_players_changes_nothing(db, tiny_match):
    academy = new_team(db, "Academy")
    new_player(db, "TwoWay1", academy, role="two-way")
    new_player(db, "TwoWay2", academy, role="two-way")
    player = tiny_match["players_a"][0]
    fails_cleanly(db, "R0014", ROSTER, "transfer_player", p_person_id=player, p_from_team=tiny_match["team_a"],
                  p_to_team=academy, p_date="2026-04-01", p_role="two-way")
    assert stint(db, player, tiny_match["team_a"]) == [("2026-01-01", None, "starter", None)]


def test_transfer_cannot_backdate_past_a_match_the_player_played(db, tiny_match):
    w = tiny_match
    list_players(db, w["match_id"], w["cup"], [w["team_a"]])
    fails_cleanly(db, "R0012", ROSTER, "transfer_player", p_person_id=w["players_a"][0], p_from_team=w["team_a"],
                  p_to_team=w["team_b"], p_date="2026-02-15")


def test_transfer_date_must_follow_the_stint_start(db, tiny_match):
    fails_cleanly(db, "FN003", ROSTER, "transfer_player", p_person_id=tiny_match["players_a"][0],
                  p_from_team=tiny_match["team_a"], p_to_team=tiny_match["team_b"], p_date="2026-01-01")


def test_transfer_to_a_disbanded_team(db, tiny_match):
    db.execute("UPDATE team SET status = 'disbanded' WHERE team_id = %s", (tiny_match["team_b"],))
    fails_cleanly(db, "FN001", ROSTER, "transfer_player", p_person_id=tiny_match["players_a"][0],
                  p_from_team=tiny_match["team_a"], p_to_team=tiny_match["team_b"], p_date="2026-04-01")


# ---------------------------------------------------------------- rebrand_team

def test_rebrand_keeps_the_old_name_in_history(db):
    team = new_team(db, "Seattle Surge", valid_from="2024-01-01")
    db.execute("UPDATE team_identity SET abbreviation = 'SEA', home_city = 'Seattle' WHERE team_id = %s", (team,))
    result = succeeds(db, "rebrand_team", p_team_id=team, p_from="2026-05-01", p_name="Vancouver Surge",
                      p_city="Vancouver")
    assert result["data"]["old_name"] == "Seattle Surge" and result["data"]["new_name"] == "Vancouver Surge"
    history = db.execute("""SELECT team_name, abbreviation, home_city, valid_from::text, valid_to::text
                            FROM team_identity WHERE team_id = %s ORDER BY valid_from""", (team,)).fetchall()
    assert history == [("Seattle Surge", "SEA", "Seattle", "2024-01-01", "2026-05-01"),
                       ("Vancouver Surge", "SEA", "Vancouver", "2026-05-01", None)]
    assert one(db, "SELECT team_name FROM v_team_current_name WHERE team_id = %s", (team,)) == "Vancouver Surge"


def test_rebrand_must_start_after_the_current_identity(db):
    team = new_team(db, "Old Name", valid_from="2025-06-01")
    result = fails_cleanly(db, "FN003", IDENTITY, "rebrand_team", p_team_id=team, p_from="2025-01-01",
                           p_name="Too Early")
    assert 'after "Old Name" began on 2025-06-01' in result["message"]


def test_rebrand_an_unknown_team(db):
    fails_cleanly(db, "FN002", IDENTITY, "rebrand_team", p_team_id=999999, p_from="2026-05-01", p_name="Ghost")


# ---------------------------------------------------------------- sign_new_player

def test_sign_creates_person_phones_player_and_stint(db):
    team = new_team(db, "Signing FC")
    result = succeeds(db, "sign_new_player", p_first_name="Ana", p_last_name="Ruiz", p_gamertag="Nova",
                      p_activision_id="Nova#0001", p_primary_role="SMG", p_region_id=1,
                      p_phones=["+1 555 0100", "+1 555 0101", "+1 555 0100"], p_team_id=team,
                      p_start_date="2026-01-10")
    person = result["data"]["person_id"]
    assert one(db, "SELECT count(*) FROM person_phone WHERE person_id = %s", (person,)) == 2
    assert one(db, "SELECT activision_id FROM player WHERE person_id = %s", (person,)) == "Nova#0001"
    assert stint(db, person, team) == [("2026-01-10", None, "starter", None)]


def test_sign_with_a_duplicate_activision_id_leaves_no_person_behind(db):
    new_player(db, "Existing")
    taken = one(db, "SELECT activision_id FROM player ORDER BY person_id DESC LIMIT 1")
    fails_cleanly(db, "23505", ROSTER, "sign_new_player", p_first_name="Copy", p_last_name="Cat",
                  p_gamertag="Copycat", p_activision_id=taken, p_primary_role="AR", p_phones=["+1 555 0199"])


def test_sign_as_a_coach_without_a_coach_record(db):
    team = new_team(db, "Coach FC")
    fails_cleanly(db, "R0015", ROSTER, "sign_new_player", p_first_name="Not", p_last_name="Coach",
                  p_gamertag="NC", p_activision_id="NC#1", p_primary_role="flex", p_team_id=team,
                  p_role="head coach", p_start_date="2026-01-10")


def test_a_failed_call_leaves_the_transaction_usable(db, tiny_match):
    fails_cleanly(db, "FN002", ROSTER, "transfer_player", p_person_id=tiny_match["players_a"][0],
                  p_from_team=tiny_match["team_b"], p_to_team=tiny_match["team_a"], p_date="2026-04-01")
    succeeds(db, "transfer_player", p_person_id=tiny_match["players_a"][0], p_from_team=tiny_match["team_a"],
             p_to_team=tiny_match["team_b"], p_date="2026-04-01")
    assert call(db, "rebrand_team", p_team_id=tiny_match["team_a"], p_from="2026-06-01", p_name="Renamed")["ok"]


