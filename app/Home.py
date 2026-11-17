import streamlit as st
from db import query

st.set_page_config(page_title="CoD League Operations", layout="wide")
st.title("Esports League and Tournament Operations")
counts = query("SELECT (SELECT count(*) FROM team) teams, (SELECT count(*) FROM match) matches")
st.write(f"Connected: {counts.teams[0]} teams, {counts.matches[0]} matches.")
