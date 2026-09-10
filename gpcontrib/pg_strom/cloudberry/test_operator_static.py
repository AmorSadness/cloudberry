#!/usr/bin/env python3
"""Source-contract checks only; this does not execute a GPU plan or SQL fixture."""
import ast
from pathlib import Path
import re


def main():
    root = Path(__file__).resolve().parent.parent
    preagg = (root / "src/gpu_preagg.c").read_text()
    codegen = (root / "src/codegen.c").read_text()
    executor = (root / "src/executor.c").read_text()
    runner = (root / "cloudberry/demo/run_development_regression.py").read_text()
    document = (root / "CLOUDBERRY_DEVELOPMENT.md").read_text()
    for feature in ("count_types", "host_input", "cpu_filter", "heap_partition"):
        guc = "cloudberry_enable_" + feature
        assert re.search(r'&' + guc + r',\s*false,\s*PGC_USERSET', preagg), guc
        assert "pg_strom." + guc in document, guc
        assert f"SET pg_strom.{guc}=off;" in runner, guc
        assert f"SET pg_strom.{guc}=on;" in runner, guc

    # Projection slots must never fall back to physical heap attribute numbers.
    lookup = codegen.split("lookup_input_varnode_defitem(codegen_context", 1)[1]
    projected = lookup.split("if (context->pd[0].inner_target != NULL)", 1)[1].split("if (!IsA(var, Var))", 1)[0]
    assert "return NULL;" in projected and "resno++" in projected
    assert "equal(var, lfirst(lc))" in projected
    assert "context->pd[0].inner_target = source->pathtarget" in codegen
    assert "DEVTASK__CPU_INPUT_PROJECTION" in preagg
    assert "foreach (lc, con.groupby_keys)" in preagg
    assert "add_new_column_to_pathtarget(con.cpu_input_target, key)" in preagg
    assert "masked->defresult = (Expr *)makeNullConst" in preagg
    assert "when->expr = aggref->aggfilter" in preagg
    assert "contain_subplans((Node *)rinfo->clause)" in preagg
    assert "contain_subplans((Node *)input_rel->baserestrictinfo)" not in preagg
    assert "GpPolicyEqualByName" in preagg and "find_all_inheritors" in preagg
    assert "HEAP_TABLE_AM_OID" in preagg and "path->motionHazard" in preagg
    assert "op_leaf->host_qual_path->locus" in preagg
    assert "PG_DETOAST_DATUM(values[i])" in executor
    assert "Native CPU scan/filter/projection rows" in executor

    # Keep semantic edge cases in the manual runner; presence is not acceptance.
    ast.parse(runner)
    for case in ("count_types_global_empty", "count_types_cpu_chunks", "count_distinct_fallback",
                 "host_input_missing", "host_input_prepared", "cpu_filter_independent",
                 "cpu_filter_short_circuit", "cpu_filter_unknown", "cpu_filter_volatile",
                 "cpu_filter_subplan_fallback", "cpu_filter_error_recovery",
                 "heap_partition_column_mapping", "heap_partition_prepared", "heap_partition_nested",
                 "heap_partition_default_rows", "heap_partition_ao_leaf_fallback",
                 "traditional_inheritance_fallback", "operators_orca_fallback"):
        assert case in runner, "missing manual case: " + case
    print("Operator source contracts: PASS (GPU/SQL execution remains pending)")


if __name__ == "__main__":
    if not __debug__:
        raise SystemExit("Run without Python -O/PYTHONOPTIMIZE")
    main()
