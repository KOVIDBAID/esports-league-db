import streamlit as st
from db import query

st.set_page_config(page_title="CoD League Operations", layout="wide")
st.title("Esports League and Tournament Operations")
counts = query("SELECT (SELECT count(*) FROM team) teams, (SELECT count(*) FROM match) matches")
st.write(f"Connected: {counts.teams[0]} teams, {counts.matches[0]} matches.")

st.markdown(
    """
**Demo order**

1. **Bracket**: pick CDL 2026 Major 2 and build its playoff bracket.
2. **Record series**: record the first match; the Bracket page shows both teams moving on.
3. **Record series** again: put a player from another team into a lineup. The database
   refuses the whole series; the match is still scheduled.
4. **Error log**: the refused call, with its rule number and inputs.
5. **Operations**: a transfer and a rebrand. **Team history** shows old results under the old name.
6. **Disputes**: raise and resolve one; awarding the match moves the bracket again.
"""
)
