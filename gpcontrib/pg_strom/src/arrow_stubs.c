/*
 * Arrow/Parquet-disabled stubs for the Cloudberry GpuScan MVP.
 *
 * Keep the executor and device-selection call sites linkable while making it
 * impossible for a foreign Arrow relation to be selected accidentally.
 */
#include "pg_strom.h"

kern_data_store *
parquetReadOneRowGroup(const char *filename,
					   const kern_data_store *kds_head,
					   void *(*malloc_callback)(void *malloc_private,
												 size_t malloc_size),
					   void *malloc_private,
					   const char **p_error_message)
{
	if (p_error_message)
		*p_error_message = "Arrow/Parquet is disabled in the Cloudberry GpuScan MVP";
	return NULL;
}

static Datum
arrow_disabled(void)
{
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("Arrow/Parquet is disabled in the Cloudberry GpuScan MVP")));
}

PG_FUNCTION_INFO_V1(pgstrom_arrow_fdw_handler);
PUBLIC_FUNCTION(Datum)
pgstrom_arrow_fdw_handler(PG_FUNCTION_ARGS)
{
	return arrow_disabled();
}

PG_FUNCTION_INFO_V1(pgstrom_arrow_fdw_validator);
PUBLIC_FUNCTION(Datum)
pgstrom_arrow_fdw_validator(PG_FUNCTION_ARGS)
{
	/* Allow CREATE EXTENSION to create its otherwise inert FDW objects. */
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(pgstrom_arrow_fdw_precheck_schema);
PUBLIC_FUNCTION(Datum)
pgstrom_arrow_fdw_precheck_schema(PG_FUNCTION_ARGS)
{
	/* The upstream extension installs this event trigger. */
	PG_RETURN_NULL();
}

PG_FUNCTION_INFO_V1(pgstrom_arrow_fdw_import_file);
PUBLIC_FUNCTION(Datum)
pgstrom_arrow_fdw_import_file(PG_FUNCTION_ARGS)
{
	return arrow_disabled();
}

PG_FUNCTION_INFO_V1(pgstrom_arrow_fdw_check_pattern);
PUBLIC_FUNCTION(Datum)
pgstrom_arrow_fdw_check_pattern(PG_FUNCTION_ARGS)
{
	return arrow_disabled();
}

PG_FUNCTION_INFO_V1(pgstrom_arrow_fdw_metadata_info);
PUBLIC_FUNCTION(Datum)
pgstrom_arrow_fdw_metadata_info(PG_FUNCTION_ARGS)
{
	return arrow_disabled();
}

PG_FUNCTION_INFO_V1(pgstrom_arrow_fdw_metadata_stats);
PUBLIC_FUNCTION(Datum)
pgstrom_arrow_fdw_metadata_stats(PG_FUNCTION_ARGS)
{
	return arrow_disabled();
}

bool
baseRelIsArrowFdw(RelOptInfo *baserel)
{
	return false;
}

bool
RelationIsArrowFdw(Relation frel)
{
	return false;
}

gpumask_t
GetOptimalGpusForArrowFdw(PlannerInfo *root, RelOptInfo *baserel)
{
	return 0UL;
}

const DpuStorageEntry *
GetOptimalDpuForArrowFdw(PlannerInfo *root, RelOptInfo *baserel)
{
	return NULL;
}

bool
pgstromArrowFdwExecInit(pgstromTaskState *pts,
						List *outer_quals,
						const Bitmapset *outer_refs)
{
	return false;
}

XpuCommand *
pgstromScanChunkArrowFdw(pgstromTaskState *pts,
						 struct iovec *xcmd_iov,
						 int *xcmd_iovcnt)
{
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("Arrow/Parquet is disabled in the Cloudberry GpuScan MVP")));
}

void
pgstromArrowFdwExecEnd(ArrowFdwState *arrow_state)
{
}

void
pgstromArrowFdwExecReset(ArrowFdwState *arrow_state)
{
}

void
pgstromArrowFdwInitDSM(ArrowFdwState *arrow_state,
					   pgstromSharedState *ps_state)
{
}

void
pgstromArrowFdwAttachDSM(ArrowFdwState *arrow_state,
						 pgstromSharedState *ps_state)
{
}

void
pgstromArrowFdwShutdown(ArrowFdwState *arrow_state)
{
}

void
pgstromArrowFdwExplain(ScanState *ss,
					   ArrowFdwState *arrow_state,
					   ExplainState *es,
					   List *dcontext)
{
}

bool
kds_arrow_fetch_tuple(TupleTableSlot *slot,
					  kern_data_store *kds,
					  size_t index,
					  const Bitmapset *referenced)
{
	return false;
}

void
pgstrom_init_arrow_fdw(void)
{
}
