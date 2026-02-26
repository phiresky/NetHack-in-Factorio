/* NetHack 3.6 Factorio port configuration header */
#ifndef FACTORIOCONF_H
#define FACTORIOCONF_H

/* Factorio window port */
#define FACTORIO_GRAPHICS
#define FACTORIO_PORT

/* Use safeprocs as a base */
#define SAFEPROCS

/* We support clipping */
#define CLIPPING

/* Enable text tombstone (genl_outrip in rip.c) */
#define TEXT_TOMBSTONE

/* No signals in WASM */
#define NO_SIGNAL

/* Disable TTY graphics - we provide our own */
#define NOTTYGRAPHICS

/* Default window system */
#ifndef DEFAULT_WINDOW_SYS
#define DEFAULT_WINDOW_SYS "factorio"
#endif

/* Disable features we don't need or can't support in WASM */
#define NOMAIL
#define NO_FILE_LINKS

/* File creation mask */
#ifndef FCMASK
#define FCMASK 0660
#endif

/* Lock file name */
#ifndef HLOCK
#define HLOCK "NHPERM"
#endif

/* We need POSIX types for compat */
#define POSIX_TYPES

/* Disable shell escape */
/* #undef SHELL */

/* Disable suspend */
/* #undef SIGTSTP */

/* Disable panic trace (no gdb in WASM) */
/* #undef PANICTRACE */

/* Ensure we have syscf support for sysconf defaults */
#define SYSCF

#endif /* FACTORIOCONF_H */
