# The 12 functions

Every operation on the league is one PL/pgSQL function in `db/functions/`, one file each,
numbered as in Section 8 of the implementation plan. Five are demoed, three are tested
backups, four are stretch goals; all twelve are built and tested.

## The contract every function follows

```
CREATE FUNCTION some_operation(p_... named parameters ...) RETURNS fn_result AS $$
DECLARE v_inputs jsonb := jsonb_build_object(...);           -- what to log if it fails
BEGIN
    -- 1. Check the inputs                     raise_check(3, ...)  -> FN003
    -- 2. Lock the rows it depends on          tournament, match, team, person (in that order)
    --    and check their state                raise_check(1 or 2, ...)
    -- 3. The writes                           every trigger checks its rules as rows go in
    -- 4. PERFORM run_commit_checks();         the commit-time rules run now, inside the call
    RETURN fn_ok('what happened', '{"ids": ...}');
EXCEPTION WHEN OTHERS THEN                     -- any error in 1 to 4
    GET STACKED DIAGNOSTICS ...;               -- code, message, detail, hint, context
    RETURN fn_fail('some_operation', v_inputs, ...);   -- one error_log row; returns ok = false
END $$;
```

- **All or nothing.** A PL/pgSQL block with an EXCEPTION clause runs as a savepoint. When
  anything in steps 1 to 4 fails, PostgreSQL undoes every write the block made, and only
  then does the handler run. So the error_log row is the only trace a failed call leaves.
- **Result.** `fn_result (ok, code, message, data)`. On success `code` is `00000` and `data`
  holds the ids the call created; on failure `data` holds the `log_id` of its error_log row.
- **Locks.** Rows a call depends on are locked with `FOR NO KEY UPDATE`, always in the order
  tournament, match, team, person, so two calls cannot deadlock. `NO KEY UPDATE` blocks other
  writers exactly like `FOR UPDATE`, but lets PostgreSQL's foreign key checks through, so a
  call that inserts a game for a locked match does not block on itself or deadlock with
  another session's foreign key check. (The plan said `FOR UPDATE`; this is the same idea
  with the lighter lock.)
- **Commit-time rules.** `run_commit_checks()` runs `SET CONSTRAINTS ALL IMMEDIATE`, so a
  game without both scores fails the call itself, then `SET CONSTRAINTS ALL DEFERRED`, so
  several calls can share one transaction (the seed loader does this). A call also runs any
  check left pending by earlier writes in the same transaction, which is why the app and the
  tests make one call per transaction.
- **Safe to repeat.** Each function checks state before it writes: a second
  `record_series_result` for a match fails with `FN001` and changes nothing.

## Error codes

| Code | Meaning | Example |
| --- | --- | --- |
| `R0001` to `R0029` | Business rule *nn* (a trigger refused a row) | `R0012: Ringer has no playing or coaching stint with ...` |
| `T0001` to `T0004` | Total participation constraint T*n* | `T0001: team 7 has no team identity` |
| `FN001` | Wrong state: the rows exist but do not allow this call | `FN001: match 40 is completed and already has its result` |
| `FN002` | Not found: a row the call needs does not exist | `FN002: Shotzzy has no open stint with OpTic Texas` |
| `FN003` | Bad input: a parameter or JSON field is missing or invalid | `FN003: these games do not decide a best of 5 (A 2, B 1)` |
| `23505`, `23503`, `23514`, `23P01` | Unique, foreign key, CHECK, EXCLUDE (PostgreSQL's own) | `23505` duplicate Activision ID |

The plan proposed `F0001` upward for function checks. PostgreSQL already uses class `F0` for
configuration-file errors (`F0001` is `lock_file_exists`), so our codes use their own class,
`FN`, to avoid two meanings for one code.

## The functions

| # | Function | Role | Inputs | What one call writes | Rules guarding it | Failure we demo |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `setup_tournament_phase` | Demo | tournament, phase, teams in seed order (JSON) | enters the teams; every match of a single or double elimination bracket or a round robin, with winner and loser links; the first round | 2, 3, 8, 26, 27 | a team not registered for the season: `R0026`, no match created |
| 2 | `record_series_result` | Demo | match, series (JSON: lineups, games, scores, stats, mode stats) | match_player, games (or fills the veto's), team_result, player_game_stats, mode stats; completes the match; the bracket moves both teams on | 1, 3, 4, 6, 7, 11, 12, 13, 16, 17, T4 | one player without a stint: `R0012`, none of the series saved |
| 3 | `transfer_player` | Demo | person, old team, new team, date, role, join type, fee | ends the open stint on the date; opens the new one that day | 12, 14, 15, 29 | a third two-way player: `R0014`, the old stint stays open |
| 4 | `rebrand_team` | Demo | team, date, name, abbreviation, city, owner | ends the current identity on the date; opens the new one | 18, 29, T1 | a date before the current identity began: `FN003` |
| 5 | `resolve_dispute` (+ `raise_dispute`) | Demo | match, dispute number, official, decision, resolution, penalties (JSON), forfeit (JSON) | match or game forfeit; penalties tied to the dispute; closes the dispute; the bracket follows a changed winner | 3, 5, 19, 20, 21, 22, 23 | a penalty for a team not in the match: `23503`, the dispute stays open |
| 6 | `run_map_veto` | Backup | match, picks and bans (JSON) | the vetoes; one scheduled game per slot: each pick, then the decider | 7, 8, 10 | a ban on a map outside the pool: `R0010` |
| 7 | `finalize_tournament` | Stretch | tournament | every team's final placement | 24, 28 | an unfinished match: `FN001`, no placement written |
| 8 | `sign_new_player` | Backup | person details, Activision and FACEIT ids, phones, team, role, start date | person, phones, player, first stint | unique keys, 14, 15 | a duplicate Activision ID: `23505`, no person row left |
| 9 | `create_tournament` | Backup | event, host, tournament details, stage, phases (JSON), prize bands (JSON) | event, host link, tournament, phases, prize bands | 8, 9, 24, 25, 29, T2, T3 | overlapping prize bands: `23P01`, no event left |
| 10 | `withdraw_team` | Stretch | tournament, team, official, reason | each unfinished match with an opponent becomes a forfeit with a penalty; the bracket moves on | 3, 5, 21 | a team not in the tournament: `FN002` |
| 11 | `disband_team` | Stretch | team, date, official | withdraws it from unfinished tournaments; ends every open stint; marks it disbanded | 12, 14, 29, and those of 10 | a match in progress: `FN001`, nothing changes |
| 12 | `update_map_pool` | Stretch | pool name, entries (JSON), phases to move (JSON) | a new pool version; moves the listed phases to it | 7, 8, 9, 10 | a phase that already has games: `FN001` |

Each file starts with a comment giving the JSON shape and an example call.

## Notes on specific functions

- **Bracket progression.** No function moves teams itself. The trigger `advance_bracket`
  (rule 3, as the report's Section 4.5 planned) places a completed match's winner and loser
  in their next matches, and places them again if a dispute changes the winner before the
  next match starts. That is why functions 2, 5, 10 and 11 all keep the bracket right.
- **Brackets built by function 1.** Seeds go in the standard order (1 v 8, 4 v 5, 2 v 7,
  3 v 6), so seeds 1 and 2 can only meet in the final. In double elimination, losers of upper
  round 1 pair up in lower round 1; losers of later upper rounds drop into the lower bracket
  in reverse order, so a team rarely meets the team it just lost to. Team counts must be a
  power of two (no byes).
- **Veto (function 6).** A slot takes the next pick of its mode in veto order; a slot with no
  pick takes the one map of that mode left unbanned and unpicked. `record_series_result` then
  fills those games without a `map_id` in its JSON.
- **Placements (function 7).** In an elimination phase a team's run ends with the loss that
  has no loser link; later exits place higher, and exits in the same round share a placement
  (1, 2, 3, 4, 5, 5, 7, 7). In a round robin, more wins place higher.
- **Withdrawal (function 10).** A match still waiting for its other team cannot be forfeited
  yet, because a started match needs two teams (rule 1). Those matches come back under
  `waiting`; calling `withdraw_team` again once the opponent is known finishes them.

## Tests

`tests/test_functions_people.py`, `tests/test_functions_matches.py` and
`tests/test_functions_operations.py` hold a success test for every function and a failure
test for each failure it guards against. Every failure test uses `fails_cleanly()`, which
checks the plan's three conditions: the call returns `ok = false` with the expected code;
every table it touches has the same row count as before; `error_log` holds exactly one new
row with that code. `tests/test_concurrency.py` runs the plan's concurrency test: two
sessions record the same match at once; one succeeds, the other waits for the lock, then
gets `FN001` and writes nothing.
