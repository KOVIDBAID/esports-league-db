-- Function 9: create_tournament                                       (backup function)
--
-- Creates a tournament in one call: the event, its host, the tournament row, its phases
-- and its prize bands.
--
--   p_stage        optional {"league_id": 1, "season_year": 2026, "stage_number": 1}
--   p_phases       [{"phase_name": "Playoffs", "default_best_of": 5, "format_id": 2,
--                    "pool_id": 1, "layout_id": 1, "points_per_win": 0,
--                    "start_date": "2026-03-01", "end_date": "2026-03-02"}, ...]
--                  numbered 1, 2, ... in the order given
--   p_prize_bands  [{"placement_from": 1, "placement_to": 1, "prize_amount": 200000,
--                    "points": 100}, ...]
--
-- Rules that guard the writes: 24 (bands never overlap), 25 (dates nest in the stage),
-- 29 (ordered dates), 8 and 9 (each phase's pool and layout fit), T2 and T3 (the event
-- has a host and is a tournament).
-- Demo failure: overlapping prize bands -> 23P01; no event, host or tournament is left.
--
-- Example:
--   SELECT * FROM create_tournament(p_event_name => 'CDL Major I', p_host_org_id => 1,
--       p_tournament_type => 'major', p_team_size => 4, p_max_teams => 8,
--       p_start_date => '2026-03-05', p_end_date => '2026-03-08',
--       p_stage => '{"league_id": 1, "season_year": 2026, "stage_number": 1}',
--       p_phases => '[{"phase_name": "Playoffs", "default_best_of": 5,
--                      "format_id": 2, "pool_id": 1, "layout_id": 1}]',
--       p_prize_bands => '[{"placement_from": 1, "placement_to": 1, "prize_amount": 200000}]');
CREATE FUNCTION create_tournament(
    p_event_name      text,
    p_host_org_id     integer,
    p_tournament_type text,
    p_team_size       integer,
    p_start_date      date    DEFAULT NULL,
    p_end_date        date    DEFAULT NULL,
    p_max_teams       integer DEFAULT NULL,
    p_tier            text    DEFAULT NULL,
    p_stage           jsonb   DEFAULT NULL,
    p_venue_id        integer DEFAULT NULL,
    p_region_id       integer DEFAULT NULL,
    p_phases          jsonb   DEFAULT '[]',
    p_prize_bands     jsonb   DEFAULT '[]')
RETURNS fn_result
LANGUAGE plpgsql AS $$
DECLARE
    v_inputs   jsonb := jsonb_build_object(
        'event_name', p_event_name, 'host_org_id', p_host_org_id, 'tournament_type', p_tournament_type,
        'team_size', p_team_size, 'start_date', p_start_date, 'end_date', p_end_date,
        'max_teams', p_max_teams, 'stage', p_stage, 'phases', p_phases, 'prize_bands', p_prize_bands);
    v_event_id integer;
    e_state text; e_msg text; e_detail text; e_hint text; e_ctx text;
BEGIN
    -- 1. Check the inputs
    IF NULLIF(trim(p_event_name), '') IS NULL OR p_host_org_id IS NULL
       OR p_tournament_type IS NULL OR p_team_size IS NULL THEN
        PERFORM raise_check(3, 'event name, host organization, tournament type and team size are required');
    END IF;
    IF jsonb_typeof(COALESCE(p_phases, '[]')) <> 'array' OR jsonb_typeof(COALESCE(p_prize_bands, '[]')) <> 'array' THEN
        PERFORM raise_check(3, 'p_phases and p_prize_bands must be JSON arrays');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM organization WHERE org_id = p_host_org_id) THEN
        PERFORM raise_check(2, format('organization %s does not exist', p_host_org_id));
    END IF;

    -- 2. Nothing to lock: every row is new. 3. The writes:
    INSERT INTO event (event_name, tier) VALUES (trim(p_event_name), p_tier)
    RETURNING event_id INTO v_event_id;

    INSERT INTO hosted_by (event_id, org_id, host_role) VALUES (v_event_id, p_host_org_id, 'organizer');

    INSERT INTO tournament (event_id, tournament_type, start_date, end_date, max_teams, team_size,
                            league_id, season_year, stage_number, venue_id, region_id)
    VALUES (v_event_id, p_tournament_type, p_start_date, p_end_date, p_max_teams, p_team_size,
            (p_stage ->> 'league_id')::int, (p_stage ->> 'season_year')::smallint,
            (p_stage ->> 'stage_number')::smallint, p_venue_id, p_region_id);

    INSERT INTO phase (tournament_id, phase_number, phase_name, default_best_of, points_per_win,
                       start_date, end_date, format_id, pool_id, layout_id)
    SELECT v_event_id, ph.ord, ph.item ->> 'phase_name', (ph.item ->> 'default_best_of')::smallint,
           COALESCE((ph.item ->> 'points_per_win')::smallint, 0),
           (ph.item ->> 'start_date')::date, (ph.item ->> 'end_date')::date,
           (ph.item ->> 'format_id')::int, (ph.item ->> 'pool_id')::int, (ph.item ->> 'layout_id')::int
    FROM jsonb_array_elements(COALESCE(p_phases, '[]')) WITH ORDINALITY AS ph(item, ord);

    INSERT INTO placement_reward (tournament_id, placement_from, placement_to, points, prize_amount)
    SELECT v_event_id, (b ->> 'placement_from')::smallint, (b ->> 'placement_to')::smallint,
           COALESCE((b ->> 'points')::int, 0), COALESCE((b ->> 'prize_amount')::numeric, 0)
    FROM jsonb_array_elements(COALESCE(p_prize_bands, '[]')) AS b;

    -- 4. Run the commit-time checks now (rules 8, 9, 25 and T2, T3)
    PERFORM run_commit_checks();

    RETURN fn_ok(format('"%s" created with %s phase(s) and %s prize band(s)', trim(p_event_name),
                        jsonb_array_length(COALESCE(p_phases, '[]')),
                        jsonb_array_length(COALESCE(p_prize_bands, '[]'))),
                 jsonb_build_object('tournament_id', v_event_id,
                                    'prize_pool', (SELECT prize_pool FROM v_tournament_prize_pool
                                                   WHERE tournament_id = v_event_id)));
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS e_state = RETURNED_SQLSTATE, e_msg = MESSAGE_TEXT,
        e_detail = PG_EXCEPTION_DETAIL, e_hint = PG_EXCEPTION_HINT, e_ctx = PG_EXCEPTION_CONTEXT;
    RETURN fn_fail('create_tournament', v_inputs, e_state, e_msg, e_detail, e_hint, e_ctx);
END $$;
