#!/usr/bin/env python3
"""GPU-free source guards and acceptance-oracle tests; no SQL/GPU validation."""
import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
base = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("gpujoin_runner", base / "demo/run_gpujoin_regression.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class PlanOracle(unittest.TestCase):
    def join(self, children=None):
        return {"Node Type": "Custom Scan", "Custom Plan Provider": "GpuJoin",
                "Cloudberry Join": "Colocated INNER hash join",
                "Plans": children if children is not None else [{"Node Type": "Seq Scan"}]}

    def test_final_motion_is_allowed(self):
        runner.verify_plan({"Node Type": "Gather Motion", "Plans": [self.join()]}, True)

    def test_native_is_not_gpu_evidence(self):
        with self.assertRaises(AssertionError):
            runner.verify_plan({"Node Type": "Hash Join"}, True)

    def test_nested_motion_is_rejected(self):
        child = {"Node Type": "Materialize", "Plans": [
            {"Node Type": "Redistribute Motion", "Plans": [{"Node Type": "Seq Scan"}]}]}
        with self.assertRaises(AssertionError):
            runner.verify_plan(self.join([child]), True)

    def test_gpu_inner_is_rejected(self):
        with self.assertRaises(AssertionError):
            runner.verify_plan(self.join([{"Node Type": "Custom Scan", "Custom Plan Provider": "GpuScan"}]), True)

    def test_fallback_must_not_hide_join(self):
        with self.assertRaises(AssertionError):
            runner.verify_plan({"Node Type": "Aggregate", "Plans": [self.join()]}, False)

    def test_native_fallback(self):
        runner.verify_plan({"Node Type": "Hash Join"}, False)

    def test_source_boundaries(self):
        source = (base.parent / "src/gpu_join.c").read_text()
        start = source.index("cloudberry_add_gpujoin_path(PlannerInfo")
        stop = source.index("\n#endif", start)
        guard = source[start:stop]
        for token in ("jointype != JOIN_INNER", "bms_num_members(root->all_baserels) != 2",
                      "cloudberry_gpujoin_colocated", "create_seqscan_path(root, innerrel, NULL, 0)",
                      "CdbPathLocus_IsHashed", "CdbPathLocus_MakeStrewn", "path->path.memory = inner_bytes",
                      "path->path.parallel_safe = false", "cloudberry_build_join_scan"):
            self.assertIn(token, guard)
        for token in ("a->opclasses[k] != b->opclasses[k]", "v1->vartype != v2->vartype",
                      "v1->varattno != a->attrs[k]", "v2->varattno != b->attrs[k]",
                      "HTEqualStrategyNumber", "get_rel_relispartition", "rte->securityQuals",
                      "GUC_UNIT_MB | GUC_GPDB_NEED_SYNC",
                      "Cloudberry GpuJoin inner buffer exceeds cloudberry_gpujoin_max_inner_size"):
            self.assertIn(token, source)
        self.assertIn("&pgstrom_enable_gpujoin,\n#ifdef GP_VERSION_NUM\n\t\t\t\t\t\t\t false,", source)
        executor = (base.parent / "src/executor.c").read_text()
        self.assertIn("0x80000000U | ++join_execution_id", executor)
        self.assertIn("Do not overwrite an mmap still owned by a draining Service session", executor)
        service = (base.parent / "src/gpu_service.c").read_text()
        self.assertIn("gq_buf->h_kmrels = NULL;", service)


if __name__ == "__main__":
    unittest.main()
