import streamlit as st
from db import query

st.title("Operations")

teams = query("SELECT team_id, team_name FROM v_team_current_name ORDER BY team_name")
team_id_of = dict(zip(teams.team_name, teams.team_id))


def show(res):
    (st.success if res.ok[0] else st.error)(res.message[0])


# ---------- Rebrand a team ----------
st.subheader("Rebrand a team")
rb_team = st.selectbox("Team", teams.team_name, key="rb_team")
rb_date = st.date_input("New identity starts", key="rb_date")
rb_name = st.text_input("New name", key="rb_name")

if st.button("Rebrand"):
    show(query(
        "SELECT * FROM rebrand_team(p_team_id => %s, p_from => %s, p_name => %s)",
        (int(team_id_of[rb_team]), rb_date, rb_name),
    ))

st.divider()

# ---------- Transfer a player ----------
st.subheader("Transfer a player")
from_team = st.selectbox("From team", teams.team_name, key="tr_from")
players = query(
    """SELECT r.person_id, p.gamertag
       FROM v_roster_current r JOIN person p USING (person_id)
       WHERE r.team_id = %s AND r.roster_role IN ('starter', 'substitute', 'two-way')
       ORDER BY p.gamertag""",
    (int(team_id_of[from_team]),),
)
player = st.selectbox("Player", players.gamertag)
to_team = st.selectbox("To team", teams.team_name, key="tr_to")
tr_date = st.date_input("Transfer date", key="tr_date")
role = st.selectbox("Role", ["starter", "substitute"])
join_type = st.selectbox("Join type", ["signing", "trade", "loan"])
fee = st.number_input("Transfer fee (USD)", min_value=0, step=10000)

if st.button("Transfer"):
    if players.empty:
        st.warning("That team has no players to transfer.")
    else:
        person_id = int(players.person_id[players.gamertag == player].iloc[0])
        show(query(
            """SELECT * FROM transfer_player(p_person_id => %s, p_from_team => %s,
                   p_to_team => %s, p_date => %s, p_role => %s, p_join_type => %s, p_fee => %s)""",
            (person_id, int(team_id_of[from_team]), int(team_id_of[to_team]),
             tr_date, role, join_type, fee),
        ))