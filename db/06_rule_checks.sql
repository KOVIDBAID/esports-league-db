-- 06_rule_checks.sql
-- Phase 3, part 1: one check function per business rule (report Section 2.8).
--
-- Each check_rNN(key) looks at the rows the key names, as they are now, and raises the
-- rule's error if they break rule NN. If the rows no longer exist it does nothing.
-- The functions change no data, so they are safe to call as often as needed.
--
-- WHEN each check runs is decided in 07_triggers.sql, which calls these functions from
-- the triggers of every table whose change could break the rule. docs/rules.md lists,
-- for each rule, its check function, the tables that call it, and when.
--
-- Errors: raise_rule(n, ...) gives SQLSTATE R00nn ('R0007: ...'); the four total-
-- participation constraints use raise_total(n, ...), SQLSTATE T000n.
--
-- Definitions used below
--   match date      the UTC calendar date of match.scheduled_at; while the match has no
--                   time yet, the tournament's start_date. UTC gives every session the
--                   same answer.
--   stint covers d  start_date <= d AND (end_date IS NULL OR d < end_date)
--                   (end_date is exclusive: docs/deviation_log.md, D5)
--   player roles    starter, substitute, two-way
--   coaching roles  head coach, assistant coach
--   started match   status is live or completed, or result_type is set
--   mode codes      HP, S&D, CTL, OVR (game_mode.abbreviation in seed/reference)
--
-- Locks, so the checks also hold when two sessions write at once
--   * A check that needs a row to EXIST locks it the way a foreign key does:
--     FOR KEY SHARE (or FOR SHARE when a non-key column matters, such as a stint's
--     end_date). Another session can then not delete or change that row until this
--     transaction ends; if it already did, the lookup finds nothing and the rule fails.
--   * A check that COUNTS rows (rules 3, 14, 27) first locks the parent row with
--     FOR NO KEY UPDATE, so a second session waits and then counts again.
--   * Neither lock blocks the KEY SHARE locks that ordinary foreign keys take.

------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------

CREATE FUNCTION match_date(p_match_id integer) RETURNS date
LANGUAGE sql STABLE AS $$
    SELECT COALESCE((m.scheduled_at AT TIME ZONE 'UTC')::date, t.start_date)
    FROM match m
    JOIN tournament t ON t.event_id = m.tournament_id
    WHERE m.match_id = p_match_id
$$;

-- Does the person have a stint with the team that covers the date?
-- p_roles limits it to stints in those roles; NULL means any role.
-- The stint found is locked FOR SHARE: until this transaction ends, no other session can
-- end, move or delete it.
CREATE FUNCTION has_stint(p_person_id integer, p_team_id integer, p_on date,
                          p_roles text[] DEFAULT NULL) RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM roster r
    WHERE r.person_id = p_person_id
      AND r.team_id = p_team_id
      AND r.start_date <= p_on
      AND (r.end_date IS NULL OR p_on < r.end_date)
      AND (p_roles IS NULL OR r.roster_role = ANY (p_roles))
    FOR SHARE;
    RETURN FOUND;
END $$;

-- Readable names for error messages, so the app shows "Den (HP)" rather than "map 3, mode 1".
CREATE FUNCTION person_label(p_person_id integer) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT COALESCE(p.gamertag, p.first_name || ' ' || p.last_name)
         FROM person p WHERE p.person_id = p_person_id),
        'person ' || p_person_id)
$$;

CREATE FUNCTION team_label(p_team_id integer) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT ti.team_name FROM team_identity ti
         WHERE ti.team_id = p_team_id ORDER BY ti.valid_from DESC LIMIT 1),
        'team ' || p_team_id)
$$;

CREATE FUNCTION mode_label(p_mode_id integer) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT abbreviation FROM game_mode WHERE mode_id = p_mode_id),
                    'mode ' || p_mode_id)
$$;

CREATE FUNCTION map_mode_label(p_map_id integer, p_mode_id integer) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT map_name FROM map WHERE map_id = p_map_id), 'map ' || p_map_id)
           || ' (' || mode_label(p_mode_id) || ')'
$$;

------------------------------------------------------------------------------
-- Rule 1: a match has at most two teams, and exactly two once it has started.
-- The slot CHECK and UNIQUE (match_id, slot) give "at most two"; this adds "exactly two".
------------------------------------------------------------------------------
CREATE FUNCTION check_r01(p_match_id integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_started boolean;
    v_teams   integer;
BEGIN
    SELECT m.status IN ('live', 'completed') OR m.result_type IS NOT NULL
    INTO v_started
    FROM match m WHERE m.match_id = p_match_id;

    IF v_started THEN
        SELECT count(*) INTO v_teams FROM competes_in WHERE match_id = p_match_id;
        IF v_teams <> 2 THEN
            PERFORM raise_rule(1, format(
                'match %s has started with %s team(s); a started match needs exactly two',
                p_match_id, v_teams));
        END IF;
    END IF;
END $$;

------------------------------------------------------------------------------
-- Rule 2: a team plays in a match only if it participates in the match's tournament.
------------------------------------------------------------------------------
CREATE FUNCTION check_r02(p_match_id integer, p_team_id integer) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM competes_in c WHERE c.match_id = p_match_id AND c.team_id = p_team_id) THEN
        RETURN;
    END IF;

    PERFORM 1
    FROM match m
    JOIN participates_in p ON p.tournament_id = m.tournament_id AND p.team_id = p_team_id
    WHERE m.match_id = p_match_id
    FOR KEY SHARE OF p;
    IF NOT FOUND THEN
        PERFORM raise_rule(2, format(
            '%s does not participate in the tournament of match %s', team_label(p_team_id), p_match_id));
    END IF;
END $$;

------------------------------------------------------------------------------
-- Rule 3: winner_to and loser_to links stay within one tournament, and each slot of a
-- match is fed by at most one link. The UNIQUE constraints stop two winner links (or two
-- loser links) feeding one slot; this stops a winner link and a loser link sharing one.
-- (Moving the winner and loser forward is the job of record_series_result, Phase 4.)
------------------------------------------------------------------------------
CREATE FUNCTION check_r03(p_match_id integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    m        match%ROWTYPE;
    v_target integer;
    v_slot   smallint;
BEGIN
    SELECT * INTO m FROM match WHERE match_id = p_match_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF p_match_id IN (m.winner_to_match_id, m.loser_to_match_id) THEN
        PERFORM raise_rule(3, format('match %s cannot feed itself', p_match_id));
    END IF;

    -- Lock the matches this one feeds, so two sessions cannot link into one slot at once.
    PERFORM 1 FROM match n WHERE n.match_id IN (m.winner_to_match_id, m.loser_to_match_id)
    ORDER BY n.match_id FOR NO KEY UPDATE;

    IF EXISTS (SELECT 1 FROM match n
               WHERE (n.match_id IN (m.winner_to_match_id, m.loser_to_match_id)
                      OR n.winner_to_match_id = p_match_id
                      OR n.loser_to_match_id = p_match_id)
                 AND n.tournament_id <> m.tournament_id) THEN
        PERFORM raise_rule(3, format('match %s is linked to a match in another tournament', p_match_id));
    END IF;

    SELECT a.winner_to_match_id, a.winner_to_slot INTO v_target, v_slot
    FROM match a
    JOIN match b ON b.loser_to_match_id = a.winner_to_match_id AND b.loser_to_slot = a.winner_to_slot
    WHERE p_match_id IN (a.match_id, b.match_id, a.winner_to_match_id)
    LIMIT 1;
    IF FOUND THEN
        PERFORM raise_rule(3, format(
            'slot %s of match %s is fed by both a winner link and a loser link', v_slot, v_target));
    END IF;
END $$;

------------------------------------------------------------------------------
-- Rule 4: a match has at most best_of games and stops once a team has won more than half.
-- Two checks: the length (immediate) and the end of the series (at commit, because a
-- game and its two scores are written one after another).
------------------------------------------------------------------------------
CREATE FUNCTION check_r04_length(p_match_id integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_game    smallint;
    v_best_of smallint;
BEGIN
    SELECT g.game_number, m.best_of INTO v_game, v_best_of
    FROM game g
    JOIN match m ON m.match_id = g.match_id
    WHERE g.match_id = p_match_id AND g.game_number > m.best_of
    ORDER BY g.game_number
    LIMIT 1;
    IF FOUND THEN
        PERFORM raise_rule(4, format(
            'match %s is a best of %s, so it cannot have a game %s', p_match_id, v_best_of, v_game));
    END IF;
END $$;

CREATE FUNCTION check_r04_end(p_match_id integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_decided smallint;   -- the game in which a team reached a majority
    v_late    smallint;   -- the first game after it that still has a result
BEGIN
    WITH wins AS (
        SELECT w.game_number,
               count(*) OVER (PARTITION BY w.team_id ORDER BY w.game_number) AS wins_so_far
        FROM v_game_winner w
        WHERE w.match_id = p_match_id)
    SELECT min(wins.game_number) INTO v_decided
    FROM wins
    JOIN match m ON m.match_id = p_match_id
    WHERE wins.wins_so_far > m.best_of / 2;

    IF v_decided IS NULL THEN
        RETURN;
    END IF;

    SELECT min(g.game_number) INTO v_late
    FROM game g
    WHERE g.match_id = p_match_id AND g.game_number > v_decided AND g.result_type IS NOT NULL;
    IF v_late IS NOT NULL THEN
        PERFORM raise_rule(4, format(
            'match %s was decided in game %s, so game %s cannot have a result',
            p_match_id, v_decided, v_late));
    END IF;
END $$;

------------------------------------------------------------------------------
-- Rule 6: a played game has exactly two team_result rows, one per team of the match.
-- The foreign key to competes_in already makes each row belong to a team of the match.
------------------------------------------------------------------------------
CREATE FUNCTION check_r06(p_match_id integer, p_game_number integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_scores integer;
BEGIN
    IF EXISTS (SELECT 1 FROM game g
               WHERE g.match_id = p_match_id AND g.game_number = p_game_number
                 AND g.result_type = 'played') THEN
        SELECT count(*) INTO v_scores
        FROM team_result WHERE match_id = p_match_id AND game_number = p_game_number;
        IF v_scores <> 2 THEN
            PERFORM raise_rule(6, format(
                'game %s of match %s was played but has %s score(s); it needs one for each team',
                p_game_number, p_match_id, v_scores));
        END IF;
    END IF;
END $$;

------------------------------------------------------------------------------
-- Rule 7: a game's map and mode are an entry of the pool its phase uses, and its mode is
-- the slot mode of the phase's layout for the match's best_of and the game's number.
------------------------------------------------------------------------------
CREATE FUNCTION check_r07(p_match_id integer, p_game_number integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_map       integer;
    v_mode      integer;
    v_pool      integer;
    v_layout    integer;
    v_best_of   smallint;
    v_slot_mode integer;
BEGIN
    -- FOR SHARE OF ph: the phase cannot switch pool or layout until this transaction ends.
    SELECT g.map_id, g.mode_id, ph.pool_id, ph.layout_id, m.best_of
    INTO v_map, v_mode, v_pool, v_layout, v_best_of
    FROM game g
    JOIN match m  ON m.match_id = g.match_id
    JOIN phase ph ON ph.tournament_id = m.tournament_id AND ph.phase_number = m.phase_number
    WHERE g.match_id = p_match_id AND g.game_number = p_game_number
    FOR SHARE OF ph;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    PERFORM 1 FROM pool_entry pe
    WHERE pe.pool_id = v_pool AND pe.map_id = v_map AND pe.mode_id = v_mode
    FOR KEY SHARE;
    IF NOT FOUND THEN
        PERFORM raise_rule(7, format('%s is not in this phase''s map pool, "%s"',
            map_mode_label(v_map, v_mode), (SELECT pool_name FROM map_pool WHERE pool_id = v_pool)));
    END IF;

    SELECT s.mode_id INTO v_slot_mode
    FROM series_slot s
    WHERE s.layout_id = v_layout AND s.best_of = v_best_of AND s.game_number = p_game_number
    FOR SHARE;
    IF v_slot_mode IS DISTINCT FROM v_mode THEN
        PERFORM raise_rule(7, format(
            'game %s of a best of %s must be %s under this phase''s layout, not %s',
            p_game_number, v_best_of,
            CASE WHEN v_slot_mode IS NULL THEN 'defined' ELSE mode_label(v_slot_mode) END,
            mode_label(v_mode)));
    END IF;
END $$;

------------------------------------------------------------------------------
-- Rule 8: a phase's layout defines every game number for each best_of its matches use,
-- and every mode in the layout appears in the phase's pool.
------------------------------------------------------------------------------
CREATE FUNCTION check_r08_match(p_match_id integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_best_of smallint;
    v_layout  integer;
    v_slots   integer;
BEGIN
    SELECT m.best_of, ph.layout_id,
           (SELECT count(*) FROM series_slot s
            WHERE s.layout_id = ph.layout_id AND s.best_of = m.best_of)
    INTO v_best_of, v_layout, v_slots
    FROM match m
    JOIN phase ph ON ph.tournament_id = m.tournament_id AND ph.phase_number = m.phase_number
    WHERE m.match_id = p_match_id;

    IF FOUND AND v_slots <> v_best_of THEN
        PERFORM raise_rule(8, format(
            'layout "%s" defines %s of the %s games of a best of %s, which match %s needs',
            (SELECT layout_name FROM series_layout WHERE layout_id = v_layout),
            v_slots, v_best_of, v_best_of, p_match_id));
    END IF;
END $$;

CREATE FUNCTION check_r08_phase(p_tournament_id integer, p_phase_number integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_pool    integer;
    v_layout  integer;
    v_missing integer;
    v_match   integer;
BEGIN
    SELECT pool_id, layout_id INTO v_pool, v_layout
    FROM phase WHERE tournament_id = p_tournament_id AND phase_number = p_phase_number;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT s.mode_id INTO v_missing
    FROM series_slot s
    WHERE s.layout_id = v_layout
      AND NOT EXISTS (SELECT 1 FROM pool_entry pe WHERE pe.pool_id = v_pool AND pe.mode_id = s.mode_id)
    LIMIT 1;
    IF FOUND THEN
        PERFORM raise_rule(8, format(
            'phase %s of tournament %s plays %s in its layout, but its map pool has no %s map',
            p_phase_number, p_tournament_id, mode_label(v_missing), mode_label(v_missing)));
    END IF;

    FOR v_match IN SELECT match_id FROM match
                   WHERE tournament_id = p_tournament_id AND phase_number = p_phase_number LOOP
        PERFORM check_r08_match(v_match);
    END LOOP;
END $$;

------------------------------------------------------------------------------
-- Rule 9: all maps in a pool share one game_title, which matches the season's
-- game_title wherever the pool is used in a season's tournament.
------------------------------------------------------------------------------
CREATE FUNCTION check_r09(p_pool_id integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_titles integer;
    v_title  text;
    v_season text;
BEGIN
    SELECT count(DISTINCT mp.game_title), min(mp.game_title) INTO v_titles, v_title
    FROM pool_entry pe
    JOIN map mp ON mp.map_id = pe.map_id
    WHERE pe.pool_id = p_pool_id;

    IF v_titles > 1 THEN
        PERFORM raise_rule(9, format('map pool "%s" mixes maps from %s game titles',
            (SELECT pool_name FROM map_pool WHERE pool_id = p_pool_id), v_titles));
    END IF;
    IF v_titles = 0 THEN
        RETURN;
    END IF;

    SELECT s.game_title INTO v_season
    FROM phase ph
    JOIN tournament t ON t.event_id = ph.tournament_id
    JOIN season s     ON s.league_id = t.league_id AND s.season_year = t.season_year
    WHERE ph.pool_id = p_pool_id AND s.game_title <> v_title
    LIMIT 1;
    IF FOUND THEN
        PERFORM raise_rule(9, format('map pool "%s" holds %s maps but is used in a %s season',
            (SELECT pool_name FROM map_pool WHERE pool_id = p_pool_id), v_title, v_season));
    END IF;
END $$;

------------------------------------------------------------------------------
-- Rule 10: every pick or ban names an entry of the phase's pool. (Once per match and by
-- one of the two teams are guaranteed by UNIQUE and the foreign key to competes_in.)
------------------------------------------------------------------------------
CREATE FUNCTION check_r10(p_match_id integer, p_veto_order integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_map  integer;
    v_mode integer;
    v_pool integer;
BEGIN
    SELECT v.map_id, v.mode_id, ph.pool_id INTO v_map, v_mode, v_pool
    FROM map_veto v
    JOIN match m  ON m.match_id = v.match_id
    JOIN phase ph ON ph.tournament_id = m.tournament_id AND ph.phase_number = m.phase_number
    WHERE v.match_id = p_match_id AND v.veto_order = p_veto_order
    FOR SHARE OF ph;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    PERFORM 1 FROM pool_entry pe
    WHERE pe.pool_id = v_pool AND pe.map_id = v_map AND pe.mode_id = v_mode
    FOR KEY SHARE;
    IF NOT FOUND THEN
        PERFORM raise_rule(10, format(
            '%s is not in this phase''s map pool, so it cannot be picked or banned',
            map_mode_label(v_map, v_mode)));
    END IF;
END $$;

------------------------------------------------------------------------------
-- Rule 11: every team with a score in a game has exactly team_size player stats rows in
-- that game, from players listed for that team in the match (match_player).
------------------------------------------------------------------------------
CREATE FUNCTION check_r11(p_match_id integer, p_game_number integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_size smallint;
    r      record;
BEGIN
    SELECT t.team_size INTO v_size
    FROM match m JOIN tournament t ON t.event_id = m.tournament_id
    WHERE m.match_id = p_match_id;

    FOR r IN
        SELECT tr.team_id,
               (SELECT count(*)
                FROM player_game_stats s
                JOIN match_player mp ON mp.person_id = s.person_id AND mp.match_id = s.match_id
                WHERE s.match_id = tr.match_id AND s.game_number = tr.game_number
                  AND mp.team_id = tr.team_id) AS players
        FROM team_result tr
        WHERE tr.match_id = p_match_id AND tr.game_number = p_game_number
    LOOP
        IF r.players <> v_size THEN
            PERFORM raise_rule(11, format(
                '%s has stats for %s player(s) in game %s of match %s; teams field %s',
                team_label(r.team_id), r.players, p_game_number, p_match_id, v_size));
        END IF;
    END LOOP;
END $$;

------------------------------------------------------------------------------
-- Rule 12: a player listed for a match has a stint with that team on the match date:
-- a player-role stint, or a coaching stint when a coach substitutes in. (That the team
-- is one of the match's teams, and that the person is a Player, are foreign keys.)
------------------------------------------------------------------------------
CREATE FUNCTION check_r12(p_person_id integer, p_match_id integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_team integer;
    v_date date;
BEGIN
    SELECT mp.team_id, match_date(mp.match_id) INTO v_team, v_date
    FROM match_player mp
    WHERE mp.person_id = p_person_id AND mp.match_id = p_match_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF v_date IS NULL THEN
        PERFORM raise_rule(12, format(
            'match %s has no date (no scheduled_at, no tournament start_date), so stints cannot be checked',
            p_match_id));
    END IF;
    IF NOT has_stint(p_person_id, v_team, v_date,
                     ARRAY['starter', 'substitute', 'two-way', 'head coach', 'assistant coach']) THEN
        PERFORM raise_rule(12, format('%s has no playing or coaching stint with %s on %s',
            person_label(p_person_id), team_label(v_team), v_date));
    END IF;
END $$;

------------------------------------------------------------------------------
-- Rule 13: a stats row's mode table matches its game's mode (hardpoint_stats only in
-- Hardpoint games, and so on). Checked per game, across the four tables.
------------------------------------------------------------------------------
CREATE FUNCTION check_r13(p_match_id integer, p_game_number integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_mode  text;
    v_table text;
BEGIN
    SELECT gm.abbreviation INTO v_mode
    FROM game g JOIN game_mode gm ON gm.mode_id = g.mode_id
    WHERE g.match_id = p_match_id AND g.game_number = p_game_number
    FOR SHARE OF g;                     -- the game's mode cannot change under us
    IF NOT FOUND THEN
        RETURN;
    END IF;

    v_table := CASE
        WHEN v_mode <> 'HP' AND EXISTS (SELECT 1 FROM hardpoint_stats s
             WHERE s.match_id = p_match_id AND s.game_number = p_game_number) THEN 'hardpoint_stats'
        WHEN v_mode <> 'S&D' AND EXISTS (SELECT 1 FROM snd_stats s
             WHERE s.match_id = p_match_id AND s.game_number = p_game_number) THEN 'snd_stats'
        WHEN v_mode <> 'CTL' AND EXISTS (SELECT 1 FROM control_stats s
             WHERE s.match_id = p_match_id AND s.game_number = p_game_number) THEN 'control_stats'
        WHEN v_mode <> 'OVR' AND EXISTS (SELECT 1 FROM overload_stats s
             WHERE s.match_id = p_match_id AND s.game_number = p_game_number) THEN 'overload_stats'
    END;
    IF v_table IS NOT NULL THEN
        PERFORM raise_rule(13, format('game %s of match %s is %s, so it cannot have %s rows',
            p_game_number, p_match_id, v_mode, v_table));
    END IF;
END $$;

------------------------------------------------------------------------------
-- Rule 14: stints of one person with different teams may overlap only when one of them
-- is two-way, and a team has at most two two-way players at once. (Same-team overlap
-- is the EXCLUDE constraint roster_no_overlap_r14.)
------------------------------------------------------------------------------
CREATE FUNCTION check_r14(p_person_id integer, p_team_id integer, p_start_date date) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    s        roster%ROWTYPE;
    v_period daterange;
    v_other  integer;
BEGIN
    SELECT * INTO s FROM roster
    WHERE person_id = p_person_id AND team_id = p_team_id AND start_date = p_start_date;
    IF NOT FOUND THEN
        RETURN;
    END IF;
    v_period := daterange(s.start_date, s.end_date, '[)');

    -- Lock order: team, then person. A second session adding a stint for the same team
    -- or person waits here, then sees this one once it commits.
    PERFORM 1 FROM team   WHERE team_id   = s.team_id   FOR NO KEY UPDATE;
    PERFORM 1 FROM person WHERE person_id = s.person_id FOR NO KEY UPDATE;

    SELECT r.team_id INTO v_other
    FROM roster r
    WHERE r.person_id = s.person_id AND r.team_id <> s.team_id
      AND daterange(r.start_date, r.end_date, '[)') && v_period
      AND r.roster_role <> 'two-way' AND s.roster_role <> 'two-way'
    LIMIT 1;
    IF FOUND THEN
        PERFORM raise_rule(14, format(
            '%s already has an overlapping stint with %s; stints with two teams may overlap only when one is two-way',
            person_label(s.person_id), team_label(v_other)));
    END IF;

    -- Three two-way stints share a moment exactly when two others overlap each other
    -- inside this one.
    IF s.roster_role = 'two-way' AND EXISTS (
        SELECT 1
        FROM roster a
        JOIN roster b ON b.team_id = a.team_id AND b.person_id > a.person_id
        WHERE a.team_id = s.team_id
          AND a.roster_role = 'two-way' AND b.roster_role = 'two-way'
          AND s.person_id NOT IN (a.person_id, b.person_id)
          AND NOT isempty(daterange(a.start_date, a.end_date, '[)')
                          * daterange(b.start_date, b.end_date, '[)')
                          * v_period)) THEN
        PERFORM raise_rule(14, format(
            '%s already has two two-way players during this stint', team_label(s.team_id)));
    END IF;
END $$;

------------------------------------------------------------------------------
-- Rule 15: roster_role fits the person: starter, substitute and two-way need Player;
-- head coach and assistant coach need Coach; team manager needs neither.
------------------------------------------------------------------------------
CREATE FUNCTION check_r15(p_person_id integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_role text;
BEGIN
    SELECT r.roster_role INTO v_role FROM roster r
    WHERE r.person_id = p_person_id AND r.roster_role IN ('starter', 'substitute', 'two-way')
    LIMIT 1;
    IF FOUND THEN
        PERFORM 1 FROM player WHERE person_id = p_person_id FOR KEY SHARE;
        IF NOT FOUND THEN
            PERFORM raise_rule(15, format('%s cannot be a %s without a player record',
                person_label(p_person_id), v_role));
        END IF;
    END IF;

    SELECT r.roster_role INTO v_role FROM roster r
    WHERE r.person_id = p_person_id AND r.roster_role IN ('head coach', 'assistant coach')
    LIMIT 1;
    IF FOUND THEN
        PERFORM 1 FROM coach WHERE person_id = p_person_id FOR KEY SHARE;
        IF NOT FOUND THEN
            PERFORM raise_rule(15, format('%s cannot be a %s without a coach record',
                person_label(p_person_id), v_role));
        END IF;
    END IF;
END $$;

------------------------------------------------------------------------------
-- Rule 16: in a league tournament, a player is at least the league's min_age on the
-- match date. A player with no date of birth cannot pass the check.
------------------------------------------------------------------------------
CREATE FUNCTION check_r16(p_person_id integer, p_match_id integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_min    smallint;
    v_league text;
    v_dob    date;
    v_date   date;
BEGIN
    SELECT l.min_age, l.abbreviation, p.date_of_birth, match_date(m.match_id)
    INTO v_min, v_league, v_dob, v_date
    FROM match_player mp
    JOIN match m      ON m.match_id = mp.match_id
    JOIN tournament t ON t.event_id = m.tournament_id
    JOIN league l     ON l.event_id = t.league_id
    JOIN person p     ON p.person_id = mp.person_id
    WHERE mp.person_id = p_person_id AND mp.match_id = p_match_id;
    IF NOT FOUND OR v_min IS NULL THEN
        RETURN;                         -- not a league tournament, or no age limit
    END IF;

    IF v_dob IS NULL THEN
        PERFORM raise_rule(16, format('%s has no date of birth, so the %s minimum age of %s cannot be checked',
            person_label(p_person_id), v_league, v_min));
    END IF;
    IF (v_dob + make_interval(years => v_min))::date > v_date THEN
        PERFORM raise_rule(16, format('%s is %s on %s; %s players must be at least %s',
            person_label(p_person_id), date_part('year', age(v_date, v_dob)), v_date, v_league, v_min));
    END IF;
END $$;

------------------------------------------------------------------------------
-- Rule 17: if a tournament has a region, every player in it is linked to that region.
-- Checked when the player is listed; a later change of the player's region does not
-- rewrite history.
------------------------------------------------------------------------------
CREATE FUNCTION check_r17(p_person_id integer, p_match_id integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_need integer;
    v_has  integer;
BEGIN
    SELECT t.region_id, pl.region_id INTO v_need, v_has
    FROM match_player mp
    JOIN match m      ON m.match_id = mp.match_id
    JOIN tournament t ON t.event_id = m.tournament_id
    JOIN player pl    ON pl.person_id = mp.person_id
    WHERE mp.person_id = p_person_id AND mp.match_id = p_match_id;
    IF NOT FOUND OR v_need IS NULL THEN
        RETURN;
    END IF;

    IF v_has IS DISTINCT FROM v_need THEN
        PERFORM raise_rule(17, format('%s is linked to %s, but this tournament is for %s',
            person_label(p_person_id),
            COALESCE((SELECT abbreviation FROM region WHERE region_id = v_has), 'no region'),
            (SELECT abbreviation FROM region WHERE region_id = v_need)));
    END IF;
END $$;

------------------------------------------------------------------------------
-- Rule 20: a penalty that names both a person and a team needs a stint of that person
-- with that team on the issue date (UTC). "Names someone" is the CHECK penalty_names_someone.
------------------------------------------------------------------------------
CREATE FUNCTION check_r20(p_penalty_id integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_person integer;
    v_team   integer;
    v_date   date;
BEGIN
    SELECT person_id, team_id, (issued_at AT TIME ZONE 'UTC')::date
    INTO v_person, v_team, v_date
    FROM penalty WHERE penalty_id = p_penalty_id;
    IF NOT FOUND OR v_person IS NULL OR v_team IS NULL THEN
        RETURN;
    END IF;

    IF NOT has_stint(v_person, v_team, v_date) THEN
        PERFORM raise_rule(20, format('%s had no stint with %s on %s, so one penalty cannot name both',
            person_label(v_person), team_label(v_team), v_date));
    END IF;
END $$;

------------------------------------------------------------------------------
-- Rule 21: a game-forfeit penalty points to a game whose result_type is forfeit; a
-- match-forfeit penalty points to a match (not a game) whose result_type is forfeit.
------------------------------------------------------------------------------
CREATE FUNCTION check_r21(p_penalty_id integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    p penalty%ROWTYPE;
BEGIN
    SELECT * INTO p FROM penalty WHERE penalty_id = p_penalty_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF p.penalty_type = 'game forfeit' AND NOT EXISTS (
        SELECT 1 FROM game g
        WHERE g.match_id = p.match_id AND g.game_number = p.game_number AND g.result_type = 'forfeit') THEN
        PERFORM raise_rule(21, format(
            'penalty %s is a game forfeit, so it must point to a game whose result is a forfeit', p.penalty_id));
    END IF;

    IF p.penalty_type = 'match forfeit' AND (p.game_number IS NOT NULL OR NOT EXISTS (
        SELECT 1 FROM match m WHERE m.match_id = p.match_id AND m.result_type = 'forfeit')) THEN
        PERFORM raise_rule(21, format(
            'penalty %s is a match forfeit, so it must point to a match (not a game) whose result is a forfeit',
            p.penalty_id));
    END IF;
END $$;

------------------------------------------------------------------------------
-- Rule 25: tournament dates fall within their stage's, stage dates within their
-- season's, and phase dates within their tournament's. Dates are inclusive; a missing
-- date is not compared.
------------------------------------------------------------------------------
CREATE FUNCTION check_r25_within(p_what text, p_from date, p_to date,
                                 p_parent text, p_parent_from date, p_parent_to date) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_from < p_parent_from OR p_from > p_parent_to
       OR p_to > p_parent_to OR p_to < p_parent_from THEN
        PERFORM raise_rule(25, format('%s (%s to %s) is not within %s (%s to %s)',
            p_what, COALESCE(p_from::text, '?'), COALESCE(p_to::text, '?'),
            p_parent, COALESCE(p_parent_from::text, '?'), COALESCE(p_parent_to::text, '?')));
    END IF;
END $$;

CREATE FUNCTION check_r25_phase(p_tournament_id integer, p_phase_number integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT ph.phase_name, ph.start_date, ph.end_date, t.start_date AS t_from, t.end_date AS t_to
             FROM phase ph JOIN tournament t ON t.event_id = ph.tournament_id
             WHERE ph.tournament_id = p_tournament_id AND ph.phase_number = p_phase_number LOOP
        PERFORM check_r25_within(format('phase "%s"', r.phase_name), r.start_date, r.end_date,
                                 'its tournament', r.t_from, r.t_to);
    END LOOP;
END $$;

-- A tournament against its stage, and its phases against it.
CREATE FUNCTION check_r25_tournament(p_tournament_id integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT e.event_name, t.start_date, t.end_date, st.stage_name,
                    st.start_date AS s_from, st.end_date AS s_to
             FROM tournament t
             JOIN event e  ON e.event_id = t.event_id
             JOIN stage st ON st.league_id = t.league_id AND st.season_year = t.season_year
                          AND st.stage_number = t.stage_number
             WHERE t.event_id = p_tournament_id LOOP
        PERFORM check_r25_within(format('tournament "%s"', r.event_name), r.start_date, r.end_date,
                                 format('stage "%s"', r.stage_name), r.s_from, r.s_to);
    END LOOP;
    FOR r IN SELECT phase_number FROM phase WHERE tournament_id = p_tournament_id LOOP
        PERFORM check_r25_phase(p_tournament_id, r.phase_number);
    END LOOP;
END $$;

-- A stage against its season, and its tournaments against it.
CREATE FUNCTION check_r25_stage(p_league_id integer, p_season_year integer, p_stage_number integer)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT st.stage_name, st.start_date, st.end_date,
                    se.start_date AS s_from, se.end_date AS s_to
             FROM stage st
             JOIN season se ON se.league_id = st.league_id AND se.season_year = st.season_year
             WHERE st.league_id = p_league_id AND st.season_year = p_season_year
               AND st.stage_number = p_stage_number LOOP
        PERFORM check_r25_within(format('stage "%s"', r.stage_name), r.start_date, r.end_date,
                                 format('the %s season', p_season_year), r.s_from, r.s_to);
    END LOOP;
    FOR r IN SELECT event_id FROM tournament
             WHERE league_id = p_league_id AND season_year = p_season_year
               AND stage_number = p_stage_number LOOP
        PERFORM check_r25_tournament(r.event_id);
    END LOOP;
END $$;

-- A season's stages against it.
CREATE FUNCTION check_r25_season(p_league_id integer, p_season_year integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT stage_number FROM stage
             WHERE league_id = p_league_id AND season_year = p_season_year LOOP
        PERFORM check_r25_stage(p_league_id, p_season_year, r.stage_number);
    END LOOP;
END $$;

------------------------------------------------------------------------------
-- Rule 26: in a tournament that belongs to a league season, every participating team
-- is registered for that season.
------------------------------------------------------------------------------
CREATE FUNCTION check_r26(p_team_id integer, p_tournament_id integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_league integer;
    v_year   smallint;
BEGIN
    SELECT t.league_id, t.season_year INTO v_league, v_year
    FROM participates_in p
    JOIN tournament t ON t.event_id = p.tournament_id
    WHERE p.team_id = p_team_id AND p.tournament_id = p_tournament_id;
    IF NOT FOUND OR v_league IS NULL THEN
        RETURN;
    END IF;

    PERFORM 1 FROM registered_in r
    WHERE r.team_id = p_team_id AND r.league_id = v_league AND r.season_year = v_year
    FOR KEY SHARE;
    IF NOT FOUND THEN
        PERFORM raise_rule(26, format('%s is not registered for the %s %s season',
            team_label(p_team_id), (SELECT abbreviation FROM league WHERE event_id = v_league), v_year));
    END IF;
END $$;

------------------------------------------------------------------------------
-- Rule 27: a tournament has at most max_teams participating teams.
------------------------------------------------------------------------------
CREATE FUNCTION check_r27(p_tournament_id integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_max   smallint;
    v_count integer;
BEGIN
    -- Lock the tournament first, so two sessions cannot both add the last allowed team.
    SELECT max_teams INTO v_max FROM tournament WHERE event_id = p_tournament_id FOR NO KEY UPDATE;
    IF v_max IS NULL THEN
        RETURN;
    END IF;

    SELECT count(*) INTO v_count FROM participates_in WHERE tournament_id = p_tournament_id;
    IF v_count > v_max THEN
        PERFORM raise_rule(27, format('tournament "%s" allows %s teams; this would make %s',
            (SELECT event_name FROM event WHERE event_id = p_tournament_id), v_max, v_count));
    END IF;
END $$;

------------------------------------------------------------------------------
-- Rule 28: a team's final_placement is at most the number of teams in the tournament.
-- (At least 1 is the CHECK participates_in_placement_check.)
------------------------------------------------------------------------------
CREATE FUNCTION check_r28(p_tournament_id integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_teams integer;
    v_worst smallint;
BEGIN
    SELECT count(*), max(final_placement) INTO v_teams, v_worst
    FROM participates_in WHERE tournament_id = p_tournament_id;
    IF v_worst > v_teams THEN
        PERFORM raise_rule(28, format(
            'a final placement of %s is impossible with %s teams in tournament "%s"',
            v_worst, v_teams, (SELECT event_name FROM event WHERE event_id = p_tournament_id)));
    END IF;
END $$;

------------------------------------------------------------------------------
-- Total participation (report Section 4.5), numbered T1 to T4
------------------------------------------------------------------------------

-- T1: every team has at least one team_identity.
CREATE FUNCTION check_t1(p_team_id integer) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM team WHERE team_id = p_team_id)
       AND NOT EXISTS (SELECT 1 FROM team_identity WHERE team_id = p_team_id) THEN
        PERFORM raise_total(1, format('team %s has no team identity; every team needs a name', p_team_id));
    END IF;
END $$;

-- T2: every event has at least one hosted_by row.
CREATE FUNCTION check_t2(p_event_id integer) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM event WHERE event_id = p_event_id)
       AND NOT EXISTS (SELECT 1 FROM hosted_by WHERE event_id = p_event_id) THEN
        PERFORM raise_total(2, format('event "%s" has no host organization',
            (SELECT event_name FROM event WHERE event_id = p_event_id)));
    END IF;
END $$;

-- T3: every event is exactly one of league or tournament (disjoint and total).
CREATE FUNCTION check_t3(p_event_id integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_kinds integer;
BEGIN
    IF EXISTS (SELECT 1 FROM event WHERE event_id = p_event_id) THEN
        v_kinds := (SELECT count(*) FROM league     WHERE event_id = p_event_id)
                 + (SELECT count(*) FROM tournament WHERE event_id = p_event_id);
        IF v_kinds <> 1 THEN
            PERFORM raise_total(3, format('event "%s" is %s; an event is exactly one of league or tournament',
                (SELECT event_name FROM event WHERE event_id = p_event_id),
                CASE v_kinds WHEN 0 THEN 'neither a league nor a tournament' ELSE 'both a league and a tournament' END));
        END IF;
    END IF;
END $$;

-- T4: every player_game_stats row has exactly one mode specialization.
CREATE FUNCTION check_t4(p_person_id integer, p_match_id integer, p_game_number integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_rows integer;
BEGIN
    IF EXISTS (SELECT 1 FROM player_game_stats
               WHERE person_id = p_person_id AND match_id = p_match_id AND game_number = p_game_number) THEN
        SELECT (SELECT count(*) FROM hardpoint_stats s WHERE (s.person_id, s.match_id, s.game_number) = (p_person_id, p_match_id, p_game_number))
             + (SELECT count(*) FROM snd_stats s       WHERE (s.person_id, s.match_id, s.game_number) = (p_person_id, p_match_id, p_game_number))
             + (SELECT count(*) FROM control_stats s   WHERE (s.person_id, s.match_id, s.game_number) = (p_person_id, p_match_id, p_game_number))
             + (SELECT count(*) FROM overload_stats s  WHERE (s.person_id, s.match_id, s.game_number) = (p_person_id, p_match_id, p_game_number))
        INTO v_rows;
        IF v_rows <> 1 THEN
            PERFORM raise_total(4, format(
                '%s has %s mode stats rows for game %s of match %s; every stats row needs exactly one',
                person_label(p_person_id), v_rows, p_game_number, p_match_id));
        END IF;
    END IF;
END $$;
