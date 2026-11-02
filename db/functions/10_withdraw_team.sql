-- Function 10: withdraw_team                                          (stretch function)
--
-- Takes a team out of a tournament: each of its unfinished matches that has an opponent
-- becomes a forfeit win for the opponent, with a 'match forfeit' penalty on the team.
-- advance_bracket moves both teams on after each forfeit, so in double elimination the
-- withdrawn team drops to the lower bracket and forfeits there too, in the same call.
--
-- A match still waiting for its other team cannot be forfeited yet (rule 1: a started
-- match has two teams). The result lists those matches under "waiting"; calling
-- withdraw_team again once the opponent is known forfeits them. Calling it again is
-- always safe: matches already forfeited are finished and are skipped.
--
-- Rules that guard the writes: 5 (the awarded team is in the match), 21 (the penalty
-- matches the forfeit), 3 (moving teams on).
-- Demo failure: a team that is not in the tournament -> FN002.
--
-- Example:
--   SELECT * FROM withdraw_team(p_tournament_id => 12, p_team_id => 6, p_official_id => 90,
--                               p_reason => 'roster could not travel');

-- Internal: the work, without error handling, so disband_team can reuse it inside its own
-- transaction. Returns {"forfeited": [match ids], "waiting": [match ids]}.
CREATE FUNCTION withdraw_from_tournament(p_tournament_id integer, p_team_id integer,
                                         p_official_id integer, p_reason text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_match     integer;
    v_opponent  integer;
    v_forfeited integer[] := '{}';
    v_waiting   integer[];
BEGIN
    IF NOT EXISTS (SELECT 1 FROM participates_in
                   WHERE tournament_id = p_tournament_id AND team_id = p_team_id) THEN
        PERFORM raise_check(2, format('%s is not in tournament %s', team_label(p_team_id), p_tournament_id));
    END IF;

    LOOP
        -- The team's next unfinished match that has an opponent
        SELECT m.match_id INTO v_match
        FROM match m
        JOIN competes_in c ON c.match_id = m.match_id AND c.team_id = p_team_id
        WHERE m.tournament_id = p_tournament_id AND m.status NOT IN ('completed', 'cancelled')
          AND (SELECT count(*) FROM competes_in x WHERE x.match_id = m.match_id) = 2
        ORDER BY m.phase_number, m.match_number
        LIMIT 1
        FOR NO KEY UPDATE OF m;
        EXIT WHEN NOT FOUND;

        SELECT team_id INTO v_opponent FROM competes_in WHERE match_id = v_match AND team_id <> p_team_id;
        UPDATE match SET status = 'completed', result_type = 'forfeit', awarded_team_id = v_opponent
        WHERE match_id = v_match;                     -- advance_bracket moves both teams on
        INSERT INTO penalty (penalty_type, reason, issued_by, team_id, match_id)
        VALUES ('match forfeit', p_reason, p_official_id, p_team_id, v_match);
        v_forfeited := v_forfeited || v_match;
    END LOOP;

    SELECT array_agg(m.match_id ORDER BY m.match_number) INTO v_waiting
    FROM match m
    JOIN competes_in c ON c.match_id = m.match_id AND c.team_id = p_team_id
    WHERE m.tournament_id = p_tournament_id AND m.status NOT IN ('completed', 'cancelled');

    RETURN jsonb_build_object('forfeited', to_jsonb(v_forfeited),
                              'waiting', to_jsonb(COALESCE(v_waiting, '{}')));
END $$;

CREATE FUNCTION withdraw_team(
    p_tournament_id integer,
    p_team_id       integer,
    p_official_id   integer,
    p_reason        text)
RETURNS fn_result
LANGUAGE plpgsql AS $$
DECLARE
    v_inputs jsonb := jsonb_build_object('tournament_id', p_tournament_id, 'team_id', p_team_id,
                                         'official_id', p_official_id, 'reason', p_reason);
    v_done   jsonb;
    e_state text; e_msg text; e_detail text; e_hint text; e_ctx text;
BEGIN
    -- 1. Check the inputs
    IF NULLIF(trim(p_reason), '') IS NULL THEN
        PERFORM raise_check(3, 'a withdrawal needs a reason');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM official WHERE person_id = p_official_id) THEN
        PERFORM raise_check(2, format('person %s is not an official', p_official_id));
    END IF;

    -- 2. Lock the tournament (the matches are locked one by one inside)
    PERFORM 1 FROM tournament WHERE event_id = p_tournament_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        PERFORM raise_check(2, format('tournament %s does not exist', p_tournament_id));
    END IF;

    -- 3. The writes
    v_done := withdraw_from_tournament(p_tournament_id, p_team_id, p_official_id, trim(p_reason));

    -- 4. Run the commit-time checks now
    PERFORM run_commit_checks();

    RETURN fn_ok(format('%s withdrawn: %s match(es) forfeited, %s waiting for an opponent',
                        team_label(p_team_id), jsonb_array_length(v_done -> 'forfeited'),
                        jsonb_array_length(v_done -> 'waiting')),
                 v_done || jsonb_build_object('tournament_id', p_tournament_id, 'team_id', p_team_id));
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS e_state = RETURNED_SQLSTATE, e_msg = MESSAGE_TEXT,
        e_detail = PG_EXCEPTION_DETAIL, e_hint = PG_EXCEPTION_HINT, e_ctx = PG_EXCEPTION_CONTEXT;
    RETURN fn_fail('withdraw_team', v_inputs, e_state, e_msg, e_detail, e_hint, e_ctx);
END $$;
