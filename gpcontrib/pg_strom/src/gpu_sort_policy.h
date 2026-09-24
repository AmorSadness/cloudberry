/* Cloudberry GPU-Sort allocation arithmetic; shared with GPU-free tests. */
#ifndef GPU_SORT_POLICY_H
#define GPU_SORT_POLICY_H
#include <stdbool.h>
#include <stdint.h>

static inline bool
gpu_sort_buffer_can_allocate(uint64_t limit, uint64_t used, uint64_t request)
{
	/* A zero limit means no feature-specific cap, not permission to overflow. */
	return request <= UINT64_MAX - used &&
		(limit == 0 || (used <= limit && request <= limit - used));
}
#endif
