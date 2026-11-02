-- Function 4: rebrand_team                                            (demo function)
--
-- Gives a team a new identity from a date. The current identity ends on that date
-- (valid_to is exclusive) and the new one starts the same day. The team itself, its
-- results and its stints are untouched, so its history reads under the old name up to
-- the date and under the new name after it.
--
-- abbreviation, city and owner keep their current values when left NULL.
--
-- Rules that guard the writes: 18 (identities never overlap), 29 (ordered dates),
-- T1 (the team keeps an identity).
-- Demo failure: a start date on or before the day the current identity began -> FN003.
--
-- Example:
--   SELECT * FROM rebrand_team(p_team_id => 4, p_from => '2026-05-01',
--                              p_name => 'Vegas Falcons', p_abbreviation => 'LVF',
--                              p_city => 'Las Vegas');
CREATE FUNCTION rebrand_team(
    p_team_id      integer,
    p_from         date,
    p_name         text,
    p_abbreviation text    DEFAULT NULL,
    p_city         text    DEFAULT NULL,
    p_org_id       integer DEFAULT NULL)
RETURNS fn_result
LANGUAGE plpgsql AS $$
DECLARE
    v_inputs  jsonb := jsonb_build_object(
        'team_id', p_team_id, 'from', p_from, 'name', p_name,
        'abbreviation', p_abbreviation, 'city', p_city, 'org_id', p_org_id);
    v_status  text;
    v_current team_identity%ROWTYPE;
    e_state text; e_msg text; e_detail text; e_hint text; e_ctx text;
BEGIN
    -- 1. Check the inputs
    IF p_team_id IS NULL OR p_from IS NULL OR NULLIF(trim(p_name), '') IS NULL THEN
        PERFORM raise_check(3, 'the team, the date and the new name are required');
    END IF;

    -- 2. Lock the team, then its current identity
    SELECT status INTO v_status FROM team WHERE team_id = p_team_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        PERFORM raise_check(2, format('team %s does not exist', p_team_id));
    END IF;
    IF v_status = 'disbanded' THEN
        PERFORM raise_check(1, format('%s has disbanded', team_label(p_team_id)));
    END IF;

    SELECT * INTO v_current FROM team_identity
    WHERE team_id = p_team_id AND valid_to IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM raise_check(2, format('team %s has no current identity', p_team_id));
    END IF;
    IF p_from <= v_current.valid_from THEN
        PERFORM raise_check(3, format('the new identity must start after "%s" began on %s',
            v_current.team_name, v_current.valid_from));
    END IF;

    -- 3. The writes: close the current identity, open the new one
    UPDATE team_identity SET valid_to = p_from
    WHERE team_id = p_team_id AND valid_from = v_current.valid_from;

    INSERT INTO team_identity (team_id, valid_from, team_name, abbreviation, home_city, org_id)
    VALUES (p_team_id, p_from, trim(p_name),
            COALESCE(p_abbreviation, v_current.abbreviation),
            COALESCE(p_city, v_current.home_city),
            COALESCE(p_org_id, v_current.org_id));

    -- 4. Run the commit-time checks now
    PERFORM run_commit_checks();

    RETURN fn_ok(format('"%s" is "%s" from %s', v_current.team_name, trim(p_name), p_from),
                 jsonb_build_object('team_id', p_team_id, 'valid_from', p_from,
                                    'old_name', v_current.team_name, 'new_name', trim(p_name)));
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS e_state = RETURNED_SQLSTATE, e_msg = MESSAGE_TEXT,
        e_detail = PG_EXCEPTION_DETAIL, e_hint = PG_EXCEPTION_HINT, e_ctx = PG_EXCEPTION_CONTEXT;
    RETURN fn_fail('rebrand_team', v_inputs, e_state, e_msg, e_detail, e_hint, e_ctx);
END $$;
