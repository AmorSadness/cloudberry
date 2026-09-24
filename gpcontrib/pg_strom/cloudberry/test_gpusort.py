#!/usr/bin/env python3
"""GPU-free acceptance-oracle and source-boundary checks; not GPU SQL evidence."""
import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
base = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("sort_runner", base / "demo/run_gpusort_regression.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class SortPlanOracle(unittest.TestCase):
    def plan(self, join=False):
        scan = {"Node Type": "Custom Scan", "Custom Plan Provider": "GpuJoin" if join else "GpuScan",
                "GPU-Sort keys": "k ASC NULLS LAST, id ASC", "Cloudberry GPU-Sort": "Per-QE order"}
        if join:
            scan["Plans"] = [{"Node Type": "Seq Scan"}]
        return {"Node Type": "Gather Motion", "Merge Key": ["k", "id"], "Plans": [scan]}

    def test_merge_receives_local_order(self):
        runner.verify_plan(self.plan())

    def test_join_sort(self):
        runner.verify_plan(self.plan(True), join=True)

    def test_unsorted_gather_rejected(self):
        plan = self.plan()
        del plan["Merge Key"]
        with self.assertRaises(AssertionError):
            runner.verify_plan(plan)

    def test_cpu_sort_cannot_mask_wrong_pathkeys(self):
        with self.assertRaises(AssertionError):
            runner.verify_plan({"Node Type": "Sort", "Plans": [self.plan()]})

    def test_native_sort_is_not_gpu_evidence(self):
        with self.assertRaises(AssertionError):
            runner.verify_plan({"Node Type": "Sort"})

    def test_gpu_topk_rejected(self):
        plan = self.plan()
        plan["Plans"][0]["GPU-Sort Limit"] = "10"
        with self.assertRaises(AssertionError):
            runner.verify_plan(plan)

    def test_native_limit(self):
        runner.verify_plan({"Node Type": "Limit", "Plans": [self.plan()]}, limited=True)
        with self.assertRaises(AssertionError):
            runner.verify_plan(self.plan(), limited=True)

    def test_negative_requires_no_gpu_sort(self):
        runner.verify_plan({"Node Type": "Sort"}, positive=False)
        with self.assertRaises(AssertionError):
            runner.verify_plan(self.plan(), positive=False)

    def test_source_contract(self):
        source = (base.parent / "src/gpu_join.c").read_text()
        guard = source[source.index("cloudberry_gpusort_input_supported("):source.index("/*\n * try_add_sorted_gpujoin_path")]
        for token in ("numGpuDevAttrs != 1", "bms_equal(root->all_baserels", "query->hasAggs",
                      "query->hasWindowFuncs", "query->distinctClause", "path->path.param_info",
                      "info->host_quals != NIL", "DEVTASK__PREAGG", "cloudberry_gpusort_type_supported"):
            self.assertIn(token, guard)
        for token in ("cpath->path.pathkeys = sortkeys_upper", "cpath->flags &= ~CUSTOMPATH_SUPPORT_PROJECTION",
                      "cpath->path.startup_cost = cpath->path.total_cost", "TYPECACHE_BTREE_OPFAMILY"):
            self.assertIn(token, source)
        executor = (base.parent / "src/executor.c").read_text()
        self.assertIn("pts->pp_info->gpusort_keys_expr != NIL", executor)
        self.assertIn("Cloudberry GpuSort requires pg_strom.cpu_fallback=off", executor)
        service = (base.parent / "src/gpu_service.c").read_text()
        self.assertRegex(service, r"uint64_t\s+sort_buffer_limit;")
        final = service[service.index("__gpuservHandleGpuScanJoinFinal(gpuClient"):]
        self.assertLess(final.index("GQBUF_KIND__FINAL_PROJECTION_BUFFER"), final.index("__kds->nitems"))
        self.assertIn("gpu_sort_buffer_can_allocate(gq_buf->sort_buffer_limit, used, bytesize)", service)
        preagg = (base.parent / "src/gpu_preagg.c").read_text()
        self.assertIn("GUC_UNIT_MB | GUC_GPDB_NEED_SYNC", preagg)


if __name__ == "__main__":
    unittest.main()
