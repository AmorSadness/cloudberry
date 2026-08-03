\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_strom;
DROP TABLE IF EXISTS pgstrom_mvp_heap;
CREATE TABLE pgstrom_mvp_heap
(
    id bigint,
    grp integer,
    amount numeric(18,2),
    payload text
)
DISTRIBUTED BY (id);

INSERT INTO pgstrom_mvp_heap
SELECT g,
       (g % 1000)::integer,
       ((g % 100000) / 100.0)::numeric(18,2),
       md5(g::text)
FROM generate_series(1, 2000000) AS g;

ANALYZE pgstrom_mvp_heap;

-- All rows share the distribution key, so one primary receives the data and
-- the remaining primaries execute an empty local scan.  The values also cover
-- NULL, negative integer/numeric, and text projection cases.
DROP TABLE IF EXISTS pgstrom_mvp_skew;
CREATE TABLE pgstrom_mvp_skew
(
    id bigint,
    dist_key integer,
    metric integer,
    amount numeric(18,2),
    nullable_metric integer,
    payload text
)
DISTRIBUTED BY (dist_key);

INSERT INTO pgstrom_mvp_skew
SELECT g,
       1,
       ((g % 2001) - 1000)::integer,
       (((g % 200000) - 100000) / 100.0)::numeric(18,2),
       CASE WHEN g % 13 = 0 THEN NULL ELSE ((g % 101) - 50)::integer END,
       CASE WHEN g % 17 = 0 THEN NULL ELSE md5(g::text) END
FROM generate_series(1, 300000) AS g;

ANALYZE pgstrom_mvp_skew;

-- A deliberately small table still has a distributed locus, but only one
-- primary owns tuples.  enable_seqscan=off in the runner makes the valid
-- GpuScan path observable even though GPU setup is not economical here.
DROP TABLE IF EXISTS pgstrom_mvp_small;
CREATE TABLE pgstrom_mvp_small
(
    id bigint,
    dist_key integer,
    metric integer,
    amount numeric(18,2),
    nullable_metric integer,
    payload text
)
DISTRIBUTED BY (dist_key);

INSERT INTO pgstrom_mvp_small
SELECT g,
       1,
       (g - 9)::integer,
       ((g - 9) * 1.25)::numeric(18,2),
       CASE WHEN g % 3 = 0 THEN NULL ELSE (g - 9)::integer END,
       CASE WHEN g % 5 = 0 THEN NULL ELSE md5(g::text) END
FROM generate_series(1, 16) AS g;

ANALYZE pgstrom_mvp_small;

DROP TABLE IF EXISTS pgstrom_mvp_ao;
CREATE TABLE pgstrom_mvp_ao (LIKE pgstrom_mvp_heap)
WITH (appendonly=true, orientation=row)
DISTRIBUTED BY (id);
INSERT INTO pgstrom_mvp_ao SELECT * FROM pgstrom_mvp_heap WHERE id <= 10000;
ANALYZE pgstrom_mvp_ao;

DROP TABLE IF EXISTS pgstrom_mvp_aoco;
CREATE TABLE pgstrom_mvp_aoco (LIKE pgstrom_mvp_heap)
WITH (appendonly=true, orientation=column)
DISTRIBUTED BY (id);
INSERT INTO pgstrom_mvp_aoco SELECT * FROM pgstrom_mvp_heap WHERE id <= 10000;
ANALYZE pgstrom_mvp_aoco;

DROP TABLE IF EXISTS pgstrom_mvp_partitioned CASCADE;
CREATE TABLE pgstrom_mvp_partitioned (LIKE pgstrom_mvp_heap)
DISTRIBUTED BY (id)
PARTITION BY RANGE (id);
CREATE TABLE pgstrom_mvp_partitioned_p1
PARTITION OF pgstrom_mvp_partitioned
FOR VALUES FROM (1) TO (10001);
INSERT INTO pgstrom_mvp_partitioned
SELECT * FROM pgstrom_mvp_heap WHERE id <= 10000;
ANALYZE pgstrom_mvp_partitioned;
