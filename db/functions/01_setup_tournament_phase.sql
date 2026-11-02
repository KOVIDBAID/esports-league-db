-- Function 1: setup_tournament_phase                                  (demo function)
--
-- Builds a phase's whole bracket in one call: enters the teams in the tournament, creates
-- every match with its winner_to and loser_to links, and places the first-round teams.
--
--   p_teams  JSON array of team ids in seed order: [seed 1, seed 2, ...]
--
-- Formats, chosen by the phase's format:
--   Single elimination   2, 4, 8, 16 ... teams; standard seeding (1 v 8, 4 v 5, 2 v 7, 3 v 6)
--   Double elimination   4, 8, 16 ... teams; upper bracket, lower bracket, grand final
--   Round robin          any number of teams; every pair plays once
-- Brackets with byes (team counts that are not a power of two) are not built.
--
-- Rules that guard the writes: 3 (links stay in the tournament, one feed per slot),
-- 8 (the layout covers the best_of), 26 (season registration), 27 (max_teams), 2.
-- Demo failure: a team not registered for the season -> R0026; no match is created.
--
-- Example:
--   SELECT * FROM setup_tournament_phase(p_tournament_id => 12, p_phase_number => 1,
--                                        p_teams => '[3, 7, 1, 5, 2, 8, 4, 6]');

-- Internal: insert one match of the phase and return its id.
CREATE FUNCTION add_bracket_match(p_tournament_id integer, p_phase_number integer,
                                  p_match_number integer, p_round_name text, p_side text,
                                  p_best_of smallint) RETURNS integer
LANGUAGE sql AS $$
    INSERT INTO match (tournament_id, phase_number, match_number, round_name, bracket_side, best_of)
    VALUES (p_tournament_id, p_phase_number, p_match_number, p_round_name, p_side, p_best_of)
    RETURNING match_id
$$;

-- Internal: point a match's winner or loser at a slot of another match.
CREATE FUNCTION link_bracket_match(p_ids jsonb, p_from text, p_kind text, p_to text, p_slot integer)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_kind = 'winner' THEN
        UPDATE match SET winner_to_match_id = (p_ids ->> p_to)::int, winner_to_slot = p_slot
        WHERE match_id = (p_ids ->> p_from)::int;
    ELSE
        UPDATE match SET loser_to_match_id = (p_ids ->> p_to)::int, loser_to_slot = p_slot
        WHERE match_id = (p_ids ->> p_from)::int;
    END IF;
END $$;

CREATE FUNCTION setup_tournament_phase(
    p_tournament_id integer,
    p_phase_number  integer,
    p_teams         jsonb)
RETURNS fn_result
LANGUAGE plpgsql AS $$
DECLARE
    v_inputs  jsonb := jsonb_build_object('tournament_id', p_tournament_id,
                                          'phase_number', p_phase_number, 'teams', p_teams);
    v_phase   phase%ROWTYPE;
    v_format  text;
    v_double  boolean;
    v_teams   integer[];
    v_n       integer;
    v_k       integer := 0;     -- number of upper-bracket rounds: 2^k = n
    v_order   integer[] := ARRAY[1, 2];
    v_grow    integer[];
    v_ids     jsonb := '{}';    -- 'U2-1' (upper round 2, match 1), 'L3-1', 'GF' -> match_id
    v_number  integer := 0;
    v_count   integer;
    v_lower   integer;          -- number of lower-bracket rounds
    s integer; r integer; i integer; j integer;
    e_state text; e_msg text; e_detail text; e_hint text; e_ctx text;
BEGIN
    -- 1. Check the inputs
    IF p_teams IS NULL OR jsonb_typeof(p_teams) <> 'array' THEN
        PERFORM raise_check(3, 'p_teams must be a JSON array of team ids in seed order');
    END IF;
    SELECT array_agg(t.value::int ORDER BY t.ord) INTO v_teams
    FROM jsonb_array_elements_text(p_teams) WITH ORDINALITY AS t(value, ord);
    v_n := COALESCE(array_length(v_teams, 1), 0);
    IF v_n < 2 THEN
        PERFORM raise_check(3, 'a phase needs at least two teams');
    END IF;
    IF (SELECT count(DISTINCT t) FROM unnest(v_teams) AS t) <> v_n THEN
        PERFORM raise_check(3, 'a team is listed twice');
    END IF;

    -- 2. Lock the tournament, then the phase
    PERFORM 1 FROM tournament WHERE event_id = p_tournament_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        PERFORM raise_check(2, format('tournament %s does not exist', p_tournament_id));
    END IF;
    SELECT * INTO v_phase FROM phase
    WHERE tournament_id = p_tournament_id AND phase_number = p_phase_number
    FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        PERFORM raise_check(2, format('tournament %s has no phase %s', p_tournament_id, p_phase_number));
    END IF;
    IF EXISTS (SELECT 1 FROM match WHERE tournament_id = p_tournament_id AND phase_number = p_phase_number) THEN
        PERFORM raise_check(1, format('phase %s "%s" already has its matches', p_phase_number, v_phase.phase_name));
    END IF;

    SELECT lower(format_name) INTO v_format FROM format WHERE format_id = v_phase.format_id;
    IF v_format NOT IN ('single elimination', 'double elimination', 'round robin') THEN
        PERFORM raise_check(3, format('cannot build a "%s" phase; the formats built are single elimination, double elimination and round robin', v_format));
    END IF;
    v_double := v_format = 'double elimination';
    IF v_format <> 'round robin' THEN
        WHILE (1 << v_k) < v_n LOOP
            v_k := v_k + 1;
        END LOOP;
        IF (1 << v_k) <> v_n THEN
            PERFORM raise_check(3, format('an elimination bracket needs 2, 4, 8 or 16 teams, not %s (byes are not built)', v_n));
        END IF;
        IF v_double AND v_n < 4 THEN
            PERFORM raise_check(3, 'a double elimination bracket needs at least 4 teams');
        END IF;
    END IF;

    -- 3a. Enter the teams in the tournament (rules 26 and 27 are checked per row).
    --     A team already entered (from an earlier phase) keeps its tournament seed.
    INSERT INTO participates_in (team_id, tournament_id, seed)
    SELECT t.team_id, p_tournament_id, t.ord
    FROM unnest(v_teams) WITH ORDINALITY AS t(team_id, ord)
    ON CONFLICT (team_id, tournament_id) DO NOTHING;

    -- 3b. Round robin: every pair plays once
    IF v_format = 'round robin' THEN
        FOR i IN 1 .. v_n - 1 LOOP
            FOR j IN i + 1 .. v_n LOOP
                v_number := v_number + 1;
                s := add_bracket_match(p_tournament_id, p_phase_number, v_number, 'Round robin', NULL,
                                       v_phase.default_best_of);
                INSERT INTO competes_in (match_id, team_id, slot)
                VALUES (s, v_teams[i], 1), (s, v_teams[j], 2);
            END LOOP;
        END LOOP;

        PERFORM run_commit_checks();
        RETURN fn_ok(format('phase %s "%s": %s round-robin matches for %s teams',
                            p_phase_number, v_phase.phase_name, v_number, v_n),
                     jsonb_build_object('tournament_id', p_tournament_id, 'phase_number', p_phase_number,
                                        'format', v_format, 'matches', v_number));
    END IF;

    -- 3c. Elimination: create every match, upper bracket first, then lower, then the final
    FOR r IN 1 .. v_k LOOP
        FOR i IN 1 .. (v_n >> r) LOOP
            v_number := v_number + 1;
            v_ids := v_ids || jsonb_build_object(format('U%s-%s', r, i), add_bracket_match(
                p_tournament_id, p_phase_number, v_number,
                CASE WHEN NOT v_double AND r = v_k THEN 'Final'
                     WHEN NOT v_double THEN format('Round %s', r)
                     WHEN r = v_k THEN 'Upper final'
                     ELSE format('Upper round %s', r) END,
                CASE WHEN NOT v_double AND r = v_k THEN 'grand final' ELSE 'winners' END,
                v_phase.default_best_of));
        END LOOP;
    END LOOP;

    IF v_double THEN
        v_lower := 2 * (v_k - 1);
        FOR r IN 1 .. v_lower LOOP
            FOR i IN 1 .. (v_n >> ((r + 1) / 2 + 1)) LOOP
                v_number := v_number + 1;
                v_ids := v_ids || jsonb_build_object(format('L%s-%s', r, i), add_bracket_match(
                    p_tournament_id, p_phase_number, v_number,
                    CASE WHEN r = v_lower THEN 'Lower final' ELSE format('Lower round %s', r) END,
                    'elimination', v_phase.default_best_of));
            END LOOP;
        END LOOP;
        v_number := v_number + 1;
        v_ids := v_ids || jsonb_build_object('GF', add_bracket_match(
            p_tournament_id, p_phase_number, v_number, 'Grand final', 'grand final', v_phase.default_best_of));
    END IF;

    -- 3d. Links. Upper round r: match i's winner goes to round r+1, match ceil(i/2),
    --     slot 1 for odd i and 2 for even i.
    FOR r IN 1 .. v_k - 1 LOOP
        FOR i IN 1 .. (v_n >> r) LOOP
            PERFORM link_bracket_match(v_ids, format('U%s-%s', r, i), 'winner',
                                       format('U%s-%s', r + 1, (i + 1) / 2), 2 - i % 2);
        END LOOP;
    END LOOP;

    IF v_double THEN
        -- Upper round 1 losers pair up in lower round 1.
        FOR i IN 1 .. (v_n >> 1) LOOP
            PERFORM link_bracket_match(v_ids, format('U1-%s', i), 'loser',
                                       format('L1-%s', (i + 1) / 2), 2 - i % 2);
        END LOOP;
        -- Losers of upper round r >= 2 drop into slot 2 of lower round 2(r-1), in reverse
        -- order, so a team is unlikely to meet the team it just played.
        FOR r IN 2 .. v_k LOOP
            v_count := v_n >> r;
            FOR i IN 1 .. v_count LOOP
                PERFORM link_bracket_match(v_ids, format('U%s-%s', r, i), 'loser',
                                           format('L%s-%s', 2 * (r - 1), v_count + 1 - i), 2);
            END LOOP;
        END LOOP;
        -- Lower bracket: odd rounds feed slot 1 of the drop-in round after them; even rounds
        -- pair up into the next odd round; the lower final feeds the grand final.
        FOR r IN 1 .. v_lower LOOP
            FOR i IN 1 .. (v_n >> ((r + 1) / 2 + 1)) LOOP
                IF r = v_lower THEN
                    PERFORM link_bracket_match(v_ids, format('L%s-%s', r, i), 'winner', 'GF', 2);
                ELSIF r % 2 = 1 THEN
                    PERFORM link_bracket_match(v_ids, format('L%s-%s', r, i), 'winner',
                                               format('L%s-%s', r + 1, i), 1);
                ELSE
                    PERFORM link_bracket_match(v_ids, format('L%s-%s', r, i), 'winner',
                                               format('L%s-%s', r + 1, (i + 1) / 2), 2 - i % 2);
                END IF;
            END LOOP;
        END LOOP;
        PERFORM link_bracket_match(v_ids, format('U%s-1', v_k), 'winner', 'GF', 1);
    END IF;

    -- 3e. Seed the first round. The bracket order puts seeds 1 and 2 in opposite halves:
    --     [1, 2] -> [1, 4, 2, 3] -> [1, 8, 4, 5, 2, 7, 3, 6] -> ...
    WHILE array_length(v_order, 1) < v_n LOOP
        v_grow := '{}';
        FOREACH s IN ARRAY v_order LOOP
            v_grow := v_grow || s || (2 * array_length(v_order, 1) + 1 - s);
        END LOOP;
        v_order := v_grow;
    END LOOP;
    FOR i IN 1 .. (v_n >> 1) LOOP
        INSERT INTO competes_in (match_id, team_id, slot)
        VALUES ((v_ids ->> format('U1-%s', i))::int, v_teams[v_order[2 * i - 1]], 1),
               ((v_ids ->> format('U1-%s', i))::int, v_teams[v_order[2 * i]], 2);
    END LOOP;

    -- 4. Run the commit-time checks now
    PERFORM run_commit_checks();

    RETURN fn_ok(format('phase %s "%s": %s %s bracket for %s teams, %s matches',
                        p_phase_number, v_phase.phase_name,
                        CASE WHEN v_double THEN 'double' ELSE 'single' END, 'elimination', v_n, v_number),
                 jsonb_build_object('tournament_id', p_tournament_id, 'phase_number', p_phase_number,
                                    'format', v_format, 'matches', v_number, 'match_ids', v_ids));
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS e_state = RETURNED_SQLSTATE, e_msg = MESSAGE_TEXT,
        e_detail = PG_EXCEPTION_DETAIL, e_hint = PG_EXCEPTION_HINT, e_ctx = PG_EXCEPTION_CONTEXT;
    RETURN fn_fail('setup_tournament_phase', v_inputs, e_state, e_msg, e_detail, e_hint, e_ctx);
END $$;
