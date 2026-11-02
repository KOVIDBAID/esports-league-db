-- 07_triggers.sql
-- Phase 3, part 2: WHEN the checks in 06_rule_checks.sql run.
--
-- Every table whose change could break a rule has up to two triggers:
--   rules_<table>            AFTER ... FOR EACH ROW: checked as soon as the statement runs
--   rules_<table>_at_commit  CONSTRAINT TRIGGER ... DEFERRABLE INITIALLY DEFERRED: checked at
--                            COMMIT, or earlier with SET CONSTRAINTS ALL IMMEDIATE
-- Each trigger function looks at what changed and calls the checks that change could
-- affect. All of them return NULL: an AFTER trigger cannot alter the row; it can only
-- raise an error, which undoes the statement (or, at commit, the transaction).
--
-- Which checks wait for commit
--   Rules 1, 4 (end of series), 6 and 11, 28, and T1 to T4 count rows that are written one
--   after another: a game, then its two scores, then its stats rows. Rules 8 (pool covers
--   layout), 9, 21 and 25 compare rows that one change may update in either order, such
--   as moving a tournament and its phases a week later. Every other check runs at once,
--   because the rows it compares against must already exist.
--
-- Names start with "rules_", so on each table PostgreSQL fires them after its own foreign
-- key triggers ("RI_...": triggers fire in name order and capital letters sort first).
-- A row that breaks a foreign key therefore reports the foreign key error.

------------------------------------------------------------------------------
-- Shared by several tables: the three checks on a listed player (rules 12, 16, 17)
------------------------------------------------------------------------------
CREATE FUNCTION check_listed_player(p_person_id integer, p_match_id integer) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_r12(p_person_id, p_match_id);
    PERFORM check_r16(p_person_id, p_match_id);
    PERFORM check_r17(p_person_id, p_match_id);
END $$;

------------------------------------------------------------------------------
-- Teams and people
------------------------------------------------------------------------------

-- team: T1 (a new team needs an identity by commit)
CREATE FUNCTION trg_team_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_t1(NEW.team_id);
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_team_at_commit AFTER INSERT ON team
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_team_at_commit();

-- team_identity: T1 (removing a team's last identity)
CREATE FUNCTION trg_team_identity_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_t1(OLD.team_id);
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_team_identity_at_commit AFTER UPDATE OR DELETE ON team_identity
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_team_identity_at_commit();

-- roster: rules 14 and 15 for the new stint; rules 12 and 20 for what the old stint covered
CREATE FUNCTION trg_roster() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    IF TG_OP <> 'DELETE' THEN
        PERFORM check_r14(NEW.person_id, NEW.team_id, NEW.start_date);
        PERFORM check_r15(NEW.person_id);
    END IF;
    IF TG_OP <> 'INSERT' THEN
        -- Ending, moving or deleting a stint must not strand a match the person played
        -- or a penalty that names the person with this team.
        FOR r IN SELECT match_id FROM match_player
                 WHERE person_id = OLD.person_id AND team_id = OLD.team_id LOOP
            PERFORM check_r12(OLD.person_id, r.match_id);
        END LOOP;
        FOR r IN SELECT penalty_id FROM penalty
                 WHERE person_id = OLD.person_id AND team_id = OLD.team_id LOOP
            PERFORM check_r20(r.penalty_id);
        END LOOP;
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER rules_roster AFTER INSERT OR UPDATE OR DELETE ON roster
    FOR EACH ROW EXECUTE FUNCTION trg_roster();

-- person: rule 16 (a corrected date of birth)
CREATE FUNCTION trg_person() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT match_id FROM match_player WHERE person_id = NEW.person_id LOOP
        PERFORM check_r16(NEW.person_id, r.match_id);
    END LOOP;
    RETURN NULL;
END $$;
CREATE TRIGGER rules_person AFTER UPDATE OF date_of_birth ON person
    FOR EACH ROW EXECUTE FUNCTION trg_person();

-- player and coach: rule 15 (a stint's role still needs the subclass row)
CREATE FUNCTION trg_player_or_coach() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_r15(OLD.person_id);
    RETURN NULL;
END $$;
CREATE TRIGGER rules_player AFTER UPDATE OF person_id OR DELETE ON player
    FOR EACH ROW EXECUTE FUNCTION trg_player_or_coach();
CREATE TRIGGER rules_coach AFTER UPDATE OR DELETE ON coach
    FOR EACH ROW EXECUTE FUNCTION trg_player_or_coach();

------------------------------------------------------------------------------
-- Events and structure
------------------------------------------------------------------------------

-- event: T2 and T3 (a new event needs a host and exactly one of league or tournament)
CREATE FUNCTION trg_event_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_t2(NEW.event_id);
    PERFORM check_t3(NEW.event_id);
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_event_at_commit AFTER INSERT ON event
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_event_at_commit();

-- hosted_by: T2 (removing an event's last host)
CREATE FUNCTION trg_hosted_by_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_t2(OLD.event_id);
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_hosted_by_at_commit AFTER UPDATE OR DELETE ON hosted_by
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_hosted_by_at_commit();

-- league: rule 16 (a changed minimum age); T3
CREATE FUNCTION trg_league() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT mp.person_id, mp.match_id
             FROM match_player mp
             JOIN match m      ON m.match_id = mp.match_id
             JOIN tournament t ON t.event_id = m.tournament_id
             WHERE t.league_id = NEW.event_id LOOP
        PERFORM check_r16(r.person_id, r.match_id);
    END LOOP;
    RETURN NULL;
END $$;
CREATE TRIGGER rules_league AFTER UPDATE OF min_age ON league
    FOR EACH ROW EXECUTE FUNCTION trg_league();

CREATE FUNCTION trg_league_or_tournament_t3() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP <> 'DELETE' THEN
        PERFORM check_t3(NEW.event_id);
    END IF;
    IF TG_OP <> 'INSERT' THEN
        PERFORM check_t3(OLD.event_id);
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_league_at_commit AFTER INSERT OR UPDATE OR DELETE ON league
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_league_or_tournament_t3();

-- season: rule 9 (game title) and rule 25 (its stages' dates)
CREATE FUNCTION trg_season_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    IF NEW.game_title IS DISTINCT FROM OLD.game_title THEN
        FOR r IN SELECT DISTINCT ph.pool_id
                 FROM phase ph JOIN tournament t ON t.event_id = ph.tournament_id
                 WHERE t.league_id = NEW.league_id AND t.season_year = NEW.season_year LOOP
            PERFORM check_r09(r.pool_id);
        END LOOP;
    END IF;
    PERFORM check_r25_season(NEW.league_id, NEW.season_year);
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_season_at_commit AFTER UPDATE ON season
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_season_at_commit();

-- stage: rule 25 (within its season; its tournaments within it)
CREATE FUNCTION trg_stage_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_r25_stage(NEW.league_id, NEW.season_year, NEW.stage_number);
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_stage_at_commit AFTER INSERT OR UPDATE ON stage
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_stage_at_commit();

-- tournament: rules 26, 27, and 12/16/17 for listed players, when the tournament changes
CREATE FUNCTION trg_tournament() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_staged boolean := (NEW.league_id, NEW.season_year, NEW.stage_number)
                        IS DISTINCT FROM (OLD.league_id, OLD.season_year, OLD.stage_number);
    r record;
BEGIN
    IF v_staged THEN
        FOR r IN SELECT team_id FROM participates_in WHERE tournament_id = NEW.event_id LOOP
            PERFORM check_r26(r.team_id, NEW.event_id);
        END LOOP;
    END IF;
    IF NEW.max_teams IS DISTINCT FROM OLD.max_teams THEN
        PERFORM check_r27(NEW.event_id);
    END IF;
    -- League (min_age), region and start date (the date of unscheduled matches)
    IF v_staged OR NEW.region_id IS DISTINCT FROM OLD.region_id
       OR NEW.start_date IS DISTINCT FROM OLD.start_date THEN
        FOR r IN SELECT mp.person_id, mp.match_id
                 FROM match_player mp JOIN match m ON m.match_id = mp.match_id
                 WHERE m.tournament_id = NEW.event_id LOOP
            PERFORM check_listed_player(r.person_id, r.match_id);
        END LOOP;
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER rules_tournament AFTER UPDATE ON tournament
    FOR EACH ROW EXECUTE FUNCTION trg_tournament();

-- tournament at commit: T3, rule 25, and rules 9 and 11 when its season or team size changes
CREATE FUNCTION trg_tournament_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    IF TG_OP <> 'DELETE' THEN
        PERFORM check_t3(NEW.event_id);
        PERFORM check_r25_tournament(NEW.event_id);
    END IF;
    IF TG_OP <> 'INSERT' THEN
        PERFORM check_t3(OLD.event_id);
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF (NEW.league_id, NEW.season_year) IS DISTINCT FROM (OLD.league_id, OLD.season_year) THEN
            FOR r IN SELECT DISTINCT pool_id FROM phase WHERE tournament_id = NEW.event_id LOOP
                PERFORM check_r09(r.pool_id);
            END LOOP;
        END IF;
        IF NEW.team_size IS DISTINCT FROM OLD.team_size THEN
            FOR r IN SELECT g.match_id, g.game_number
                     FROM game g JOIN match m ON m.match_id = g.match_id
                     WHERE m.tournament_id = NEW.event_id LOOP
                PERFORM check_r11(r.match_id, r.game_number);
            END LOOP;
        END IF;
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_tournament_at_commit AFTER INSERT OR UPDATE OR DELETE ON tournament
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_tournament_at_commit();

-- phase: rules 7 and 10 when its pool or layout changes
CREATE FUNCTION trg_phase() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    IF (NEW.pool_id, NEW.layout_id) IS DISTINCT FROM (OLD.pool_id, OLD.layout_id) THEN
        FOR r IN SELECT g.match_id, g.game_number
                 FROM game g JOIN match m ON m.match_id = g.match_id
                 WHERE m.tournament_id = NEW.tournament_id AND m.phase_number = NEW.phase_number LOOP
            PERFORM check_r07(r.match_id, r.game_number);
        END LOOP;
        FOR r IN SELECT v.match_id, v.veto_order
                 FROM map_veto v JOIN match m ON m.match_id = v.match_id
                 WHERE m.tournament_id = NEW.tournament_id AND m.phase_number = NEW.phase_number LOOP
            PERFORM check_r10(r.match_id, r.veto_order);
        END LOOP;
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER rules_phase AFTER UPDATE ON phase
    FOR EACH ROW EXECUTE FUNCTION trg_phase();

-- phase at commit: rules 8, 9 and 25
CREATE FUNCTION trg_phase_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_r08_phase(NEW.tournament_id, NEW.phase_number);
    PERFORM check_r09(NEW.pool_id);
    PERFORM check_r25_phase(NEW.tournament_id, NEW.phase_number);
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_phase_at_commit AFTER INSERT OR UPDATE ON phase
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_phase_at_commit();

-- participates_in: rules 26 and 27 for a new entry; rule 2 for a removed one
CREATE FUNCTION trg_participates_in() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_keys_changed boolean := TG_OP <> 'UPDATE'
        OR (NEW.team_id, NEW.tournament_id) IS DISTINCT FROM (OLD.team_id, OLD.tournament_id);
    r record;
BEGIN
    IF TG_OP <> 'DELETE' AND v_keys_changed THEN
        PERFORM check_r26(NEW.team_id, NEW.tournament_id);
        PERFORM check_r27(NEW.tournament_id);
    END IF;
    IF TG_OP <> 'INSERT' AND v_keys_changed THEN
        FOR r IN SELECT c.match_id
                 FROM competes_in c JOIN match m ON m.match_id = c.match_id
                 WHERE c.team_id = OLD.team_id AND m.tournament_id = OLD.tournament_id LOOP
            PERFORM check_r02(r.match_id, OLD.team_id);
        END LOOP;
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER rules_participates_in AFTER INSERT OR UPDATE OR DELETE ON participates_in
    FOR EACH ROW EXECUTE FUNCTION trg_participates_in();

-- participates_in at commit: rule 28 (placements fit the field)
CREATE FUNCTION trg_participates_in_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP <> 'DELETE' THEN
        PERFORM check_r28(NEW.tournament_id);
    END IF;
    IF TG_OP <> 'INSERT' THEN
        PERFORM check_r28(OLD.tournament_id);
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_participates_in_at_commit AFTER INSERT OR UPDATE OR DELETE ON participates_in
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_participates_in_at_commit();

-- registered_in: rule 26 (a registration a participating team still needs)
CREATE FUNCTION trg_registered_in() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT p.tournament_id
             FROM participates_in p JOIN tournament t ON t.event_id = p.tournament_id
             WHERE p.team_id = OLD.team_id
               AND t.league_id = OLD.league_id AND t.season_year = OLD.season_year LOOP
        PERFORM check_r26(OLD.team_id, r.tournament_id);
    END LOOP;
    RETURN NULL;
END $$;
CREATE TRIGGER rules_registered_in AFTER UPDATE OR DELETE ON registered_in
    FOR EACH ROW EXECUTE FUNCTION trg_registered_in();

------------------------------------------------------------------------------
-- Competitive settings
------------------------------------------------------------------------------

-- map at commit: rule 9 (a changed game title)
CREATE FUNCTION trg_map_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT DISTINCT pool_id FROM pool_entry WHERE map_id = NEW.map_id LOOP
        PERFORM check_r09(r.pool_id);
    END LOOP;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_map_at_commit AFTER UPDATE OF game_title ON map
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_map_at_commit();

-- pool_entry: rules 7 and 10 (an entry that games or vetoes used)
CREATE FUNCTION trg_pool_entry() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT g.match_id, g.game_number
             FROM game g
             JOIN match m  ON m.match_id = g.match_id
             JOIN phase ph ON ph.tournament_id = m.tournament_id AND ph.phase_number = m.phase_number
             WHERE ph.pool_id = OLD.pool_id AND g.map_id = OLD.map_id AND g.mode_id = OLD.mode_id LOOP
        PERFORM check_r07(r.match_id, r.game_number);
    END LOOP;
    FOR r IN SELECT v.match_id, v.veto_order
             FROM map_veto v
             JOIN match m  ON m.match_id = v.match_id
             JOIN phase ph ON ph.tournament_id = m.tournament_id AND ph.phase_number = m.phase_number
             WHERE ph.pool_id = OLD.pool_id AND v.map_id = OLD.map_id AND v.mode_id = OLD.mode_id LOOP
        PERFORM check_r10(r.match_id, r.veto_order);
    END LOOP;
    RETURN NULL;
END $$;
CREATE TRIGGER rules_pool_entry AFTER UPDATE OR DELETE ON pool_entry
    FOR EACH ROW EXECUTE FUNCTION trg_pool_entry();

-- pool_entry at commit: rule 9 (one title per pool); rule 8 (the pool still covers layouts)
CREATE FUNCTION trg_pool_entry_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    IF TG_OP <> 'DELETE' THEN
        PERFORM check_r09(NEW.pool_id);
    END IF;
    IF TG_OP <> 'INSERT' THEN
        FOR r IN SELECT tournament_id, phase_number FROM phase WHERE pool_id = OLD.pool_id LOOP
            PERFORM check_r08_phase(r.tournament_id, r.phase_number);
        END LOOP;
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_pool_entry_at_commit AFTER INSERT OR UPDATE OR DELETE ON pool_entry
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_pool_entry_at_commit();

-- series_slot: rule 7 (a slot that games were played under)
CREATE FUNCTION trg_series_slot() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT g.match_id, g.game_number
             FROM game g
             JOIN match m  ON m.match_id = g.match_id
             JOIN phase ph ON ph.tournament_id = m.tournament_id AND ph.phase_number = m.phase_number
             WHERE ph.layout_id = OLD.layout_id AND m.best_of = OLD.best_of
               AND g.game_number = OLD.game_number LOOP
        PERFORM check_r07(r.match_id, r.game_number);
    END LOOP;
    RETURN NULL;
END $$;
CREATE TRIGGER rules_series_slot AFTER UPDATE OR DELETE ON series_slot
    FOR EACH ROW EXECUTE FUNCTION trg_series_slot();

-- series_slot at commit: rule 8 (phases using the layout)
CREATE FUNCTION trg_series_slot_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT tournament_id, phase_number FROM phase
             WHERE layout_id IN (CASE WHEN TG_OP <> 'DELETE' THEN NEW.layout_id END,
                                 CASE WHEN TG_OP <> 'INSERT' THEN OLD.layout_id END) LOOP
        PERFORM check_r08_phase(r.tournament_id, r.phase_number);
    END LOOP;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_series_slot_at_commit AFTER INSERT OR UPDATE OR DELETE ON series_slot
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_series_slot_at_commit();

------------------------------------------------------------------------------
-- Matches and games
------------------------------------------------------------------------------

-- match: rules 3, 4 (length) and 8; and everything judged against its tournament,
-- phase, best_of or date when one of those changes (rules 2, 7, 10, 12, 16, 17)
CREATE FUNCTION trg_match() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_new    boolean := TG_OP = 'INSERT';
    v_moved  boolean := TG_OP = 'UPDATE' AND (NEW.tournament_id, NEW.phase_number)
                                             IS DISTINCT FROM (OLD.tournament_id, OLD.phase_number);
    v_length boolean := TG_OP = 'UPDATE' AND NEW.best_of IS DISTINCT FROM OLD.best_of;
    r record;
BEGIN
    IF v_new OR v_moved
       OR (NEW.winner_to_match_id, NEW.winner_to_slot, NEW.loser_to_match_id, NEW.loser_to_slot)
          IS DISTINCT FROM (OLD.winner_to_match_id, OLD.winner_to_slot, OLD.loser_to_match_id, OLD.loser_to_slot) THEN
        PERFORM check_r03(NEW.match_id);
    END IF;

    IF v_new OR v_moved OR v_length THEN
        PERFORM check_r08_match(NEW.match_id);
        PERFORM check_r04_length(NEW.match_id);
    END IF;

    IF v_moved OR v_length THEN
        FOR r IN SELECT game_number FROM game WHERE match_id = NEW.match_id LOOP
            PERFORM check_r07(NEW.match_id, r.game_number);
        END LOOP;
    END IF;

    IF v_moved THEN
        FOR r IN SELECT team_id FROM competes_in WHERE match_id = NEW.match_id LOOP
            PERFORM check_r02(NEW.match_id, r.team_id);
        END LOOP;
        FOR r IN SELECT veto_order FROM map_veto WHERE match_id = NEW.match_id LOOP
            PERFORM check_r10(NEW.match_id, r.veto_order);
        END LOOP;
    END IF;

    IF v_moved OR (TG_OP = 'UPDATE' AND NEW.scheduled_at IS DISTINCT FROM OLD.scheduled_at) THEN
        FOR r IN SELECT person_id FROM match_player WHERE match_id = NEW.match_id LOOP
            PERFORM check_listed_player(r.person_id, NEW.match_id);
        END LOOP;
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER rules_match AFTER INSERT OR UPDATE ON match
    FOR EACH ROW EXECUTE FUNCTION trg_match();

-- match at commit: rules 1 and 4 (end of series); rule 21 when its result changes
CREATE FUNCTION trg_match_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    PERFORM check_r01(NEW.match_id);
    PERFORM check_r04_end(NEW.match_id);
    IF TG_OP = 'UPDATE' AND NEW.result_type IS DISTINCT FROM OLD.result_type THEN
        FOR r IN SELECT penalty_id FROM penalty WHERE match_id = NEW.match_id LOOP
            PERFORM check_r21(r.penalty_id);
        END LOOP;
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_match_at_commit AFTER INSERT OR UPDATE ON match
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_match_at_commit();

-- match: rule 3, second part (report Section 4.5): "when a match ends, its winner and
-- loser take their to_slot in the next match". This trigger WRITES rather than checks.
-- It runs on every update of a completed match, so a corrected result (resolve_dispute)
-- moves the right teams on, as long as the next match has not started. It does nothing
-- when the teams are already in place, so running it twice changes nothing.
CREATE FUNCTION advance_bracket() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_winner  integer;
    v_loser   integer;
    v_current integer;
    t         record;
BEGIN
    SELECT team_id INTO v_winner FROM v_match_winner WHERE match_id = NEW.match_id;
    IF v_winner IS NULL THEN
        IF NEW.winner_to_match_id IS NOT NULL OR NEW.loser_to_match_id IS NOT NULL THEN
            PERFORM raise_rule(3, format(
                'match %s is completed without a winner, so no team can move on', NEW.match_id));
        END IF;
        RETURN NULL;
    END IF;
    SELECT team_id INTO v_loser FROM competes_in WHERE match_id = NEW.match_id AND team_id <> v_winner;

    -- First pass: empty any target slot that holds the wrong team of this match (a
    -- corrected result). A slot holding some other team means a broken bracket.
    FOR t IN SELECT * FROM (VALUES (NEW.winner_to_match_id, NEW.winner_to_slot, v_winner),
                                   (NEW.loser_to_match_id,  NEW.loser_to_slot,  v_loser))
                          AS x(match_id, slot, team_id)
             WHERE x.match_id IS NOT NULL AND x.team_id IS NOT NULL LOOP
        SELECT team_id INTO v_current FROM competes_in WHERE match_id = t.match_id AND slot = t.slot;
        IF FOUND AND v_current <> t.team_id THEN
            IF v_current NOT IN (v_winner, v_loser) THEN
                PERFORM raise_rule(3, format('slot %s of match %s already holds %s',
                    t.slot, t.match_id, team_label(v_current)));
            END IF;
            IF EXISTS (SELECT 1 FROM match m WHERE m.match_id = t.match_id
                       AND (m.status IN ('live', 'completed') OR m.result_type IS NOT NULL)) THEN
                PERFORM raise_rule(3, format(
                    'match %s has started, so the team that moved into it can no longer change', t.match_id));
            END IF;
            DELETE FROM competes_in WHERE match_id = t.match_id AND slot = t.slot;
        END IF;
    END LOOP;

    -- Second pass: place the winner and the loser.
    FOR t IN SELECT * FROM (VALUES (NEW.winner_to_match_id, NEW.winner_to_slot, v_winner),
                                   (NEW.loser_to_match_id,  NEW.loser_to_slot,  v_loser))
                          AS x(match_id, slot, team_id)
             WHERE x.match_id IS NOT NULL AND x.team_id IS NOT NULL LOOP
        IF NOT EXISTS (SELECT 1 FROM competes_in WHERE match_id = t.match_id AND slot = t.slot) THEN
            INSERT INTO competes_in (match_id, team_id, slot) VALUES (t.match_id, t.team_id, t.slot);
        END IF;
    END LOOP;
    RETURN NULL;
END $$;
CREATE TRIGGER rules_match_advance AFTER UPDATE ON match
    FOR EACH ROW WHEN (NEW.status = 'completed')
    EXECUTE FUNCTION advance_bracket();

-- competes_in: rule 2
CREATE FUNCTION trg_competes_in() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_r02(NEW.match_id, NEW.team_id);
    RETURN NULL;
END $$;
CREATE TRIGGER rules_competes_in AFTER INSERT OR UPDATE ON competes_in
    FOR EACH ROW EXECUTE FUNCTION trg_competes_in();

-- competes_in at commit: rule 1
CREATE FUNCTION trg_competes_in_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP <> 'DELETE' THEN
        PERFORM check_r01(NEW.match_id);
    END IF;
    IF TG_OP <> 'INSERT' THEN
        PERFORM check_r01(OLD.match_id);
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_competes_in_at_commit AFTER INSERT OR UPDATE OR DELETE ON competes_in
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_competes_in_at_commit();

-- game: rules 4 (length), 7, and 13 when its mode changes
CREATE FUNCTION trg_game() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_new   boolean := TG_OP = 'INSERT';
    v_moved boolean := TG_OP = 'UPDATE' AND (NEW.match_id, NEW.game_number)
                                            IS DISTINCT FROM (OLD.match_id, OLD.game_number);
BEGIN
    IF v_new OR v_moved THEN
        PERFORM check_r04_length(NEW.match_id);
    END IF;
    IF v_new OR v_moved OR (NEW.map_id, NEW.mode_id) IS DISTINCT FROM (OLD.map_id, OLD.mode_id) THEN
        PERFORM check_r07(NEW.match_id, NEW.game_number);
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.mode_id IS DISTINCT FROM OLD.mode_id THEN
        PERFORM check_r13(NEW.match_id, NEW.game_number);
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER rules_game AFTER INSERT OR UPDATE ON game
    FOR EACH ROW EXECUTE FUNCTION trg_game();

-- game at commit: rules 4 (end of series) and 6; rule 21 when its result changes
CREATE FUNCTION trg_game_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    PERFORM check_r04_end(NEW.match_id);
    PERFORM check_r06(NEW.match_id, NEW.game_number);
    IF TG_OP = 'UPDATE' AND NEW.result_type IS DISTINCT FROM OLD.result_type THEN
        FOR r IN SELECT penalty_id FROM penalty
                 WHERE match_id = NEW.match_id AND game_number = NEW.game_number LOOP
            PERFORM check_r21(r.penalty_id);
        END LOOP;
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_game_at_commit AFTER INSERT OR UPDATE ON game
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_game_at_commit();

-- team_result at commit: rules 4 (end of series), 6 and 11
CREATE FUNCTION trg_team_result_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP <> 'DELETE' THEN
        PERFORM check_r04_end(NEW.match_id);
        PERFORM check_r06(NEW.match_id, NEW.game_number);
        PERFORM check_r11(NEW.match_id, NEW.game_number);
    END IF;
    IF TG_OP <> 'INSERT' THEN
        PERFORM check_r04_end(OLD.match_id);
        PERFORM check_r06(OLD.match_id, OLD.game_number);
        PERFORM check_r11(OLD.match_id, OLD.game_number);
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_team_result_at_commit AFTER INSERT OR UPDATE OR DELETE ON team_result
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_team_result_at_commit();

-- map_veto: rule 10
CREATE FUNCTION trg_map_veto() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_r10(NEW.match_id, NEW.veto_order);
    RETURN NULL;
END $$;
CREATE TRIGGER rules_map_veto AFTER INSERT OR UPDATE ON map_veto
    FOR EACH ROW EXECUTE FUNCTION trg_map_veto();

------------------------------------------------------------------------------
-- Player stats
------------------------------------------------------------------------------

-- match_player: rules 12, 16, 17
CREATE FUNCTION trg_match_player() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_listed_player(NEW.person_id, NEW.match_id);
    RETURN NULL;
END $$;
CREATE TRIGGER rules_match_player AFTER INSERT OR UPDATE ON match_player
    FOR EACH ROW EXECUTE FUNCTION trg_match_player();

-- match_player at commit: rule 11 (a player moved to the other team, or removed)
CREATE FUNCTION trg_match_player_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT match_id, game_number FROM game WHERE match_id = OLD.match_id LOOP
        PERFORM check_r11(r.match_id, r.game_number);
    END LOOP;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_match_player_at_commit AFTER UPDATE OR DELETE ON match_player
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_match_player_at_commit();

-- player_game_stats at commit: rule 11 and T4
CREATE FUNCTION trg_player_game_stats_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP <> 'DELETE' THEN
        PERFORM check_r11(NEW.match_id, NEW.game_number);
        PERFORM check_t4(NEW.person_id, NEW.match_id, NEW.game_number);
    END IF;
    IF TG_OP <> 'INSERT' THEN
        PERFORM check_r11(OLD.match_id, OLD.game_number);
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_player_game_stats_at_commit AFTER INSERT OR UPDATE OR DELETE ON player_game_stats
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_player_game_stats_at_commit();

-- The four mode tables: rule 13 at once, T4 at commit
CREATE FUNCTION trg_mode_stats() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_r13(NEW.match_id, NEW.game_number);
    RETURN NULL;
END $$;

CREATE FUNCTION trg_mode_stats_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP <> 'DELETE' THEN
        PERFORM check_t4(NEW.person_id, NEW.match_id, NEW.game_number);
    END IF;
    IF TG_OP <> 'INSERT' THEN
        PERFORM check_t4(OLD.person_id, OLD.match_id, OLD.game_number);
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER rules_hardpoint_stats AFTER INSERT OR UPDATE ON hardpoint_stats
    FOR EACH ROW EXECUTE FUNCTION trg_mode_stats();
CREATE TRIGGER rules_snd_stats AFTER INSERT OR UPDATE ON snd_stats
    FOR EACH ROW EXECUTE FUNCTION trg_mode_stats();
CREATE TRIGGER rules_control_stats AFTER INSERT OR UPDATE ON control_stats
    FOR EACH ROW EXECUTE FUNCTION trg_mode_stats();
CREATE TRIGGER rules_overload_stats AFTER INSERT OR UPDATE ON overload_stats
    FOR EACH ROW EXECUTE FUNCTION trg_mode_stats();

CREATE CONSTRAINT TRIGGER rules_hardpoint_stats_at_commit AFTER INSERT OR UPDATE OR DELETE ON hardpoint_stats
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_mode_stats_at_commit();
CREATE CONSTRAINT TRIGGER rules_snd_stats_at_commit AFTER INSERT OR UPDATE OR DELETE ON snd_stats
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_mode_stats_at_commit();
CREATE CONSTRAINT TRIGGER rules_control_stats_at_commit AFTER INSERT OR UPDATE OR DELETE ON control_stats
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_mode_stats_at_commit();
CREATE CONSTRAINT TRIGGER rules_overload_stats_at_commit AFTER INSERT OR UPDATE OR DELETE ON overload_stats
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_mode_stats_at_commit();

------------------------------------------------------------------------------
-- Operations
------------------------------------------------------------------------------

-- penalty: rule 20 at once, rule 21 at commit
CREATE FUNCTION trg_penalty() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_r20(NEW.penalty_id);
    RETURN NULL;
END $$;
CREATE TRIGGER rules_penalty AFTER INSERT OR UPDATE ON penalty
    FOR EACH ROW EXECUTE FUNCTION trg_penalty();

CREATE FUNCTION trg_penalty_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM check_r21(NEW.penalty_id);
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER rules_penalty_at_commit AFTER INSERT OR UPDATE ON penalty
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_penalty_at_commit();
