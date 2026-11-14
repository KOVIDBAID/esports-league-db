import streamlit as st
from db import query

st.title("Operations: rebrand a team")
team_id = st.number_input("Team id", min_value=1, value=4)
start = st.date_input("New identity starts")
name = st.text_input("New name", "Test Name")
if st.button("Run"):
    res = query("SELECT * FROM rebrand_team(p_team_id => %s, p_from => %s, p_name => %s)",
                (team_id, start, name))
    (st.success if res.ok[0] else st.error)(res.message[0])
    st.json(res.iloc[0].to_dict(), expanded=False)
