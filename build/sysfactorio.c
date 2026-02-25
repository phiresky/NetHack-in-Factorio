/* NetHack 3.6 sysfactorio.c - System stubs for Factorio WASM build */
/* Copyright (c) 2026, NetHack-Factorio project */
/* NetHack may be freely redistributed.  See license for details. */

/*
 * This file provides replacements for Unix-specific system functions
 * that NetHack expects. In the WASM environment, most of these are
 * no-ops or return stub values.
 *
 * It replaces the functionality from:
 *   sys/unix/unixmain.c  (main entry point, command line processing)
 *   sys/unix/unixunix.c  (file locking, process management)
 *   sys/unix/unixres.c   (privilege management)
 */

#define NEED_VARARGS
#include "hack.h"
#include "dlb.h"

/* External reference to the factorio window procs */
extern struct window_procs factorio_procs;

/* ================================================================
 * Main entry point
 *
 * In the WASM build, main() does minimal initialization and then
 * enters the game loop. No command-line processing, no file locking,
 * no signal handling.
 * ================================================================ */

int
main(argc, argv)
int argc;
char *argv[];
{
    boolean resuming = FALSE;

    sys_early_init();

    hname = "nethack";
    hackpid = 1;

    /* Install the factorio window port directly */
    windowprocs = factorio_procs;

    initoptions();

    u.uhp = 1; /* prevent RIP on early quits */

    dlb_init(); /* must be before newgame() */

    vision_init();

    display_gamewindows();

    /* Ask the player for their name (uses getlin prompt) */
    askname();
    plnamesuffix();

    /* getlock() creates the lock file */
    getlock();

    /* No save file restoration in this minimal build - always new game */
    player_selection();
    newgame();

    /* moveloop() never returns */
    moveloop(resuming);

    return 0;
}

/* ================================================================
 * Functions from unixunix.c that we need to stub
 * ================================================================ */

/*
 * getlock() - In Unix, this manages lock files to prevent multiple
 * games from running. In WASM, we're always single-instance.
 */
void
getlock()
{
    /* Create a fake lock name so the rest of NetHack is happy */
    Sprintf(lock, "%d%s", (int) getuid(), plname);
    regularize(lock);

    /* Create the level 0 file (lock/checkpoint file) with our PID.
     * save_currentstate() expects it to exist with a valid PID. */
    {
        int fd;
        Sprintf(lock, "%d%s", (int) getuid(), plname);
        regularize(lock);
        set_levelfile_name(lock, 0);
        fd = create_levelfile(0, (char *) 0);
        if (fd >= 0) {
            if (write(fd, (genericptr_t) &hackpid, sizeof hackpid)
                != sizeof hackpid) {
                /* error writing pid, but continue anyway */
            }
            close(fd);
        }
    }
}

/*
 * regularize() - Normalize a file name (remove dots, slashes, spaces).
 * Keep this functional since it's used on player names for save files.
 */
void
regularize(s)
register char *s;
{
    register char *lp;

    while ((lp = index(s, '.')) != 0
           || (lp = index(s, '/')) != 0
           || (lp = index(s, ' ')) != 0)
        *lp = '_';
}

/* ================================================================
 * Functions from unixmain.c that we need to stub
 * ================================================================ */

/*
 * sethanguphandler() - Set signal handler for hangup.
 * No signals in WASM.
 */
void
sethanguphandler(handler)
void FDECL((*handler), (int));
{
    /* no-op */
    nhUse(handler);
}

/*
 * authorize_wizard_mode() / authorize_explore_mode()
 * Always allow in the Factorio build.
 */
boolean
authorize_wizard_mode()
{
    return TRUE;
}

boolean
authorize_explore_mode()
{
    return TRUE;
}

/*
 * get_login_name() - Return the current user's login name.
 */
char *
get_login_name()
{
    static char buf[BUFSZ];
    Strcpy(buf, "player");
    return buf;
}

/*
 * append_slash() - Add a trailing slash to a path if not present.
 */
void
append_slash(name)
char *name;
{
    char *ptr;

    if (!*name)
        return;
    ptr = name + (strlen(name) - 1);
    if (*ptr != '/') {
        *++ptr = '/';
        *++ptr = '\0';
    }
}

/*
 * check_user_string() - Check if the current user matches a string.
 * Always return TRUE in WASM (no user restrictions).
 */
boolean
check_user_string(optstr)
char *optstr UNUSED;
{
    return TRUE;
}

/* ================================================================
 * POSIX / system call stubs
 * ================================================================ */

/*
 * sys_random_seed() - Provide a random seed.
 * In WASM, we use a simple time-based seed.
 */
unsigned long
sys_random_seed()
{
    unsigned long seed;

    seed = (unsigned long) getnow();
    if (!seed)
        seed = 42;
    return seed;
}

/* wasi-libc doesn't provide these POSIX functions */
uid_t getuid(void) { return 1000; }
gid_t getgid(void) { return 1000; }
int getpid(void) { return 1; }

/* ================================================================
 * Unix-specific function stubs (referenced but not needed in WASM)
 * ================================================================ */

/* Shell escape - not available in WASM */
int
dosh()
{
    return 0;
}

/* Suspend (ctrl-Z) - not available in WASM */
int
dosuspend()
{
    return 0;
}

/* Enable/disable keyboard interrupts - no-op in WASM */
void
intron()
{
}

void
introff()
{
}

/* Check if a file exists */
boolean
file_exists(path)
const char *path;
{
    FILE *f = fopen(path, "r");
    if (f) {
        fclose(f);
        return TRUE;
    }
    return FALSE;
}

/* error() - fatal error handler */
void
error VA_DECL(const char *, s)
{
    char buf[BUFSZ];
    VA_START(s);
    VA_INIT(s, const char *);

    vsprintf(buf, s, the_args);
    raw_printf("Error: %s", buf);

    VA_END();
    nh_terminate(EXIT_FAILURE);
}

/* sysfactorio.c */
