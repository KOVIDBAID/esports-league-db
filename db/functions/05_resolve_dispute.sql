-- Function 5: resolve_dispute                                         (demo function)
-- with its helper raise_dispute.
--
-- raise_dispute records a team's complaint about a match: one row, numbered per match.
--
-- resolve_dispute closes it in one call:
--   * p_decision 'resolved' (the dispute is upheld) or 'rejected'
--   * p_forfeit (optional, only when resolved) applies a forfeit:
--       {"awarded_team_id": 7}                     the whole match goes to team 7
--       {"game_number": 2, "awarded_team_id": 7}   game 2 goes to team 7
--     If the match was already completed, advance_bracket moves the right teams on again.
--   * p_penalties (optional): a JSON array of penalties, each tied to this match and dispute:
--       [{"penalty_type": "match forfeit", "team_id": 8, "reason": "...",
--         "person_id": null, "game_number": null, "start_date": null, "end_date": null,
--         "fine_amount": null}, ...]
--
-- Rules that guard the writes: 5 (awarded team is a match team), 19 (a penalty's team is
-- in the match), 20, 21 (forfeit penalties match a forfeit), 22 (dispute penalties point
-- at the dispute's match), 23 (a resolved dispute is complete), 3 (moving teams on).
-- Demo failure: a penalty naming a team that is not in the match -> 23503; the dispute
-- stays open and no penalty or forfeit is written.
--
-- Example:
--   SELECT * FROM raise_dispute(p_match_id => 40, p_team_id => 7, p_reason => 'server crash in game 2');
--   SELECT * FROM resolve_dispute(p_match_id => 40, p_dispute_number => 1, p_official_id => 90,
--       p_decision => 'resolved', p_resolution => 'Team 8 used a banned weapon',
--       p_forfeit => '{"awarded_team_id": 7}',
--       p_penalties => '[{"penalty_type": "match forfeit", "team_id": 8}]');

CREATE FUNCTION raise_dispute(
    p_match_id integer,
    p_team_id  integer,
    p_reason   text)
RETURNS fn_result
LANGUAGE plpgsql AS $$
DECLARE
    v_inputs jsonb := jsonb_build_object('match_id', p_match_id, 'team_id', p_team_id, 'reason', p_reason);
    v_number smallint;
    e_state text; e_msg text; e_detail text; e_hint text; e_ctx text;
BEGIN
    IF NULLIF(trim(p_reason), '') IS NULL THEN
        PERFORM raise_check(3, 'a dispute needs a reason');
    END IF;

    -- Lock the match, so two disputes raised at once get different numbers
    PERFORM 1 FROM match WHERE match_id = p_match_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        PERFORM raise_check(2, format('match %s does not exist', p_match_id));
    END IF;
    SELECT COALESCE(max(dispute_number), 0) + 1 INTO v_number FROM dispute WHERE match_id = p_match_id;

    -- Rule 23: the foreign key to competes_in refuses a team that is not in the match
    INSERT INTO dispute (match_id, dispute_number, reason, raised_by_team_id)
    VALUES (p_match_id, v_number, trim(p_reason), p_team_id);

    PERFORM run_commit_checks();
    RETURN fn_ok(format('dispute %s on match %s raised by %s', v_number, p_match_id, team_label(p_team_id)),
                 jsonb_build_object('match_id', p_match_id, 'dispute_number', v_number));
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS e_state = RETURNED_SQLSTATE, e_msg = MESSAGE_TEXT,
        e_detail = PG_EXCEPTION_DETAIL, e_hint = PG_EXCEPTION_HINT, e_ctx = PG_EXCEPTION_CONTEXT;
    RETURN fn_fail('raise_dispute', v_inputs, e_state, e_msg, e_detail, e_hint, e_ctx);
END $$;

CREATE FUNCTION resolve_dispute(
    p_match_id       integer,
    p_dispute_number integer,
    p_official_id    integer,
    p_decision       text,
    p_resolution     text,
    p_penalties      jsonb DEFAULT '[]',
    p_forfeit        jsonb DEFAULT NULL)
RETURNS fn_result
LANGUAGE plpgsql AS $$
DECLARE
    v_inputs    jsonb := jsonb_build_object(
        'match_id', p_match_id, 'dispute_number', p_dispute_number, 'official_id', p_official_id,
        'decision', p_decision, 'penalties', p_penalties, 'forfeit', p_forfeit);
    v_dispute   dispute%ROWTYPE;
    v_status    text;
    v_awarded   integer;
    v_game      smallint;
    v_penalty   jsonb;
    v_ids       integer[] := '{}';
    v_id        integer;
    v_winner    integer;
    e_state text; e_msg text; e_detail text; e_hint text; e_ctx text;
BEGIN
    -- 1. Check the inputs
    IF p_decision NOT IN ('resolved', 'rejected') OR p_decision IS NULL THEN
        PERFORM raise_check(3, 'p_decision is ''resolved'' (upheld) or ''rejected''');
    END IF;
    IF NULLIF(trim(p_resolution), '') IS NULL THEN
        PERFORM raise_check(3, 'a decision needs a written resolution');
    END IF;
    IF jsonb_typeof(COALESCE(p_penalties, '[]')) <> 'array' THEN
        PERFORM raise_check(3, 'p_penalties must be a JSON array');
    END IF;
    IF p_forfeit IS NOT NULL AND p_decision = 'rejected' THEN
        PERFORM raise_check(3, 'a rejected dispute cannot change the result');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM official WHERE person_id = p_official_id) THEN
        PERFORM raise_check(2, format('person %s is not an official', p_official_id));
    END IF;

    -- 2. Lock the match, then the dispute
    SELECT status INTO v_status FROM match WHERE match_id = p_match_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        PERFORM raise_check(2, format('match %s does not exist', p_match_id));
    END IF;
    SELECT * INTO v_dispute FROM dispute
    WHERE match_id = p_match_id AND dispute_number = p_dispute_number FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM raise_check(2, format('match %s has no dispute %s', p_match_id, p_dispute_number));
    END IF;
    IF v_dispute.status IN ('resolved', 'rejected') THEN
        PERFORM raise_check(1, format('dispute %s on match %s is already %s',
                                      p_dispute_number, p_match_id, v_dispute.status));
    END IF;

    -- 3a. Apply a forfeit (rule 5: the awarded team must be one of the match's teams)
    IF p_forfeit IS NOT NULL THEN
        v_awarded := (p_forfeit ->> 'awarded_team_id')::int;
        v_game    := (p_forfeit ->> 'game_number')::smallint;
        IF v_awarded IS NULL THEN
            PERFORM raise_check(3, 'p_forfeit needs awarded_team_id');
        END IF;
        IF v_game IS NULL THEN
            UPDATE match SET status = 'completed', result_type = 'forfeit', awarded_team_id = v_awarded
            WHERE match_id = p_match_id;
        ELSE
            UPDATE game SET status = 'completed', result_type = 'forfeit', awarded_team_id = v_awarded
            WHERE match_id = p_match_id AND game_number = v_game;
            IF NOT FOUND THEN
                PERFORM raise_check(2, format('match %s has no game %s', p_match_id, v_game));
            END IF;
            -- A completed match may now have another winner: let advance_bracket re-check it
            UPDATE match SET status = status WHERE match_id = p_match_id AND status = 'completed';
        END IF;
    END IF;

    -- 3b. Issue the penalties, each tied to this match and this dispute (rules 19 to 22)
    FOR v_penalty IN SELECT * FROM jsonb_array_elements(COALESCE(p_penalties, '[]')) LOOP
        INSERT INTO penalty (penalty_type, reason, start_date, end_date, fine_amount,
                             issued_by, team_id, person_id, match_id, game_number, dispute_number)
        VALUES (v_penalty ->> 'penalty_type',
                COALESCE(v_penalty ->> 'reason', trim(p_resolution)),
                (v_penalty ->> 'start_date')::date, (v_penalty ->> 'end_date')::date,
                (v_penalty ->> 'fine_amount')::numeric,
                p_official_id, (v_penalty ->> 'team_id')::int, (v_penalty ->> 'person_id')::int,
                p_match_id, (v_penalty ->> 'game_number')::smallint, p_dispute_number)
        RETURNING penalty_id INTO v_id;
        v_ids := v_ids || v_id;
    END LOOP;

    -- 3c. Close the dispute (rule 23: resolved_by and resolved_at are set)
    UPDATE dispute SET status = p_decision, resolution = trim(p_resolution),
                       resolved_by = p_official_id, resolved_at = now()
    WHERE match_id = p_match_id AND dispute_number = p_dispute_number;

    -- 4. Run the commit-time checks now (rule 21 among them)
    PERFORM run_commit_checks();

    SELECT team_id INTO v_winner FROM v_match_winner WHERE match_id = p_match_id;
    RETURN fn_ok(format('dispute %s on match %s %s; %s penalty(ies) issued', p_dispute_number, p_match_id,
                        p_decision, COALESCE(array_length(v_ids, 1), 0)),
                 jsonb_build_object('match_id', p_match_id, 'dispute_number', p_dispute_number,
                                    'status', p_decision, 'penalty_ids', to_jsonb(v_ids),
                                    'winner_team_id', v_winner));
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS e_state = RETURNED_SQLSTATE, e_msg = MESSAGE_TEXT,
        e_detail = PG_EXCEPTION_DETAIL, e_hint = PG_EXCEPTION_HINT, e_ctx = PG_EXCEPTION_CONTEXT;
    RETURN fn_fail('resolve_dispute', v_inputs, e_state, e_msg, e_detail, e_hint, e_ctx);
END $$;
