-- 00_extensions.sql
-- Extensions the schema depends on.
--
-- btree_gist lets an EXCLUDE constraint combine "same team" (an equality on an
-- integer) with "overlapping dates" (a range overlap). We use it for rules 14,
-- 18 and 24 in 02_checks.sql.

CREATE EXTENSION IF NOT EXISTS btree_gist;
