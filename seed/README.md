# Seed data

`scripts/load_seed.py` loads five stages in order, each in one transaction (implementation
plan, Section 6). Static data comes from the CSV files here; everything that happens in the
season goes in through our own functions (`scripts/seed_season.py`), so every seeded match,
stat and stint has passed the same rules the demo shows.

| Stage | Source | What it loads |
| --- | --- | --- |
| 1. Reference data | `reference/*.csv` | regions, organizations, venues, game modes, formats, maps, the 2026 map pool, the Bo5 layout |
| 2. People and teams | `people/*.csv` | the 12 CDL teams, 48 players with their opening stints, 4 officials |
| 3. Competition structure | `structure/*.csv` | the CDL, its 2026 season, stages 1 and 2, the 12 registrations, Major 1 with its phases and prize bands |
| 4. Season history | `seed_season.season_history()` | G2's rebrand, Major 1 played end to end (44 series, 166 games), two disputes, Mamba's transfer |
| 5. Demo starting point | `seed_season.demo_starting_point()` | Major 2 created, its playoff phase not yet set up |

A full rebuild loads all of it in about a second and logs nothing to `error_log`. The
`--seed-upto reference` option of `rebuild.py` loads only the first stage.

## What is real and what is generated

**Real** (sources below)

- The 12 teams of the 2026 season, their cities and owning organizations.
- Each team's four players at Major 1 (their gamertags), and the officials' roles.
- Major 1: dates, venue (Moody Coliseum, Dallas), host (OpTic), prize money and points per
  placement, and the final placements (Paris Gentle Mates 1st, OpTic Texas 2nd, ...).
- Major 2: dates, venue (National Exhibition Centre, Birmingham), prize money and points.
- G2's rebrand from Minnesota RØKKR (announced 21 October 2025) and Mamba's move from G2
  Minnesota to Vancouver Surge (28 May 2026).
- The 2026 map pool and Bo5 mode order.

**Generated or placeholder**

- Every veto, series score, map, game score and player stat, from a fixed random seed
  (`RANDOM_SEED = 2026`): every rebuild produces exactly the same data. A team's rating is
  its real Major 1 finish and the stronger team wins every series, which reproduces the real
  placements; who wins each game inside a series is random.
- Major 1's format is simplified to what our functions build: two six-team qualifier groups
  (round robin, 10 CDL points per win, as in the real qualifiers), then an 8-team double
  elimination playoff, all best of 5. The real Major 1 had a 12-team LAN bracket and a best
  of 7 grand final.
- The two disputes are illustrative technical complaints (one rejected, one upheld with no
  action). No penalty is seeded, so the data never records misconduct by a real player or
  team; the demo creates penalties live.
- Personal details. Players' legal names are not stored: `first_name` is `Player` and
  `last_name` repeats the gamertag. Dates of birth are placeholders (1 January of a year
  from 1996 to 2004, derived from the gamertag), Activision IDs are placeholders
  (`gamertag#1001`), every player's role is `flex`, and regions are left empty. The four
  officials are fictional, with 555 phone numbers.
- Dates that start our data: every team identity begins on 1 October 2025 and every opening
  stint on 14 November 2025 (the Black Ops 7 launch). They mark the start of the data, not
  when a team took its name or signed a player.

## Sources

- Teams and cities: Wikipedia, "2026 Call of Duty League season",
  https://en.wikipedia.org/wiki/2026_Call_of_Duty_League_season
- Major 1 lineups: Call of Duty Esports Wiki, "Call of Duty League/2026 Season/Major 1/Qualifiers",
  https://cod-esports.fandom.com/wiki/Call_of_Duty_League/2026_Season/Major_1/Qualifiers
- Paris Gentle Mates lineup: Insider Gaming, https://insider-gaming.com/gentlemates-cdl-roster-revealed-2026-season/
- Cloud9 New York lineup: Fragster, https://www.fragster.com/cloud9-new-york-rebuilds-cdl-roster-after-disastrous-start-to-2026-season/
- Mamba to Vancouver Surge: BreakingPoint, https://lab.breakingpoint.gg/posts/1315
- G2 rebrand: esports.net, https://www.esports.net/news/cod/g2-rebrands-call-of-duty-league-team-from-minnesota-rokkr-to-g2-minnesota/
- Major 1 and Major 2: esports.net, https://www.esports.net/wiki/tournaments/cdl-2026-major-1 and
  https://www.esports.net/wiki/tournaments/cdl-2026-major-2
- Map pool per mode (Raid is Search & Destroy only, Blackheart is Hardpoint only):
  Dot Esports, https://dotesports.com/call-of-duty/news/cdl-2026-competitive-settings
- Best-of-5 mode order (HP, S&D, OVR, HP, S&D): Call of Duty Esports Wiki, https://cod-esports.fandom.com/wiki/Black_Ops_7
- Overload: https://www.callofduty.com/guides/blackops7/modes/overload

Raid also appears as a Black Ops II map (map 7), to show why `map` is keyed by
`(map_name, game_title)`. Control has no 2026 pool entries; it is kept for earlier seasons.

## Resetting between rehearsals

```bash
python scripts/rebuild.py              # the demo starting point, from scratch
python scripts/snapshot.py save        # dump it to demo.dump
python scripts/snapshot.py restore     # back to that state in seconds, before each rehearsal
```
