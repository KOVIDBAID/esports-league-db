import json

import streamlit as st
from db import query, team_name_on

st.title("Bracket")

if "flash" in st.session_state:
    st.success(st.session_state.pop("flash"))

tournaments = query(
    """SELECT e.event_id, e.event_name
       FROM tournament t JOIN event e ON e.event_id = t.event_id
       ORDER BY e.event_id"""
)
# The newest tournament first: on demo day that is Major 2
name = st.selectbox("Tournament", tournaments.event_name, index=len(tournaments) - 1)
tid = int(tournaments.event_id[tournaments.event_name == name].iloc[0])

# Team names as they were on each match's date, so old results keep old names after a rebrand
matches = query(
    f"""SELECT m.match_id, ph.phase_name AS phase, m.round_name AS round, m.bracket_side AS side,
              m.status,
              {team_name_on('c1.team_id', 'match_date(m.match_id)')} AS team_1,
              {team_name_on('c2.team_id', 'match_date(m.match_id)')} AS team_2,
              COALESCE(s1.games_won, 0)::int AS score_1, COALESCE(s2.games_won, 0)::int AS score_2,
              {team_name_on('mw.team_id', 'match_date(m.match_id)')} AS winner,
              COALESCE(m.winner_to_match_id::text, '-') AS winner_to,
              COALESCE(m.loser_to_match_id::text, '-') AS loser_to
       FROM match m
       JOIN phase ph ON ph.tournament_id = m.tournament_id AND ph.phase_number = m.phase_number
       LEFT JOIN competes_in c1 ON c1.match_id = m.match_id AND c1.slot = 1
       LEFT JOIN competes_in c2 ON c2.match_id = m.match_id AND c2.slot = 2
       LEFT JOIN v_series_score s1 ON s1.match_id = m.match_id AND s1.team_id = c1.team_id
       LEFT JOIN v_series_score s2 ON s2.match_id = m.match_id AND s2.team_id = c2.team_id
       LEFT JOIN v_match_winner mw ON mw.match_id = m.match_id
       WHERE m.tournament_id = %s
       ORDER BY m.match_id""",
    (tid,),
)

if matches.empty:
    st.info("No matches yet for this tournament.")
    phase = query(
        """SELECT ph.phase_number, ph.phase_name,
                  COALESCE(ph.start_date, t.start_date, current_date) AS first_day
           FROM phase ph JOIN tournament t ON t.event_id = ph.tournament_id
           WHERE ph.tournament_id = %s ORDER BY ph.phase_number LIMIT 1""",
        (tid,),
    ).iloc[0]

    # Teams that may enter: active, registered for the tournament's season (rule 26), and with
    # a full roster on the phase's first day. Seeded by season points.
    candidates = query(
        """SELECT n.team_id, n.team_name, COALESCE(sp.points, 0)::int AS season_points
           FROM v_team_current_name n
           JOIN team tm ON tm.team_id = n.team_id AND tm.status = 'active'
           JOIN tournament t ON t.event_id = %(tid)s
           LEFT JOIN v_team_season_points sp ON sp.team_id = n.team_id
                AND sp.league_id = t.league_id AND sp.season_year = t.season_year
           WHERE (t.league_id IS NULL OR EXISTS (
                     SELECT 1 FROM registered_in r WHERE r.team_id = n.team_id
                     AND r.league_id = t.league_id AND r.season_year = t.season_year))
             AND (SELECT count(*) FROM roster r WHERE r.team_id = n.team_id
                  AND r.roster_role IN ('starter', 'substitute', 'two-way')
                  AND r.start_date <= %(day)s AND (r.end_date IS NULL OR %(day)s < r.end_date)) >= t.team_size
           ORDER BY season_points DESC, n.team_name""",
        {"tid": tid, "day": phase.first_day},
    )

    st.subheader(f"Set up {phase.phase_name}")
    st.caption(f"Teams registered for the season with a full roster on {phase.first_day}, "
               "seeded by season points. The bracket needs 2, 4, 8 or 16 teams.")
    picked = st.multiselect("Teams", candidates.team_name, default=list(candidates.team_name[:8]),
                            key=f"seeds_{tid}")
    seeds = candidates[candidates.team_name.isin(picked)].reset_index(drop=True)
    seeds.insert(0, "seed", range(1, len(seeds) + 1))
    st.dataframe(seeds[["seed", "team_name", "season_points"]], hide_index=True)

    if st.button(f"Build the bracket ({len(seeds)} teams)"):
        res = query(
            "SELECT * FROM setup_tournament_phase(p_tournament_id => %s, p_phase_number => %s, p_teams => %s::jsonb)",
            (tid, int(phase.phase_number), json.dumps([int(t) for t in seeds.team_id])),
        )
        if res.ok[0]:
            st.session_state["flash"] = res.message[0]
            st.rerun()
        else:
            st.error(res.message[0])
else:
    st.caption(f"{len(matches)} matches. winner_to and loser_to show which match each result feeds. "
               "Names are as they were on the day of each match.")
    st.dataframe(matches, hide_index=True)
