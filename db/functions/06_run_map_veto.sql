-- Function 6: run_map_veto                                            (backup function)
--
-- Records a match's pick-and-ban sequence and creates its games before play starts.
--
--   p_vetoes  JSON array in veto order:
--             [{"team_id": 7, "action": "ban",  "map_id": 2, "mode_id": 1},
--              {"team_id": 8, "action": "pick", "map_id": 3, "mode_id": 1}, ...]
--
-- Games: the phase's layout gives the mode of each game number. A slot takes the next
-- unused pick of its mode, in veto order. A slot with no pick left takes the decider: the
-- one map of that mode in the phase's pool that was neither banned nor picked. Every pick
-- must land in a game. The games are created as scheduled; record_series_result fills them.
--
-- Rules that guard the writes: 10 (picks and bans from the pool, once each, by the two
-- teams), 7 (each game's map and mode match the pool and the slot), 8 (the layout covers
-- the series).
-- Demo failure: a ban on a map outside the phase's pool -> R0010; no veto or game is saved.
--
-- Example (the CDL 2026 Bo5 veto: HP and S&D picked, Overload decided by two bans):
--   SELECT * FROM run_map_veto(p_match_id => 40, p_vetoes => '[
--     {"team_id": 7, "action": "ban",  "map_id": 2, "mode_id": 1}, ...]');
CREATE FUNCTION run_map_veto(
    p_match_id  integer,
    p_vetoes    jsonb,
    p_vetoed_at timestamptz DEFAULT now())   -- given only when loading history
RETURNS fn_result
LANGUAGE plpgsql AS $$
DECLARE
    v_inputs jsonb := jsonb_build_object('match_id', p_match_id, 'vetoes', p_vetoes);
    m        match%ROWTYPE;
    v_pool   integer;
    v_layout integer;
    v_slot   record;
    v_map    integer;
    v_left   integer[];
    v_games  jsonb := '[]';
    v_unused text;
    e_state text; e_msg text; e_detail text; e_hint text; e_ctx text;
BEGIN
    -- 1. Check the shape of the input
    IF p_vetoes IS NULL OR jsonb_typeof(p_vetoes) <> 'array' OR jsonb_array_length(p_vetoes) = 0 THEN
        PERFORM raise_check(3, 'p_vetoes must be a non-empty JSON array of picks and bans in order');
    END IF;

    -- 2. Lock the match and check its state
    SELECT * INTO m FROM match WHERE match_id = p_match_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        PERFORM raise_check(2, format('match %s does not exist', p_match_id));
    END IF;
    IF m.status <> 'scheduled' OR EXISTS (SELECT 1 FROM map_veto WHERE match_id = p_match_id)
       OR EXISTS (SELECT 1 FROM game WHERE match_id = p_match_id) THEN
        PERFORM raise_check(1, format('match %s already has its veto or games', p_match_id));
    END IF;
    IF (SELECT count(*) FROM competes_in WHERE match_id = p_match_id) <> 2 THEN
        PERFORM raise_check(1, format('match %s does not have both teams yet', p_match_id));
    END IF;
    SELECT pool_id, layout_id INTO v_pool, v_layout FROM phase
    WHERE tournament_id = m.tournament_id AND phase_number = m.phase_number;

    -- 3a. The picks and bans (rule 10 is checked as each row goes in)
    INSERT INTO map_veto (match_id, veto_order, action, vetoed_at, team_id, map_id, mode_id)
    SELECT p_match_id, v.ord, v.item ->> 'action', COALESCE(p_vetoed_at, now()),
           (v.item ->> 'team_id')::int, (v.item ->> 'map_id')::int, (v.item ->> 'mode_id')::int
    FROM jsonb_array_elements(p_vetoes) WITH ORDINALITY AS v(item, ord);

    -- 3b. One game per slot of the layout: the next pick of the slot's mode, or the decider
    FOR v_slot IN SELECT game_number, mode_id FROM series_slot
                  WHERE layout_id = v_layout AND best_of = m.best_of ORDER BY game_number LOOP
        SELECT v.map_id INTO v_map
        FROM map_veto v
        WHERE v.match_id = p_match_id AND v.action = 'pick' AND v.mode_id = v_slot.mode_id
          AND NOT EXISTS (SELECT 1 FROM game g WHERE g.match_id = p_match_id
                          AND g.map_id = v.map_id AND g.mode_id = v.mode_id)
        ORDER BY v.veto_order
        LIMIT 1;
        IF NOT FOUND THEN
            SELECT array_agg(pe.map_id ORDER BY pe.map_id) INTO v_left
            FROM pool_entry pe
            WHERE pe.pool_id = v_pool AND pe.mode_id = v_slot.mode_id
              AND NOT EXISTS (SELECT 1 FROM map_veto v WHERE v.match_id = p_match_id
                              AND v.map_id = pe.map_id AND v.mode_id = pe.mode_id);
            IF COALESCE(cardinality(v_left), 0) <> 1 THEN
                PERFORM raise_check(3, format(
                    'game %s (%s) has no pick, and %s %s maps are left, so there is no single decider',
                    v_slot.game_number, mode_label(v_slot.mode_id), COALESCE(cardinality(v_left), 0),
                    mode_label(v_slot.mode_id)));
            END IF;
            v_map := v_left[1];
        END IF;

        INSERT INTO game (match_id, game_number, status, map_id, mode_id)
        VALUES (p_match_id, v_slot.game_number, 'scheduled', v_map, v_slot.mode_id);
        v_games := v_games || jsonb_build_object('game_number', v_slot.game_number,
                                                 'map', map_mode_label(v_map, v_slot.mode_id));
    END LOOP;

    -- Every pick must have become a game
    SELECT string_agg(map_mode_label(v.map_id, v.mode_id), ', ') INTO v_unused
    FROM map_veto v
    WHERE v.match_id = p_match_id AND v.action = 'pick'
      AND NOT EXISTS (SELECT 1 FROM game g WHERE g.match_id = p_match_id
                      AND g.map_id = v.map_id AND g.mode_id = v.mode_id);
    IF v_unused IS NOT NULL THEN
        PERFORM raise_check(3, format('more picks than games for their mode: %s', v_unused));
    END IF;

    -- 4. Run the commit-time checks now
    PERFORM run_commit_checks();

    RETURN fn_ok(format('match %s: %s picks and bans, %s games set', p_match_id,
                        jsonb_array_length(p_vetoes), jsonb_array_length(v_games)),
                 jsonb_build_object('match_id', p_match_id, 'games', v_games));
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS e_state = RETURNED_SQLSTATE, e_msg = MESSAGE_TEXT,
        e_detail = PG_EXCEPTION_DETAIL, e_hint = PG_EXCEPTION_HINT, e_ctx = PG_EXCEPTION_CONTEXT;
    RETURN fn_fail('run_map_veto', v_inputs, e_state, e_msg, e_detail, e_hint, e_ctx);
END $$;
