"""Phase 3 tests: every rule enforced by a trigger refuses the change that would break it.

Each test builds a valid world with the builders in conftest.py, makes one change that
breaks one rule, and expects that rule's code: R00nn for rule nn, T000n for the total-
participation constraints. Checks that wait for commit run via rejects_at_commit().
The first tests show that valid data passes everything, so a refusal below is caused
by the one change the test makes.
"""
from conftest import (
    COLOSSUS, CTL, DEN, EU, HP, NA, OVR, POOL_2026, RAID_BO2, SCAR, SND,
    add_stats, add_stint, at_commit, list_players, new_cup, new_event, new_league, new_match,
    new_official, new_person, new_player, new_team, one, play_game, rejects, rejects_at_commit,
)


def sweep(db, w):
    """Team A wins games 1 to 3 (HP Den, S&D Scar, OVR Den) with full stats."""
    m, a, b = w["match_id"], w["team_a"], w["team_b"]
    players = {a: w["players_a"], b: w["players_b"]}
    play_game(db, m, 1, DEN, HP, {a: 250, b: 180}, players)
    play_game(db, m, 2, SCAR, SND, {a: 6, b: 3}, players)
    play_game(db, m, 3, DEN, OVR, {a: 8, b: 4}, players)


# ---------------------------------------------------------------- valid data passes

def test_a_full_valid_match_passes_every_check(db, tiny_match):
    w = tiny_match
    list_players(db, w["match_id"], w["cup"], [w["team_a"], w["team_b"]])
    sweep(db, w)
    db.execute("UPDATE match SET status = 'completed', result_type = 'played' WHERE match_id = %s",
               (w["match_id"],))
    at_commit(db)
    assert one(db, "SELECT team_id FROM v_match_winner WHERE match_id = %s", (w["match_id"],)) == w["team_a"]


def test_a_valid_league_tournament_passes_every_check(db):
    league = new_league(db)
    cup = new_cup(db, "Stage 1 Major", league=league, region_id=NA)
    a, b = cup["teams"]
    m = new_match(db, cup, [a, b])
    list_players(db, m, cup, [a, b])
    play_game(db, m, 1, DEN, HP, {a: 250, b: 240}, {a: cup["players"][a], b: cup["players"][b]})
    at_commit(db)


# ---------------------------------------------------------------- matches and brackets

def test_r01_a_started_match_needs_two_teams(db, tiny_match):
    cup = tiny_match["cup"]
    m2 = new_match(db, cup, [tiny_match["team_a"]], match_number=2)
    db.execute("UPDATE match SET status = 'live' WHERE match_id = %s", (m2,))
    rejects_at_commit(db, "R0001")


def test_r02_team_must_participate_in_the_tournament(db, tiny_match):
    outsider = new_team(db, "Outsider")
    m2 = new_match(db, tiny_match["cup"], [tiny_match["team_a"]], match_number=2)
    message = rejects(db, "R0002", "INSERT INTO competes_in (match_id, team_id, slot) VALUES (%s, %s, 2)",
                      (m2, outsider))
    assert "Outsider does not participate" in message


def test_r02_a_team_with_matches_cannot_leave_the_tournament(db, tiny_match):
    rejects(db, "R0002", "DELETE FROM participates_in WHERE team_id = %s AND tournament_id = %s",
            (tiny_match["team_a"], tiny_match["tournament_id"]))


def test_r03_bracket_links_stay_in_one_tournament(db, tiny_match):
    other = new_cup(db, "Other Cup")
    other_match = new_match(db, other, other["teams"])
    rejects(db, "R0003", "UPDATE match SET winner_to_match_id = %s, winner_to_slot = 1 WHERE match_id = %s",
            (other_match, tiny_match["match_id"]))


def test_r03_a_slot_cannot_be_fed_by_a_winner_and_a_loser(db, tiny_match):
    cup = tiny_match["cup"]
    final = new_match(db, cup, [], match_number=2)
    semi = new_match(db, cup, [], match_number=3)
    db.execute("UPDATE match SET winner_to_match_id = %s, winner_to_slot = 1 WHERE match_id = %s",
               (final, tiny_match["match_id"]))
    rejects(db, "R0003", "UPDATE match SET loser_to_match_id = %s, loser_to_slot = 1 WHERE match_id = %s",
            (final, semi))
    db.execute("UPDATE match SET loser_to_match_id = %s, loser_to_slot = 2 WHERE match_id = %s", (final, semi))


def test_r04_no_game_beyond_best_of(db, tiny_match):
    rejects(db, "R0004", """INSERT INTO game (match_id, game_number, map_id, mode_id)
                            VALUES (%s, 6, %s, %s)""", (tiny_match["match_id"], DEN, HP))


def test_r04_no_result_after_the_series_is_decided(db, tiny_match):
    w = tiny_match
    list_players(db, w["match_id"], w["cup"], [w["team_a"], w["team_b"]])
    sweep(db, w)
    play_game(db, w["match_id"], 4, SCAR, HP, {w["team_a"]: 250, w["team_b"]: 200},
              {w["team_a"]: w["players_a"], w["team_b"]: w["players_b"]})
    message = rejects_at_commit(db, "R0004")
    assert "decided in game 3" in message


# ---------------------------------------------------------------- games and settings

def test_r06_a_played_game_needs_both_scores(db, tiny_match):
    w = tiny_match
    list_players(db, w["match_id"], w["cup"], [w["team_a"], w["team_b"]])
    play_game(db, w["match_id"], 1, DEN, HP, {w["team_a"]: 250}, {w["team_a"]: w["players_a"]})
    rejects_at_commit(db, "R0006")


def test_r07_map_must_be_in_the_phase_pool(db, tiny_match):
    # Game 3 is Overload; Colossus is not an Overload map in the 2026 pool.
    message = rejects(db, "R0007", """INSERT INTO game (match_id, game_number, map_id, mode_id)
                                      VALUES (%s, 3, %s, %s)""", (tiny_match["match_id"], COLOSSUS, OVR))
    assert "Colossus (OVR) is not in this phase's map pool" in message


def test_r07_mode_must_match_the_layout_slot(db, tiny_match):
    # Scar S&D is in the pool, but game 1 of a Bo5 is Hardpoint.
    message = rejects(db, "R0007", """INSERT INTO game (match_id, game_number, map_id, mode_id)
                                      VALUES (%s, 1, %s, %s)""", (tiny_match["match_id"], SCAR, SND))
    assert "must be HP" in message


def test_r08_layout_must_define_the_series_length(db, tiny_match):
    rejects(db, "R0008", """INSERT INTO match (tournament_id, phase_number, match_number, best_of)
                            VALUES (%s, 1, 9, 7)""", (tiny_match["tournament_id"],))


def test_r08_pool_must_cover_every_mode_of_the_layout(db, tiny_match):
    layout = one(db, "INSERT INTO series_layout (layout_name) VALUES ('Control Bo1') RETURNING layout_id")
    db.execute("INSERT INTO series_slot (layout_id, best_of, game_number, mode_id) VALUES (%s, 1, 1, %s)",
               (layout, CTL))
    db.execute("""INSERT INTO phase (tournament_id, phase_number, phase_name, default_best_of,
                                     format_id, pool_id, layout_id)
                  VALUES (%s, 2, 'Showmatch', 1, 1, %s, %s)""", (tiny_match["tournament_id"], POOL_2026, layout))
    rejects_at_commit(db, "R0008")


def test_r09_a_pool_holds_one_game_title(db):
    # Raid from Black Ops II cannot join the Black Ops 7 pool.
    db.execute("INSERT INTO pool_entry (pool_id, map_id, mode_id) VALUES (%s, %s, %s)", (POOL_2026, RAID_BO2, SND))
    rejects_at_commit(db, "R0009")


def test_r09_a_season_uses_pools_of_its_game_title(db):
    league = new_league(db, game_title="Black Ops 6")
    new_cup(db, "Wrong Title Cup", league=league)
    rejects_at_commit(db, "R0009")


def test_r10_picks_and_bans_come_from_the_pool(db, tiny_match):
    rejects(db, "R0010", """INSERT INTO map_veto (match_id, veto_order, action, team_id, map_id, mode_id)
                            VALUES (%s, 1, 'ban', %s, %s, %s)""",
            (tiny_match["match_id"], tiny_match["team_a"], COLOSSUS, OVR))


# ---------------------------------------------------------------- player stats

def test_r11_each_team_fields_team_size_players(db, tiny_match):
    w = tiny_match
    list_players(db, w["match_id"], w["cup"], [w["team_a"], w["team_b"]])
    play_game(db, w["match_id"], 1, DEN, HP, {w["team_a"]: 250, w["team_b"]: 200},
              {w["team_a"]: w["players_a"], w["team_b"]: w["players_b"][:3]})
    message = rejects_at_commit(db, "R0011")
    assert "stats for 3 player(s)" in message


def test_r12_a_listed_player_needs_a_stint_on_the_match_date(db, tiny_match):
    free_agent = new_player(db, "FreeAgent")
    message = rejects(db, "R0012", "INSERT INTO match_player (person_id, match_id, team_id) VALUES (%s, %s, %s)",
                      (free_agent, tiny_match["match_id"], tiny_match["team_a"]))
    assert "FreeAgent has no playing or coaching stint" in message


def test_r12_a_stint_cannot_end_before_a_match_it_covered(db, tiny_match):
    w = tiny_match
    list_players(db, w["match_id"], w["cup"], [w["team_a"]])
    rejects(db, "R0012", "UPDATE roster SET end_date = '2026-02-01' WHERE person_id = %s AND team_id = %s",
            (w["players_a"][0], w["team_a"]))
    # Ending it after the match is a normal release.
    db.execute("UPDATE roster SET end_date = '2026-03-02' WHERE person_id = %s AND team_id = %s",
               (w["players_a"][0], w["team_a"]))


def test_r12_a_coach_who_is_a_player_can_substitute_in(db, tiny_match):
    coach = new_player(db, "PlayingCoach")
    db.execute("INSERT INTO coach (person_id) VALUES (%s)", (coach,))
    add_stint(db, coach, tiny_match["team_a"], role="head coach")
    db.execute("INSERT INTO match_player (person_id, match_id, team_id) VALUES (%s, %s, %s)",
               (coach, tiny_match["match_id"], tiny_match["team_a"]))


def test_r13_mode_stats_must_match_the_game_mode(db, tiny_match):
    w = tiny_match
    list_players(db, w["match_id"], w["cup"], [w["team_a"]])
    db.execute("""INSERT INTO game (match_id, game_number, status, map_id, mode_id)
                  VALUES (%s, 2, 'live', %s, %s)""", (w["match_id"], SCAR, SND))
    add_stats(db, w["players_a"][0], w["match_id"], 2, None)
    rejects(db, "R0013", "INSERT INTO hardpoint_stats (person_id, match_id, game_number) VALUES (%s, %s, 2)",
            (w["players_a"][0], w["match_id"]))


# ---------------------------------------------------------------- people

def test_r14_stints_with_two_teams_overlap_only_when_two_way(db, tiny_match):
    player = tiny_match["players_a"][0]
    rejects(db, "R0014", """INSERT INTO roster (person_id, team_id, start_date, roster_role, join_type)
                            VALUES (%s, %s, '2026-02-01', 'starter', 'loan')""", (player, tiny_match["team_b"]))
    add_stint(db, player, tiny_match["team_b"], role="two-way", start="2026-02-01")


def test_r14_at_most_two_two_way_players_at_once(db):
    team = new_team(db, "Academy")
    new_player(db, "TwoWay1", team, role="two-way", start="2026-01-01")
    new_player(db, "TwoWay2", team, role="two-way", start="2026-02-01", end="2026-04-01")
    # From April the second two-way slot is free again.
    new_player(db, "TwoWay3", team, role="two-way", start="2026-04-01")
    late = new_player(db, "TwoWay4")
    rejects(db, "R0014", """INSERT INTO roster (person_id, team_id, start_date, roster_role, join_type)
                            VALUES (%s, %s, '2026-05-01', 'two-way', 'signing')""", (late, team))


def test_r15_a_coaching_role_needs_a_coach(db, tiny_match):
    person = new_person(db, "NotACoach")
    message = rejects(db, "R0015", """INSERT INTO roster (person_id, team_id, start_date, roster_role, join_type)
                                      VALUES (%s, %s, '2026-01-01', 'head coach', 'signing')""",
                      (person, tiny_match["team_a"]))
    assert "without a coach record" in message


def test_r15_a_player_with_a_playing_stint_keeps_the_player_row(db, tiny_match):
    rejects(db, "R0015", "DELETE FROM player WHERE person_id = %s", (tiny_match["players_a"][0],))


def test_r16_players_meet_the_league_minimum_age(db):
    league = new_league(db, min_age=18)
    cup = new_cup(db, "Major", league=league)
    a, b = cup["teams"]
    m = new_match(db, cup, [a, b])
    young = new_player(db, "Prodigy", a, dob="2010-06-01")
    message = rejects(db, "R0016", "INSERT INTO match_player (person_id, match_id, team_id) VALUES (%s, %s, %s)",
                      (young, m, a))
    assert "Prodigy is 15 on 2026-03-01" in message


def test_r16_a_player_without_a_birth_date_cannot_play_an_age_limited_league(db):
    league = new_league(db, min_age=18)
    cup = new_cup(db, "Major", league=league)
    a, b = cup["teams"]
    m = new_match(db, cup, [a, b])
    unknown = new_player(db, "NoDob", a, dob=None)
    rejects(db, "R0016", "INSERT INTO match_player (person_id, match_id, team_id) VALUES (%s, %s, %s)",
            (unknown, m, a))


def test_r17_players_match_the_tournament_region(db):
    cup = new_cup(db, "NA Cup", region_id=NA)
    a, b = cup["teams"]
    m = new_match(db, cup, [a, b])
    import_player = new_player(db, "EuImport", a, region_id=EU)
    message = rejects(db, "R0017", "INSERT INTO match_player (person_id, match_id, team_id) VALUES (%s, %s, %s)",
                      (import_player, m, a))
    assert "EuImport is linked to EU, but this tournament is for NA" in message


# ---------------------------------------------------------------- penalties

def test_r20_a_penalty_naming_both_needs_their_stint(db, tiny_match):
    ref = new_official(db)
    rejects(db, "R0020", """INSERT INTO penalty (penalty_type, reason, issued_at, issued_by, person_id, team_id)
                            VALUES ('warning', 'conduct', '2026-03-01 19:00+00', %s, %s, %s)""",
            (ref, tiny_match["players_a"][0], tiny_match["team_b"]))


def test_r21_a_game_forfeit_penalty_needs_a_forfeited_game(db, tiny_match):
    w = tiny_match
    list_players(db, w["match_id"], w["cup"], [w["team_a"], w["team_b"]])
    play_game(db, w["match_id"], 1, DEN, HP, {w["team_a"]: 250, w["team_b"]: 200},
              {w["team_a"]: w["players_a"], w["team_b"]: w["players_b"]})
    db.execute("""INSERT INTO penalty (penalty_type, reason, issued_by, team_id, match_id, game_number)
                  VALUES ('game forfeit', 'late', %s, %s, %s, 1)""", (new_official(db), w["team_b"], w["match_id"]))
    rejects_at_commit(db, "R0021")


def test_r21_a_match_forfeit_penalty_matches_a_forfeited_match(db, tiny_match):
    w = tiny_match
    db.execute("""INSERT INTO penalty (penalty_type, reason, issued_by, team_id, match_id)
                  VALUES ('match forfeit', 'no show', %s, %s, %s)""", (new_official(db), w["team_b"], w["match_id"]))
    # Recording the forfeit after the penalty is fine: the check waits for commit.
    db.execute("""UPDATE match SET status = 'completed', result_type = 'forfeit', awarded_team_id = %s
                  WHERE match_id = %s""", (w["team_a"], w["match_id"]))
    at_commit(db)
    db.execute("UPDATE match SET result_type = 'played', awarded_team_id = NULL WHERE match_id = %s",
               (w["match_id"],))
    rejects_at_commit(db, "R0021")


# ---------------------------------------------------------------- dates, registration, capacity

def test_r25_a_tournament_falls_within_its_stage(db):
    league = new_league(db)
    new_cup(db, "Summer Cup", league=league, start="2026-07-01", end="2026-07-02")
    message = rejects_at_commit(db, "R0025")
    assert 'not within stage "Stage 1"' in message


def test_r25_a_phase_falls_within_its_tournament(db, tiny_match):
    db.execute("UPDATE phase SET start_date = '2026-02-27', end_date = '2026-03-01' WHERE tournament_id = %s",
               (tiny_match["tournament_id"],))
    rejects_at_commit(db, "R0025")


def test_r25_moving_a_tournament_and_its_phase_together_is_allowed(db, tiny_match):
    t = tiny_match["tournament_id"]
    db.execute("UPDATE phase SET start_date = '2026-03-01', end_date = '2026-03-02' WHERE tournament_id = %s", (t,))
    at_commit(db)
    # Between these two statements the phase lies outside its tournament; at commit it does not.
    db.execute("UPDATE tournament SET start_date = '2026-03-08', end_date = '2026-03-09' WHERE event_id = %s", (t,))
    db.execute("UPDATE phase SET start_date = '2026-03-08', end_date = '2026-03-09' WHERE tournament_id = %s", (t,))
    db.execute("UPDATE match SET scheduled_at = '2026-03-08 18:00+00' WHERE tournament_id = %s", (t,))
    at_commit(db)


def test_r26_season_participants_must_be_registered(db):
    league = new_league(db)
    cup = new_cup(db, "Major", league=league)
    walk_in = new_team(db, "Walk-in")
    message = rejects(db, "R0026", "INSERT INTO participates_in (team_id, tournament_id) VALUES (%s, %s)",
                      (walk_in, cup["tournament_id"]))
    assert "Walk-in is not registered" in message


def test_r26_a_registration_in_use_cannot_be_dropped(db):
    league = new_league(db)
    cup = new_cup(db, "Major", league=league)
    rejects(db, "R0026", "DELETE FROM registered_in WHERE team_id = %s", (cup["teams"][0],))


def test_r27_a_tournament_takes_at_most_max_teams(db):
    cup = new_cup(db, "Small Cup", teams=2, max_teams=2)
    third = new_team(db, "Third")
    rejects(db, "R0027", "INSERT INTO participates_in (team_id, tournament_id) VALUES (%s, %s)",
            (third, cup["tournament_id"]))


def test_r27_max_teams_cannot_drop_below_the_field(db):
    cup = new_cup(db, "Cup", teams=3, max_teams=8)
    rejects(db, "R0027", "UPDATE tournament SET max_teams = 2 WHERE event_id = %s", (cup["tournament_id"],))


def test_r28_final_placement_fits_the_field(db, tiny_match):
    db.execute("UPDATE participates_in SET final_placement = 3 WHERE team_id = %s AND tournament_id = %s",
               (tiny_match["team_a"], tiny_match["tournament_id"]))
    message = rejects_at_commit(db, "R0028")
    assert "placement of 3 is impossible with 2 teams" in message


# ---------------------------------------------------------------- total participation

def test_t1_every_team_has_an_identity(db):
    db.execute("INSERT INTO team (status) VALUES ('active')")
    rejects_at_commit(db, "T0001")


def test_t2_every_event_has_a_host(db):
    event_id = one(db, "INSERT INTO event (event_name) VALUES ('Unhosted') RETURNING event_id")
    db.execute("INSERT INTO tournament (event_id, tournament_type, team_size) VALUES (%s, 'cup', 4)", (event_id,))
    rejects_at_commit(db, "T0002")


def test_t3_an_event_is_a_league_or_a_tournament(db):
    new_event(db, "Nothing Yet")
    rejects_at_commit(db, "T0003")


def test_t3_an_event_cannot_be_both(db):
    league = new_league(db)
    db.execute("INSERT INTO tournament (event_id, tournament_type, team_size) VALUES (%s, 'cup', 4)",
               (league["league_id"],))
    rejects_at_commit(db, "T0003")


def test_t4_every_stats_row_has_its_mode_details(db, tiny_match):
    w = tiny_match
    a, b = w["team_a"], w["team_b"]
    list_players(db, w["match_id"], w["cup"], [a, b])
    play_game(db, w["match_id"], 1, DEN, HP, {a: 250, b: 200}, {a: w["players_a"], b: w["players_b"][:3]})
    add_stats(db, w["players_b"][3], w["match_id"], 1, None)      # stats row without its Hardpoint row
    rejects_at_commit(db, "T0004")


# ---------------------------------------------------------------- rules 22 and 23 (declarative)

def test_r22_a_suspension_needs_a_start_date(db, tiny_match):
    rejects(db, "23514", """INSERT INTO penalty (penalty_type, reason, issued_by, person_id)
                            VALUES ('suspension', 'conduct', %s, %s)""",
            (new_official(db), tiny_match["players_a"][0]))


def test_r22_a_dispute_penalty_points_at_the_dispute_match(db, tiny_match):
    cup = tiny_match["cup"]
    other = new_match(db, cup, [tiny_match["team_a"], tiny_match["team_b"]], match_number=2)
    db.execute("""INSERT INTO dispute (match_id, dispute_number, reason, raised_by_team_id)
                  VALUES (%s, 1, 'lag', %s)""", (tiny_match["match_id"], tiny_match["team_a"]))
    # Dispute 1 belongs to match 1; a penalty on match 2 cannot cite it.
    rejects(db, "23503", """INSERT INTO penalty (penalty_type, reason, issued_by, team_id, match_id, dispute_number)
                            VALUES ('warning', 'lag abuse', %s, %s, %s, 1)""",
            (new_official(db), tiny_match["team_b"], other))


def test_r23_a_dispute_is_raised_by_a_team_in_the_match(db, tiny_match):
    outsider = new_team(db, "Outsider")
    rejects(db, "23503", """INSERT INTO dispute (match_id, dispute_number, reason, raised_by_team_id)
                            VALUES (%s, 1, 'lag', %s)""", (tiny_match["match_id"], outsider))


def test_r23_a_resolved_dispute_is_complete(db, tiny_match):
    rejects(db, "23514", """INSERT INTO dispute (match_id, dispute_number, reason, raised_by_team_id, status)
                            VALUES (%s, 1, 'lag', %s, 'resolved')""", (tiny_match["match_id"], tiny_match["team_a"]))


# ---------------------------------------------------------------- rule 3: the bracket moves teams on

def bracket(db, w):
    """Match 1 sends its winner to slot 1 of the final and its loser to slot 2 of a lower match."""
    cup = w["cup"]
    final = new_match(db, cup, [], match_number=2)
    lower = new_match(db, cup, [], match_number=3)
    db.execute("""UPDATE match SET winner_to_match_id = %s, winner_to_slot = 1,
                                   loser_to_match_id = %s, loser_to_slot = 2 WHERE match_id = %s""",
               (final, lower, w["match_id"]))
    return final, lower


def slots(db, match_id):
    return dict(db.execute("SELECT slot, team_id FROM competes_in WHERE match_id = %s", (match_id,)).fetchall())


def test_r03_a_completed_match_moves_its_winner_and_loser_on(db, tiny_match):
    w = tiny_match
    final, lower = bracket(db, w)
    list_players(db, w["match_id"], w["cup"], [w["team_a"], w["team_b"]])
    sweep(db, w)
    db.execute("UPDATE match SET status = 'completed', result_type = 'played' WHERE match_id = %s", (w["match_id"],))
    assert slots(db, final) == {1: w["team_a"]}
    assert slots(db, lower) == {2: w["team_b"]}
    at_commit(db)


def test_r03_a_corrected_result_moves_the_right_teams(db, tiny_match):
    w = tiny_match
    final, lower = bracket(db, w)
    list_players(db, w["match_id"], w["cup"], [w["team_a"], w["team_b"]])
    sweep(db, w)
    db.execute("UPDATE match SET status = 'completed', result_type = 'played' WHERE match_id = %s", (w["match_id"],))
    # A dispute awards the match to B: the two teams swap places in the next matches.
    db.execute("UPDATE match SET result_type = 'forfeit', awarded_team_id = %s WHERE match_id = %s",
               (w["team_b"], w["match_id"]))
    assert slots(db, final) == {1: w["team_b"]}
    assert slots(db, lower) == {2: w["team_a"]}


def test_r03_who_moved_on_cannot_change_once_the_next_match_started(db, tiny_match):
    w = tiny_match
    final, _ = bracket(db, w)
    list_players(db, w["match_id"], w["cup"], [w["team_a"], w["team_b"]])
    sweep(db, w)
    db.execute("UPDATE match SET status = 'completed', result_type = 'played' WHERE match_id = %s", (w["match_id"],))
    db.execute("UPDATE match SET status = 'live' WHERE match_id = %s", (final,))
    rejects(db, "R0003", "UPDATE match SET result_type = 'forfeit', awarded_team_id = %s WHERE match_id = %s",
            (w["team_b"], w["match_id"]))


def test_r03_a_match_cannot_complete_without_a_winner(db, tiny_match):
    bracket(db, tiny_match)
    rejects(db, "R0003", "UPDATE match SET status = 'completed' WHERE match_id = %s", (tiny_match["match_id"],))
