"""Seed stages 4 and 5: the season, played through our own functions.

Stage 4, season history
  * G2 Minnesota's rebrand from Minnesota RØKKR (real: announced 21 October 2025),
    through rebrand_team.
  * CDL 2026 Major 1, run end to end through setup_tournament_phase, run_map_veto,
    record_series_result and finalize_tournament: two qualifier groups (round robin) and an
    8-team double elimination playoff. The final placements are the real ones; every veto,
    series score, map and stat is generated from a fixed random seed, so every rebuild
    produces exactly the same data.
  * Two disputes about technical problems, through raise_dispute and resolve_dispute. They
    are illustrative and carry no penalty, so the data never accuses a real player or team.
  * Mamba's move from G2 Minnesota to Vancouver Surge (real: 28 May 2026), through
    transfer_player.

Stage 5, demo starting point
  * CDL 2026 Major 2 (real dates, venue, prizes and points), created through
    create_tournament. Its playoff phase is not set up: the live demo starts by calling
    setup_tournament_phase.

Every call must succeed; the first failure stops the stage, and the loader rolls it back.
"""
from __future__ import annotations

import random
from datetime import datetime, timedelta, timezone

from psycopg import sql
from psycopg.types.json import Jsonb

RANDOM_SEED = 2026
MAJOR_1, MAJOR_1_GROUPS, MAJOR_1_PLAYOFFS = 2, (1, 2), 3
HP, SND, CTL, OVR = 1, 2, 3, 4
BO5_MODES = [HP, SND, OVR, HP, SND]

# The generator's team rating: the real Major 1 order of finish (esports.net), best first.
# The stronger team wins every series, so the bracket reproduces the real placements.
RATING = ["Paris Gentle Mates", "OpTic Texas", "FaZe Vegas", "G2 Minnesota", "Miami Heretics",
          "Los Angeles Thieves", "Vancouver Surge", "Riyadh Falcons", "Toronto KOI",
          "Carolina Royal Ravens", "Boston Breach", "Cloud9 New York"]
GROUPS = {1: ["Paris Gentle Mates", "G2 Minnesota", "Los Angeles Thieves", "Vancouver Surge",
              "Toronto KOI", "Boston Breach"],
          2: ["OpTic Texas", "FaZe Vegas", "Miami Heretics", "Riyadh Falcons",
              "Carolina Royal Ravens", "Cloud9 New York"]}

QUALIFIERS_START = datetime(2025, 12, 5, 18, 0, tzinfo=timezone.utc)
QUALIFIER_DAYS = 51                                   # 5 December to 25 January
PLAYOFF_DAY = {"Upper round 1": 0, "Upper round 2": 1, "Lower round 1": 1, "Lower round 2": 2,
               "Upper final": 2, "Lower round 3": 2, "Lower final": 3, "Grand final": 3}
PLAYOFFS_START = datetime(2026, 1, 29, 17, 0, tzinfo=timezone.utc)


class SeedCallError(RuntimeError):
    pass


def call(conn, function: str, **params) -> dict:
    """Call one of our functions; stop the stage if it reports a failure."""
    args = sql.SQL(", ").join(sql.SQL("{} => {}").format(sql.Identifier(k), sql.Placeholder()) for k in params)
    query = sql.SQL("SELECT * FROM {}({})").format(sql.Identifier(function), args)
    values = [Jsonb(v) if isinstance(v, (dict, list)) else v for v in params.values()]
    ok, code, message, data = conn.execute(query, values).fetchone()
    if not ok:
        raise SeedCallError(f"{function} failed: {message} (code {code})")
    return data


class Season:
    def __init__(self, conn):
        self.conn = conn
        self.rng = random.Random(RANDOM_SEED)
        self.team = dict(conn.execute("SELECT team_name, team_id FROM v_team_current_name").fetchall())
        # G2 Minnesota is still Minnesota RØKKR until history() loads the rebrand
        self.rank = {self.team[name]: i for i, name in enumerate(RATING) if name in self.team}
        self.pool = {}
        for mode_id, map_id in conn.execute(
                "SELECT mode_id, map_id FROM pool_entry WHERE pool_id = 1 ORDER BY mode_id, map_id"):
            self.pool.setdefault(mode_id, []).append(map_id)
        self.referee, self.admin = conn.execute(
            """SELECT min(person_id) FILTER (WHERE official_type = 'referee'),
                      min(person_id) FILTER (WHERE official_type = 'league admin') FROM official""").fetchone()
        self.counts = {"series": 0, "games": 0}

    # ------------------------------------------------------------------ one series

    def lineup(self, team_id: int, when: datetime) -> list[int]:
        return [r[0] for r in self.conn.execute(
            """SELECT person_id FROM roster WHERE team_id = %s AND roster_role = 'starter'
               AND start_date <= %s AND (end_date IS NULL OR %s < end_date)
               ORDER BY person_id LIMIT 4""", (team_id, when.date(), when.date()))]

    def veto(self, a: int, b: int) -> list[dict]:
        """The 2026 Bo5 veto: HP ban, ban, pick, pick; S&D ban, ban, pick, pick; Overload ban, ban."""
        def v(team, action, map_id, mode_id):
            return {"team_id": team, "action": action, "map_id": map_id, "mode_id": mode_id}
        hp, snd, ovr = (self.rng.sample(self.pool[m], len(self.pool[m])) for m in (HP, SND, OVR))
        return [v(a, "ban", hp[0], HP), v(b, "ban", hp[1], HP), v(a, "pick", hp[2], HP), v(b, "pick", hp[3], HP),
                v(b, "ban", snd[0], SND), v(a, "ban", snd[1], SND), v(b, "pick", snd[2], SND), v(a, "pick", snd[3], SND),
                v(a, "ban", ovr[0], OVR), v(b, "ban", ovr[1], OVR)]

    def stats(self, person_id: int, mode: int, won: bool) -> dict:
        r = self.rng.randint
        edge = 2 if won else 0
        if mode == HP:
            base = {"kills": r(17, 33) + edge, "deaths": r(18, 34) - edge, "assists": r(3, 10), "damage": r(2600, 5200)}
            extra = {"hill_time_seconds": r(25, 120), "contested_time_seconds": r(8, 45), "captures": r(1, 6)}
        elif mode == SND:
            base = {"kills": r(2, 10) + edge // 2, "deaths": r(3, 10) - edge // 2, "assists": r(0, 4), "damage": r(500, 1700)}
            extra = {"first_bloods": r(0, 3), "plants": r(0, 2), "defuses": r(0, 1)}
        else:
            base = {"kills": r(14, 28) + edge, "deaths": r(15, 29) - edge, "assists": r(2, 8), "damage": r(2100, 4300)}
            extra = {"overloads_scored": r(0, 3), "device_pickups": r(0, 6), "carry_time_seconds": r(0, 90)}
        return {"person_id": person_id, **base, "mode_stats": extra}

    def play(self, match_id: int, when: datetime) -> int:
        """Veto, then record the whole series; the stronger team wins. Returns the winner."""
        a, b = [r[0] for r in self.conn.execute(
            "SELECT team_id FROM competes_in WHERE match_id = %s ORDER BY slot", (match_id,))]
        call(self.conn, "run_map_veto", p_match_id=match_id, p_vetoes=self.veto(a, b),
             p_vetoed_at=when - timedelta(minutes=20))

        winner = a if self.rank[a] < self.rank[b] else b
        loser = b if winner == a else a
        games_lost = self.rng.choices([0, 1, 2], weights=[45, 35, 20])[0]
        order = [winner] * 2 + [loser] * games_lost
        self.rng.shuffle(order)
        order.append(winner)                          # the winner takes the deciding game

        lineups = {t: self.lineup(t, when) for t in (a, b)}
        games = []
        for number, game_winner in enumerate(order, start=1):
            mode = BO5_MODES[number - 1]
            game_loser = loser if game_winner == winner else winner
            high, low = {HP: (250, self.rng.randint(140, 245)), SND: (6, self.rng.randint(1, 5)),
                         OVR: (8, self.rng.randint(2, 7))}[mode]
            games.append({
                "game_number": number,
                "started_at": (when + timedelta(minutes=17 * (number - 1))).isoformat(),
                "duration_seconds": self.rng.randint(540, 900),
                "scores": [{"team_id": game_winner, "score": high}, {"team_id": game_loser, "score": low}],
                "stats": [self.stats(p, mode, t == game_winner) for t in (a, b) for p in lineups[t]],
            })
        call(self.conn, "record_series_result", p_match_id=match_id,
             p_series={"played_at": when.isoformat(),
                       "lineups": [{"team_id": t, "players": lineups[t]} for t in (a, b)],
                       "games": games})
        self.counts["series"] += 1
        self.counts["games"] += len(games)
        return winner

    # ------------------------------------------------------------------ stage 4

    def history(self) -> dict:
        # The real rebrand: Minnesota RØKKR became G2 Minnesota on 21 October 2025
        g2 = self.conn.execute("SELECT team_id FROM team_identity WHERE team_name = 'Minnesota RØKKR'").fetchone()[0]
        call(self.conn, "rebrand_team", p_team_id=g2, p_from="2025-10-21", p_name="G2 Minnesota",
             p_org_id=self.conn.execute("SELECT org_id FROM organization WHERE org_name = 'G2 Esports'").fetchone()[0])
        self.team["G2 Minnesota"] = g2
        self.rank[g2] = RATING.index("G2 Minnesota")

        # Major 1 qualifiers: two round-robin groups, matches spread over the qualifier window
        for phase in MAJOR_1_GROUPS:
            call(self.conn, "setup_tournament_phase", p_tournament_id=MAJOR_1, p_phase_number=phase,
                 p_teams=[self.team[name] for name in GROUPS[phase]])
        group_matches = self.conn.execute(
            """SELECT match_id FROM match WHERE tournament_id = %s AND phase_number = ANY(%s)
               ORDER BY match_number, phase_number""", (MAJOR_1, list(MAJOR_1_GROUPS))).fetchall()
        for i, (match_id,) in enumerate(group_matches):
            day = i * QUALIFIER_DAYS // len(group_matches)
            self.play(match_id, QUALIFIERS_START + timedelta(days=day, hours=i % 3))

        # The top four of each group make the playoffs, seeded by rating
        qualified = []
        for phase in MAJOR_1_GROUPS:
            standings = self.conn.execute(
                """SELECT c.team_id, count(w.team_id) FILTER (WHERE w.team_id = c.team_id) AS wins
                   FROM match m JOIN competes_in c ON c.match_id = m.match_id
                   LEFT JOIN v_match_winner w ON w.match_id = m.match_id
                   WHERE m.tournament_id = %s AND m.phase_number = %s
                   GROUP BY c.team_id ORDER BY wins DESC""", (MAJOR_1, phase)).fetchall()
            qualified += [team_id for team_id, _ in standings[:4]]
        seeds = sorted(qualified, key=self.rank.get)
        call(self.conn, "setup_tournament_phase", p_tournament_id=MAJOR_1, p_phase_number=MAJOR_1_PLAYOFFS,
             p_teams=seeds)

        # Playoffs: matches in bracket order, each round on its real LAN day
        playoff_matches = self.conn.execute(
            """SELECT match_id, round_name FROM match WHERE tournament_id = %s AND phase_number = %s
               ORDER BY match_number""", (MAJOR_1, MAJOR_1_PLAYOFFS)).fetchall()
        slot_in_day = {}
        for match_id, round_name in playoff_matches:
            day = PLAYOFF_DAY[round_name]
            slot_in_day[day] = slot_in_day.get(day, -1) + 1
            when = PLAYOFFS_START + timedelta(days=day, minutes=90 * slot_in_day[day])
            self.play(match_id, when)

            # Two illustrative disputes about technical problems: one rejected, one upheld
            # with no further action. Neither carries a penalty.
            if round_name == "Upper round 1" and slot_in_day[day] == 0:
                loser = self.loser(match_id)
                d = call(self.conn, "raise_dispute", p_match_id=match_id, p_team_id=loser,
                         p_reason="Server latency spike during game 2", p_raised_at=when + timedelta(hours=2))
                call(self.conn, "resolve_dispute", p_match_id=match_id, p_dispute_number=d["dispute_number"],
                     p_official_id=self.referee, p_decision="rejected",
                     p_resolution="Server logs show no latency above the remake threshold; the result stands",
                     p_resolved_at=when + timedelta(hours=3))
            if round_name == "Upper round 2" and slot_in_day[day] == 0:
                loser = self.loser(match_id)
                d = call(self.conn, "raise_dispute", p_match_id=match_id, p_team_id=loser,
                         p_reason="Controller disconnect at the start of game 1", p_raised_at=when + timedelta(hours=2))
                call(self.conn, "resolve_dispute", p_match_id=match_id, p_dispute_number=d["dispute_number"],
                     p_official_id=self.admin, p_decision="resolved",
                     p_resolution="The disconnect happened before first blood and the round was correctly "
                                  "restarted; no further action",
                     p_resolved_at=when + timedelta(hours=4))

        placements = call(self.conn, "finalize_tournament", p_tournament_id=MAJOR_1)["placements"]

        # The real transfer: Mamba left G2 Minnesota and joined Vancouver Surge on 28 May 2026
        mamba = self.conn.execute("SELECT person_id FROM person WHERE gamertag = 'Mamba'").fetchone()[0]
        call(self.conn, "transfer_player", p_person_id=mamba, p_from_team=g2,
             p_to_team=self.team["Vancouver Surge"], p_date="2026-05-28", p_role="starter", p_join_type="signing")

        return {"series played": self.counts["series"], "games": self.counts["games"],
                "Major 1 winner": placements[0]["team"], "rebrands": 1, "transfers": 1, "disputes": 2}

    def loser(self, match_id: int) -> int:
        return self.conn.execute(
            """SELECT c.team_id FROM competes_in c JOIN v_match_winner w ON w.match_id = c.match_id
               WHERE c.match_id = %s AND c.team_id <> w.team_id""", (match_id,)).fetchone()[0]


def season_history(conn) -> dict:
    return Season(conn).history()


def demo_starting_point(conn) -> dict:
    """CDL 2026 Major 2 (esports.net): created, playoff phase not yet set up."""
    host = conn.execute("SELECT org_id FROM organization WHERE org_name = 'Call of Duty League'").fetchone()[0]
    venue = conn.execute("SELECT venue_id FROM venue WHERE venue_name = 'National Exhibition Centre'").fetchone()[0]
    data = call(conn, "create_tournament", p_event_name="CDL 2026 Major 2", p_host_org_id=host,
                p_tournament_type="major", p_team_size=4, p_max_teams=12, p_tier="S",
                p_start_date="2026-02-13", p_end_date="2026-03-29", p_venue_id=venue,
                p_stage={"league_id": 1, "season_year": 2026, "stage_number": 2},
                p_phases=[{"phase_name": "Playoffs", "default_best_of": 5, "format_id": 2, "pool_id": 1,
                           "layout_id": 1, "start_date": "2026-03-27", "end_date": "2026-03-29"}],
                p_prize_bands=[{"placement_from": 1, "placement_to": 1, "prize_amount": 150000, "points": 100},
                               {"placement_from": 2, "placement_to": 2, "prize_amount": 90000, "points": 75},
                               {"placement_from": 3, "placement_to": 3, "prize_amount": 50000, "points": 60},
                               {"placement_from": 4, "placement_to": 4, "prize_amount": 30000, "points": 45},
                               {"placement_from": 5, "placement_to": 6, "prize_amount": 15000, "points": 30},
                               {"placement_from": 7, "placement_to": 8, "prize_amount": 7500, "points": 15}])
    return {"Major 2 tournament_id": data["tournament_id"], "prize pool": float(data["prize_pool"])}
