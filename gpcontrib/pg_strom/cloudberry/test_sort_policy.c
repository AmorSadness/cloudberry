/* Exercise the exact allocation arithmetic used by GPU Service, without CUDA. */
#include <assert.h>
#include <stdio.h>
#include "../src/gpu_sort_policy.h"

int main(void)
{
	for (uint64_t cap=1; cap <= 128; cap++)
		for (uint64_t used=0; used <= 140; used++)
			for (uint64_t request=0; request <= 140; request++)
				assert(gpu_sort_buffer_can_allocate(cap, used, request) ==
					   (used + request <= cap));
	assert(gpu_sort_buffer_can_allocate(0, 100, 200));
	assert(gpu_sort_buffer_can_allocate(UINT64_MAX, UINT64_MAX-1, 1));
	assert(!gpu_sort_buffer_can_allocate(0, UINT64_MAX, 1));
	assert(!gpu_sort_buffer_can_allocate(UINT64_MAX, UINT64_MAX-1, 2));
	/* Three retained 16MB chunks + a 40MB replacement cannot fit 64MB.
	 * Reserving just replacement-minus-old would incorrectly admit it. */
	assert(!gpu_sort_buffer_can_allocate(64ULL<<20, 48ULL<<20, 40ULL<<20));
	assert(gpu_sort_buffer_can_allocate(128ULL<<20, 48ULL<<20, 40ULL<<20));
	puts("GPU-Sort live-buffer cap arithmetic: PASS");
	return 0;
}
