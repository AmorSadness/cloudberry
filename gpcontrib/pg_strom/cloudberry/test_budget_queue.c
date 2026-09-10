/* CPU-only invariants for the exact FIFO used by gpu_service.c. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../src/gpu_budget_queue.h"

int main(void)
{
    GpuBudgetQueue q = {0};
    int large = gpu_budget_queue_push(&q, 1);
    int small = gpu_budget_queue_push(&q, 2);
    int next = gpu_budget_queue_push(&q, 1);
    assert(gpu_budget_queue_head(&q) == q.waiters[large].ticket);
    /* A small request cannot pass the head merely because it fits. */
    assert(gpu_budget_queue_head(&q) != q.waiters[small].ticket);
    assert(!gpu_budget_queue_can_admit(&q, large, 80, 100, 30));
    assert(!gpu_budget_queue_can_admit(&q, small, 10, 100, 30));
    assert(!gpu_budget_queue_can_admit(&q, -1, 1, 100, 0));
    assert(gpu_budget_queue_can_admit(&q, large, 80, 100, 20));
    gpu_budget_queue_remove(&q, large); /* cancel/timeout */
    assert(gpu_budget_queue_head(&q) == q.waiters[small].ticket);
    gpu_budget_queue_remove_owner(&q, 2); /* Service death */
    assert(gpu_budget_queue_head(&q) == q.waiters[next].ticket);
    gpu_budget_queue_remove_owner(&q, 1);
    assert(!gpu_budget_queue_head(&q));
    assert(gpu_budget_queue_can_admit(&q, -1, 10, 100, 90));
    assert(!gpu_budget_queue_can_admit(&q, -1, UINT64_MAX, 100, 0));
    assert(!gpu_budget_queue_can_admit(&q, -1, 1, 100, UINT64_MAX));
    for (unsigned i = 0; i < GPU_BUDGET_QUEUE_SLOTS; i++)
        assert(gpu_budget_queue_push(&q, i % 128 + 1) >= 0);
    assert(gpu_budget_queue_push(&q, 1) == -1);
    gpu_budget_queue_remove(&q, 7);
    assert(gpu_budget_queue_push(&q, 129) == 7);
    assert(gpu_budget_queue_head(&q) == q.waiters[0].ticket);
    memset(&q, 0, sizeof(q));
    q.next_ticket = UINT64_MAX - 1;
    large = gpu_budget_queue_push(&q, 1);
    assert(q.waiters[large].ticket == UINT64_MAX);
    assert(gpu_budget_queue_push(&q, 2) == -1);
    gpu_budget_queue_remove(&q, large);
    small = gpu_budget_queue_push(&q, 2);
    assert(q.waiters[small].ticket == 1);
    puts("GPU budget FIFO invariants: PASS");
    return 0;
}
