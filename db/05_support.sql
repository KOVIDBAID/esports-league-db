-- 05_support.sql
-- Support objects outside the esports domain (logged in docs/deviation_log.md).
-- They reference no domain table, so the ER design is unchanged.

------------------------------------------------------------------------------
-- fn_result: what every prototype function returns
------------------------------------------------------------------------------
--   ok       true on success, false on failure
--   code     '00000' on success, otherwise the SQLSTATE (R00nn = rule nn, F0nnn = function check)
--   message  a readable sentence for the app and the logs
--   data     JSON with the ids the call created (on success) or the error_log id (on failure)
CREATE TYPE fn_result AS (
    ok       boolean,
    code     text,
    message  text,
    data     jsonb
);

------------------------------------------------------------------------------
-- error_log: one row per failed function call
------------------------------------------------------------------------------
CREATE TABLE error_log (
    log_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    logged_at      timestamptz NOT NULL DEFAULT now(),
    function_name  text NOT NULL,
    inputs         jsonb,
    sqlstate       text NOT NULL,
    rule_no        smallint,          -- filled when sqlstate is R00nn
    message        text,
    detail         text,
    hint           text,
    context        text,              -- PostgreSQL's trace: which line of which function failed
    db_user        text NOT NULL DEFAULT current_user
);

CREATE INDEX error_log_time_idx ON error_log (logged_at DESC);

------------------------------------------------------------------------------
-- raise_rule: raise a business-rule error with a code that names the rule
------------------------------------------------------------------------------
-- raise_rule(12, 'player has no stint with this team on the match date')
--   -> ERROR with SQLSTATE R0012 and message 'R0012: player has no stint ...'
CREATE FUNCTION raise_rule(p_rule integer, p_message text, p_detail text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_code text := 'R' || lpad(p_rule::text, 4, '0');
BEGIN
    IF p_detail IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = v_code, MESSAGE = v_code || ': ' || p_message;
    ELSE
        RAISE EXCEPTION USING ERRCODE = v_code, MESSAGE = v_code || ': ' || p_message, DETAIL = p_detail;
    END IF;
END $$;

------------------------------------------------------------------------------
-- raise_total: raise a total-participation error
------------------------------------------------------------------------------
-- The report's four participation constraints (Section 4.5) are numbered T1 to T4 in
-- docs/rules.md: every team has an identity, every event a host, every event is a league
-- or a tournament, every stats row has its mode details.
-- raise_total(1, 'team 7 has no team identity') -> SQLSTATE T0001, message 'T0001: ...'
CREATE FUNCTION raise_total(p_constraint integer, p_message text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_code text := 'T' || lpad(p_constraint::text, 4, '0');
BEGIN
    RAISE EXCEPTION USING ERRCODE = v_code, MESSAGE = v_code || ': ' || p_message;
END $$;

------------------------------------------------------------------------------
-- fn_ok / fn_fail: build results; fn_fail also writes the error_log row
------------------------------------------------------------------------------
CREATE FUNCTION fn_ok(p_message text, p_data jsonb DEFAULT NULL)
RETURNS fn_result
LANGUAGE sql IMMUTABLE AS $$
    SELECT ROW(true, '00000', p_message, p_data)::fn_result;
$$;

-- Called from a function's EXCEPTION handler, after PostgreSQL has rolled back the
-- failed work, so the log row is the only thing the failed call leaves behind.
CREATE FUNCTION fn_fail(
    p_function text, p_inputs jsonb, p_sqlstate text, p_message text,
    p_detail text DEFAULT NULL, p_hint text DEFAULT NULL, p_context text DEFAULT NULL)
RETURNS fn_result
LANGUAGE plpgsql AS $$
DECLARE
    v_log_id bigint;
BEGIN
    INSERT INTO error_log (function_name, inputs, sqlstate, rule_no, message, detail, hint, context)
    VALUES (p_function, p_inputs, p_sqlstate,
            CASE WHEN p_sqlstate ~ '^R00[0-9]{2}$' THEN substr(p_sqlstate, 4)::smallint END,
            p_message, NULLIF(p_detail, ''), NULLIF(p_hint, ''), NULLIF(p_context, ''))
    RETURNING log_id INTO v_log_id;
    RETURN ROW(false, p_sqlstate, p_message, jsonb_build_object('log_id', v_log_id))::fn_result;
END $$;
