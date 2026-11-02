"""Phase 4, batch 3: run_map_veto (6), create_tournament (9), finalize_tournament (7),
withdraw_team (10), disband_team (11), update_map_pool (12).
"""
from psycopg.types.json import Jsonb

from conftest import (
    BLACKHEART, COLOSSUS, DEN, EXPOSURE, HP, OVR, POOL_2026, RAID, RAID_BO2, SCAR, SND,
    at_commit, fails_cleanly, list_players, new_cup, new_league, new_official, new_org, one, succeeds,
)
from test_functions_matches import play, series, setup_bracket, teams_of

VETO_TABLES = ["map_veto", "game"]
EVENT_TABLES = ["event", "hosted_by", "tournament", "phase", "placement_reward"]
PLACEMENTS = ["participates_in"]


# ---------------------------------------------------------------- run_map_veto

def cdl_veto(a, b):
    """The 2026 Bo5 veto: HP ban-ban-pick-pick, S&D ban-ban-pick-pick, Overload ban-ban."""
    v = lambda team, action, map_id, mode_id: {"team_id": team, "action": action, "map_id": map_id, "mode_id": mode_id}
    return [v(a, "ban", BLACKHEART, HP), v(b, "ban", COLOSSUS, HP), v(a, "pick", DEN, HP), v(b, "pick", SCAR, HP),
            v(b, "ban", RAID, SND), v(a, "ban", COLOSSUS, SND), v(b, "pick", SCAR, SND), v(a, "pick", EXPOSURE, SND),
            v(a, "ban", DEN, OVR), v(b, "ban", SCAR, OVR)]


def test_veto_records_picks_and_bans_and_sets_every_game(db, tiny_match):
    a, b, m = tiny_match["team_a"], tiny_match["team_b"], tiny_match["match_id"]
    result = succeeds(db, "run_map_veto", p_match_id=m, p_vetoes=Jsonb(cdl_veto(a, b)))
    assert [g["map"] for g in result["data"]["games"]] == [
        "Den (HP)", "Scar (S&D)", "Exposure (OVR)", "Scar (HP)", "Exposure (S&D)"]   # game 3 is the decider
    picked_by = dict(db.execute("SELECT game_number, team_id FROM v_map_picked_by WHERE match_id = %s", (m,)).fetchall())
    assert picked_by == {1: a, 2: b, 4: b, 5: a}


def test_record_fills_the_games_the_veto_set(db, tiny_match):
    w = tiny_match
    a, b, m = w["team_a"], w["team_b"], w["match_id"]
    succeeds(db, "run_map_veto", p_match_id=m, p_vetoes=Jsonb(cdl_veto(a, b)))
    payload = series(w["cup"], [a, b], [a, a, a])
    for game in payload["games"]:
        del game["map_id"], game["mode_id"]          # the veto already chose them
    payload["games"][2]["stats"] = [dict(s, mode_stats={"overloads_scored": 1})
                                    for s in payload["games"][2]["stats"]]
    succeeds(db, "record_series_result", p_match_id=m, p_series=payload)
    assert one(db, "SELECT count(*) FROM game WHERE match_id = %s AND status = 'scheduled'", (m,)) == 2
    at_commit(db)


def test_a_ban_outside_the_pool_saves_no_veto(db, tiny_match):
    a, b = tiny_match["team_a"], tiny_match["team_b"]
    vetoes = cdl_veto(a, b)
    vetoes[0] = {"team_id": a, "action": "ban", "map_id": RAID, "mode_id": HP}   # Raid is not a 2026 HP map
    fails_cleanly(db, "R0010", VETO_TABLES, "run_map_veto", p_match_id=tiny_match["match_id"], p_vetoes=Jsonb(vetoes))


def test_a_veto_must_leave_a_single_decider(db, tiny_match):
    a, b = tiny_match["team_a"], tiny_match["team_b"]
    fails_cleanly(db, "FN003", VETO_TABLES, "run_map_veto", p_match_id=tiny_match["match_id"],
                  p_vetoes=Jsonb(cdl_veto(a, b)[:-1]))           # only one Overload ban: two maps left


def test_a_match_is_vetoed_once(db, tiny_match):
    a, b, m = tiny_match["team_a"], tiny_match["team_b"], tiny_match["match_id"]
    succeeds(db, "run_map_veto", p_match_id=m, p_vetoes=Jsonb(cdl_veto(a, b)))
    fails_cleanly(db, "FN001", VETO_TABLES, "run_map_veto", p_match_id=m, p_vetoes=Jsonb(cdl_veto(a, b)))


# ---------------------------------------------------------------- create_tournament

PLAYOFFS = [{"phase_name": "Playoffs", "default_best_of": 5, "format_id": 2, "pool_id": POOL_2026,
             "layout_id": 1, "start_date": "2026-03-06", "end_date": "2026-03-08"}]
BANDS = [{"placement_from": 1, "placement_to": 1, "prize_amount": 200000, "points": 100},
         {"placement_from": 2, "placement_to": 2, "prize_amount": 100000, "points": 80},
         {"placement_from": 3, "placement_to": 4, "prize_amount": 50000, "points": 60}]


def test_create_tournament_writes_event_host_phases_and_bands(db):
    league = new_league(db)
    result = succeeds(db, "create_tournament", p_event_name="Major I", p_host_org_id=new_org(db),
                      p_tournament_type="major", p_team_size=4, p_max_teams=8,
                      p_start_date="2026-03-05", p_end_date="2026-03-08", p_stage=league,
                      p_phases=Jsonb(PLAYOFFS), p_prize_bands=Jsonb(BANDS))
    t = result["data"]["tournament_id"]
    assert result["data"]["prize_pool"] == 400000
    assert one(db, "SELECT count(*) FROM phase WHERE tournament_id = %s", (t,)) == 1
    assert one(db, "SELECT host_role FROM hosted_by WHERE event_id = %s", (t,)) == "organizer"
    at_commit(db)


def test_overlapping_prize_bands_leave_no_event_behind(db):
    bands = BANDS + [{"placement_from": 4, "placement_to": 6, "prize_amount": 10000}]
    fails_cleanly(db, "23P01", EVENT_TABLES, "create_tournament", p_event_name="Bad Bands",
                  p_host_org_id=new_org(db), p_tournament_type="major", p_team_size=4,
                  p_phases=Jsonb(PLAYOFFS), p_prize_bands=Jsonb(bands))


def test_a_tournament_outside_its_stage_is_refused(db):
    league = new_league(db)
    fails_cleanly(db, "R0025", EVENT_TABLES, "create_tournament", p_event_name="Summer Major",
                  p_host_org_id=new_org(db), p_tournament_type="major", p_team_size=4,
                  p_start_date="2026-07-05", p_end_date="2026-07-08", p_stage=league)


# ---------------------------------------------------------------- finalize_tournament

def run_bracket(db, teams):
    """Play a whole double elimination bracket; the higher seed (slot 1) wins every match."""
    cup = setup_bracket(db, teams=teams)
    order = db.execute("""SELECT match_id FROM match WHERE tournament_id = %s ORDER BY match_number""",
                       (cup["tournament_id"],)).fetchall()
    for (match_id,) in order:
        play(db, cup, match_id)
    return cup


def placements(db, cup):
    return [one(db, "SELECT final_placement FROM participates_in WHERE tournament_id = %s AND team_id = %s",
                (cup["tournament_id"], t)) for t in cup["teams"]]


def test_finalize_places_every_team(db):
    cup = run_bracket(db, 4)
    db.execute("""INSERT INTO placement_reward (tournament_id, placement_from, placement_to, prize_amount)
                  VALUES (%s, 1, 1, 1000), (%s, 2, 2, 500)""", (cup["tournament_id"], cup["tournament_id"]))
    result = succeeds(db, "finalize_tournament", p_tournament_id=cup["tournament_id"])
    # Slot 1 wins every match. Seed 1 wins everything: 1st. Seed 4 loses to seed 1, then beats
    # seed 3 and seed 2 in the lower bracket, then loses the grand final: 2nd. Seed 2 loses the
    # upper final and the lower final: 3rd. Seed 3 is out in lower round 1: 4th.
    assert placements(db, cup) == [1, 3, 4, 2]
    assert result["data"]["placements"][0]["prize"] == 1000
    at_commit(db)


def test_teams_out_in_the_same_round_share_a_placement(db):
    cup = run_bracket(db, 8)
    succeeds(db, "finalize_tournament", p_tournament_id=cup["tournament_id"])
    assert sorted(placements(db, cup)) == [1, 2, 3, 4, 5, 5, 7, 7]


def test_finalize_waits_for_every_match(db):
    cup = setup_bracket(db)
    play(db, cup, cup["ids"]["U1-1"])
    result = fails_cleanly(db, "FN001", PLACEMENTS, "finalize_tournament", p_tournament_id=cup["tournament_id"])
    assert "is not finished" in result["message"]
    assert one(db, "SELECT count(final_placement) FROM participates_in WHERE tournament_id = %s",
               (cup["tournament_id"],)) == 0


# ---------------------------------------------------------------- withdraw_team

def test_a_withdrawn_team_forfeits_down_through_the_bracket(db):
    cup = setup_bracket(db)
    ids, (s1, s2, s3, s4) = cup["ids"], cup["teams"]
    play(db, cup, ids["U1-1"])                                       # s4 drops to lower round 1
    result = succeeds(db, "withdraw_team", p_tournament_id=cup["tournament_id"], p_team_id=s2,
                      p_official_id=new_official(db), p_reason="visa problems")
    # s2 forfeits its upper match to s3, drops to the lower bracket, and forfeits there to s4
    assert result["data"]["forfeited"] == [ids["U1-2"], ids["L1-1"]]
    assert result["data"]["waiting"] == []
    assert teams_of(db, ids["U2-1"]) == [s1, s3]
    assert teams_of(db, ids["L2-1"]) == [s4]
    assert one(db, "SELECT count(*) FROM penalty WHERE team_id = %s AND penalty_type = 'match forfeit'", (s2,)) == 2
    at_commit(db)


def test_a_match_without_an_opponent_waits_and_a_second_call_finishes_it(db):
    cup = setup_bracket(db)
    ids, (s1, s2, s3, s4) = cup["ids"], cup["teams"]
    ref = new_official(db)
    first = succeeds(db, "withdraw_team", p_tournament_id=cup["tournament_id"], p_team_id=s2,
                     p_official_id=ref, p_reason="visa problems")
    assert first["data"]["waiting"] == [ids["L1-1"]]                 # its lower-bracket opponent is not known
    play(db, cup, ids["U1-1"])                                       # now s4 arrives in lower round 1
    second = succeeds(db, "withdraw_team", p_tournament_id=cup["tournament_id"], p_team_id=s2,
                      p_official_id=ref, p_reason="visa problems")
    assert second["data"]["forfeited"] == [ids["L1-1"]] and second["data"]["waiting"] == []


def test_withdrawing_a_team_that_is_not_in_the_tournament(db):
    cup = setup_bracket(db)
    other = new_cup(db, "Other", teams=1)
    fails_cleanly(db, "FN002", ["match", "penalty"], "withdraw_team", p_tournament_id=cup["tournament_id"],
                  p_team_id=other["teams"][0], p_official_id=new_official(db), p_reason="mistake")


# ---------------------------------------------------------------- disband_team

def test_disband_ends_stints_and_forfeits_upcoming_matches(db, tiny_match):
    w = tiny_match
    result = succeeds(db, "disband_team", p_team_id=w["team_b"], p_date="2026-02-20",
                      p_official_id=new_official(db))
    assert result["data"]["stints_ended"] == 4
    assert one(db, "SELECT status FROM team WHERE team_id = %s", (w["team_b"],)) == "disbanded"
    assert one(db, """SELECT count(*) FROM roster WHERE team_id = %s
                      AND end_date = '2026-02-20' AND end_reason = 'team disbanded'""", (w["team_b"],)) == 4
    assert one(db, "SELECT team_id FROM v_match_winner WHERE match_id = %s", (w["match_id"],)) == w["team_a"]
    at_commit(db)


def test_a_team_in_a_live_match_cannot_disband(db, tiny_match):
    db.execute("UPDATE match SET status = 'live' WHERE match_id = %s", (tiny_match["match_id"],))
    fails_cleanly(db, "FN001", ["roster", "penalty"], "disband_team", p_team_id=tiny_match["team_b"],
                  p_date="2026-02-20", p_official_id=new_official(db))
    assert one(db, "SELECT status FROM team WHERE team_id = %s", (tiny_match["team_b"],)) == "active"


# ---------------------------------------------------------------- update_map_pool

STAGE_2_POOL = [{"map_id": m, "mode_id": HP} for m in (BLACKHEART, COLOSSUS, DEN, SCAR)] + \
               [{"map_id": m, "mode_id": SND} for m in (COLOSSUS, DEN, EXPOSURE, RAID, SCAR)] + \
               [{"map_id": m, "mode_id": OVR} for m in (DEN, EXPOSURE, SCAR)]


def test_a_new_pool_version_moves_unstarted_phases(db, tiny_match):
    t = tiny_match["tournament_id"]
    result = succeeds(db, "update_map_pool", p_pool_name="CDL 2026 pool, Stage 2", p_entries=Jsonb(STAGE_2_POOL),
                      p_phases=Jsonb([{"tournament_id": t, "phase_number": 1}]))
    assert one(db, "SELECT pool_id FROM phase WHERE tournament_id = %s", (t,)) == result["data"]["pool_id"]
    assert one(db, "SELECT count(*) FROM pool_entry WHERE pool_id = %s", (POOL_2026,)) == 13   # old pool untouched
    at_commit(db)


def test_a_phase_with_games_keeps_its_pool(db, tiny_match):
    w = tiny_match
    list_players(db, w["match_id"], w["cup"], [w["team_a"], w["team_b"]])
    db.execute("INSERT INTO game (match_id, game_number, map_id, mode_id) VALUES (%s, 1, %s, %s)",
               (w["match_id"], DEN, HP))
    fails_cleanly(db, "FN001", ["map_pool", "pool_entry"], "update_map_pool", p_pool_name="Too late",
                  p_entries=Jsonb(STAGE_2_POOL), p_phases=Jsonb([{"tournament_id": w["tournament_id"], "phase_number": 1}]))


def test_a_pool_must_cover_the_layout_modes(db, tiny_match):
    no_overload = [e for e in STAGE_2_POOL if e["mode_id"] != OVR]
    fails_cleanly(db, "R0008", ["map_pool", "pool_entry"], "update_map_pool", p_pool_name="No Overload",
                  p_entries=Jsonb(no_overload),
                  p_phases=Jsonb([{"tournament_id": tiny_match["tournament_id"], "phase_number": 1}]))


def test_a_pool_cannot_mix_game_titles(db):
    fails_cleanly(db, "R0009", ["map_pool", "pool_entry"], "update_map_pool", p_pool_name="Mixed",
                  p_entries=Jsonb(STAGE_2_POOL + [{"map_id": RAID_BO2, "mode_id": SND}]))




# ---------------------------------------------------------------- review fixes

def test_a_disbanded_team_cannot_be_placed_in_a_bracket(db):
    cup = new_cup(db, "After Disband", teams=4)
    db.execute("UPDATE team SET status = 'disbanded' WHERE team_id = %s", (cup["teams"][3],))
    fails_cleanly(db, "FN001", ["match", "competes_in"], "setup_tournament_phase",
                  p_tournament_id=cup["tournament_id"], p_phase_number=1, p_teams=Jsonb(cup["teams"]))


def test_withdrawing_before_any_match_removes_the_entry(db):
    cup = new_cup(db, "Not Started", teams=4)
    result = succeeds(db, "withdraw_team", p_tournament_id=cup["tournament_id"], p_team_id=cup["teams"][0],
                      p_official_id=new_official(db), p_reason="schedule clash")
    assert result["data"]["entry_removed"] is True
    assert one(db, "SELECT count(*) FROM participates_in WHERE tournament_id = %s", (cup["tournament_id"],)) == 3


def test_disband_also_leaves_events_that_have_not_started(db, tiny_match):
    upcoming = new_cup(db, "Upcoming", teams=0)
    db.execute("INSERT INTO participates_in (team_id, tournament_id) VALUES (%s, %s)",
               (tiny_match["team_b"], upcoming["tournament_id"]))
    succeeds(db, "disband_team", p_team_id=tiny_match["team_b"], p_date="2026-02-20", p_official_id=new_official(db))
    assert one(db, "SELECT count(*) FROM participates_in WHERE team_id = %s AND tournament_id = %s",
               (tiny_match["team_b"], upcoming["tournament_id"])) == 0


def test_stats_for_a_player_outside_the_lineups(db):
    cup = setup_bracket(db)
    m = cup["ids"]["U1-1"]
    teams = teams_of(db, m)
    payload = series(cup, teams, [teams[0]] * 3)
    outsider = cup["players"][cup["teams"][1]][0]          # seed 2 does not play this match
    payload["games"][0]["stats"][0]["person_id"] = outsider
    result = fails_cleanly(db, "FN003", ["game", "match_player"], "record_series_result", p_match_id=m, p_series=payload)
    assert "has stats but is not in either lineup" in result["message"]


def test_games_are_numbered_without_gaps(db):
    cup = setup_bracket(db)
    m = cup["ids"]["U1-1"]
    teams = teams_of(db, m)
    payload = series(cup, teams, [teams[0]] * 3)
    payload["games"][2]["game_number"] = 4
    fails_cleanly(db, "FN003", ["game", "match_player"], "record_series_result", p_match_id=m, p_series=payload)
