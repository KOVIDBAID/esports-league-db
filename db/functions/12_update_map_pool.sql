-- Function 12: update_map_pool                                        (stretch function)
--
-- Publishes a new version of a map pool and moves phases that have not started onto it.
-- The old pool is never edited, so every game already played keeps pointing at the pool
-- it was played under.
--
--   p_entries  [{"map_id": 1, "mode_id": 1}, {"map_id": 2, "mode_id": 2}, ...]
--   p_phases   [{"tournament_id": 12, "phase_number": 1}, ...]   (may be empty)
--
-- Rules that guard the writes: 8 (each moved phase's pool covers its layout's modes),
-- 9 (one game title per pool, the season's), 7 and 10 (no game or veto may lose its pool
-- entry; a phase with games or vetoes is refused before it moves).
-- Demo failure: a phase that already has games -> FN001; no pool is created.
--
-- Example:
--   SELECT * FROM update_map_pool(p_pool_name => 'CDL 2026 pool, Stage 2',
--       p_entries => '[{"map_id": 1, "mode_id": 1}, ...]',
--       p_phases => '[{"tournament_id": 12, "phase_number": 2}]');
CREATE FUNCTION update_map_pool(
    p_pool_name   text,
    p_entries     jsonb,
    p_phases      jsonb DEFAULT '[]',
    p_description text  DEFAULT NULL)
RETURNS fn_result
LANGUAGE plpgsql AS $$
DECLARE
    v_inputs  jsonb := jsonb_build_object('pool_name', p_pool_name, 'entries', p_entries, 'phases', p_phases);
    v_pool_id integer;
    v_phase   record;
    v_moved   integer := 0;
    e_state text; e_msg text; e_detail text; e_hint text; e_ctx text;
BEGIN
    -- 1. Check the inputs
    IF NULLIF(trim(p_pool_name), '') IS NULL THEN
        PERFORM raise_check(3, 'the new pool needs a name');
    END IF;
    IF p_entries IS NULL OR jsonb_typeof(p_entries) <> 'array' OR jsonb_array_length(p_entries) = 0 THEN
        PERFORM raise_check(3, 'p_entries must be a non-empty JSON array of {map_id, mode_id}');
    END IF;
    IF jsonb_typeof(COALESCE(p_phases, '[]')) <> 'array' THEN
        PERFORM raise_check(3, 'p_phases must be a JSON array of {tournament_id, phase_number}');
    END IF;

    -- 3a. The new pool and its entries (rule 9 is checked at the end)
    INSERT INTO map_pool (pool_name, description) VALUES (trim(p_pool_name), p_description)
    RETURNING pool_id INTO v_pool_id;
    INSERT INTO pool_entry (pool_id, map_id, mode_id)
    SELECT v_pool_id, (e ->> 'map_id')::int, (e ->> 'mode_id')::int
    FROM jsonb_array_elements(p_entries) AS e;

    -- 2 and 3b. Each phase: lock its tournament, then the phase, in a fixed order;
    --           refuse a phase that has started; move it to the new pool
    FOR v_phase IN SELECT DISTINCT (p ->> 'tournament_id')::int AS tournament_id,
                                   (p ->> 'phase_number')::int AS phase_number
                   FROM jsonb_array_elements(COALESCE(p_phases, '[]')) AS p
                   ORDER BY 1, 2 LOOP
        PERFORM 1 FROM tournament WHERE event_id = v_phase.tournament_id FOR NO KEY UPDATE;
        PERFORM 1 FROM phase WHERE tournament_id = v_phase.tournament_id
                               AND phase_number = v_phase.phase_number FOR NO KEY UPDATE;
        IF NOT FOUND THEN
            PERFORM raise_check(2, format('tournament %s has no phase %s',
                                          v_phase.tournament_id, v_phase.phase_number));
        END IF;
        IF EXISTS (SELECT 1 FROM match m
                   WHERE m.tournament_id = v_phase.tournament_id AND m.phase_number = v_phase.phase_number
                     AND (EXISTS (SELECT 1 FROM game g WHERE g.match_id = m.match_id)
                          OR EXISTS (SELECT 1 FROM map_veto v WHERE v.match_id = m.match_id))) THEN
            PERFORM raise_check(1, format('phase %s of tournament %s already has games or vetoes',
                                          v_phase.phase_number, v_phase.tournament_id));
        END IF;
        UPDATE phase SET pool_id = v_pool_id
        WHERE tournament_id = v_phase.tournament_id AND phase_number = v_phase.phase_number;
        v_moved := v_moved + 1;
    END LOOP;

    -- 4. Run the commit-time checks now (rules 8 and 9)
    PERFORM run_commit_checks();

    RETURN fn_ok(format('pool "%s" created with %s entries; %s phase(s) moved to it',
                        trim(p_pool_name), jsonb_array_length(p_entries), v_moved),
                 jsonb_build_object('pool_id', v_pool_id, 'phases_moved', v_moved));
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS e_state = RETURNED_SQLSTATE, e_msg = MESSAGE_TEXT,
        e_detail = PG_EXCEPTION_DETAIL, e_hint = PG_EXCEPTION_HINT, e_ctx = PG_EXCEPTION_CONTEXT;
    RETURN fn_fail('update_map_pool', v_inputs, e_state, e_msg, e_detail, e_hint, e_ctx);
END $$;
