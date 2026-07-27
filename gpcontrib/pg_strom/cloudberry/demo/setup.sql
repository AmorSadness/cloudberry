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
