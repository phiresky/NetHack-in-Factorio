/* pwd.h stub for WASI - wasi-libc doesn't provide pwd.h.
 * NetHack's mail.c includes it under #ifdef UNIX, but mail
 * is disabled (NOMAIL). This stub satisfies the include. */
#ifndef _PWD_H_STUB
#define _PWD_H_STUB

#include <sys/types.h>

struct passwd {
    char *pw_name;
    char *pw_dir;
    uid_t pw_uid;
    gid_t pw_gid;
};

static inline struct passwd *getpwuid(uid_t uid) { (void)uid; return 0; }
static inline struct passwd *getpwnam(const char *n) { (void)n; return 0; }

#endif /* _PWD_H_STUB */
