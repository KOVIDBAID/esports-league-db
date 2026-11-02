# Esports League and Tournament Operations System

DBMS course project (CS-3-09(MO), IIT Jammu): a PostgreSQL database that runs Call of Duty
leagues and tournaments, built from the ER design and relational schema in our mid-semester
report.

Team: Ishita Kaushik (2024UMA0210), Kovid Baid (2024UMA0214), Saswade Aditya Nachiket
(2024UMA0225), Sawan Rawat (2024UMA0226), Vanisha (2024UMA0233).

## Progress

| Phase | What | Status |
| --- | --- | --- |
| 1. Set up | Repository, Docker database, rebuild script, tests on every push | Done |
| 2. Schema | 42 tables, keys and checks, 16 views, reference data, schema tests | Done |
| 3. Rules | All 29 rules and 4 participation constraints enforced; 46 triggers ([docs/rules.md](docs/rules.md)) | Done |
| 4. Functions | All 12 functions, each one transaction with logged errors ([docs/functions.md](docs/functions.md)) | Done |
| 5. Data | The 2026 CDL teams and players, Major 1 played through the functions, Major 2 ready for the demo ([seed/README.md](seed/README.md)) | Done |
| 6. Demo | Streamlit app for the live presentation | Next |

## Quick start

You need [Docker Desktop](https://www.docker.com/products/docker-desktop/), Python 3.11 or
newer, and Git.

```bash
git clone https://github.com/KOVIDBAID/esports-league-db.git
cd esports-league-db

cp .env.example .env               # Windows: copy .env.example .env
docker compose up -d               # starts PostgreSQL 18.6 on port 5433

python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt

python scripts/rebuild.py          # builds the database and loads the season (about 1 second)
python -m pytest                   # all tests should pass
```

`rebuild.py` drops and recreates the `esports` database every time, so it is always safe to
run, and it is the only way the database should change: edit a file in `db/` or `seed/`, then
rebuild. Never change the database by hand; the next rebuild would undo it.

To look inside the database:

```bash
docker exec -it esports-db psql -U esports -d esports
```

Useful `psql` commands: `\dt` lists tables, `\d match` describes a table, `\dv` lists views,
`\q` quits.

## Repository layout

```
db/
  00_extensions.sql   btree_gist, needed by the EXCLUDE constraints
  01_tables.sql       the 42 relations of the report, Section 4.2, in foreign key order
  02_checks.sql       coded values, date order, and the EXCLUDE constraints for rules 14, 18, 24
  04_views.sql        16 views for the derived attributes (report Section 2.7)
  05_support.sql      error_log, fn_result and the error helpers used by every function
  06_rule_checks.sql  one check function per business rule: check_r01 ... check_r28, check_t1 ... t4
  07_triggers.sql     when each check runs: per table, immediately or at commit
  functions/          the 12 functions, one file each, numbered as in the plan
seed/
  reference/          stage 1: regions, organizations, venues, modes, formats, maps, map pool, layout
  people/             stage 2: the 12 teams, 48 players and their stints, 4 officials
  structure/          stage 3: the CDL, the 2026 season, stages, registrations, Major 1
  README.md           what is real, what is generated, and the sources
scripts/
  rebuild.py          drop, recreate, run db/ in order, load seed/
  load_seed.py        loads each seed stage in one transaction
  seed_season.py      stages 4 and 5: Major 1 played through the functions; Major 2 created
  snapshot.py         save and restore the demo starting point (pg_dump / pg_restore)
tests/
  conftest.py         fresh database per test run; each test rolled back afterwards
  test_schema.py      the schema and its declarative rules
  test_rules.py       one test per way of breaking each trigger-enforced rule
  test_functions_*.py a success test per function and a failure test per guarded rule
  test_concurrency.py two sessions at once: rules 26 and 27, and the same match recorded twice
  test_seed.py        the loaded season: real placements, history, determinism
docs/
  rules.md            each of the 29 business rules: how and when it is enforced, and its tests
  functions.md        the 12 functions: contract, error codes, inputs, rules, demo failures
  deviation_log.md    every difference from the mid-semester report, with the reason
.github/workflows/
  ci.yml              runs rebuild and tests on PostgreSQL 18.6 for every push
```

The `db/` files run in name order, then `db/functions/`.

Every operation is a function call, for example
`SELECT * FROM transfer_player(p_person_id => 17, p_from_team => 3, p_to_team => 5, p_date => '2026-04-01');`.
It returns `(ok, code, message, data)`; a failed call changes nothing and leaves one row in
`error_log`. When a change breaks a rule, the error code names it: `R0012` is rule 12, `T0001`
is the first participation constraint (every team has a name), `FN001` to `FN003` are the
functions' own checks. The message says which rows are
involved, for example `R0012: Shotzzy has no playing or coaching stint with OpTic Texas on
2026-03-01`.

## How we work

- Each phase ends with its tests passing, here and on GitHub.
- A rule enforced by the schema gets a test that tries to break it and expects the error.
- Any difference from the report goes into [docs/deviation_log.md](docs/deviation_log.md)
  with its reason, the same day it is made.
- Connection settings come from `.env` (copied from `.env.example`); `.env` is never
  committed.
