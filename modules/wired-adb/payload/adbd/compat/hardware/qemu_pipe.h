/* HMG-Seogaemo: stand-in for hardware/libhardware's qemu_pipe.h. The cable adbd
 * never runs in the Android emulator, so the pipe never opens. */
#ifndef HMG_SEOGAEMO_QEMU_PIPE_H
#define HMG_SEOGAEMO_QEMU_PIPE_H
#include <errno.h>
static inline int qemu_pipe_open(const char *name)
{
    (void)name;
    errno = ENOENT;
    return -1;
}
#endif
