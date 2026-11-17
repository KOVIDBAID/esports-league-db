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