# Business rules: where each one is enforced

Rule numbers and wording follow Section 2.8 of our mid-semester report. Section 4.5 of the
report planned how each rule would be enforced; this file records how the live database
enforces it, and which test proves it.

**All 29 rules and all 4 total-participation constraints are enforced.**

| How a rule is enforced | Report (Section 4.5) | Database |
| --- | --- | --- |
| Keys, foreign keys, CHECK and EXCLUDE only | 5 | **7**: rules 5, 18, 19, 22, 23, 24, 29 |
| Partly declarative, rest by trigger | 8 | **8**: rules 1, 3, 6, 10, 12, 14, 20, 28 |
| Trigger only | 16 | **14**: rules 2, 4, 7, 8, 9, 11, 13, 15, 16, 17, 21, 25, 26, 27 |

Rules 18 and 24 need no trigger because PostgreSQL's EXCLUDE constraints express them;
rule 14's same-team part is an EXCLUDE constraint too (docs/deviation_log.md, D2 to D4).

## How the triggers are built

- `db/06_rule_checks.sql` has one **check function** per rule, `check_rNN(key)`. It reads
  the rows the key names and raises the rule's error if they break the rule. It changes no
  data.
- `db/07_triggers.sql` decides **when** each check runs. Each table that can break a rule has
  up to two triggers: `rules_<table>` runs as soon as the statement runs (**immediate**), and
  `rules_<table>_at_commit` is a deferred constraint trigger that runs at COMMIT
  (**at commit**). In total there are 45 triggers, 24 of them at commit.
- A check waits for commit when the rows it counts are written one after another (a game,
  then its two scores, then eight stats rows), or when one change may update the rows it
  compares in either order (moving a tournament and its phases a week later). A function
  can run the commit-time checks early with `SET CONSTRAINTS ALL IMMEDIATE`; the Phase 4
  functions do this so that their error handler sees every failure.
- Checks run on **every table whose change could break the rule**, not only on the table
  the rule is about. Rule 12, for example, is checked when a player is listed for a match,
  and again when a stint is ended or deleted, when a match is rescheduled, and when its
  tournament changes.
- Counting checks lock the parent row first (rule 27: the tournament; rule 14: the team, then
  the person) with `FOR NO KEY UPDATE`, so two sessions cannot both pass the count.
  `tests/test_concurrency.py` shows that the second session waits, then is refused.
- Trigger names start with `rules_`, so on each table they fire after PostgreSQL's own
  foreign key triggers (`RI_...`). A row that breaks a foreign key reports that error first.

## Definitions the checks use

| Term | Meaning |
| --- | --- |
| Match date | The UTC date of `match.scheduled_at`; while the match has no time, the tournament's `start_date` (D11) |
| Stint covers date *d* | `start_date <= d` and (`end_date` is empty or `d < end_date`); `end_date` is exclusive (D5) |
| Player roles | starter, substitute, two-way |
| Coaching roles | head coach, assistant coach |
| Started match | `status` is live or completed, or `result_type` is set |
| Decided series | After the first game in which a team's wins pass `best_of / 2` |

## The 29 rules

"Runs on" lists the tables whose changes call the check. I = insert, U = update, D = delete.

| # | Rule (short form) | Declarative part | Check function | Runs on | When | Tests (`tests/`) |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | At most two teams per match; exactly two once started | `slot IN (1, 2)`, `UNIQUE (match_id, slot)` | `check_r01` | match I/U; competes_in I/U/D | At commit | `test_match_has_at_most_two_slots_rule_1`, `test_r01_a_started_match_needs_two_teams` |
| 2 | A team plays only in tournaments it participates in | | `check_r02` | competes_in I/U; match U (moved); participates_in U/D | Immediate | `test_r02_team_must_participate_in_the_tournament`, `test_r02_a_team_with_matches_cannot_leave_the_tournament` |
| 3 | Bracket links stay in one tournament; each slot fed once | `UNIQUE (winner_to_match_id, winner_to_slot)`, `UNIQUE (loser_to_match_id, loser_to_slot)`, slot checks | `check_r03` | match I/U | Immediate | `test_r03_bracket_links_stay_in_one_tournament`, `test_r03_a_slot_cannot_be_fed_by_a_winner_and_a_loser` |
| 4 | At most `best_of` games; no result after the series is decided | | `check_r04_length`, `check_r04_end` | length: game I/U, match U; end: game, team_result, match | Length immediate, end at commit | `test_r04_no_game_beyond_best_of`, `test_r04_no_result_after_the_series_is_decided` |
| 5 | Awarded team only on a forfeit, and one of the match's teams | NULL-safe CHECKs; `(match_id, awarded_team_id) → competes_in` | | | Immediate | `test_awarded_team_must_be_one_of_the_match_teams_rule_5`, `test_awarded_team_only_on_forfeit_even_when_result_type_is_null_rule_5` |
| 6 | A played game has scores for both teams | `team_result (match_id, team_id) → competes_in` | `check_r06` | game I/U; team_result I/U/D | At commit | `test_score_must_belong_to_a_team_in_the_match_rule_6`, `test_r06_a_played_game_needs_both_scores` |
| 7 | A game's map and mode are in its phase's pool and match the layout slot | | `check_r07` | game I/U; match U; phase U; pool_entry U/D; series_slot U/D | Immediate | `test_r07_map_must_be_in_the_phase_pool`, `test_r07_mode_must_match_the_layout_slot` |
| 8 | The layout defines every game of each series length used; the pool covers the layout's modes | | `check_r08_match`, `check_r08_phase` | match I/U (immediate); phase I/U, pool_entry U/D, series_slot I/U/D (at commit) | Both | `test_r08_layout_must_define_the_series_length`, `test_r08_pool_must_cover_every_mode_of_the_layout` |
| 9 | A pool's maps share one game title, the season's | | `check_r09` | pool_entry I/U/D; phase I/U; map U; season U; tournament U | At commit | `test_r09_a_pool_holds_one_game_title`, `test_r09_a_season_uses_pools_of_its_game_title` |
| 10 | Picks and bans come from the phase pool, once each, by the two teams | `UNIQUE (match_id, map_id, mode_id)`; `(match_id, team_id) → competes_in` | `check_r10` | map_veto I/U; match U; phase U; pool_entry U/D | Immediate | `test_r10_picks_and_bans_come_from_the_pool` |
| 11 | Each team fields `team_size` players per game | | `check_r11` | team_result I/U/D; player_game_stats I/U/D; match_player U/D; tournament U | At commit | `test_r11_each_team_fields_team_size_players` |
| 12 | A listed player has a playing or coaching stint with the team on the match date | `player_game_stats → match_player`; `match_player.person_id → player`; `(match_id, team_id) → competes_in` | `check_r12` | match_player I/U; roster U/D; match U; tournament U | Immediate | `test_r12_a_listed_player_needs_a_stint_on_the_match_date`, `test_r12_a_stint_cannot_end_before_a_match_it_covered`, `test_r12_a_coach_who_is_a_player_can_substitute_in` |
| 13 | A stats row's mode table matches its game's mode | | `check_r13` | the four mode tables I/U; game U | Immediate | `test_r13_mode_stats_must_match_the_game_mode` |
| 14 | No overlapping stints except two-way; at most two two-way players per team | EXCLUDE `roster_no_overlap_r14` (same team) | `check_r14` | roster I/U | Immediate | `test_same_team_stints_cannot_overlap_rule_14`, `test_r14_stints_with_two_teams_overlap_only_when_two_way`, `test_r14_at_most_two_two_way_players_at_once` |
| 15 | `roster_role` fits the person (Player or Coach) | | `check_r15` | roster I/U; player U/D; coach U/D | Immediate | `test_r15_a_coaching_role_needs_a_coach`, `test_r15_a_player_with_a_playing_stint_keeps_the_player_row` |
| 16 | Players meet the league's `min_age` on the match date | | `check_r16` | match_player I/U; person U; league U; match U; tournament U | Immediate | `test_r16_players_meet_the_league_minimum_age`, `test_r16_a_player_without_a_birth_date_cannot_play_an_age_limited_league` |
| 17 | Players are linked to the tournament's region | | `check_r17` | match_player I/U; match U; tournament U | Immediate | `test_r17_players_match_the_tournament_region` |
| 18 | `team_identity` periods do not overlap | EXCLUDE `team_identity_no_overlap_r18` | | | Immediate | `test_team_identity_periods_cannot_overlap_rule_18` |
| 19 | A penalty points to a match or one of its games; a named team is in that match | shared `match_id`; CHECK `penalty_parts_need_match`; `(match_id, team_id) → competes_in` | | | Immediate | `test_penalty_game_needs_its_match_rule_19` |
| 20 | A penalty names someone; a named person had a stint with the named team | CHECK `penalty_names_someone` | `check_r20` | penalty I/U; roster U/D | Immediate | `test_penalty_names_someone_rule_20`, `test_r20_a_penalty_naming_both_needs_their_stint` |
| 21 | Forfeit penalties agree with the forfeit result | | `check_r21` | penalty I/U; match U; game U | At commit | `test_r21_a_game_forfeit_penalty_needs_a_forfeited_game`, `test_r21_a_match_forfeit_penalty_matches_a_forfeited_match` |
| 22 | Suspensions have a start date; dispute penalties point at the dispute's match | CHECK `penalty_suspension_has_start`; `(match_id, dispute_number) → dispute` | | | Immediate | |
| 23 | Disputes are raised by a match team; resolved disputes are complete | `(match_id, raised_by_team_id) → competes_in`; CHECK `dispute_resolved_is_complete` | | | Immediate | |
| 24 | Reward bands do not overlap; points count only in league seasons | EXCLUDE `placement_reward_no_overlap_r24`; points views only sum staged tournaments | | | Immediate | `test_reward_bands_cannot_overlap_rule_24` |
| 25 | Tournament, stage and phase dates nest | | `check_r25_season`, `_stage`, `_tournament`, `_phase` | season U; stage I/U; tournament I/U; phase I/U | At commit | `test_r25_a_tournament_falls_within_its_stage`, `test_r25_a_phase_falls_within_its_tournament`, `test_r25_moving_a_tournament_and_its_phase_together_is_allowed` |
| 26 | Teams in a season tournament are registered for that season | | `check_r26` | participates_in I/U; registered_in U/D; tournament U | Immediate | `test_r26_season_participants_must_be_registered`, `test_r26_a_registration_in_use_cannot_be_dropped` |
| 27 | At most `max_teams` participants | | `check_r27` (locks the tournament) | participates_in I/U; tournament U | Immediate | `test_r27_a_tournament_takes_at_most_max_teams`, `test_r27_max_teams_cannot_drop_below_the_field`, `test_r27_two_sessions_cannot_both_take_the_last_place` |
| 28 | `final_placement` is between 1 and the number of teams | CHECK `final_placement >= 1` | `check_r28` | participates_in I/U/D | At commit | `test_r28_final_placement_fits_the_field` |
| 29 | Every period is ordered | CHECKs `end_date >= start_date`, `valid_to >= valid_from` | | | Immediate | `test_periods_must_be_ordered_rule_29` |

## Total participation (report Section 4.5)

A foreign key cannot require "at least one child row". These four run at commit, after the
parent and its children have both been written.

| # | Constraint | Check function | Runs on | Test |
| --- | --- | --- | --- | --- |
| T1 | Every team has at least one `team_identity` | `check_t1` | team I; team_identity U/D | `test_t1_every_team_has_an_identity` |
| T2 | Every event has at least one `hosted_by` row | `check_t2` | event I; hosted_by U/D | `test_t2_every_event_has_a_host` |
| T3 | Every event is exactly one of `league` or `tournament` | `check_t3` | event I; league I/U/D; tournament I/U/D | `test_t3_an_event_is_a_league_or_a_tournament`, `test_t3_an_event_cannot_be_both` |
| T4 | Every `player_game_stats` row has exactly one mode row | `check_t4` | player_game_stats I/U/D; the four mode tables I/U/D | `test_t4_every_stats_row_has_its_mode_details` |

## Error codes

| Code | Meaning | Raised by |
| --- | --- | --- |
| `R0001` to `R0029` | Business rule *nn* | `raise_rule(nn, message)` |
| `T0001` to `T0004` | Total-participation constraint T*n* | `raise_total(n, message)` |
| `23505`, `23503`, `23514`, `23P01` | Unique, foreign key, CHECK, EXCLUDE | PostgreSQL itself |

Messages start with the code and name the rows involved, for example
`R0007: Colossus (OVR) is not in this phase's map pool, "CDL 2026 opening pool"`, so the demo
app can show them as they are.

## Proving the tests test something

With `db/07_triggers.sql` removed, 41 of the 45 tests in `tests/test_rules.py` fail. The 4 that
still pass are the ones that check valid data is accepted. With the lock in `check_r27`
removed, `tests/test_concurrency.py` fails because the second session no longer waits.
