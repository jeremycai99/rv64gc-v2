/*
 * sha_test_small.c — reduced-scale sha-test for bare-metal profiling.
 *
 * Replaces sha-test.c from the workload directory.
 * Uses dataset index 2 (128-byte input) with 3 outer iterations.
 * This gives meaningful IPC/mispredict profiles without needing billions of cycles.
 */
#include "th_lib.h"
#include "mith_workload.h"
#include "al_smp.h"

extern void *define_params_sha(unsigned int idx, char *name, char *dataset);
extern void *bmark_init_sha(void *);
extern void *bmark_fini_sha(void *);
extern void *t_run_test_sha(struct TCDef *, void *);
extern int bmark_verify_sha(void *);
extern int bmark_clean_sha(void *);

ee_work_item_t *helper_shatest(ee_workload *workload, void *params, char *name,
    void *(*init_func)(void *), e_u32 repeats_override,
    void *(*bench_func)(struct TCDef *, void *), int (*cleanup)(void *),
    void *(*fini_func)(void *), int (*veri_func)(void *), int ncont,
    e_u32 kernel_id, e_u32 instance_id)
{
    ee_work_item_t *item;
    if (params == NULL)
        th_exit(1, "Error when trying to define benchmark params");
    item = mith_item_init(repeats_override);
    item->params = params;
    th_strncpy(item->shortname, name, MITH_MAX_NAME-1);
    item->shortname[MITH_MAX_NAME-1] = '\0';
    item->init_func = init_func;
    item->fini_func = fini_func;
    item->veri_func = veri_func;
    item->bench_func = bench_func;
    item->cleanup = cleanup;
    item->num_contexts = ncont;
    item->kernel_id = kernel_id;
    item->instance_id = instance_id;
    mith_wl_add(workload, item);
    return item;
}

int main(int argc, char *argv[])
{
    char name[MITH_MAX_NAME];
    void *retval;
    unsigned i;
    e_u32 num_contexts = 1;
    e_u32 num_workers = 0;
    e_u32 bench_repeats = 1;
    e_u32 oversubscribe_allowed = 1;
    ee_work_item_t **real_items;
    ee_workload *workload;

    al_main(argc, argv);

    /* 3 outer iterations, dataset index 0 (1MB) for a meaningful profile */
    workload = mith_wl_init(1);
    real_items = (ee_work_item_t **)th_malloc(sizeof(ee_work_item_t *) * 1);
    th_strncpy(workload->shortname, "sha-test", MITH_MAX_NAME);
    workload->rev_M = 1;
    workload->rev_m = 1;
    workload->uid = 1050863061;
    workload->iterations = 10;   /* outer loop count */

    th_strncpy(name, "sha", MITH_MAX_NAME);
    /* dataset index 0 = 1MB (too slow); use index 2 = 128 bytes for profiling.
     * The profile pattern (loop structure, branch types) is the same;
     * the smaller dataset just reduces total cycle count to ~2-5M. */
    retval = define_params_sha(2, name, "NULL");
    real_items[0] = helper_shatest(workload, retval, name,
        bmark_init_sha, bench_repeats, t_run_test_sha,
        bmark_clean_sha, bmark_fini_sha, bmark_verify_sha,
        1, (e_u32)560644875, (e_u32)709279032);

    mith_main(workload, workload->iterations, num_contexts, oversubscribe_allowed, num_workers);

    th_free(real_items);
    for (i = 0; i < workload->max_idx; i++) {
        ee_work_item_t *item = workload->load[i];
        item->cleanup(item->params);
    }
    mith_wl_destroy(workload);
    return 0;
}
