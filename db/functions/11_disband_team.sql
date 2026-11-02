-- Function 11: disband_team                                           (stretch function)
--
-- Closes a team down on a date:
--   * withdraws it from every tournament it is still in (no final placement yet): its
--     unfinished matches become forfeits, and an entry in a tournament where it has not
--     played yet is removed (the same work as withdraw_team);
--   * ends every open stint with end_reason 'team disbanded';
--   * marks the team disbanded, so no function will sign players to it or put it in a
--     bracket again.
-- Its identities, results and past stints stay as history.
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
    -- 1. Check the inputs and the team's state
    IF p_team_id IS NULL OR p_date IS NULL THEN
        PERFORM raise_check(3, 'the team and the date are required');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM official WHERE person_id = p_official_id) THEN
        PERFORM raise_check(2, format('person %s is not an official', p_official_id));
    END IF;
    SELECT status INTO v_status FROM team WHERE team_id = p_team_id;
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

    -- 2. Lock in the agreed order: tournaments (here), matches (inside the withdrawal),
    --    then the team
    SELECT array_agg(tournament_id ORDER BY tournament_id) INTO v_tournaments
    FROM participates_in WHERE team_id = p_team_id AND final_placement IS NULL;
    PERFORM 1 FROM tournament WHERE event_id = ANY (COALESCE(v_tournaments, '{}'))
    ORDER BY event_id FOR NO KEY UPDATE;

    -- 3a. Withdraw from every tournament it is still in. A tournament where all its
    --     matches are finished (it is already out) needs nothing.
    FOREACH v_tournament IN ARRAY COALESCE(v_tournaments, '{}') LOOP
        IF EXISTS (SELECT 1 FROM match m JOIN competes_in c ON c.match_id = m.match_id
                   WHERE c.team_id = p_team_id AND m.tournament_id = v_tournament
                     AND m.status NOT IN ('completed', 'cancelled'))
           OR NOT EXISTS (SELECT 1 FROM match m JOIN competes_in c ON c.match_id = m.match_id
                          WHERE c.team_id = p_team_id AND m.tournament_id = v_tournament) THEN
            v_done := withdraw_from_tournament(v_tournament, p_team_id, p_official_id, p_reason);
            v_withdrawn := v_withdrawn || (v_done || jsonb_build_object('tournament_id', v_tournament));
        END IF;
    END LOOP;

    -- 3b. Lock the team, check nobody disbanded it meanwhile, end every open stint
    SELECT status INTO v_status FROM team WHERE team_id = p_team_id FOR NO KEY UPDATE;
    IF v_status = 'disbanded' THEN
        PERFORM raise_check(1, format('%s has already disbanded', team_label(p_team_id)));
    END IF;
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
