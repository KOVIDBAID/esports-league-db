-- Function 8: sign_new_player                                         (backup function)
--
-- Adds a new player in one call: the person, their phone numbers, the player profile,
-- and, when a team is given, their first stint with it.
--
-- Rules that guard the writes: the UNIQUE keys on activision_id, faceit_id and email,
-- 14 (overlapping stints), 15 (the role fits the person).
-- Demo failure: a duplicate Activision ID -> 23505; the person row inserted just before
-- it is rolled back too, so no half-created player is left behind.
--
-- Example:
--   SELECT * FROM sign_new_player(p_first_name => 'Anthony', p_last_name => 'Cuevas-Castro',
--                                 p_gamertag => 'Shotzzy', p_activision_id => 'Shotzzy#1234',
--                                 p_primary_role => 'SMG', p_region_id => 1,
--                                 p_phones => ARRAY['+1 555 0100'],
--                                 p_team_id => 1, p_start_date => '2026-01-05');
CREATE FUNCTION sign_new_player(
    p_first_name    text,
    p_last_name     text,
    p_gamertag      text,
    p_activision_id text,
    p_primary_role  text,
    p_date_of_birth date    DEFAULT NULL,
    p_nationality   text    DEFAULT NULL,
    p_email         text    DEFAULT NULL,
    p_faceit_id     text    DEFAULT NULL,
    p_region_id     integer DEFAULT NULL,
    p_phones        text[]  DEFAULT '{}',
    p_team_id       integer DEFAULT NULL,
    p_role          text    DEFAULT 'starter',
    p_start_date    date    DEFAULT current_date,
    p_join_type     text    DEFAULT 'signing',
    p_fee           numeric DEFAULT NULL)
RETURNS fn_result
LANGUAGE plpgsql AS $$
DECLARE
    v_inputs    jsonb := jsonb_build_object(
        'gamertag', p_gamertag, 'activision_id', p_activision_id, 'faceit_id', p_faceit_id,
        'primary_role', p_primary_role, 'region_id', p_region_id, 'team_id', p_team_id,
        'role', p_role, 'start_date', p_start_date);
    v_status    text;
    v_person_id integer;
    e_state text; e_msg text; e_detail text; e_hint text; e_ctx text;
BEGIN
    -- 1. Check the inputs
    IF NULLIF(trim(p_first_name), '') IS NULL OR NULLIF(trim(p_last_name), '') IS NULL
       OR NULLIF(trim(p_activision_id), '') IS NULL THEN
        PERFORM raise_check(3, 'first name, last name and Activision ID are required');
    END IF;

    -- 2. Lock the team the player joins
    IF p_team_id IS NOT NULL THEN
        SELECT status INTO v_status FROM team WHERE team_id = p_team_id FOR NO KEY UPDATE;
        IF NOT FOUND THEN
            PERFORM raise_check(2, format('team %s does not exist', p_team_id));
        END IF;
        IF v_status = 'disbanded' THEN
            PERFORM raise_check(1, format('%s has disbanded and cannot sign players', team_label(p_team_id)));
        END IF;
    END IF;

    -- 3. The writes
    INSERT INTO person (first_name, last_name, gamertag, date_of_birth, nationality, email)
    VALUES (trim(p_first_name), trim(p_last_name), p_gamertag, p_date_of_birth, p_nationality, p_email)
    RETURNING person_id INTO v_person_id;

    INSERT INTO person_phone (person_id, phone_number)
    SELECT DISTINCT v_person_id, trim(phone)
    FROM unnest(COALESCE(p_phones, '{}')) AS phone
    WHERE NULLIF(trim(phone), '') IS NOT NULL;

    INSERT INTO player (person_id, activision_id, faceit_id, primary_role, region_id)
    VALUES (v_person_id, trim(p_activision_id), p_faceit_id, p_primary_role, p_region_id);

    IF p_team_id IS NOT NULL THEN
        INSERT INTO roster (person_id, team_id, start_date, roster_role, join_type, transfer_fee)
        VALUES (v_person_id, p_team_id, p_start_date, p_role, p_join_type, p_fee);
    END IF;

    -- 4. Run the commit-time checks now
    PERFORM run_commit_checks();

    RETURN fn_ok(format('%s signed%s', person_label(v_person_id),
                        CASE WHEN p_team_id IS NULL THEN ' as a free agent'
                             ELSE format(' with %s from %s', team_label(p_team_id), p_start_date) END),
                 jsonb_build_object('person_id', v_person_id, 'team_id', p_team_id));
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS e_state = RETURNED_SQLSTATE, e_msg = MESSAGE_TEXT,
        e_detail = PG_EXCEPTION_DETAIL, e_hint = PG_EXCEPTION_HINT, e_ctx = PG_EXCEPTION_CONTEXT;
    RETURN fn_fail('sign_new_player', v_inputs, e_state, e_msg, e_detail, e_hint, e_ctx);
END $$;
