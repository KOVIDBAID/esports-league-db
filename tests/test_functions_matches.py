"""Phase 4, batch 2: setup_tournament_phase (1), record_series_result (2),
resolve_dispute (5) with raise_dispute.
"""
from psycopg.types.json import Jsonb

from conftest import (
    DEN, EXPOSURE, HP, OVR, RAID, SCAR, SND, at_commit, call, fails_cleanly, new_cup, new_league,
    new_official, new_player, new_team, one, succeeds,
)

MATCH_TABLES = ["match", "competes_in", "participates_in"]
SERIES_TABLES = ["match_player", "game", "team_result", "player_game_stats", "hardpoint_stats",
                 "snd_stats", "overload_stats", "competes_in"]
DISPUTE_TABLES = ["dispute", "penalty", "competes_in"]

# Bo5 slots are HP, S&D, OVR, HP, S&D; these map-mode pairs are all in the 2026 pool.
MAPS = [(DEN, HP), (SCAR, SND), (DEN, OVR), (SCAR, HP), (EXPOSURE, SND)]
SCORES = {HP: (250, 201), SND: (6, 4), OVR: (8, 5)}
MODE_STATS = {HP: {"hill_time_seconds": 80, "captures": 3}, SND: {"first_bloods": 1, "plants": 1},
              OVR: {"overloads_scored": 2, "device_pickups": 3}}


# ---------------------------------------------------------------- helpers

def setup_bracket(db, teams=4, fmt=None, **cup_args):
    cup = new_cup(db, "Major", teams=teams, **cup_args)
    if fmt is not None:
        db.execute("UPDATE phase SET format_id = %s WHERE tournament_id = %s", (fmt, cup["tournament_id"]))
    result = succeeds(db, "setup_tournament_phase", p_tournament_id=cup["tournament_id"], p_phase_number=1,
                      p_teams=Jsonb(cup["teams"]))
    cup["ids"] = result["data"].get("match_ids", {})
    return cup


def teams_of(db, match_id):
    return [r[0] for r in db.execute("SELECT team_id FROM competes_in WHERE match_id = %s ORDER BY slot",
                                     (match_id,))]


def series(cup, teams, winners, *, skip_stats_for=None, extra_player=None):
    """A series JSON. winners: the winning team of each game, in order."""
    games = []
    for number, winner in enumerate(winners, start=1):
        map_id, mode_id = MAPS[number - 1]
        high, low = SCORES[mode_id]
        loser = teams[1] if winner == teams[0] else teams[0]
        stats = [{"person_id": p, "kills": 22, "deaths": 19, "assists": 4, "damage": 3100,
                  "mode_stats": MODE_STATS[mode_id]}
                 for t in teams for p in cup["players"][t] if p != skip_stats_for]
        games.append({"game_number": number, "map_id": map_id, "mode_id": mode_id, "duration_seconds": 600,
                      "scores": [{"team_id": winner, "score": high}, {"team_id": loser, "score": low}],
                      "stats": stats})
    lineups = [{"team_id": t, "players": list(cup["players"][t])} for t in teams]
    if extra_player:
        team_id, person_id = extra_player
        lineups[[l["team_id"] for l in lineups].index(team_id)]["players"][0] = person_id
        for g in games:
            for s in g["stats"]:
                if s["person_id"] == cup["players"][team_id][0]:
                    s["person_id"] = person_id
    return {"lineups": lineups, "games": games}


def play(db, cup, match_id, winner_slot=1, length=3):
    teams = teams_of(db, match_id)
    winner = teams[winner_slot - 1]
    return succeeds(db, "record_series_result", p_match_id=match_id,
                    p_series=series(cup, teams, [winner] * length))


# ---------------------------------------------------------------- setup_tournament_phase

def test_setup_builds_a_seeded_double_elimination_bracket(db):
    cup = setup_bracket(db, teams=8)
    t, seeds = cup["tournament_id"], cup["teams"]
    assert one(db, "SELECT count(*) FROM match WHERE tournament_id = %s", (t,)) == 14
    first_round = [teams_of(db, cup["ids"][f"U1-{i}"]) for i in range(1, 5)]
    assert first_round == [[seeds[0], seeds[7]], [seeds[3], seeds[4]], [seeds[1], seeds[6]], [seeds[2], seeds[5]]]
    links = db.execute("""SELECT count(winner_to_match_id), count(loser_to_match_id) FROM match
                          WHERE tournament_id = %s""", (t,)).fetchone()
    assert links == (13, 7)              # every match but the grand final sends its winner on;
    gf = cup["ids"]["GF"]                # every upper-bracket match sends its loser down
    feeders = db.execute("""SELECT round_name FROM match WHERE winner_to_match_id = %s
                            ORDER BY winner_to_slot""", (gf,)).fetchall()
    assert feeders == [("Upper final",), ("Lower final",)]
    at_commit(db)


def test_setup_builds_single_elimination_and_round_robin(db):
    single = setup_bracket(db, teams=4, fmt=1)
    assert one(db, "SELECT count(*) FROM match WHERE tournament_id = %s", (single["tournament_id"],)) == 3
    assert one(db, """SELECT count(*) FROM match WHERE tournament_id = %s
                      AND round_name = 'Final' AND winner_to_match_id IS NULL""", (single["tournament_id"],)) == 1
    groups = setup_bracket(db, teams=4, fmt=3)
    assert one(db, """SELECT count(*) FROM match m WHERE tournament_id = %s
                      AND (SELECT count(*) FROM competes_in c WHERE c.match_id = m.match_id) = 2""",
               (groups["tournament_id"],)) == 6
    at_commit(db)


def test_setup_runs_once_per_phase(db):
    cup = setup_bracket(db, teams=4)
    fails_cleanly(db, "FN001", MATCH_TABLES, "setup_tournament_phase", p_tournament_id=cup["tournament_id"],
                  p_phase_number=1, p_teams=Jsonb(cup["teams"]))


def test_setup_needs_a_power_of_two_for_elimination(db):
    cup = new_cup(db, "Odd Cup", teams=6)
    fails_cleanly(db, "FN003", MATCH_TABLES, "setup_tournament_phase", p_tournament_id=cup["tournament_id"],
                  p_phase_number=1, p_teams=Jsonb(cup["teams"]))


def test_setup_with_a_team_not_registered_for_the_season_creates_nothing(db):
    league = new_league(db)
    cup = new_cup(db, "Major", teams=3, league=league)
    unregistered = new_team(db, "Unregistered")
    result = fails_cleanly(db, "R0026", MATCH_TABLES, "setup_tournament_phase",
                           p_tournament_id=cup["tournament_id"], p_phase_number=1,
                           p_teams=Jsonb(cup["teams"] + [unregistered]))
    assert "Unregistered is not registered" in result["message"]


def test_setup_beyond_max_teams_creates_nothing(db):
    cup = new_cup(db, "Small Cup", teams=0, max_teams=4)
    teams = [new_team(db, f"Team {i}") for i in range(8)]
    fails_cleanly(db, "R0027", MATCH_TABLES, "setup_tournament_phase", p_tournament_id=cup["tournament_id"],
                  p_phase_number=1, p_teams=Jsonb(teams))


# ---------------------------------------------------------------- record_series_result

def test_record_completes_the_match_and_moves_both_teams_on(db):
    cup = setup_bracket(db)
    ids, (s1, s2, s3, s4) = cup["ids"], cup["teams"]
    result = play(db, cup, ids["U1-1"])                  # seed 1 beats seed 4, 3-0
    assert result["data"]["winner_team_id"] == s1
    assert result["data"]["score"] == {str(s1): 3, str(s4): 0}
    assert one(db, "SELECT status FROM match WHERE match_id = %s", (ids["U1-1"],)) == "completed"
    assert teams_of(db, ids["U2-1"]) == [s1]             # upper final, slot 1
    assert teams_of(db, ids["L1-1"]) == [s4]             # lower round 1, slot 1
    assert one(db, "SELECT count(*) FROM player_game_stats WHERE match_id = %s", (ids["U1-1"],)) == 24


def test_a_whole_double_elimination_bracket_runs_to_a_champion(db):
    cup = setup_bracket(db)
    ids = cup["ids"]
    for key in ["U1-1", "U1-2", "U2-1", "L1-1", "L2-1", "GF"]:
        play(db, cup, ids[key], winner_slot=2 if key == "L2-1" else 1, length=3)
    at_commit(db)
    champion = one(db, "SELECT team_id FROM v_match_winner WHERE match_id = %s", (ids["GF"],))
    assert champion == cup["teams"][0]


def test_a_second_record_for_the_same_match_changes_nothing(db):
    cup = setup_bracket(db)
    play(db, cup, cup["ids"]["U1-1"])
    teams = teams_of(db, cup["ids"]["U1-1"])
    fails_cleanly(db, "FN001", SERIES_TABLES, "record_series_result", p_match_id=cup["ids"]["U1-1"],
                  p_series=series(cup, teams, [teams[0]] * 3))


def test_one_ineligible_player_saves_none_of_the_series(db):
    cup = setup_bracket(db)
    m = cup["ids"]["U1-1"]
    teams = teams_of(db, m)
    ringer = new_player(db, "Ringer")                    # a player with no stint on any team
    result = fails_cleanly(db, "R0012", SERIES_TABLES, "record_series_result", p_match_id=m,
                           p_series=series(cup, teams, [teams[0]] * 3, extra_player=(teams[0], ringer)))
    assert "Ringer has no playing or coaching stint" in result["message"]
    assert one(db, "SELECT status FROM match WHERE match_id = %s", (m,)) == "scheduled"


def test_the_games_must_decide_the_series(db):
    cup = setup_bracket(db)
    m = cup["ids"]["U1-1"]
    teams = teams_of(db, m)
    fails_cleanly(db, "FN003", SERIES_TABLES, "record_series_result", p_match_id=m,
                  p_series=series(cup, teams, [teams[0], teams[1]]))


def test_no_game_after_the_series_is_decided(db):
    cup = setup_bracket(db)
    m = cup["ids"]["U1-1"]
    teams = teams_of(db, m)
    fails_cleanly(db, "R0004", SERIES_TABLES, "record_series_result", p_match_id=m,
                  p_series=series(cup, teams, [teams[0], teams[0], teams[0], teams[1]]))


def test_every_player_needs_stats_in_every_game(db):
    cup = setup_bracket(db)
    m = cup["ids"]["U1-1"]
    teams = teams_of(db, m)
    fails_cleanly(db, "R0011", SERIES_TABLES, "record_series_result", p_match_id=m,
                  p_series=series(cup, teams, [teams[0]] * 3, skip_stats_for=cup["players"][teams[1]][0]))


def test_a_map_outside_the_pool_saves_nothing(db):
    cup = setup_bracket(db)
    m = cup["ids"]["U1-1"]
    teams = teams_of(db, m)
    bad = series(cup, teams, [teams[0]] * 3)
    bad["games"][0]["map_id"] = RAID                     # Raid is S&D only in 2026, not Hardpoint
    fails_cleanly(db, "R0007", SERIES_TABLES, "record_series_result", p_match_id=m, p_series=bad)


def test_a_match_waiting_for_its_teams_cannot_be_recorded(db):
    cup = setup_bracket(db)
    fails_cleanly(db, "FN001", SERIES_TABLES, "record_series_result", p_match_id=cup["ids"]["U2-1"],
                  p_series={"lineups": [], "games": [{"game_number": 1}]})


# ---------------------------------------------------------------- raise_dispute and resolve_dispute

def played_match(db):
    cup = setup_bracket(db)
    m = cup["ids"]["U1-1"]
    play(db, cup, m)                                     # slot 1 (seed 1) wins 3-0
    winner, loser = teams_of(db, m)
    return cup, m, winner, loser


def test_disputes_are_numbered_per_match(db):
    cup, m, winner, loser = played_match(db)
    assert succeeds(db, "raise_dispute", p_match_id=m, p_team_id=loser, p_reason="lag")["data"]["dispute_number"] == 1
    assert succeeds(db, "raise_dispute", p_match_id=m, p_team_id=winner, p_reason="ruling")["data"]["dispute_number"] == 2


def test_only_a_team_in_the_match_can_raise_a_dispute(db):
    cup, m, winner, loser = played_match(db)
    fails_cleanly(db, "23503", ["dispute"], "raise_dispute", p_match_id=m, p_team_id=cup["teams"][1],
                  p_reason="not even playing")


def test_an_upheld_dispute_overturns_the_result_and_the_bracket_follows(db):
    cup, m, winner, loser = played_match(db)
    ref = new_official(db)
    succeeds(db, "raise_dispute", p_match_id=m, p_team_id=loser, p_reason="illegal weapon")
    result = succeeds(db, "resolve_dispute", p_match_id=m, p_dispute_number=1, p_official_id=ref,
                      p_decision="resolved", p_resolution="Winner used a banned weapon",
                      p_forfeit={"awarded_team_id": loser},
                      p_penalties=Jsonb([{"penalty_type": "match forfeit", "team_id": winner}]))
    assert result["data"]["winner_team_id"] == loser
    assert teams_of(db, cup["ids"]["U2-1"]) == [loser]   # the swap reaches the next matches
    assert teams_of(db, cup["ids"]["L1-1"]) == [winner]
    assert db.execute("SELECT status, resolved_by FROM dispute WHERE match_id = %s", (m,)).fetchone() == ("resolved", ref)
    assert one(db, "SELECT dispute_number FROM penalty WHERE match_id = %s", (m,)) == 1
    at_commit(db)


def test_a_penalty_for_a_team_outside_the_match_keeps_the_dispute_open(db):
    cup, m, winner, loser = played_match(db)
    succeeds(db, "raise_dispute", p_match_id=m, p_team_id=loser, p_reason="lag")
    fails_cleanly(db, "23503", DISPUTE_TABLES, "resolve_dispute", p_match_id=m, p_dispute_number=1,
                  p_official_id=new_official(db), p_decision="resolved", p_resolution="warnings",
                  p_penalties=Jsonb([{"penalty_type": "warning", "team_id": cup["teams"][1]}]))
    assert one(db, "SELECT status FROM dispute WHERE match_id = %s", (m,)) == "open"


def test_a_game_forfeit_penalty_needs_a_forfeited_game(db):
    cup, m, winner, loser = played_match(db)
    succeeds(db, "raise_dispute", p_match_id=m, p_team_id=loser, p_reason="late start")
    fails_cleanly(db, "R0021", DISPUTE_TABLES, "resolve_dispute", p_match_id=m, p_dispute_number=1,
                  p_official_id=new_official(db), p_decision="resolved", p_resolution="late",
                  p_penalties=Jsonb([{"penalty_type": "game forfeit", "team_id": winner, "game_number": 1}]))


def test_a_closed_dispute_cannot_be_resolved_again(db):
    cup, m, winner, loser = played_match(db)
    ref = new_official(db)
    succeeds(db, "raise_dispute", p_match_id=m, p_team_id=loser, p_reason="lag")
    succeeds(db, "resolve_dispute", p_match_id=m, p_dispute_number=1, p_official_id=ref,
             p_decision="rejected", p_resolution="No evidence of lag")
    assert teams_of(db, cup["ids"]["U2-1"]) == [winner]
    fails_cleanly(db, "FN001", DISPUTE_TABLES, "resolve_dispute", p_match_id=m, p_dispute_number=1,
                  p_official_id=ref, p_decision="resolved", p_resolution="changed my mind")
