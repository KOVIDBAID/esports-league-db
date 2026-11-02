# Business rules: where each one is enforced

Rule numbers and wording follow Section 2.8 of our mid-semester report; Section 4.5 of the
report listed which rules the schema guarantees. This file tracks the same 29 rules in the
live database.

**Status**

- **Done**: guaranteed by keys, foreign keys, CHECK or EXCLUDE constraints. No row can break it.
- **Partly**: the structural part is done; a trigger in Phase 3 adds the rest.
- **Phase 3**: needs a trigger, because it compares or counts rows across tables.

**Summary**

| | Report (Section 4.5) | Database now |
| --- | --- | --- |
| Done | 5 | **7** (rules 18 and 24 moved up through EXCLUDE constraints) |
| Partly | 8 | **8** (rule 14 joined through an EXCLUDE constraint; rule 24 left for Done) |
| Phase 3 | 16 | **14** |

## The 29 rules

| # | Rule (short form) | Enforced now (Phase 2) | Still to add (Phase 3) | Status | Test |
| --- | --- | --- | --- | --- | --- |
| 1 | At most two teams per match; exactly two once played | `competes_in`: `slot IN (1, 2)` and `UNIQUE (match_id, slot)` | Exactly two rows once the match is played | Partly | `test_match_has_at_most_two_slots_rule_1` |
| 2 | A team plays only in tournaments it participates in | | `competes_in` row checked against `participates_in` | Phase 3 | |
| 3 | Bracket links stay in one tournament; each slot is fed once | `UNIQUE (winner_to_match_id, winner_to_slot)`, `UNIQUE (loser_to_match_id, loser_to_slot)`, slot checks | Same tournament; a slot not fed by both a winner and a loser link. Moving teams forward is done by `record_series_result` | Partly | |
| 4 | At most `best_of` games; play stops at a majority | | `game_number ≤ best_of`; no new game once a team has a majority | Phase 3 | |
| 5 | Awarded team only on a forfeit, and one of the match's teams | NULL-safe CHECKs on `match` and `game`; `(match_id, awarded_team_id) → competes_in` | | Done | `test_awarded_team_must_be_one_of_the_match_teams_rule_5`, `test_awarded_team_only_on_forfeit_even_when_result_type_is_null_rule_5` |
| 6 | A played game has scores for both of the match's teams | `team_result (match_id, team_id) → competes_in` | Exactly two `team_result` rows once played (deferred, checked at commit) | Partly | `test_score_must_belong_to_a_team_in_the_match_rule_6` |
| 7 | A game's map-mode pair is in its phase's pool and matches the layout slot | | `(pool_id, map_id, mode_id)` is in `pool_entry`; `mode_id` equals the slot mode | Phase 3 | |
| 8 | A phase's layout covers every series length it uses | | Check when a match is created or its `best_of` changes | Phase 3 | |
| 9 | All maps in a pool share the season's game title | | Check on `pool_entry` and `phase` | Phase 3 | |
| 10 | Picks and bans come from the phase pool, once each, by the two teams | `UNIQUE (match_id, map_id, mode_id)`; `(match_id, team_id) → competes_in` | The pair is in the phase's pool | Partly | |
| 11 | Each team fields `team_size` players per game | | Count check (deferred, checked at commit) | Phase 3 | |
| 12 | A player with stats is listed for the match, for one of its teams, with a stint on that date | `player_game_stats → match_player`; `match_player.person_id → player`; `(match_id, team_id) → competes_in` | A stint covers the match date (`start_date ≤ date < end_date`) | Partly | |
| 13 | A stats row's specialization matches its game's mode | | Check on each of the four mode tables | Phase 3 | |
| 14 | No overlapping stints, except two-way; at most two two-way players | `EXCLUDE` on `roster`: one person's stints with the same team cannot overlap | Overlap across different teams only when one stint is two-way; at most two two-way players per team | Partly | `test_same_team_stints_cannot_overlap_rule_14` |
| 15 | `roster_role` fits the person (Player or Coach) | | Check against `player` and `coach` | Phase 3 | |
| 16 | Players meet the league's `min_age` | | Check on `match_player` | Phase 3 | |
| 17 | Players' region matches the tournament region | | Check on `match_player` | Phase 3 | |
| 18 | `team_identity` periods do not overlap | `EXCLUDE` on `team_identity` | | Done | `test_team_identity_periods_cannot_overlap_rule_18` |
| 19 | A penalty points to a match or one of its games, never both; a named team is one of the match's teams | Shared `match_id`; CHECK `penalty_parts_need_match`; `(match_id, team_id) → competes_in` | | Done | `test_penalty_game_needs_its_match_rule_19` |
| 20 | A penalty names a team, a person, or both | CHECK `penalty_names_someone` | The person had a stint with the team on the issue date | Partly | `test_penalty_names_someone_rule_20` |
| 21 | Forfeit penalties agree with the forfeit outcome | | Compare `penalty_type` with the match or game `result_type` | Phase 3 | |
| 22 | Suspensions have a start date; dispute penalties point at the dispute's match | CHECK `penalty_suspension_has_start`; `(match_id, dispute_number) → dispute` uses the penalty's own `match_id` | | Done | |
| 23 | Disputes are raised by a match team; resolved disputes are complete | `(match_id, raised_by_team_id) → competes_in`; CHECK on `resolved_by` and `resolved_at` | | Done | |
| 24 | Reward bands do not overlap; points count only in league seasons | `EXCLUDE` on `placement_reward`; the points views only sum tournaments that have a stage | | Done | `test_reward_bands_cannot_overlap_rule_24` |
| 25 | Tournament, stage and phase dates nest | | Date range checks | Phase 3 | |
| 26 | Teams in a season tournament are registered for that season | | `participates_in` checked against `registered_in` | Phase 3 | |
| 27 | At most `max_teams` participants | | Count check, with the tournament row locked | Phase 3 | |
| 28 | `final_placement` is within range | CHECK `final_placement ≥ 1` | `final_placement ≤` number of participants | Partly | |
| 29 | Every period is ordered | CHECKs `end_date ≥ start_date`, `valid_to ≥ valid_from` | | Done | `test_periods_must_be_ordered_rule_29` |

## Participation constraints (Section 4.5)

A foreign key cannot say "at least one child row", so each of these becomes a deferred
constraint trigger in Phase 3, checked at commit after the parent and its children exist.

| Constraint | Status |
| --- | --- |
| Every team has at least one `team_identity` | Phase 3 |
| Every event has at least one `hosted_by` row | Phase 3 |
| Every event is exactly one of `league` or `tournament` | Phase 3 |
| Every `player_game_stats` row has exactly one mode specialization | Phase 3 |

## Error codes

When a trigger or function rejects a change because of rule *n*, it raises SQLSTATE
`R00nn` (rule 7 → `R0007`) with a message that starts the same way, so the error log and the
demo app show which rule stopped the change. `raise_rule(n, message)` in `db/05_support.sql`
does this. Errors from keys and constraints keep PostgreSQL's own codes: `23505` unique,
`23503` foreign key, `23514` check, `23P01` exclusion.
