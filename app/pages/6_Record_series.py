import json

import streamlit as st
from db import query

st.title("Record a series")
st.caption("Quick play: pick a match, the winner and the score. "
           "The page generates the games and the player stats.")

SCORES = {"HP": (250, 200), "S&D": (6, 3), "OVR": (8, 5)}  # winner and loser score per mode

todo = query(
    """SELECT m.match_id, m.round_name, m.best_of, ph.pool_id, ph.layout_id,
              c1.team_id AS id_a, c2.team_id AS id_b,
              t1.team_name AS team_a, t2.team_name AS team_b
       FROM match m
       JOIN phase ph ON ph.tournament_id = m.tournament_id AND ph.phase_number = m.phase_number
       JOIN competes_in c1 ON c1.match_id = m.match_id AND c1.slot = 1
       JOIN competes_in c2 ON c2.match_id = m.match_id AND c2.slot = 2
       JOIN v_team_current_name t1 ON t1.team_id = c1.team_id
       JOIN v_team_current_name t2 ON t2.team_id = c2.team_id
       WHERE m.status = 'scheduled'
       ORDER BY m.match_id"""
)

if todo.empty:
    st.info("No match is ready to play. Build the Major 2 bracket on the Bracket page first.")
    st.stop()

todo["label"] = ("Match " + todo.match_id.astype(str) + ": " + todo.team_a + " v "
                 + todo.team_b + " (" + todo.round_name + ")")
pick = st.selectbox("Match", todo.label, key="rs_match")
row = todo[todo.label == pick].iloc[0]
best_of = int(row.best_of)
wins_needed = best_of // 2 + 1

winner = st.selectbox("Winner", [row.team_a, row.team_b], key="rs_winner")
loser_wins = st.selectbox(f"Games won by the loser (best of {best_of})", list(range(wins_needed)), key="rs_loser")
played = st.date_input("Played on", key="rs_date")

if st.button("Record series"):
    winner_id = int(row.id_a if winner == row.team_a else row.id_b)
    loser_id = int(row.id_b if winner == row.team_a else row.id_a)
    total_games = wins_needed + loser_wins

    slots = query(
        """SELECT s.game_number, s.mode_id, gm.abbreviation AS mode
           FROM series_slot s JOIN game_mode gm USING (mode_id)
           WHERE s.layout_id = %s AND s.best_of = %s ORDER BY s.game_number""",
        (int(row.layout_id), best_of),
    )
    if len(slots) < total_games:
        st.error("The map layout does not cover this series length.")
        st.stop()

    lineups = []
    for tid in (int(row.id_a), int(row.id_b)):
        ps = query(
            """SELECT person_id FROM v_roster_current
               WHERE team_id = %s AND roster_role IN ('starter', 'substitute', 'two-way')
               ORDER BY CASE roster_role WHEN 'starter' THEN 0 WHEN 'substitute' THEN 1 ELSE 2 END, person_id
               LIMIT 4""",
            (tid,),
        )
        lineups.append({"team_id": tid, "players": [int(p) for p in ps.person_id]})
    players = [p for lineup in lineups for p in lineup["players"]]

    games, used = [], {}
    for n in range(1, total_games + 1):
        slot = slots[slots.game_number == n].iloc[0]
        maps = query(
            "SELECT map_id FROM pool_entry WHERE pool_id = %s AND mode_id = %s ORDER BY map_id",
            (int(row.pool_id), int(slot.mode_id)),
        )
        k = used.get(slot["mode"], 0)
        used[slot["mode"]] = k + 1
        map_id = int(maps.map_id.iloc[k % len(maps)])
        winner_takes_it = n > loser_wins  # the loser's wins come first, so the series ends on the last game
        high, low = SCORES.get(slot["mode"], (6, 3))
        games.append({
            "game_number": n, "map_id": map_id, "mode_id": int(slot.mode_id), "duration_seconds": 600,
            "scores": [
                {"team_id": winner_id if winner_takes_it else loser_id, "score": high},
                {"team_id": loser_id if winner_takes_it else winner_id, "score": low},
            ],
            "stats": [{"person_id": p, "kills": 12 + (p + n) % 12, "deaths": 10 + (p * 3 + n) % 10,
                       "assists": 3 + p % 6, "damage": 1800 + ((p + n) % 12) * 120} for p in players],
        })

    series = {"played_at": f"{played}T18:00:00Z", "lineups": lineups, "games": games}
    res = query("SELECT * FROM record_series_result(%s, %s::jsonb)", (int(row.match_id), json.dumps(series)))
    if res.ok[0]:
        st.success(res.message[0] + " Open the Bracket page to see the teams move on.")
    else:
        st.error(res.message[0])