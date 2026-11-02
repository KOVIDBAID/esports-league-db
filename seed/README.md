# Seed data

Loaded by `scripts/load_seed.py` in stages, each stage in one transaction
(implementation plan, Section 6).

| Stage | Folder | Status |
| --- | --- | --- |
| 1. Reference data | `reference/` | Loaded |
| 2. People and teams | `people/` | Phase 5 |
| 3. Competition structure | `structure/` | Phase 5 |
| 4. Season history | generated through the functions | Phase 5 |
| 5. Demo starting point | generated through the functions | Phase 5 |

## Sources for the reference data

- Map pool per mode (Raid is Search & Destroy only, Blackheart is Hardpoint only):
  Dot Esports, "CDL 2026 competitive settings",
  https://dotesports.com/call-of-duty/news/cdl-2026-competitive-settings
- Best-of-5 mode order (HP, S&D, OVR, HP, S&D): Call of Duty Esports Wiki, "Black Ops 7",
  https://cod-esports.fandom.com/wiki/Black_Ops_7
- Overload goal: Call of Duty, Black Ops 7 Overload guide,
  https://www.callofduty.com/guides/blackops7/modes/overload

Raid also appears as a Black Ops II map (map 7), to show why `map` is keyed by
`(map_name, game_title)`. Control has no 2026 pool entries; it is kept for earlier seasons.
