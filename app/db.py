import sys
from pathlib import Path

import pandas as pd
import psycopg
import streamlit as st

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from rebuild import connect  # same .env settings as the tests


@st.cache_resource
def conn():
    return connect(autocommit=True)  # one function call = one transaction


def query(sql, params=None) -> pd.DataFrame:
    for attempt in (1, 2):
        try:
            with conn().cursor() as cur:
                cur.execute(sql, params)
                cols = [c.name for c in cur.description]
                return pd.DataFrame(cur.fetchall(), columns=cols)
        except psycopg.OperationalError:
            if attempt == 2:
                raise
            conn.clear()  # the saved connection died (database rebuilt); reconnect once


def team_name_on(team: str, day: str) -> str:
    """SQL for the name a team had on a day (its identity then), or its current name if it
    had none recorded then. Old results show the name the team played under; after a
    rebrand they keep the old name. `team` and `day` are SQL expressions, never user input."""
    return (f"COALESCE((SELECT ti.team_name FROM team_identity ti WHERE ti.team_id = {team}"
            f" AND ti.valid_from <= {day} AND (ti.valid_to IS NULL OR {day} < ti.valid_to)),"
            f" (SELECT cn.team_name FROM v_team_current_name cn WHERE cn.team_id = {team}))")