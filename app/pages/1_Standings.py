import streamlit as st
from db import query

st.title("Standings")

st.subheader("Teams")
st.caption("Season points: placement points plus points per win in each phase. "
           "Prize money: every placement's prize so far.")
st.dataframe(query(
    """SELECT n.team_name,
              COALESCE((SELECT sum(sp.points) FROM v_team_season_points sp
                        WHERE sp.team_id = n.team_id), 0)::int AS season_points,
              COALESCE((SELECT sum(tp.prize) FROM v_team_prize tp
                        WHERE tp.team_id = n.team_id), 0) AS prize_money
       FROM v_team_current_name n
       ORDER BY season_points DESC, prize_money DESC, n.team_name"""
), hide_index=True)

st.subheader("Players")
st.caption("Season totals over every game a player has played, best K/D first (at least 10 games).")
st.dataframe(query(
    """SELECT p.gamertag, n.team_name AS team_now, s.games, s.kills, s.deaths, s.kd_ratio,
              s.damage, s.hill_time_seconds, s.first_bloods, s.overloads_scored
       FROM v_player_season_stats s
       JOIN person p ON p.person_id = s.person_id
       LEFT JOIN v_roster_current r ON r.person_id = s.person_id
            AND r.roster_role IN ('starter', 'substitute', 'two-way')
       LEFT JOIN v_team_current_name n ON n.team_id = r.team_id
       WHERE s.games >= 10
       ORDER BY s.kd_ratio DESC, s.kills DESC"""
), hide_index=True)
