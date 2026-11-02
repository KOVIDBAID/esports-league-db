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
| 3. Rules | Triggers for the rules that compare or count rows ([docs/rules.md](docs/rules.md)) | Next |
| 4. Functions | 12 transactional functions (5 for the demo, 7 in reserve) | |
| 5. Data | Seed stages 2 to 5: people, teams, a season, the demo starting point | |
| 6. Demo | Streamlit app for the live presentation | |

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

python scripts/rebuild.py          # builds the database from scratch (about 1 second)
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
  functions/          one file per function (Phase 4)
seed/
  reference/          stage 1: regions, modes, formats, maps, the 2026 map pool, the Bo5 layout
scripts/
  rebuild.py          drop, recreate, run db/ in order, load seed/
  load_seed.py        loads each seed stage in one transaction
tests/
  conftest.py         fresh database per test run; each test rolled back afterwards
  test_schema.py      the schema and its declarative rules
docs/
  rules.md            each of the 29 business rules: how it is enforced, status, test
  deviation_log.md    every difference from the mid-semester report, with the reason
.github/workflows/
  ci.yml              runs rebuild and tests on PostgreSQL 18.6 for every push
```

The `db/` files run in name order, then `db/functions/`. The Phase 3 triggers will go in
`06_triggers.sql`, after the support helpers they call.

## How we work

- Each phase ends with its tests passing, here and on GitHub.
- A rule enforced by the schema gets a test that tries to break it and expects the error.
- Any difference from the report goes into [docs/deviation_log.md](docs/deviation_log.md)
  with its reason, the same day it is made.
- Connection settings come from `.env` (copied from `.env.example`); `.env` is never
  committed.
