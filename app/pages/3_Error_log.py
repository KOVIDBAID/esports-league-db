import streamlit as st
from db import query

st.title("Error log")
st.caption("Every failed call is recorded here. Nothing was saved for these calls.")

df = query("""
    SELECT logged_at, function_name, inputs::text AS attempted_with,
           sqlstate, rule_no AS rule, message
    FROM error_log
    ORDER BY logged_at DESC
""")

if df.empty:
    st.info("No failures yet")
else:
    st.dataframe(df, hide_index=True)