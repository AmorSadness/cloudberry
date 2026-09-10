/* Allocation FIFO shared by independent GPU Services. Caller holds ledger mutex.
 * No PostgreSQL/CUDA dependencies: exercise the real queue in CPU-only tests. */
#ifndef GPU_BUDGET_QUEUE_H
#define GPU_BUDGET_QUEUE_H
#include <stdint.h>
#include <stdbool.h>

#define GPU_BUDGET_QUEUE_SLOTS 1024
typedef struct
{
    uint64_t ticket;                 /* zero means unused */
    unsigned owner;                  /* ledger owner slot + 1 */
} GpuBudgetWaiter;
typedef struct
{
    uint64_t next_ticket;
    GpuBudgetWaiter waiters[GPU_BUDGET_QUEUE_SLOTS];
} GpuBudgetQueue;

static inline uint64_t
gpu_budget_queue_head(const GpuBudgetQueue *queue)
{
    uint64_t head = 0;
    for (unsigned i = 0; i < GPU_BUDGET_QUEUE_SLOTS; i++)
        if (queue->waiters[i].ticket &&
            (!head || queue->waiters[i].ticket < head))
            head = queue->waiters[i].ticket;
    return head;
}

static inline int
gpu_budget_queue_push(GpuBudgetQueue *queue, unsigned owner)
{
    /* Never wrap ahead of outstanding tickets. Reset only an empty queue. */
    if (queue->next_ticket == UINT64_MAX)
    {
        if (gpu_budget_queue_head(queue))
            return -1;
        queue->next_ticket = 0;
    }
    for (unsigned i = 0; i < GPU_BUDGET_QUEUE_SLOTS; i++)
        if (!queue->waiters[i].ticket)
        {
            queue->waiters[i].owner = owner;
            queue->waiters[i].ticket = ++queue->next_ticket;
            return (int)i;
        }
    return -1;
}

static inline bool
gpu_budget_queue_can_admit(const GpuBudgetQueue *queue, int slot,
                          uint64_t bytes, uint64_t budget, uint64_t reserved)
{
    uint64_t head = gpu_budget_queue_head(queue);
    return (head == 0 || (slot >= 0 && head == queue->waiters[slot].ticket)) &&
           bytes <= budget && reserved <= budget - bytes;
}

static inline void
gpu_budget_queue_remove(GpuBudgetQueue *queue, int slot)
{
    if (slot >= 0)
    {
        queue->waiters[slot].ticket = 0;
        queue->waiters[slot].owner = 0;
    }
}

static inline void
gpu_budget_queue_remove_owner(GpuBudgetQueue *queue, unsigned owner)
{
    for (unsigned i = 0; i < GPU_BUDGET_QUEUE_SLOTS; i++)
        if (queue->waiters[i].owner == owner)
            gpu_budget_queue_remove(queue, (int)i);
}
#endif
