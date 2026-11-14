import streamlit as st
from db import query

st.title("Standings")
df = query("""SELECT n.team_name, s.points FROM v_team_season_points s
              JOIN v_team_current_name n USING (team_id) ORDER BY points DESC""")
st.dataframe(df, hide_index=True)
