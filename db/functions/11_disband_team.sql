-- Function 11: disband_team                                           (stretch function)
--
-- Closes a team down on a date: withdraws it from every tournament where it still has
-- unfinished matches (using the same work as withdraw_team), ends every open stint with
-- end_reason 'team disbanded', and marks the team disbanded. Its identities, results and
-- past stints stay as history.
--
-- Rules that guard the writes: 14 and 29 (stint dates), 12 (a stint cannot end before a
-- match it covered), 5, 21 and 3 (the forfeits).
-- Demo failure: the team has a match in progress -> FN001; nothing changes.
--
-- Example:
--   SELECT * FROM disband_team(p_team_id => 6, p_date => '2026-06-30', p_official_id => 90);
CREATE FUNCTION disband_team(
    p_team_id     integer,
    p_date        date,
    p_official_id integer,
    p_reason      text DEFAULT 'team disbanded')
RETURNS fn_result
LANGUAGE plpgsql AS $$
DECLARE
    v_inputs      jsonb := jsonb_build_object('team_id', p_team_id, 'date', p_date,
                                              'official_id', p_official_id, 'reason', p_reason);
    v_status      text;
    v_live        integer;
    v_tournament  integer;
    v_tournaments integer[];
    v_done        jsonb;
    v_withdrawn   jsonb := '[]';
    v_stints      integer;
    e_state text; e_msg text; e_detail text; e_hint text; e_ctx text;
BEGIN
    -- 1. Check the inputs
    IF p_team_id IS NULL OR p_date IS NULL THEN
        PERFORM raise_check(3, 'the team and the date are required');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM official WHERE person_id = p_official_id) THEN
        PERFORM raise_check(2, format('person %s is not an official', p_official_id));
    END IF;

    -- 2. Lock in the agreed order: the tournaments it still plays in, then the team
    SELECT array_agg(DISTINCT m.tournament_id ORDER BY m.tournament_id) INTO v_tournaments
    FROM match m JOIN competes_in c ON c.match_id = m.match_id
    WHERE c.team_id = p_team_id AND m.status NOT IN ('completed', 'cancelled');
    PERFORM 1 FROM tournament WHERE event_id = ANY (COALESCE(v_tournaments, '{}'))
    ORDER BY event_id FOR NO KEY UPDATE;

    SELECT status INTO v_status FROM team WHERE team_id = p_team_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        PERFORM raise_check(2, format('team %s does not exist', p_team_id));
    END IF;
    IF v_status = 'disbanded' THEN
        PERFORM raise_check(1, format('%s has already disbanded', team_label(p_team_id)));
    END IF;
    SELECT m.match_id INTO v_live
    FROM match m JOIN competes_in c ON c.match_id = m.match_id
    WHERE c.team_id = p_team_id AND m.status = 'live'
    LIMIT 1;
    IF FOUND THEN
        PERFORM raise_check(1, format('%s is playing match %s right now', team_label(p_team_id), v_live));
    END IF;

    -- 3a. Withdraw from every tournament with unfinished matches
    FOREACH v_tournament IN ARRAY COALESCE(v_tournaments, '{}') LOOP
        v_done := withdraw_from_tournament(v_tournament, p_team_id, p_official_id, p_reason);
        v_withdrawn := v_withdrawn || (v_done || jsonb_build_object('tournament_id', v_tournament));
    END LOOP;

    -- 3b. End every open stint, then mark the team disbanded
    UPDATE roster SET end_date = p_date, end_reason = 'team disbanded'
    WHERE team_id = p_team_id AND end_date IS NULL;
    GET DIAGNOSTICS v_stints = ROW_COUNT;

    UPDATE team SET status = 'disbanded' WHERE team_id = p_team_id;

    -- 4. Run the commit-time checks now
    PERFORM run_commit_checks();

    RETURN fn_ok(format('%s disbanded on %s: %s stint(s) ended, withdrawn from %s tournament(s)',
                        team_label(p_team_id), p_date, v_stints, jsonb_array_length(v_withdrawn)),
                 jsonb_build_object('team_id', p_team_id, 'stints_ended', v_stints,
                                    'withdrawn', v_withdrawn));
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS e_state = RETURNED_SQLSTATE, e_msg = MESSAGE_TEXT,
        e_detail = PG_EXCEPTION_DETAIL, e_hint = PG_EXCEPTION_HINT, e_ctx = PG_EXCEPTION_CONTEXT;
    RETURN fn_fail('disband_team', v_inputs, e_state, e_msg, e_detail, e_hint, e_ctx);
END $$;
