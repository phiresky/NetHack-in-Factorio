/* NetHack 3.7 sysfactorio.c - System stubs for Factorio WASM build */
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

#include "hack.h"

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
main(int argc, char *argv[])
{
    boolean resuming = FALSE;

    early_init(argc, argv);

    gh.hname = "nethack";
    svh.hackpid = 1;

    /* Install the factorio window port directly */
    windowprocs = factorio_procs;

    initoptions();

    /* Set player name directly - no whoami/getlogin needed */
    if (!*svp.plname)
        Strcpy(svp.plname, "Player");

    u.uhp = 1; /* prevent RIP on early quits */

    plnamesuffix();

    vision_init();
    init_sound_disp_gamewindows();

    /* Create level 0 file (lock/checkpoint file) with our PID.
     * Platform mains (pcmain.c, unixmain.c) do this before newgame().
     * save_currentstate() expects it to exist with a valid PID. */
    {
        NHFILE *nhfp = create_levelfile(0, (char *) 0);
        if (nhfp) {
            Sfo_int(nhfp, &svh.hackpid, "svh.hackpid");
            close_nhfile(nhfp);
        }
    }

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
getlock(void)
{
    /* Create a fake lock name so the rest of NetHack is happy */
    Sprintf(gl.lock, "1lock");
    /* No actual file locking needed in WASM */
}

/*
 * regularize() - Normalize a file name (remove dots, slashes, spaces).
 * Keep this functional since it's used on player names for save files.
 */
void
regularize(char *s)
{
    char *lp;

    while ((lp = strchr(s, '.')) != 0
           || (lp = strchr(s, '/')) != 0
           || (lp = strchr(s, ' ')) != 0)
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
sethanguphandler(void (*handler)(int) UNUSED)
{
    /* no-op */
}

/*
 * authorize_wizard_mode() / authorize_explore_mode()
 * Always allow in the Factorio build.
 */
boolean
authorize_wizard_mode(void)
{
    return TRUE;
}

boolean
authorize_explore_mode(void)
{
    return TRUE;
}

/*
 * get_login_name() - Return the current user's login name.
 */
char *
get_login_name(void)
{
    static char buf[BUFSZ];
    Strcpy(buf, "player");
    return buf;
}

/*
 * append_slash() - Add a trailing slash to a path if not present.
 */
void
append_slash(char *name)
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
check_user_string(const char *optstr UNUSED)
{
    return TRUE;
}

/*
 * ask_about_panic_save() - Handle panic save recovery prompt.
 * In WASM, just proceed with new game.
 */
void
ask_about_panic_save(void)
{
    return;
}

/* ================================================================
 * POSIX / system call stubs
 * ================================================================ */

/*
 * sys_random_seed() - Provide a random seed.
 * In WASM, we use a simple time-based seed.
 */
unsigned long
sys_random_seed(void)
{
    unsigned long seed;

    seed = (unsigned long) getnow();
    if (!seed)
        seed = 42;
    return seed;
}

#ifndef __EMSCRIPTEN__
/* These are only needed if Emscripten doesn't provide them.
 * Emscripten's libc normally supplies these, but if we're using
 * -s NO_FILESYSTEM or very minimal builds, we may need stubs. */

int getuid(void) { return 1000; }
int getgid(void) { return 1000; }
int getpid(void) { return 1; }
#endif

/* ================================================================
 * Unix-specific function stubs (referenced but not needed in WASM)
 * ================================================================ */

/* Shell escape - not available in WASM */
int
dosh(void)
{
    return 0;
}

/* Suspend (ctrl-Z) - not available in WASM */
int
dosuspend(void)
{
    return 0;
}

/* Enable/disable keyboard interrupts - no-op in WASM */
void
intron(void)
{
}

void
introff(void)
{
}

/* Check if a file exists */
boolean
file_exists(const char *path)
{
    FILE *f = fopen(path, "r");
    if (f) {
        fclose(f);
        return TRUE;
    }
    return FALSE;
}

/* after_opt_showpaths() - show file paths then exit (--showpaths option) */
void
after_opt_showpaths(const char *dir UNUSED)
{
    nh_terminate(EXIT_SUCCESS);
}

/* error() - fatal error handler */
void
error(const char *fmt, ...)
{
    va_list ap;
    char buf[BUFSZ];

    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    raw_printf("Error: %s", buf);
    nh_terminate(EXIT_FAILURE);
}

/* sysfactorio.c */
