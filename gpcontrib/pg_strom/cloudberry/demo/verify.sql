\set ON_ERROR_STOP on

SET optimizer = off;
SET pg_strom.enabled = on;
SET pg_strom.enable_gpuscan = on;
SET pg_strom.cpu_fallback = off;
SET enable_seqscan = off;

EXPLAIN (ANALYZE, VERBOSE, COSTS OFF)
SELECT id, amount
FROM pgstrom_mvp_heap
WHERE grp BETWEEN 101 AND 207
  AND amount >= 500.00
LIMIT 10000;

-- Stable result signatures for a CPU/GPU comparison.
SELECT count(*) AS n,
       sum(id)::numeric AS sum_id,
       sum(amount)::numeric AS sum_amount,
       md5(string_agg(id::text || ':' || payload, ',' ORDER BY id)) AS digest
FROM pgstrom_mvp_heap
WHERE grp BETWEEN 101 AND 207
  AND amount >= 500.00;

PREPARE pgstrom_mvp_q(integer, numeric) AS
SELECT count(*), sum(id), sum(amount)
FROM pgstrom_mvp_heap
WHERE grp = $1 AND amount >= $2;
EXECUTE pgstrom_mvp_q(123, 400.00);
EXECUTE pgstrom_mvp_q(456, 700.00);
EXECUTE pgstrom_mvp_q(123, 400.00);

-- Parameterized repeated execution/rescan shape and LIMIT.
SELECT p.grp, q.n
FROM (VALUES (11), (22), (11)) AS p(grp)
CROSS JOIN LATERAL
  (SELECT count(*) AS n
   FROM pgstrom_mvp_heap t
   WHERE t.grp = p.grp AND t.amount > 250.00) AS q
ORDER BY p.grp, q.n
LIMIT 3;

DEALLOCATE pgstrom_mvp_q;
