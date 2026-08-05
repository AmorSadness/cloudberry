\set ON_ERROR_STOP on

SET optimizer = off;
SET pg_strom.enabled = on;
SET pg_strom.enable_gpuscan = on;
SET pg_strom.cloudberry_enable_host_quals = on;
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

-- Mixed qualifiers: numeric predicates execute on GPU and the regular
-- expression remains a host Filter on each QE.
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF)
SELECT id, amount, payload
FROM pgstrom_mvp_heap
WHERE grp BETWEEN 101 AND 207
  AND amount >= 500.00
  AND payload ~ '^[0-7]'
LIMIT 10000;

SELECT count(*) AS n,
       sum(id)::numeric AS sum_id,
       sum(amount)::numeric AS sum_amount
FROM pgstrom_mvp_heap
WHERE grp BETWEEN 101 AND 207
  AND amount >= 500.00
  AND payload ~ '^[0-7]';

PREPARE pgstrom_mvp_q(integer, numeric) AS
SELECT count(*), sum(id), sum(amount)
FROM pgstrom_mvp_heap
WHERE grp = $1 AND amount >= $2;
EXECUTE pgstrom_mvp_q(123, 400.00);

PREPARE pgstrom_mvp_mixed_q(integer, text) AS
SELECT count(*), sum(id), sum(amount)
FROM pgstrom_mvp_heap
WHERE grp >= $1
  AND grp < $1 + 25
  AND amount >= 250.00
  AND payload ~ $2;
EXECUTE pgstrom_mvp_mixed_q(123, '^[0-7]');
EXECUTE pgstrom_mvp_mixed_q(456, '^[8-f]');
EXECUTE pgstrom_mvp_mixed_q(123, '^[0-7]');
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

-- Parameterized mixed-quals rescan shape.  The numeric predicates remain
-- device executable; the regular expression is evaluated by ExecQual.
SELECT p.grp, q.n
FROM (VALUES (11), (22), (11)) AS p(grp)
CROSS JOIN LATERAL
  (SELECT count(*) AS n
   FROM pgstrom_mvp_heap t
   WHERE t.grp = p.grp
     AND t.amount > 250.00
     AND t.payload ~ '^[0-7]') AS q
ORDER BY p.grp, q.n
LIMIT 3;

-- A skewed distribution makes all but one QE execute an empty local scan.
-- NULL-bearing columns are projected through GpuScan and consumed above it.
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF)
SELECT id, amount, nullable_metric, payload
FROM pgstrom_mvp_skew
WHERE metric BETWEEN -500 AND 750
  AND amount >= -250.00;

SELECT count(*) AS n,
       sum(id)::numeric AS sum_id,
       sum(metric)::numeric AS sum_metric,
       sum(amount)::numeric AS sum_amount,
       count(*) FILTER (WHERE nullable_metric IS NULL) AS null_metrics,
       count(*) FILTER (WHERE payload IS NULL) AS null_payloads
FROM pgstrom_mvp_skew
WHERE metric BETWEEN -500 AND 750
  AND amount >= -250.00;

-- The GPU path is forced only to validate distributed execution with a tiny
-- input; this is deliberately not a performance claim.
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF)
SELECT id, metric, amount, nullable_metric, payload
FROM pgstrom_mvp_small
WHERE id BETWEEN 1 AND 16;

DEALLOCATE pgstrom_mvp_q;
DEALLOCATE pgstrom_mvp_mixed_q;
