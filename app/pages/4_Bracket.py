import json

import streamlit as st
from db import query

st.title("Bracket")

if "flash" in st.session_state:
    st.success(st.session_state.pop("flash"))

tournaments = query(
    """SELECT e.event_id, e.event_name
       FROM tournament t JOIN event e ON e.event_id = t.event_id
       ORDER BY e.event_id"""
)
name = st.selectbox("Tournament", tournaments.event_name)
tid = int(tournaments.event_id[tournaments.event_name == name].iloc[0])

matches = query(
    """SELECT m.match_id, ph.phase_name AS phase, m.round_name AS round, m.bracket_side AS side,
              m.status, t1.team_name AS team_1, t2.team_name AS team_2,
              COALESCE(s1.games_won, 0)::int AS score_1, COALESCE(s2.games_won, 0)::int AS score_2, w.team_name AS winner,
              COALESCE(m.winner_to_match_id::text, '-') AS winner_to,
              COALESCE(m.loser_to_match_id::text, '-') AS loser_to
       FROM match m
       JOIN phase ph ON ph.tournament_id = m.tournament_id AND ph.phase_number = m.phase_number
       LEFT JOIN competes_in c1 ON c1.match_id = m.match_id AND c1.slot = 1
       LEFT JOIN competes_in c2 ON c2.match_id = m.match_id AND c2.slot = 2
       LEFT JOIN v_team_current_name t1 ON t1.team_id = c1.team_id
       LEFT JOIN v_team_current_name t2 ON t2.team_id = c2.team_id
       LEFT JOIN v_series_score s1 ON s1.match_id = m.match_id AND s1.team_id = c1.team_id
       LEFT JOIN v_series_score s2 ON s2.match_id = m.match_id AND s2.team_id = c2.team_id
       LEFT JOIN v_match_winner mw ON mw.match_id = m.match_id
       LEFT JOIN v_team_current_name w ON w.team_id = mw.team_id
       WHERE m.tournament_id = %s
       ORDER BY m.match_id""",
    (tid,),
)

if matches.empty:
    st.info("No matches yet for this tournament.")
    if st.button("Build the playoff bracket (8 teams with a full roster)"):
        phase_no = int(query("SELECT min(phase_number) AS p FROM phase WHERE tournament_id = %s", (tid,)).p[0])
        full = query(
            """SELECT team_id FROM v_roster_current
               WHERE roster_role IN ('starter', 'substitute', 'two-way')
               GROUP BY team_id HAVING count(*) >= 4 ORDER BY team_id LIMIT 8"""
        )
        res = query(
            "SELECT * FROM setup_tournament_phase(p_tournament_id => %s, p_phase_number => %s, p_teams => %s::jsonb)",
            (tid, phase_no, json.dumps([int(t) for t in full.team_id])),
        )
        if res.ok[0]:
            st.session_state["flash"] = res.message[0]
            st.rerun()
        else:
            st.error(res.message[0])
else:
    st.caption(f"{len(matches)} matches. winner_to and loser_to show which match each result feeds.")
    st.dataframe(matches, hide_index=True)