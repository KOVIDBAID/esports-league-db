-- Function 3: transfer_player                                         (demo function)
--
-- Moves a person from one team to another on a date. The open stint with the old team
-- ends on that date (end_date is exclusive) and a stint with the new team starts the same
-- day, so there is no gap and no overlap.
--
-- Rules that guard the writes: 14 (overlapping stints, at most two two-way players),
-- 15 (the role fits the person), 29 (ordered dates), and 12 (a stint cannot end before a
-- match it covered).
-- Demo failure: the new team already has two two-way players -> R0014; the old stint
-- stays open because nothing the call wrote survives.
--
-- Example:
--   SELECT * FROM transfer_player(p_person_id => 17, p_from_team => 3, p_to_team => 5,
--                                 p_date => '2026-04-01', p_role => 'starter',
--                                 p_join_type => 'signing', p_fee => 250000);
CREATE FUNCTION transfer_player(
    p_person_id integer,
    p_from_team integer,
    p_to_team   integer,
    p_date      date,
    p_role      text    DEFAULT 'starter',
    p_join_type text    DEFAULT 'signing',
    p_fee       numeric DEFAULT NULL)
RETURNS fn_result
LANGUAGE plpgsql AS $$
DECLARE
    v_inputs jsonb := jsonb_build_object(
        'person_id', p_person_id, 'from_team', p_from_team, 'to_team', p_to_team,
        'date', p_date, 'role', p_role, 'join_type', p_join_type, 'fee', p_fee);
    v_stint  roster%ROWTYPE;
    v_status text;
    e_state text; e_msg text; e_detail text; e_hint text; e_ctx text;
BEGIN
    -- 1. Check the inputs
    IF p_person_id IS NULL OR p_from_team IS NULL OR p_to_team IS NULL OR p_date IS NULL THEN
        PERFORM raise_check(3, 'the person, both teams and the date are required');
    END IF;
    IF p_from_team = p_to_team THEN
        PERFORM raise_check(3, 'the old and the new team are the same team');
    END IF;

    -- 2. Lock both teams (lower id first, so two opposite transfers cannot deadlock),
    --    then the person, then the open stint
    PERFORM 1 FROM team WHERE team_id IN (p_from_team, p_to_team) ORDER BY team_id FOR NO KEY UPDATE;
    SELECT status INTO v_status FROM team WHERE team_id = p_to_team;
    IF NOT FOUND THEN
        PERFORM raise_check(2, format('team %s does not exist', p_to_team));
    END IF;
    IF v_status = 'disbanded' THEN
        PERFORM raise_check(1, format('%s has disbanded and cannot sign players', team_label(p_to_team)));
    END IF;

    PERFORM 1 FROM person WHERE person_id = p_person_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        PERFORM raise_check(2, format('person %s does not exist', p_person_id));
    END IF;

    SELECT * INTO v_stint FROM roster
    WHERE person_id = p_person_id AND team_id = p_from_team AND end_date IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM raise_check(2, format('%s has no open stint with %s',
            person_label(p_person_id), team_label(p_from_team)));
    END IF;
    IF p_date <= v_stint.start_date THEN
        PERFORM raise_check(3, format('the transfer date %s must be after the stint with %s began (%s)',
            p_date, team_label(p_from_team), v_stint.start_date));
    END IF;

    -- 3. The writes: close the old stint, open the new one
    UPDATE roster SET end_date = p_date, end_reason = 'transferred'
    WHERE person_id = p_person_id AND team_id = p_from_team AND start_date = v_stint.start_date;

    INSERT INTO roster (person_id, team_id, start_date, roster_role, join_type, transfer_fee)
    VALUES (p_person_id, p_to_team, p_date, p_role, p_join_type, p_fee);

    -- 4. Run the commit-time checks now, inside this call
    PERFORM run_commit_checks();

    RETURN fn_ok(format('%s moved from %s to %s on %s',
                        person_label(p_person_id), team_label(p_from_team), team_label(p_to_team), p_date),
                 jsonb_build_object('person_id', p_person_id, 'from_team', p_from_team,
                                    'to_team', p_to_team, 'date', p_date));
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS e_state = RETURNED_SQLSTATE, e_msg = MESSAGE_TEXT,
        e_detail = PG_EXCEPTION_DETAIL, e_hint = PG_EXCEPTION_HINT, e_ctx = PG_EXCEPTION_CONTEXT;
    RETURN fn_fail('transfer_player', v_inputs, e_state, e_msg, e_detail, e_hint, e_ctx);
END $$;
