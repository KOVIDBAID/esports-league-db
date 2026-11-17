import json

import streamlit as st
from db import query

st.title("Disputes")


def show(res):
    (st.success if res.ok[0] else st.error)(res.message[0])


# ---------- Raise a dispute ----------
st.subheader("Raise a dispute")
done = query(
    """SELECT m.match_id, m.round_name, t1.team_name AS team_a, t2.team_name AS team_b,
              c1.team_id AS id_a, c2.team_id AS id_b
       FROM match m
       JOIN competes_in c1 ON c1.match_id = m.match_id AND c1.slot = 1
       JOIN competes_in c2 ON c2.match_id = m.match_id AND c2.slot = 2
       JOIN v_team_current_name t1 ON t1.team_id = c1.team_id
       JOIN v_team_current_name t2 ON t2.team_id = c2.team_id
       WHERE m.status = 'completed'
       ORDER BY m.match_id DESC"""
)
done["label"] = ("Match " + done.match_id.astype(str) + ": " + done.team_a + " v "
                 + done.team_b + " (" + done.round_name + ")")
pick = st.selectbox("Match", done.label, key="rd_match")
row = done[done.label == pick].iloc[0]
raiser = st.selectbox("Raised by", [row.team_a, row.team_b], key="rd_team")
reason = st.text_input("Reason", key="rd_reason")

if st.button("Raise dispute"):
    raiser_id = int(row.id_a if raiser == row.team_a else row.id_b)
    show(query(
        "SELECT * FROM raise_dispute(p_match_id => %s, p_team_id => %s, p_reason => %s)",
        (int(row.match_id), raiser_id, reason),
    ))

st.divider()

# ---------- Resolve a dispute ----------
st.subheader("Resolve a dispute")
open_d = query(
    """SELECT d.match_id, d.dispute_number, d.reason, n.team_name AS raised_by
       FROM dispute d JOIN v_team_current_name n ON n.team_id = d.raised_by_team_id
       WHERE d.status = 'open' ORDER BY d.match_id, d.dispute_number"""
)
if open_d.empty:
    st.info("No open disputes.")
else:
    open_d["label"] = ("Match " + open_d.match_id.astype(str) + ", dispute "
                       + open_d.dispute_number.astype(str) + " by " + open_d.raised_by
                       + ": " + open_d.reason)
    sel = st.selectbox("Open dispute", open_d.label, key="rs_dispute")
    d = open_d[open_d.label == sel].iloc[0]
    officials = query(
        """SELECT p.person_id, p.first_name || ' ' || p.last_name AS name
           FROM official o JOIN person p ON p.person_id = o.person_id ORDER BY name"""
    )
    official = st.selectbox("Official", officials.name, key="rs_official")
    decision = st.selectbox("Decision", ["resolved", "rejected"], key="rs_decision")
    resolution = st.text_input("Resolution (written decision)", key="rs_text")
    match_teams = query(
        """SELECT c.team_id, n.team_name FROM competes_in c
           JOIN v_team_current_name n ON n.team_id = c.team_id WHERE c.match_id = %s ORDER BY c.slot""",
        (int(d.match_id),),
    )
    fined = st.selectbox("Fine this team (optional)", match_teams.team_name, key="rs_team")
    fine = st.number_input("Fine amount (USD, 0 = none)", min_value=0, step=1000, key="rs_fine")

    if st.button("Resolve"):
        penalties = []
        if fine > 0 and decision == "resolved":
            fined_id = int(match_teams.team_id[match_teams.team_name == fined].iloc[0])
            penalties = [{"penalty_type": "fine", "team_id": fined_id,
                          "fine_amount": int(fine), "reason": resolution}]
        official_id = int(officials.person_id[officials.name == official].iloc[0])
        show(query(
            """SELECT * FROM resolve_dispute(p_match_id => %s, p_dispute_number => %s,
                   p_official_id => %s, p_decision => %s, p_resolution => %s, p_penalties => %s::jsonb)""",
            (int(d.match_id), int(d.dispute_number), official_id, decision, resolution, json.dumps(penalties)),
        ))