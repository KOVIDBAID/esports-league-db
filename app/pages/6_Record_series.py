import json

import streamlit as st
from db import query

st.title("Record a series")
st.caption("Quick play: pick a match, check both lineups, the winner and the score. "
           "The page generates the games and the player stats. To show a refusal, put a "
           "player from another team into a lineup: the database rejects the whole series.")

SCORES = {"HP": (250, 200), "S&D": (6, 3), "OVR": (8, 5)}  # winner and loser score per mode

todo = query(
    """SELECT m.match_id, m.round_name, m.best_of, ph.pool_id, ph.layout_id, t.team_size,
              COALESCE(m.scheduled_at::date, ph.start_date, t.start_date, current_date) AS default_day,
              c1.team_id AS id_a, c2.team_id AS id_b,
              t1.team_name AS team_a, t2.team_name AS team_b
       FROM match m
       JOIN phase ph ON ph.tournament_id = m.tournament_id AND ph.phase_number = m.phase_number
       JOIN tournament t ON t.event_id = m.tournament_id
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
match_id = int(row.match_id)
best_of = int(row.best_of)
wins_needed = best_of // 2 + 1

# The phase's dates by default: Major 2 was played in March, and stints are checked on this day
played = st.date_input("Played on", value=row.default_day, key=f"rs_date_{match_id}")

# Every player, labelled with their team today, so a player from another team can be picked
everyone = query(
    """SELECT DISTINCT ON (p.person_id) p.person_id,
              p.gamertag || ' (' || COALESCE(n.team_name, 'no team') || ')' AS label
       FROM player pl
       JOIN person p ON p.person_id = pl.person_id
       LEFT JOIN v_roster_current r ON r.person_id = p.person_id
       LEFT JOIN v_team_current_name n ON n.team_id = r.team_id
       ORDER BY p.person_id, r.start_date DESC"""
).sort_values("label")
label_of = dict(zip(everyone.person_id, everyone.label))
person_of = dict(zip(everyone.label, everyone.person_id))


def roster_on(team_id: int, day) -> list[str]:
    """The team's players with a playing stint on that day, starters first (rule 12)."""
    ps = query(
        """SELECT r.person_id FROM roster r JOIN player pl ON pl.person_id = r.person_id
           WHERE r.team_id = %s AND r.roster_role IN ('starter', 'substitute', 'two-way')
             AND r.start_date <= %s AND (r.end_date IS NULL OR %s < r.end_date)
           ORDER BY CASE r.roster_role WHEN 'starter' THEN 0 WHEN 'substitute' THEN 1 ELSE 2 END, r.person_id
           LIMIT %s""",
        (team_id, day, day, int(row.team_size)),
    )
    return [label_of[p] for p in ps.person_id]


lineups = []
for team_id, team_name in ((int(row.id_a), row.team_a), (int(row.id_b), row.team_b)):
    chosen = st.multiselect(f"Lineup: {team_name}", list(everyone.label), default=roster_on(team_id, played),
                            key=f"lineup_{match_id}_{team_id}_{played}")
    lineups.append({"team_id": team_id, "players": [int(person_of[c]) for c in chosen]})

winner = st.selectbox("Winner", [row.team_a, row.team_b], key="rs_winner")
loser_wins = st.selectbox(f"Games won by the loser (best of {best_of})", list(range(wins_needed)), key="rs_loser")

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
    res = query("SELECT * FROM record_series_result(%s, %s::jsonb)", (match_id, json.dumps(series)))
    if res.ok[0]:
        st.success(res.message[0] + " Open the Bracket page to see the teams move on.")
    else:
        st.error(res.message[0])
        after = query(
            """SELECT m.status, (SELECT count(*) FROM game g WHERE g.match_id = m.match_id) AS games
               FROM match m WHERE m.match_id = %s""",
            (match_id,),
        ).iloc[0]
        st.info(f"Nothing was saved: match {match_id} is still {after.status} with {after.games} games. "
                "The Error log page shows the attempt.")
