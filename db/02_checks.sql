-- 02_checks.sql
-- Domain, date and range checks (report Section 4.2, "Domain and date checks"),
-- and the EXCLUDE constraints that keep periods from overlapping.
--
-- Coded attributes take only the values listed in Section 2 of the report.
-- end_reason and result_type stay NULL until the stint, match or game ends; a CHECK
-- with IN (...) passes for NULL, which is what we want for those columns.

------------------------------------------------------------------------------
-- Coded values
------------------------------------------------------------------------------

ALTER TABLE organization ADD CONSTRAINT organization_org_type_check
    CHECK (org_type IN ('publisher', 'tournament organizer', 'esports organization'));

ALTER TABLE player ADD CONSTRAINT player_primary_role_check
    CHECK (primary_role IN ('AR', 'SMG', 'flex'));

ALTER TABLE official ADD CONSTRAINT official_type_check
    CHECK (official_type IN ('referee', 'league admin', 'tournament admin'));

ALTER TABLE team ADD CONSTRAINT team_status_check
    CHECK (status IN ('active', 'disbanded'));

ALTER TABLE roster
    ADD CONSTRAINT roster_role_check CHECK (roster_role IN (
        'starter', 'substitute', 'two-way', 'head coach', 'assistant coach', 'team manager')),
    ADD CONSTRAINT roster_join_type_check CHECK (join_type IN ('signing', 'trade', 'loan', 'promotion')),
    ADD CONSTRAINT roster_end_reason_check CHECK (end_reason IN (
        'released', 'transferred', 'loan ended', 'contract expired', 'retired', 'team disbanded')),
    ADD CONSTRAINT roster_transfer_fee_check CHECK (transfer_fee >= 0);

ALTER TABLE event ADD CONSTRAINT event_tier_check
    CHECK (tier IN ('S', 'A', 'B', 'C'));

ALTER TABLE hosted_by ADD CONSTRAINT hosted_by_host_role_check
    CHECK (host_role IN ('organizer', 'host team', 'partner'));

ALTER TABLE league
    ADD CONSTRAINT league_competition_level_check CHECK (competition_level IN ('professional', 'amateur')),
    ADD CONSTRAINT league_points_awarded_to_check CHECK (points_awarded_to IN ('team', 'player')),
    ADD CONSTRAINT league_min_age_check CHECK (min_age > 0);

ALTER TABLE tournament
    ADD CONSTRAINT tournament_type_check CHECK (tournament_type IN (
        'major', 'minor', 'championship', 'open', 'cup', 'qualifier', 'invitational')),
    ADD CONSTRAINT tournament_max_teams_check CHECK (max_teams >= 2);

ALTER TABLE match
    ADD CONSTRAINT match_bracket_side_check CHECK (bracket_side IN ('winners', 'elimination', 'grand final')),
    ADD CONSTRAINT match_status_check CHECK (status IN ('scheduled', 'live', 'completed', 'cancelled')),
    ADD CONSTRAINT match_result_type_check CHECK (result_type IN ('played', 'forfeit'));

ALTER TABLE officiates ADD CONSTRAINT officiates_duty_check
    CHECK (duty IN ('referee', 'admin'));

ALTER TABLE game
    ADD CONSTRAINT game_status_check CHECK (status IN ('scheduled', 'live', 'completed')),
    ADD CONSTRAINT game_result_type_check CHECK (result_type IN ('played', 'forfeit'));

ALTER TABLE map_veto ADD CONSTRAINT map_veto_action_check
    CHECK (action IN ('pick', 'ban'));

ALTER TABLE dispute ADD CONSTRAINT dispute_status_check
    CHECK (status IN ('open', 'under review', 'resolved', 'rejected'));

ALTER TABLE penalty ADD CONSTRAINT penalty_type_check
    CHECK (penalty_type IN ('warning', 'round loss', 'game forfeit', 'match forfeit',
                            'fine', 'suspension', 'ban', 'license termination'));

------------------------------------------------------------------------------
-- Dates, amounts and counts (rule 29: every period is ordered)
------------------------------------------------------------------------------

ALTER TABLE season     ADD CONSTRAINT season_dates_check     CHECK (end_date >= start_date);
ALTER TABLE stage      ADD CONSTRAINT stage_dates_check      CHECK (end_date >= start_date);
ALTER TABLE tournament ADD CONSTRAINT tournament_dates_check CHECK (end_date >= start_date);
ALTER TABLE phase
    ADD CONSTRAINT phase_dates_check CHECK (end_date >= start_date),
    ADD CONSTRAINT phase_points_per_win_check CHECK (points_per_win >= 0);

ALTER TABLE venue ADD CONSTRAINT venue_capacity_check CHECK (capacity > 0);

ALTER TABLE placement_reward
    ADD CONSTRAINT placement_reward_points_check CHECK (points >= 0),
    ADD CONSTRAINT placement_reward_prize_check  CHECK (prize_amount >= 0);

ALTER TABLE participates_in ADD CONSTRAINT participates_in_placement_check
    CHECK (final_placement >= 1);                                   -- part of rule 28

ALTER TABLE game        ADD CONSTRAINT game_duration_check  CHECK (duration_seconds >= 0);
ALTER TABLE team_result ADD CONSTRAINT team_result_score_check CHECK (score >= 0);
ALTER TABLE penalty     ADD CONSTRAINT penalty_fine_check   CHECK (fine_amount >= 0);

ALTER TABLE hardpoint_stats ADD CONSTRAINT hardpoint_stats_counts_check
    CHECK (hill_time_seconds >= 0 AND contested_time_seconds >= 0 AND captures >= 0);
ALTER TABLE snd_stats ADD CONSTRAINT snd_stats_counts_check
    CHECK (first_bloods >= 0 AND plants >= 0 AND defuses >= 0);
ALTER TABLE control_stats ADD CONSTRAINT control_stats_counts_check
    CHECK (tiers_captured >= 0 AND ticks >= 0);
ALTER TABLE overload_stats ADD CONSTRAINT overload_stats_counts_check
    CHECK (overloads_scored >= 0 AND device_pickups >= 0 AND carry_time_seconds >= 0);

------------------------------------------------------------------------------
-- Periods that must not overlap
-- Ranges are half-open, [start, end): a stint ending on 1 May and the next one
-- starting on 1 May do not overlap. A NULL end means "still open".
------------------------------------------------------------------------------

-- Rule 14 (part): two stints of one person with the same team cannot overlap.
-- The two-way exception between different teams is a trigger (Phase 3).
ALTER TABLE roster ADD CONSTRAINT roster_no_overlap_r14
    EXCLUDE USING gist (
        person_id WITH =,
        team_id WITH =,
        daterange(start_date, end_date, '[)') WITH &&);

-- Rule 18: a team's TeamIdentity periods cannot overlap.
ALTER TABLE team_identity ADD CONSTRAINT team_identity_no_overlap_r18
    EXCLUDE USING gist (
        team_id WITH =,
        daterange(valid_from, valid_to, '[)') WITH &&);

-- Rule 24 (part): PlacementReward bands in one tournament cannot overlap.
-- Bands are inclusive at both ends: 5th to 6th is [5, 6].
ALTER TABLE placement_reward ADD CONSTRAINT placement_reward_no_overlap_r24
    EXCLUDE USING gist (
        tournament_id WITH =,
        int4range(placement_from, placement_to, '[]') WITH &&);
