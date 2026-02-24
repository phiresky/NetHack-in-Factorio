/* wasi_compat.h - WASI compatibility stubs for missing POSIX features.
 * Force-included via -include wasi_compat.h before all source files. */
#ifndef WASI_COMPAT_H
#define WASI_COMPAT_H

/* NetHack's unixconf.h defines USE_FCNTL when POSIX_TYPES is set,
 * but wasi-libc lacks fcntl file locking constants and implementation.
 * Provide stub definitions so the code compiles (locking is a no-op
 * in single-instance WASM). struct flock is provided by wasi-libc. */
#ifndef F_SETLK
#define F_SETLK  6
#endif
#ifndef F_WRLCK
#define F_WRLCK  1
#endif
#ifndef F_UNLCK
#define F_UNLCK  2
#endif

/* fcntl stub: file locking is a no-op in WASM.
 * wasi-libc declares fcntl() but doesn't implement locking commands.
 * This macro redirects all fcntl calls to our no-op stub. */
static inline int __wasi_fcntl_stub(int fd, int cmd, ...) { return 0; }
#define fcntl __wasi_fcntl_stub

/* wasi-libc has signal.h with SIG_IGN etc. but NetHack doesn't include it.
 * Pull it in so UNIX-guarded code using SIG_IGN compiles. */
#include <signal.h>

#endif /* WASI_COMPAT_H */
