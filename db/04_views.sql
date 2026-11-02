-- 04_views.sql
-- The 16 views of Section 4.6 of the report. Every derived attribute and derived
-- value is computed from stored data, so it can never go stale.

------------------------------------------------------------------------------
-- People and teams
------------------------------------------------------------------------------

-- Person.age()
CREATE VIEW v_person_age AS
SELECT person_id,
       extract(year FROM age(current_date, date_of_birth))::int AS age
FROM person;

-- Team.current_name(): the identity with an empty valid_to
CREATE VIEW v_team_current_name AS
SELECT team_id, team_name, abbreviation, home_city, org_id, valid_from
FROM team_identity
WHERE valid_to IS NULL;

-- Roster.is_current(): stints with an empty end_date
CREATE VIEW v_roster_current AS
SELECT person_id, team_id, start_date, roster_role, join_type
FROM roster
WHERE end_date IS NULL;

-- Coach.coaching_since(): earliest head or assistant coach stint
CREATE VIEW v_coaching_since AS
SELECT person_id, min(start_date) AS coaching_since
FROM roster
WHERE roster_role IN ('head coach', 'assistant coach')
GROUP BY person_id;

-- Previous team of a stint: the same person's latest non-two-way stint
-- ending on or before this stint's start_date
CREATE VIEW v_previous_team AS
SELECT r.person_id, r.team_id, r.start_date,
       p.team_id    AS previous_team_id,
       p.start_date AS previous_start_date,
       p.end_date   AS previous_end_date
FROM roster r
LEFT JOIN LATERAL (
    SELECT q.team_id, q.start_date, q.end_date
    FROM roster q
    WHERE q.person_id = r.person_id
      AND q.roster_role <> 'two-way'
      AND q.end_date IS NOT NULL
      AND q.end_date <= r.start_date
    ORDER BY q.end_date DESC, q.start_date DESC
    LIMIT 1
) p ON true;

------------------------------------------------------------------------------
-- Games and matches
------------------------------------------------------------------------------

-- Game.winner(): the awarded team for a forfeited game,
-- otherwise the team with the strictly higher score
CREATE VIEW v_game_winner AS
SELECT g.match_id, g.game_number, g.awarded_team_id AS team_id, 'forfeit'::text AS decided_by
FROM game g
WHERE g.result_type = 'forfeit'
UNION ALL
SELECT tr.match_id, tr.game_number, tr.team_id, 'score'::text
FROM team_result tr
JOIN game g ON g.match_id = tr.match_id AND g.game_number = tr.game_number
WHERE g.result_type = 'played'
  AND EXISTS (SELECT 1 FROM team_result o
              WHERE o.match_id = tr.match_id AND o.game_number = tr.game_number
                AND o.team_id <> tr.team_id)
  AND tr.score > ALL (SELECT o.score FROM team_result o
                      WHERE o.match_id = tr.match_id AND o.game_number = tr.game_number
                        AND o.team_id <> tr.team_id);

-- Series score: games won by each team in each match
CREATE VIEW v_series_score AS
SELECT c.match_id, c.team_id, count(w.game_number)::int AS games_won
FROM competes_in c
LEFT JOIN v_game_winner w ON w.match_id = c.match_id AND w.team_id = c.team_id
GROUP BY c.match_id, c.team_id;

-- Match.winner(): the awarded team for a forfeited match,
-- otherwise the team that won more than half of best_of
CREATE VIEW v_match_winner AS
SELECT m.match_id, m.awarded_team_id AS team_id, 'forfeit'::text AS decided_by
FROM match m
WHERE m.result_type = 'forfeit'
UNION ALL
SELECT s.match_id, s.team_id, 'games'::text
FROM v_series_score s
JOIN match m ON m.match_id = s.match_id
WHERE COALESCE(m.result_type, '') <> 'forfeit'
  AND s.games_won > m.best_of / 2;

-- Who picked a game's map: the MapVeto pick with the game's map and mode;
-- no row means the map was the decider
CREATE VIEW v_map_picked_by AS
SELECT g.match_id, g.game_number, v.team_id
FROM game g
JOIN map_veto v ON v.match_id = g.match_id
               AND v.map_id = g.map_id
               AND v.mode_id = g.mode_id
               AND v.action = 'pick';

-- PlayerGameStats.kd_ratio(): kills / deaths, equal to kills when deaths is 0
CREATE VIEW v_player_kd AS
SELECT person_id, match_id, game_number, kills, deaths,
       CASE WHEN deaths = 0 THEN kills::numeric
            ELSE round(kills::numeric / deaths, 2) END AS kd_ratio
FROM player_game_stats;

------------------------------------------------------------------------------
-- Prizes and points
------------------------------------------------------------------------------

-- Tournament.prize_pool(): each band's prize_amount times the placements in it
CREATE VIEW v_tournament_prize_pool AS
SELECT t.event_id AS tournament_id,
       COALESCE(sum(r.prize_amount * (r.placement_to - r.placement_from + 1)), 0) AS prize_pool
FROM tournament t
LEFT JOIN placement_reward r ON r.tournament_id = t.event_id
GROUP BY t.event_id;

-- Prize and placement points won by a team: the band containing its final_placement
CREATE VIEW v_team_prize AS
SELECT p.tournament_id, p.team_id, p.final_placement,
       r.prize_amount AS prize,
       r.points       AS placement_points
FROM participates_in p
JOIN placement_reward r ON r.tournament_id = p.tournament_id
                       AND p.final_placement BETWEEN r.placement_from AND r.placement_to;

-- Team season leaderboard (leagues whose points_awarded_to is 'team'):
-- placement points plus series wins times the phase's points_per_win,
-- over tournaments in that season's stages (rule 24: points only in league seasons).
-- Forfeit wins count as wins.
CREATE VIEW v_team_season_points AS
WITH season_tournament AS (
    SELECT t.event_id AS tournament_id, t.league_id, t.season_year
    FROM tournament t
    JOIN league l ON l.event_id = t.league_id
    WHERE l.points_awarded_to = 'team'
),
earned AS (
    SELECT st.league_id, st.season_year, tp.team_id, tp.placement_points AS points
    FROM season_tournament st
    JOIN v_team_prize tp ON tp.tournament_id = st.tournament_id
    UNION ALL
    SELECT st.league_id, st.season_year, w.team_id, ph.points_per_win
    FROM season_tournament st
    JOIN match m  ON m.tournament_id = st.tournament_id
    JOIN phase ph ON ph.tournament_id = m.tournament_id AND ph.phase_number = m.phase_number
    JOIN v_match_winner w ON w.match_id = m.match_id
)
SELECT league_id, season_year, team_id, sum(points)::int AS points
FROM earned
GROUP BY league_id, season_year, team_id;

-- Player season leaderboard (leagues whose points_awarded_to is 'player'):
-- each tournament's placement points, credited to every player with a player-role
-- stint on that team at the tournament's start date
CREATE VIEW v_player_season_points AS
SELECT t.league_id, t.season_year, r.person_id, sum(tp.placement_points)::int AS points
FROM tournament t
JOIN league l       ON l.event_id = t.league_id AND l.points_awarded_to = 'player'
JOIN v_team_prize tp ON tp.tournament_id = t.event_id
JOIN roster r       ON r.team_id = tp.team_id
                   AND r.roster_role IN ('starter', 'substitute', 'two-way')
                   AND r.start_date <= t.start_date
                   AND (r.end_date IS NULL OR r.end_date > t.start_date)
GROUP BY t.league_id, t.season_year, r.person_id;

------------------------------------------------------------------------------
-- Season statistics
------------------------------------------------------------------------------

-- Team season stats: matches and games won, overall and per mode
CREATE VIEW v_team_season_stats AS
WITH season_match AS (
    SELECT m.match_id, t.league_id, t.season_year
    FROM match m
    JOIN tournament t ON t.event_id = m.tournament_id
    WHERE t.league_id IS NOT NULL AND m.status = 'completed'
),
matches AS (
    SELECT sm.league_id, sm.season_year, c.team_id,
           count(*)::int                                     AS matches_played,
           count(*) FILTER (WHERE mw.team_id = c.team_id)::int AS matches_won
    FROM season_match sm
    JOIN competes_in c ON c.match_id = sm.match_id
    LEFT JOIN v_match_winner mw ON mw.match_id = sm.match_id
    GROUP BY sm.league_id, sm.season_year, c.team_id
),
games AS (
    SELECT sm.league_id, sm.season_year, c.team_id, gm.abbreviation AS mode,
           (w.team_id = c.team_id) AS won
    FROM season_match sm
    JOIN competes_in c   ON c.match_id = sm.match_id
    JOIN game g          ON g.match_id = sm.match_id
    JOIN game_mode gm    ON gm.mode_id = g.mode_id
    JOIN v_game_winner w ON w.match_id = g.match_id AND w.game_number = g.game_number
)
SELECT m.league_id, m.season_year, m.team_id,
       m.matches_played, m.matches_won,
       round(m.matches_won::numeric / NULLIF(m.matches_played, 0), 3) AS match_win_rate,
       count(g.*)::int                                   AS games_played,
       count(*) FILTER (WHERE g.won)::int                AS games_won,
       count(*) FILTER (WHERE g.mode = 'HP')::int        AS hp_played,
       count(*) FILTER (WHERE g.mode = 'HP' AND g.won)::int  AS hp_won,
       count(*) FILTER (WHERE g.mode = 'S&D')::int       AS snd_played,
       count(*) FILTER (WHERE g.mode = 'S&D' AND g.won)::int AS snd_won,
       count(*) FILTER (WHERE g.mode = 'OVR')::int       AS ovr_played,
       count(*) FILTER (WHERE g.mode = 'OVR' AND g.won)::int AS ovr_won,
       count(*) FILTER (WHERE g.mode = 'CTL')::int       AS ctl_played,
       count(*) FILTER (WHERE g.mode = 'CTL' AND g.won)::int AS ctl_won
FROM matches m
LEFT JOIN games g ON g.league_id = m.league_id AND g.season_year = m.season_year AND g.team_id = m.team_id
GROUP BY m.league_id, m.season_year, m.team_id, m.matches_played, m.matches_won;

-- Player season stats: totals over PlayerGameStats and its four specializations
CREATE VIEW v_player_season_stats AS
SELECT t.league_id, t.season_year, s.person_id,
       count(*)::int       AS games,
       sum(s.kills)::int   AS kills,
       sum(s.deaths)::int  AS deaths,
       sum(s.assists)::int AS assists,
       sum(s.damage)::int  AS damage,
       CASE WHEN sum(s.deaths) = 0 THEN sum(s.kills)::numeric
            ELSE round(sum(s.kills)::numeric / sum(s.deaths), 2) END AS kd_ratio,
       COALESCE(sum(h.hill_time_seconds), 0)::int AS hill_time_seconds,
       COALESCE(sum(h.captures), 0)::int          AS hp_captures,
       COALESCE(sum(sd.first_bloods), 0)::int     AS first_bloods,
       COALESCE(sum(sd.plants), 0)::int           AS plants,
       COALESCE(sum(sd.defuses), 0)::int          AS defuses,
       COALESCE(sum(o.overloads_scored), 0)::int  AS overloads_scored,
       COALESCE(sum(ct.tiers_captured), 0)::int   AS tiers_captured
FROM player_game_stats s
JOIN match m      ON m.match_id = s.match_id
JOIN tournament t ON t.event_id = m.tournament_id AND t.league_id IS NOT NULL
LEFT JOIN hardpoint_stats h ON (h.person_id, h.match_id, h.game_number) = (s.person_id, s.match_id, s.game_number)
LEFT JOIN snd_stats sd      ON (sd.person_id, sd.match_id, sd.game_number) = (s.person_id, s.match_id, s.game_number)
LEFT JOIN overload_stats o  ON (o.person_id, o.match_id, o.game_number) = (s.person_id, s.match_id, s.game_number)
LEFT JOIN control_stats ct  ON (ct.person_id, ct.match_id, ct.game_number) = (s.person_id, s.match_id, s.game_number)
GROUP BY t.league_id, t.season_year, s.person_id;
