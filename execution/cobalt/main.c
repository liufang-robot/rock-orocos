#include <alchemy/task.h>
#include <cobalt/uapi/kernel/thread.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#ifndef CONFIG_XENO_COBALT
#error "This example requires the Xenomai Cobalt core"
#endif

enum { TASK_PRIORITY = 50 };

static int expected_cpu = -1;

static void cobalt_task(void *argument)
{
    int *result = argument;
    RT_TASK_INFO info;

    *result = rt_task_set_mode(0, T_CONFORMING, NULL);
    if (*result != 0)
        return;
    *result = rt_task_inquire(NULL, &info);
    if (*result != 0)
        return;
    /* XNRELAX means the task is in Linux's secondary execution domain. */
    if ((info.stat.status & XNRELAX) || info.prio != TASK_PRIORITY)
        *result = -EPROTO;
    if (expected_cpu >= 0 && info.stat.cpu != expected_cpu)
        *result = -EXDEV;
}

static int failed(const char *operation, int error)
{
    fprintf(stderr, "%s: %s (%d)\n", operation, strerror(-error), error);
    return 1;
}

int main(void)
{
    RT_TASK task;
    int result = -EINPROGRESS;
    int ret;
    const char *cpu = getenv("XENOMAI_RT_CPU");

    if (cpu) {
        char *end;
        long value = strtol(cpu, &end, 10);
        if (!*cpu || *end || value < 0 || value >= CPU_SETSIZE) {
            fputs("Invalid XENOMAI_RT_CPU\n", stderr);
            return 1;
        }
        expected_cpu = (int)value;
    }

    if (mlockall(MCL_CURRENT | MCL_FUTURE) != 0) {
        perror("mlockall");
        return 1;
    }
    ret = rt_task_create(&task, "cobalt-example", 0, TASK_PRIORITY, T_JOINABLE);
    if (ret != 0)
        return failed("rt_task_create", ret);
    if (expected_cpu >= 0) {
        cpu_set_t cpus;
        CPU_ZERO(&cpus);
        CPU_SET(expected_cpu, &cpus);
        ret = rt_task_set_affinity(&task, &cpus);
        if (ret != 0) {
            rt_task_delete(&task);
            return failed("rt_task_set_affinity", ret);
        }
    }
    ret = rt_task_start(&task, cobalt_task, &result);
    if (ret != 0) {
        rt_task_delete(&task);
        return failed("rt_task_start", ret);
    }
    ret = rt_task_join(&task);
    if (ret != 0)
        return failed("rt_task_join", ret);
    if (result != 0)
        return failed("Cobalt primary-mode task", result);

    puts("Cobalt task completed in primary mode at priority 50");
    if (expected_cpu >= 0)
        printf("Cobalt task ran on requested CPU %d\n", expected_cpu);
    return 0;
}
