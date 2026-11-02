-- Function 2: record_series_result                                    (demo function)
--
-- Records a whole series in one call: who played (match_player), each game with its map,
-- mode, both scores and every player's stats with their mode details; then completes the
-- match. The trigger advance_bracket (rule 3) moves the winner and the loser into their
-- next matches as the match completes.
--
-- If run_map_veto already created the games, their maps and modes are kept and the games
-- are filled in; otherwise each game in the JSON must give map_id and mode_id.
--
--   p_series = {
--     "played_at": "2026-03-01T18:00:00Z",                     (optional: the match time)
--     "lineups": [{"team_id": 1, "players": [11, 12, 13, 14]},
--                 {"team_id": 2, "players": [21, 22, 23, 24]}],
--     "games": [
--       {"game_number": 1, "map_id": 3, "mode_id": 1, "duration_seconds": 612,
--        "scores": [{"team_id": 1, "score": 250}, {"team_id": 2, "score": 201}],
--        "stats":  [{"person_id": 11, "kills": 27, "deaths": 21, "assists": 6, "damage": 3810,
--                    "mode_stats": {"hill_time_seconds": 95, "captures": 4}}, ...]},
--       ...]}
--   mode_stats keys:  HP  hill_time_seconds, contested_time_seconds, captures
--                     S&D first_bloods, plants, defuses
--                     CTL tiers_captured, ticks
--                     OVR overloads_scored, device_pickups, carry_time_seconds
--
-- Rules that guard the writes: 1, 3, 4, 6, 7, 11, 12, 13 (and 16, 17, T4).
-- Demo failure: one player without a roster stint on the match date -> R0012; none of
-- the series is saved and the match stays unplayed.
-- A second call for the same match fails with FN001 and changes nothing: the first
-- statement locks the match, so a concurrent second call waits, then sees it completed.

-- Internal: one mode-specific stats row, in the table that matches the game's mode.
CREATE FUNCTION add_mode_stats(p_mode text, p_person_id integer, p_match_id integer,
                               p_game_number integer, s jsonb) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    CASE p_mode
    WHEN 'HP' THEN
        INSERT INTO hardpoint_stats (person_id, match_id, game_number,
                                     hill_time_seconds, contested_time_seconds, captures)
        VALUES (p_person_id, p_match_id, p_game_number,
                COALESCE((s ->> 'hill_time_seconds')::int, 0),
                COALESCE((s ->> 'contested_time_seconds')::int, 0),
                COALESCE((s ->> 'captures')::int, 0));
    WHEN 'S&D' THEN
        INSERT INTO snd_stats (person_id, match_id, game_number, first_bloods, plants, defuses)
        VALUES (p_person_id, p_match_id, p_game_number,
                COALESCE((s ->> 'first_bloods')::int, 0),
                COALESCE((s ->> 'plants')::int, 0),
                COALESCE((s ->> 'defuses')::int, 0));
    WHEN 'CTL' THEN
        INSERT INTO control_stats (person_id, match_id, game_number, tiers_captured, ticks)
        VALUES (p_person_id, p_match_id, p_game_number,
                COALESCE((s ->> 'tiers_captured')::int, 0),
                COALESCE((s ->> 'ticks')::int, 0));
    WHEN 'OVR' THEN
        INSERT INTO overload_stats (person_id, match_id, game_number,
                                    overloads_scored, device_pickups, carry_time_seconds)
        VALUES (p_person_id, p_match_id, p_game_number,
                COALESCE((s ->> 'overloads_scored')::int, 0),
                COALESCE((s ->> 'device_pickups')::int, 0),
                COALESCE((s ->> 'carry_time_seconds')::int, 0));
    END CASE;
END $$;

CREATE FUNCTION record_series_result(
    p_match_id integer,
    p_series   jsonb)
RETURNS fn_result
LANGUAGE plpgsql AS $$
DECLARE
    v_inputs   jsonb := jsonb_build_object('match_id', p_match_id, 'series', p_series);
    m          match%ROWTYPE;
    v_teams    integer[];
    v_lineup   jsonb;
    v_game     jsonb;
    v_stat     jsonb;
    v_number   smallint;
    v_existing game%ROWTYPE;
    v_mode     integer;
    v_code     text;
    v_scores   integer[];
    v_winner   integer;
    v_person   integer;
    v_score    text;
    e_state text; e_msg text; e_detail text; e_hint text; e_ctx text;
BEGIN
    -- 1. Check the shape of the input
    IF p_series IS NULL OR jsonb_typeof(p_series -> 'lineups') IS DISTINCT FROM 'array'
       OR jsonb_typeof(p_series -> 'games') IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_series -> 'games') = 0 THEN
        PERFORM raise_check(3, 'p_series needs a "lineups" array and a non-empty "games" array');
    END IF;

    -- 2. Lock the match and check its state
    SELECT * INTO m FROM match WHERE match_id = p_match_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        PERFORM raise_check(2, format('match %s does not exist', p_match_id));
    END IF;
    IF m.status IN ('completed', 'cancelled') OR m.result_type IS NOT NULL THEN
        PERFORM raise_check(1, format('match %s is %s and already has its result', p_match_id, m.status));
    END IF;
    SELECT array_agg(team_id ORDER BY team_id) INTO v_teams FROM competes_in WHERE match_id = p_match_id;
    IF COALESCE(array_length(v_teams, 1), 0) <> 2 THEN
        PERFORM raise_check(1, format('match %s does not have both teams yet', p_match_id));
    END IF;
    IF (SELECT array_agg((l ->> 'team_id')::int ORDER BY (l ->> 'team_id')::int)
        FROM jsonb_array_elements(p_series -> 'lineups') AS l) IS DISTINCT FROM v_teams THEN
        PERFORM raise_check(3, format('give one lineup for each of the two teams in match %s', p_match_id));
    END IF;
    -- Games are numbered 1, 2, 3 ... with no gap
    IF (SELECT array_agg((g ->> 'game_number')::int ORDER BY (g ->> 'game_number')::int)
        FROM jsonb_array_elements(p_series -> 'games') AS g)
       IS DISTINCT FROM (SELECT array_agg(n) FROM generate_series(1, jsonb_array_length(p_series -> 'games')) AS n) THEN
        PERFORM raise_check(3, 'the games must be numbered 1, 2, 3 ... with no gap or repeat');
    END IF;
    -- Every player with stats is in a lineup (otherwise the foreign key to match_player
    -- would refuse the row with a less readable message)
    SELECT (s ->> 'person_id')::int INTO v_person
    FROM jsonb_array_elements(p_series -> 'games') AS g,
         jsonb_array_elements(COALESCE(g -> 'stats', '[]')) AS s
    WHERE (s ->> 'person_id')::int NOT IN (
        SELECT p.value::int FROM jsonb_array_elements(p_series -> 'lineups') AS l,
                                 jsonb_array_elements_text(l -> 'players') AS p)
    LIMIT 1;
    IF FOUND THEN
        PERFORM raise_check(3, format('%s has stats but is not in either lineup', person_label(v_person)));
    END IF;

    -- 3a. When the series was played (optional); rules 12 and 16 use this date
    IF p_series ? 'played_at' THEN
        UPDATE match SET scheduled_at = (p_series ->> 'played_at')::timestamptz WHERE match_id = p_match_id;
    END IF;

    -- 3b. Lineups (played_for): rules 12, 16 and 17 are checked as each row goes in
    FOR v_lineup IN SELECT * FROM jsonb_array_elements(p_series -> 'lineups') LOOP
        INSERT INTO match_player (person_id, match_id, team_id)
        SELECT p.value::int, p_match_id, (v_lineup ->> 'team_id')::int
        FROM jsonb_array_elements_text(v_lineup -> 'players') AS p;
    END LOOP;

    -- 3c. Games, in game order
    FOR v_game IN SELECT g FROM jsonb_array_elements(p_series -> 'games') AS g
                  ORDER BY (g ->> 'game_number')::int LOOP
        v_number := (v_game ->> 'game_number')::smallint;
        IF v_number IS NULL THEN
            PERFORM raise_check(3, 'every game needs a game_number');
        END IF;
        SELECT array_agg((s ->> 'score')::int) INTO v_scores
        FROM jsonb_array_elements(COALESCE(v_game -> 'scores', '[]')) AS s;
        IF COALESCE(array_length(v_scores, 1), 0) <> 2 THEN
            PERFORM raise_check(3, format('game %s needs one score for each team', v_number));
        END IF;
        IF v_scores[1] = v_scores[2] THEN
            PERFORM raise_check(3, format('game %s is a tie (%s-%s); a played game has a winner',
                                          v_number, v_scores[1], v_scores[2]));
        END IF;

        SELECT * INTO v_existing FROM game
        WHERE match_id = p_match_id AND game_number = v_number FOR UPDATE;
        IF FOUND THEN
            -- Created by run_map_veto: keep its map and mode, fill in the result
            IF (v_game ? 'map_id' AND (v_game ->> 'map_id')::int <> v_existing.map_id)
               OR (v_game ? 'mode_id' AND (v_game ->> 'mode_id')::int <> v_existing.mode_id) THEN
                PERFORM raise_check(3, format('the map veto set game %s to %s', v_number,
                                              map_mode_label(v_existing.map_id, v_existing.mode_id)));
            END IF;
            UPDATE game SET status = 'completed', result_type = 'played',
                            started_at = (v_game ->> 'started_at')::timestamptz,
                            duration_seconds = (v_game ->> 'duration_seconds')::int
            WHERE match_id = p_match_id AND game_number = v_number;
            v_mode := v_existing.mode_id;
        ELSE
            IF NOT (v_game ? 'map_id' AND v_game ? 'mode_id') THEN
                PERFORM raise_check(3, format('game %s needs map_id and mode_id (no map veto set them)', v_number));
            END IF;
            v_mode := (v_game ->> 'mode_id')::int;
            INSERT INTO game (match_id, game_number, started_at, duration_seconds, status, result_type, map_id, mode_id)
            VALUES (p_match_id, v_number, (v_game ->> 'started_at')::timestamptz,
                    (v_game ->> 'duration_seconds')::int, 'completed', 'played',
                    (v_game ->> 'map_id')::int, v_mode);
        END IF;

        INSERT INTO team_result (match_id, game_number, team_id, score)
        SELECT p_match_id, v_number, (s ->> 'team_id')::int, (s ->> 'score')::int
        FROM jsonb_array_elements(v_game -> 'scores') AS s;

        SELECT abbreviation INTO v_code FROM game_mode WHERE mode_id = v_mode;
        FOR v_stat IN SELECT * FROM jsonb_array_elements(COALESCE(v_game -> 'stats', '[]')) LOOP
            INSERT INTO player_game_stats (person_id, match_id, game_number, kills, deaths, assists, damage)
            VALUES ((v_stat ->> 'person_id')::int, p_match_id, v_number,
                    COALESCE((v_stat ->> 'kills')::int, 0), COALESCE((v_stat ->> 'deaths')::int, 0),
                    COALESCE((v_stat ->> 'assists')::int, 0), COALESCE((v_stat ->> 'damage')::int, 0));
            PERFORM add_mode_stats(v_code, (v_stat ->> 'person_id')::int, p_match_id, v_number,
                                   COALESCE(v_stat -> 'mode_stats', '{}'));
        END LOOP;
    END LOOP;

    -- 3d. The games must decide the series; then the match is complete
    SELECT team_id INTO v_winner FROM v_series_score
    WHERE match_id = p_match_id AND games_won > m.best_of / 2;
    SELECT string_agg(team_label(team_id) || ' ' || games_won, ', ' ORDER BY games_won DESC) INTO v_score
    FROM v_series_score WHERE match_id = p_match_id;
    IF v_winner IS NULL THEN
        PERFORM raise_check(3, format('these games do not decide a best of %s (%s)', m.best_of, v_score));
    END IF;

    UPDATE match SET status = 'completed', result_type = 'played' WHERE match_id = p_match_id;
    -- advance_bracket has now placed the winner and the loser in their next matches

    -- 4. Run the commit-time checks now: rules 1, 4, 6, 11 and T4
    PERFORM run_commit_checks();

    RETURN fn_ok(format('%s won match %s (%s)', team_label(v_winner), p_match_id, v_score),
                 jsonb_build_object(
                     'match_id', p_match_id, 'winner_team_id', v_winner,
                     'score', (SELECT jsonb_object_agg(team_id, games_won) FROM v_series_score
                               WHERE match_id = p_match_id),
                     'winner_to', m.winner_to_match_id, 'loser_to', m.loser_to_match_id));
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS e_state = RETURNED_SQLSTATE, e_msg = MESSAGE_TEXT,
        e_detail = PG_EXCEPTION_DETAIL, e_hint = PG_EXCEPTION_HINT, e_ctx = PG_EXCEPTION_CONTEXT;
    RETURN fn_fail('record_series_result', v_inputs, e_state, e_msg, e_detail, e_hint, e_ctx);
END $$;
