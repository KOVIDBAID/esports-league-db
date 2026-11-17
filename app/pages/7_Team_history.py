import streamlit as st
from db import query, team_name_on

st.title("Team history")
st.caption("A rebrand or a transfer adds history; it never rewrites it. Old results keep the "
           "name the team played under, and old stints keep the team the player played for.")

teams = query("SELECT team_id, team_name FROM v_team_current_name ORDER BY team_name")
name = st.selectbox("Team", teams.team_name, key="th_team")
tid = int(teams.team_id[teams.team_name == name].iloc[0])

st.subheader("Names")
st.dataframe(query(
    """SELECT ti.team_name, ti.abbreviation, ti.home_city, o.org_name AS owner,
              ti.valid_from, ti.valid_to
       FROM team_identity ti LEFT JOIN organization o ON o.org_id = ti.org_id
       WHERE ti.team_id = %s ORDER BY ti.valid_from""",
    (tid,),
), hide_index=True)

st.subheader("Results, under the name the team had that day")
results = query(
    f"""SELECT match_date(m.match_id) AS played_on, e.event_name AS tournament, m.round_name AS round,
              {team_name_on('c.team_id', 'match_date(m.match_id)')} AS played_as,
              {team_name_on('o.team_id', 'match_date(m.match_id)')} AS opponent,
              COALESCE(s.games_won, 0) || '-' || COALESCE(so.games_won, 0) AS score,
              CASE WHEN w.team_id = c.team_id THEN 'won'
                   WHEN w.team_id IS NOT NULL THEN 'lost' ELSE m.status END AS result
       FROM competes_in c
       JOIN match m ON m.match_id = c.match_id
       JOIN event e ON e.event_id = m.tournament_id
       LEFT JOIN competes_in o ON o.match_id = c.match_id AND o.team_id <> c.team_id
       LEFT JOIN v_series_score s ON s.match_id = m.match_id AND s.team_id = c.team_id
       LEFT JOIN v_series_score so ON so.match_id = m.match_id AND so.team_id = o.team_id
       LEFT JOIN v_match_winner w ON w.match_id = m.match_id
       WHERE c.team_id = %s
       ORDER BY played_on DESC, m.match_id DESC""",
    (tid,),
)
if results.empty:
    st.info("No matches yet.")
else:
    st.dataframe(results, hide_index=True)

st.subheader("Players")
st.dataframe(query(
    """SELECT p.gamertag, r.roster_role AS role, r.start_date, r.end_date, r.end_reason,
              r.join_type, r.transfer_fee
       FROM roster r JOIN person p ON p.person_id = r.person_id
       WHERE r.team_id = %s ORDER BY r.end_date IS NOT NULL, r.start_date, p.gamertag""",
    (tid,),
), hide_index=True)
