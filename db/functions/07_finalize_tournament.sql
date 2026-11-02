-- Function 7: finalize_tournament                                     (stretch function)
--
-- Once every match is finished, writes every team's final placement. The prize and points
-- each team earns then follow from the views (v_team_prize, v_team_season_points).
--
-- How placements are decided, for the tournament's last phase:
--   * Elimination formats: a team is knocked out by the match it loses that has no loser
--     link. Teams knocked out in a later round place higher; teams knocked out in the same
--     round share a placement (both lower-round-1 losers of an 8-team bracket place 7th).
--     The team never knocked out is 1st.
--   * Round robin: more wins place higher; equal wins share a placement.
-- Teams that did not reach the last phase place below everyone who did, by wins.
-- A shared placement uses standard competition ranking: 1, 2, 3, 4, 5, 5, 7, 7.
--
-- Rules that guard the writes: 28 (placements fit the field), 24 (bands decide prizes).
-- Demo failure: one unfinished match -> FN001; no placement is written.
--
-- Example:
--   SELECT * FROM finalize_tournament(p_tournament_id => 12);
CREATE FUNCTION finalize_tournament(p_tournament_id integer)
RETURNS fn_result
LANGUAGE plpgsql AS $$
DECLARE
    v_inputs  jsonb := jsonb_build_object('tournament_id', p_tournament_id);
    v_name    text;
    v_open    record;
    v_phase   smallint;
    v_format  text;
    v_result  jsonb;
    e_state text; e_msg text; e_detail text; e_hint text; e_ctx text;
BEGIN
    -- 1-2. Lock the tournament and check its state
    PERFORM 1 FROM tournament WHERE event_id = p_tournament_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        PERFORM raise_check(2, format('tournament %s does not exist', p_tournament_id));
    END IF;
    SELECT event_name INTO v_name FROM event WHERE event_id = p_tournament_id;
    IF EXISTS (SELECT 1 FROM participates_in WHERE tournament_id = p_tournament_id
               AND final_placement IS NOT NULL) THEN
        PERFORM raise_check(1, format('"%s" already has its final placements', v_name));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM match WHERE tournament_id = p_tournament_id) THEN
        PERFORM raise_check(1, format('"%s" has no matches yet', v_name));
    END IF;
    SELECT match_number, round_name, phase_number INTO v_open
    FROM match
    WHERE tournament_id = p_tournament_id AND status NOT IN ('completed', 'cancelled')
    ORDER BY phase_number, match_number
    LIMIT 1;
    IF FOUND THEN
        PERFORM raise_check(1, format('match %s (%s, phase %s) of "%s" is not finished',
                                      v_open.match_number, v_open.round_name, v_open.phase_number, v_name));
    END IF;

    SELECT max(phase_number) INTO v_phase FROM match WHERE tournament_id = p_tournament_id;
    SELECT lower(f.format_name) INTO v_format
    FROM phase ph JOIN format f ON f.format_id = ph.format_id
    WHERE ph.tournament_id = p_tournament_id AND ph.phase_number = v_phase;

    -- 3. The writes: one placement per participating team
    WITH last_phase AS (
        SELECT m.* FROM match m
        WHERE m.tournament_id = p_tournament_id AND m.phase_number = v_phase AND m.status = 'completed'),
    round_position AS (                 -- a round's position is its first match number
        SELECT round_name, min(match_number) AS pos FROM last_phase GROUP BY round_name),
    knocked_out AS (                    -- losing a match with no loser link ends a team's run
        SELECT c.team_id, max(rp.pos) AS pos
        FROM last_phase m
        JOIN competes_in c      ON c.match_id = m.match_id
        JOIN v_match_winner w   ON w.match_id = m.match_id
        JOIN round_position rp  ON rp.round_name = m.round_name
        WHERE c.team_id <> w.team_id AND m.loser_to_match_id IS NULL
        GROUP BY c.team_id),
    team_record AS (                    -- wins in the tournament; did the team reach the last phase?
        SELECT c.team_id,
               count(*) FILTER (WHERE w.team_id = c.team_id) AS wins,
               bool_or(m.phase_number = v_phase) AS in_last_phase
        FROM match m
        JOIN competes_in c          ON c.match_id = m.match_id
        LEFT JOIN v_match_winner w  ON w.match_id = m.match_id
        WHERE m.tournament_id = p_tournament_id
        GROUP BY c.team_id),
    score AS (
        SELECT p.team_id,
               COALESCE(r.in_last_phase, false) AS reached,
               CASE WHEN v_format = 'round robin' OR NOT COALESCE(r.in_last_phase, false)
                    THEN COALESCE(r.wins, 0)
                    ELSE COALESCE(k.pos, 1000000)         -- never knocked out: the champion
               END AS level
        FROM participates_in p
        LEFT JOIN team_record r ON r.team_id = p.team_id
        LEFT JOIN knocked_out k ON k.team_id = p.team_id
        WHERE p.tournament_id = p_tournament_id),
    placed AS (
        SELECT team_id, rank() OVER (ORDER BY reached DESC, level DESC) AS place FROM score)
    UPDATE participates_in p SET final_placement = placed.place
    FROM placed
    WHERE p.tournament_id = p_tournament_id AND p.team_id = placed.team_id;

    -- 4. Run the commit-time checks now (rule 28)
    PERFORM run_commit_checks();

    SELECT jsonb_agg(jsonb_build_object('team_id', p.team_id, 'team', team_label(p.team_id),
                                        'placement', p.final_placement, 'prize', COALESCE(tp.prize, 0))
                     ORDER BY p.final_placement, p.team_id)
    INTO v_result
    FROM participates_in p
    LEFT JOIN v_team_prize tp ON tp.tournament_id = p.tournament_id AND tp.team_id = p.team_id
    WHERE p.tournament_id = p_tournament_id;

    RETURN fn_ok(format('"%s" finalized: %s placed 1st', v_name, v_result -> 0 ->> 'team'),
                 jsonb_build_object('tournament_id', p_tournament_id, 'placements', v_result));
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS e_state = RETURNED_SQLSTATE, e_msg = MESSAGE_TEXT,
        e_detail = PG_EXCEPTION_DETAIL, e_hint = PG_EXCEPTION_HINT, e_ctx = PG_EXCEPTION_CONTEXT;
    RETURN fn_fail('finalize_tournament', v_inputs, e_state, e_msg, e_detail, e_hint, e_ctx);
END $$;
