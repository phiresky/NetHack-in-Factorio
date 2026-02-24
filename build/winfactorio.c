/* NetHack 3.7 winfactorio.c - Factorio WASM window port */
/* Copyright (c) 2026, NetHack-Factorio project */
/* NetHack may be freely redistributed.  See license for details. */

#include "hack.h"
#include "func_tab.h"

/*
 * Factorio window port for NetHack.
 *
 * This implements the window_procs interface by forwarding display and
 * input calls to WASM host imports, which are provided by the Lua runtime
 * in Factorio. Functions that don't need host interaction are no-op stubs.
 *
 * Based on the safe_procs template in win/share/safeproc.c.
 */

/* ================================================================
 * WASM imports - provided by the Lua host environment.
 * Declared as extern functions; Emscripten generates WASM import
 * entries for them. The Lua WASM interpreter supplies implementations.
 * ================================================================ */

extern int host_nhgetch(void);
extern void host_print_glyph(int x, int y, int ch, int color, int special);
extern void host_putstr(int win_type, int attr, const char *str, int len);
extern void host_raw_print(const char *str, int len);
extern void host_status_update(int idx, const char *val, int len,
                               int color, int percent);
extern void host_start_menu(int winid);
extern void host_add_menu_item(int winid, int glyph, int identifier,
                               int accelerator, int group_accel, int attr,
                               const char *str, int len, int preselected);
extern void host_end_menu(int winid, const char *prompt, int prompt_len);
extern int host_select_menu(int winid, int how);
extern void host_yn_function(const char *query, int qlen,
                             const char *resp, int rlen, char def);
extern void host_getlin(const char *prompt, int len);
extern int host_create_nhwindow(int type);
extern void host_display_nhwindow(int winid, int blocking);
extern void host_clear_nhwindow(int winid);
extern void host_destroy_nhwindow(int winid);
extern void host_exit_nhwindows(const char *str, int len);
extern void host_curs(int winid, int x, int y);
extern void host_cliparound(int x, int y);
extern void host_delay_output(void);
extern void host_update_inventory(int arg);
extern void host_mark_synch(void);

/* ================================================================
 * Forward declarations for all window port functions
 * ================================================================ */

static void factorio_init_nhwindows(int *, char **);
static void factorio_player_selection(void);
static void factorio_askname(void);
static void factorio_get_nh_event(void);
static void factorio_exit_nhwindows(const char *);
static void factorio_suspend_nhwindows(const char *);
static void factorio_resume_nhwindows(void);
static winid factorio_create_nhwindow(int);
static void factorio_clear_nhwindow(winid);
static void factorio_display_nhwindow(winid, boolean);
static void factorio_destroy_nhwindow(winid);
static void factorio_curs(winid, int, int);
static void factorio_putstr(winid, int, const char *);
static void factorio_putmixed(winid, int, const char *);
static void factorio_display_file(const char *, boolean);
static void factorio_start_menu(winid, unsigned long);
static void factorio_add_menu(winid, const glyph_info *, const ANY_P *,
                              char, char, int, int, const char *,
                              unsigned int);
static void factorio_end_menu(winid, const char *);
static int factorio_select_menu(winid, int, MENU_ITEM_P **);
static char factorio_message_menu(char, int, const char *);
static void factorio_mark_synch(void);
static void factorio_wait_synch(void);
#ifdef CLIPPING
static void factorio_cliparound(int, int);
#endif
static void factorio_print_glyph(winid, coordxy, coordxy,
                                 const glyph_info *, const glyph_info *);
static void factorio_raw_print(const char *);
static void factorio_raw_print_bold(const char *);
static int factorio_nhgetch(void);
static int factorio_nh_poskey(coordxy *, coordxy *, int *);
static void factorio_nhbell(void);
static int factorio_doprev_message(void);
static char factorio_yn_function(const char *, const char *, char);
static void factorio_getlin(const char *, char *);
static int factorio_get_ext_cmd(void);
static void factorio_number_pad(int);
static void factorio_delay_output(void);
static void factorio_outrip(winid, int, time_t);
static void factorio_preference_update(const char *);
static char *factorio_getmsghistory(boolean);
static void factorio_putmsghistory(const char *, boolean);
static void factorio_status_init(void);
static void factorio_status_finish(void);
static void factorio_status_enablefield(int, const char *, const char *,
                                        boolean);
static void factorio_status_update(int, genericptr_t, int, int, int,
                                   unsigned long *);
static boolean factorio_can_suspend(void);
static void factorio_update_inventory(int);
static win_request_info *factorio_ctrl_nhwindow(winid, int,
                                                win_request_info *);

/* ================================================================
 * The window_procs structure - registered with NetHack core
 * ================================================================ */

struct window_procs factorio_procs = {
    "factorio",
    wp_safestartup, /* reuse safestartup id; no dedicated enum value */
    (WC_COLOR | WC_HILITE_PET | WC_ASCII_MAP | WC_INVERSE
     | WC_EIGHT_BIT_IN),
    (WC2_DARKGRAY | WC2_SUPPRESS_HIST | WC2_URGENT_MESG
     | WC2_FLUSH_STATUS | WC2_RESET_STATUS
#ifdef STATUS_HILITES
     | WC2_HILITE_STATUS | WC2_HITPOINTBAR
#endif
     | WC2_STATUSLINES),
    {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}, /* color avail */
    factorio_init_nhwindows,
    factorio_player_selection,
    factorio_askname,
    factorio_get_nh_event,
    factorio_exit_nhwindows,
    factorio_suspend_nhwindows,
    factorio_resume_nhwindows,
    factorio_create_nhwindow,
    factorio_clear_nhwindow,
    factorio_display_nhwindow,
    factorio_destroy_nhwindow,
    factorio_curs,
    factorio_putstr,
    factorio_putmixed,
    factorio_display_file,
    factorio_start_menu,
    factorio_add_menu,
    factorio_end_menu,
    factorio_select_menu,
    factorio_message_menu,
    factorio_mark_synch,
    factorio_wait_synch,
#ifdef CLIPPING
    factorio_cliparound,
#endif
#ifdef POSITIONBAR
    (void (*)(char *)) 0, /* update_positionbar - not supported */
#endif
    factorio_print_glyph,
    factorio_raw_print,
    factorio_raw_print_bold,
    factorio_nhgetch,
    factorio_nh_poskey,
    factorio_nhbell,
    factorio_doprev_message,
    factorio_yn_function,
    factorio_getlin,
    factorio_get_ext_cmd,
    factorio_number_pad,
    factorio_delay_output,
#ifdef CHANGE_COLOR
    (void (*)(int, long, int)) 0, /* change_color */
#ifdef MAC
    (void (*)(int)) 0,            /* change_background */
    (short (*)(winid, char *)) 0, /* set_font_name */
#endif
    (char *(*)(void)) 0,          /* get_color_string */
#endif
    factorio_outrip,
    factorio_preference_update,
    factorio_getmsghistory,
    factorio_putmsghistory,
    factorio_status_init,
    factorio_status_finish,
    factorio_status_enablefield,
    factorio_status_update,
    factorio_can_suspend,
    factorio_update_inventory,
    factorio_ctrl_nhwindow,
};

/* ================================================================
 * Implementation of window port functions
 * ================================================================ */

static void
factorio_init_nhwindows(int *argcp UNUSED, char **argv UNUSED)
{
    iflags.window_inited = TRUE;
}

static void
factorio_player_selection(void)
{
    /* Auto-select: random role, race, gender, alignment.
     * This avoids interactive character creation menus. */
    if (flags.initrole < 0)
        flags.initrole = ROLE_RANDOM;
    if (flags.initrace < 0)
        flags.initrace = ROLE_RANDOM;
    if (flags.initgend < 0)
        flags.initgend = ROLE_RANDOM;
    if (flags.initalign < 0)
        flags.initalign = ROLE_RANDOM;
    flags.randomall = 1;
}

static void
factorio_askname(void)
{
    Strcpy(svp.plname, "Player");
}

static void
factorio_get_nh_event(void)
{
    /* no-op */
}

static void
factorio_exit_nhwindows(const char *str)
{
    if (str) {
        host_exit_nhwindows(str, (int) strlen(str));
    } else {
        host_exit_nhwindows("", 0);
    }
}

static void
factorio_suspend_nhwindows(const char *str UNUSED)
{
    /* cannot suspend in WASM */
}

static void
factorio_resume_nhwindows(void)
{
    /* no-op */
}

static winid
factorio_create_nhwindow(int type)
{
    return (winid) host_create_nhwindow(type);
}

static void
factorio_clear_nhwindow(winid window)
{
    host_clear_nhwindow((int) window);
}

static void
factorio_display_nhwindow(winid window, boolean blocking)
{
    host_display_nhwindow((int) window, (int) blocking);
}

static void
factorio_destroy_nhwindow(winid window)
{
    host_destroy_nhwindow((int) window);
}

static void
factorio_curs(winid window, int x, int y)
{
    host_curs((int) window, x, y);
}

static void
factorio_putstr(winid window, int attr, const char *str)
{
    if (str) {
        host_putstr((int) window, attr, str, (int) strlen(str));
    }
}

static void
factorio_putmixed(winid window, int attr, const char *str)
{
    /* putmixed handles encoded glyphs in strings; for our port
     * we just treat it like putstr since the Lua side handles
     * display anyway */
    factorio_putstr(window, attr, str);
}

static void
factorio_display_file(const char *fname UNUSED, boolean complain UNUSED)
{
    /* no-op: we don't display help files etc. in Factorio */
}

static void
factorio_start_menu(winid window, unsigned long mbehavior UNUSED)
{
    host_start_menu((int) window);
}

static void
factorio_add_menu(
    winid window,
    const glyph_info *glyphinfo,
    const anything *identifier,
    char ch,
    char gch,
    int attr,
    int clr UNUSED,
    const char *str,
    unsigned int itemflags)
{
    int glyph_val = glyphinfo ? glyphinfo->glyph : 0;
    int id_val = identifier ? identifier->a_int : 0;
    int presel = (itemflags & MENU_ITEMFLAGS_SELECTED) ? 1 : 0;

    if (str) {
        host_add_menu_item((int) window, glyph_val, id_val,
                           (int) ch, (int) gch, attr,
                           str, (int) strlen(str), presel);
    }
}

static void
factorio_end_menu(winid window, const char *prompt)
{
    if (prompt) {
        host_end_menu((int) window, prompt, (int) strlen(prompt));
    } else {
        host_end_menu((int) window, "", 0);
    }
}

static int
factorio_select_menu(winid window, int how, menu_item **menu_list)
{
    int result;

    *menu_list = (menu_item *) 0;
    result = host_select_menu((int) window, how);

    if (result > 0) {
        /* The host will have communicated selection(s) through
         * a separate mechanism. For single-pick menus, we need
         * to allocate and return the selection.
         * The host returns the selected identifier via nhgetch. */
        int sel_id = host_nhgetch();

        *menu_list = (menu_item *) alloc(sizeof(menu_item));
        (*menu_list)->item.a_int = sel_id;
        (*menu_list)->count = -1;
        (*menu_list)->itemflags = 0;
        return 1;
    }
    return result; /* 0 = nothing selected, -1 = cancelled */
}

static char
factorio_message_menu(char let UNUSED, int how UNUSED,
                      const char *mesg UNUSED)
{
    return '\033';
}

static void
factorio_mark_synch(void)
{
    host_mark_synch();
}

static void
factorio_wait_synch(void)
{
    /* no-op: Factorio renders synchronously */
}

#ifdef CLIPPING
static void
factorio_cliparound(int x, int y)
{
    host_cliparound(x, y);
}
#endif

/*
 * Print a glyph at position (x,y) on the map window.
 * Extract the TTY character and color from the glyph_info struct.
 */
static void
factorio_print_glyph(
    winid window UNUSED,
    coordxy x,
    coordxy y,
    const glyph_info *glyphinfo,
    const glyph_info *bkglyphinfo UNUSED)
{
    if (glyphinfo) {
        host_print_glyph(x, y,
                         glyphinfo->ttychar,
                         glyphinfo->gm.sym.color,
                         (int) glyphinfo->gm.glyphflags);
    }
}

static void
factorio_raw_print(const char *str)
{
    if (str) {
        host_raw_print(str, (int) strlen(str));
    }
}

static void
factorio_raw_print_bold(const char *str)
{
    /* bold and normal are the same for our port */
    factorio_raw_print(str);
}

static int
factorio_nhgetch(void)
{
    /* This is the critical input function.
     * In the WASM interpreter, this import triggers a coroutine yield
     * back to the Lua host, which waits for player input. */
    return host_nhgetch();
}

static int
factorio_nh_poskey(coordxy *x, coordxy *y, int *mod)
{
    /* No mouse support; treat as regular key input */
    *x = 0;
    *y = 0;
    *mod = 0;
    return host_nhgetch();
}

static void
factorio_nhbell(void)
{
    /* no-op: no bell in Factorio */
}

static int
factorio_doprev_message(void)
{
    return 0;
}

static char
factorio_yn_function(const char *query, const char *resp, char def)
{
    int qlen = query ? (int) strlen(query) : 0;
    int rlen = resp ? (int) strlen(resp) : 0;

    /* Tell the host about the question */
    host_yn_function(query ? query : "", qlen,
                     resp ? resp : "", rlen, def);
    /* Then wait for the answer */
    return (char) host_nhgetch();
}

static void
factorio_getlin(const char *prompt, char *outbuf)
{
    int len = prompt ? (int) strlen(prompt) : 0;
    int i;
    int ch;

    /* Tell the host we need a line of input */
    host_getlin(prompt ? prompt : "", len);

    /* Read the response character by character from the host.
     * The host will feed characters followed by a null terminator. */
    for (i = 0; i < BUFSZ - 1; i++) {
        ch = host_nhgetch();
        if (ch == '\0' || ch == '\n' || ch == '\r' || ch == '\033')
            break;
        outbuf[i] = (char) ch;
    }
    outbuf[i] = '\0';

    if (ch == '\033') {
        /* Escape means cancel */
        outbuf[0] = '\033';
        outbuf[1] = '\0';
    }
}

static int
factorio_get_ext_cmd(void)
{
    /* Extended command selection - treat like getlin but for
     * the # command. Use the same mechanism. */
    char buf[BUFSZ];

    factorio_getlin("#", buf);
    if (buf[0] == '\033')
        return -1;

    /* Search extcmdlist for matching command name */
    {
        int i;
        for (i = 0; extcmdlist[i].ef_txt; i++) {
            if (!strcmpi(buf, extcmdlist[i].ef_txt))
                return i;
        }
    }
    return -1;
}

static void
factorio_number_pad(int mode UNUSED)
{
    /* no-op */
}

static void
factorio_delay_output(void)
{
    host_delay_output();
}

static void
factorio_outrip(winid tmpwin UNUSED, int how UNUSED, time_t when UNUSED)
{
    /* no-op: tombstone display handled by Lua side if desired */
}

static void
factorio_preference_update(const char *pref UNUSED)
{
    /* no-op */
}

static char *
factorio_getmsghistory(boolean init UNUSED)
{
    return (char *) 0;
}

static void
factorio_putmsghistory(const char *msg UNUSED, boolean is_restoring UNUSED)
{
    /* no-op */
}

static void
factorio_status_init(void)
{
    /* no-op */
}

static void
factorio_status_finish(void)
{
    /* no-op */
}

static void
factorio_status_enablefield(int fieldidx UNUSED, const char *nm UNUSED,
                            const char *fmt UNUSED, boolean enable UNUSED)
{
    /* no-op */
}

static void
factorio_status_update(int idx, genericptr_t ptr, int chg UNUSED,
                       int percent, int color,
                       unsigned long *colormasks UNUSED)
{
    const char *val;
    char numbuf[32];

    if (idx == BL_FLUSH || idx == BL_RESET) {
        /* Signal the host to refresh status display */
        host_status_update(idx, "", 0, 0, 0);
        return;
    }

    /* ptr is either a string or a long, depending on the field */
    if (idx == BL_CONDITION) {
        /* BL_CONDITION: ptr is a bitmask (unsigned long) */
        Sprintf(numbuf, "%lu", *(unsigned long *) ptr);
        val = numbuf;
    } else if (ptr) {
        /* For most fields, ptr points to a formatted string
         * from the status update code, but some pass a long */
        val = (const char *) ptr;
    } else {
        val = "";
    }

    host_status_update(idx, val, (int) strlen(val), color, percent);
}

static boolean
factorio_can_suspend(void)
{
    return FALSE;
}

static void
factorio_update_inventory(int arg)
{
    host_update_inventory(arg);
}

static win_request_info *
factorio_ctrl_nhwindow(winid window UNUSED, int request UNUSED,
                       win_request_info *wri UNUSED)
{
    return (win_request_info *) 0;
}

/* winfactorio.c */
