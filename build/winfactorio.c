/* NetHack 3.6 winfactorio.c - Factorio WASM window port */
/* Copyright (c) 2026, NetHack-Factorio project */
/* NetHack may be freely redistributed.  See license for details. */

#include "hack.h"
#include "dlb.h"
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
 * Declared as extern functions; clang generates WASM import
 * entries for them. The Lua WASM interpreter supplies implementations.
 * ================================================================ */

extern int host_nhgetch(void);
extern short glyph2tile[];
extern void host_print_glyph(int x, int y, int tile_idx, int ch, int color, int special);
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
extern void host_update_inventory(void);
extern void host_mark_synch(void);
extern void host_describe_result(const char *buf, int buf_len,
                                 const char *monbuf, int monbuf_len);

/* Click-to-travel: non-blocking imports to read click coordinates
 * after host_nhgetch returns 0 (signaling a mouse click). */
extern int host_poskey_x(void);
extern int host_poskey_y(void);
extern int host_poskey_mod(void);

/* Player selection dialog imports */
extern void host_plsel_setup_role(int idx, const char *name, int len, int allow);
extern void host_plsel_setup_race(int idx, const char *noun, int len, int allow);
extern void host_plsel_setup_gend(int idx, const char *adj, int len, int allow);
extern void host_plsel_setup_align(int idx, const char *adj, int len, int allow);
extern int host_plsel_show(void);  /* BLOCKING - shows dialog, returns status */

/* ================================================================
 * Forward declarations for all window port functions
 * ================================================================ */

static void FDECL(factorio_init_nhwindows, (int *, char **));
static void NDECL(factorio_player_selection);
static void NDECL(factorio_askname);
static void NDECL(factorio_get_nh_event);
static void FDECL(factorio_exit_nhwindows, (const char *));
static void FDECL(factorio_suspend_nhwindows, (const char *));
static void NDECL(factorio_resume_nhwindows);
static winid FDECL(factorio_create_nhwindow, (int));
static void FDECL(factorio_clear_nhwindow, (winid));
static void FDECL(factorio_display_nhwindow, (winid, BOOLEAN_P));
static void FDECL(factorio_destroy_nhwindow, (winid));
static void FDECL(factorio_curs, (winid, int, int));
static void FDECL(factorio_putstr, (winid, int, const char *));
static void FDECL(factorio_putmixed, (winid, int, const char *));
static void FDECL(factorio_display_file, (const char *, BOOLEAN_P));
static void FDECL(factorio_start_menu, (winid));
static void FDECL(factorio_add_menu, (winid, int, const ANY_P *, CHAR_P,
                                       CHAR_P, int, const char *, BOOLEAN_P));
static void FDECL(factorio_end_menu, (winid, const char *));
static int FDECL(factorio_select_menu, (winid, int, MENU_ITEM_P **));
static char FDECL(factorio_message_menu, (CHAR_P, int, const char *));
static void NDECL(factorio_update_inventory);
static void NDECL(factorio_mark_synch);
static void NDECL(factorio_wait_synch);
#ifdef CLIPPING
static void FDECL(factorio_cliparound, (int, int));
#endif
static void FDECL(factorio_print_glyph, (winid, XCHAR_P, XCHAR_P, int, int));
static void FDECL(factorio_raw_print, (const char *));
static void FDECL(factorio_raw_print_bold, (const char *));
static int NDECL(factorio_nhgetch);
static int FDECL(factorio_nh_poskey, (int *, int *, int *));
static void NDECL(factorio_nhbell);
static int NDECL(factorio_doprev_message);
static char FDECL(factorio_yn_function, (const char *, const char *, CHAR_P));
static void FDECL(factorio_getlin, (const char *, char *));
static int NDECL(factorio_get_ext_cmd);
static void FDECL(factorio_number_pad, (int));
static void NDECL(factorio_delay_output);
static void NDECL(factorio_start_screen);
static void NDECL(factorio_end_screen);
static void FDECL(factorio_outrip, (winid, int, time_t));
static void FDECL(factorio_preference_update, (const char *));
static char *FDECL(factorio_getmsghistory, (BOOLEAN_P));
static void FDECL(factorio_putmsghistory, (const char *, BOOLEAN_P));
static void NDECL(factorio_status_init);
static void NDECL(factorio_status_finish);
static void FDECL(factorio_status_enablefield,
                   (int, const char *, const char *, BOOLEAN_P));
static void FDECL(factorio_status_update,
                   (int, genericptr_t, int, int, int, unsigned long *));
static boolean NDECL(factorio_can_suspend);

/* ================================================================
 * The window_procs structure - registered with NetHack core
 * ================================================================ */

struct window_procs factorio_procs = {
    "factorio",
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
    factorio_update_inventory,
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
    factorio_start_screen,
    factorio_end_screen,
    factorio_outrip,
    factorio_preference_update,
    factorio_getmsghistory,
    factorio_putmsghistory,
    factorio_status_init,
    factorio_status_finish,
    factorio_status_enablefield,
    factorio_status_update,
    factorio_can_suspend,
};

/* ================================================================
 * Window type tracking (for blocking display_nhwindow decisions)
 * ================================================================ */

#define MAX_FACTORIO_WINDOWS 32
static int factorio_window_types[MAX_FACTORIO_WINDOWS];

/* Player selection dialog results (set by askname, read by player_selection) */
static int plsel_role = -1, plsel_race = -1, plsel_gend = -1, plsel_align = -1;

/* ================================================================
 * Glyph decoding for rich text sprite references
 * ================================================================ */

/* Decode \G glyph sequences into Factorio rich text sprite references.
 * Uses glyph2tile[] to convert glyph index to tile index.
 * Returns buf. */
static char *
decode_glyph_to_sprite(buf, str)
char *buf;
const char *str;
{
    static const char hex[] = "00112233445566778899aAbBcCdDeEfF";
    char *put = buf;

    if (!str)
        return strcpy(buf, "");

    while (*str) {
        if (*str == '\\' && *(str + 1) == 'G') {
            int rndchk, dcount, gv;
            const char *dp, *save_str;

            save_str = str;
            str += 2; /* skip \G */

            /* Parse 4-hex rndencode */
            rndchk = dcount = 0;
            for (; *str && dcount < 4; ++str, ++dcount)
                if ((dp = index(hex, *str)) != 0)
                    rndchk = (rndchk * 16) + ((int)(dp - hex) / 2);

            if (rndchk == context.rndencode) {
                /* Parse 4-hex glyph value */
                gv = dcount = 0;
                for (; *str && dcount < 4; ++str, ++dcount)
                    if ((dp = index(hex, *str)) != 0)
                        gv = (gv * 16) + ((int)(dp - hex) / 2);

                /* Convert glyph to tile index, emit rich text */
                if (gv >= 0 && gv < MAX_GLYPH) {
                    int tile = (int) glyph2tile[gv];
                    put += sprintf(put, "[img=nh-sprite-%d]", tile);
                } else {
                    /* Invalid glyph, copy original */
                    while (save_str < str)
                        *put++ = *save_str++;
                }
                continue;
            }
            /* rndencode mismatch - copy original text */
            str = save_str;
        }
        *put++ = *str++;
    }
    *put = '\0';
    return buf;
}

/* ================================================================
 * Implementation of window port functions
 * ================================================================ */

static void
factorio_init_nhwindows(argcp, argv)
int *argcp UNUSED;
char **argv UNUSED;
{
    iflags.window_inited = TRUE;
    /* Always use full menu for inventory, even with a single matching item */
    iflags.force_invmenu = TRUE;
    /* flags.travelcmd defaults to TRUE (options.c), enabling click-to-travel */
    iflags.echo = TRUE;
}

static void
factorio_player_selection()
{
    /* Use selections from the combined dialog (set in askname) */
    if (flags.initrole < 0)
        flags.initrole = (plsel_role >= 0) ? plsel_role : ROLE_RANDOM;
    if (flags.initrace < 0)
        flags.initrace = (plsel_race >= 0) ? plsel_race : ROLE_RANDOM;
    if (flags.initgend < 0)
        flags.initgend = (plsel_gend >= 0) ? plsel_gend : ROLE_RANDOM;
    if (flags.initalign < 0)
        flags.initalign = (plsel_align >= 0) ? plsel_align : ROLE_RANDOM;
}

static void
factorio_askname()
{
    int i, ch, status;

    /* Send all role/race/gender/alignment data to Lua for the selection dialog */
    for (i = 0; roles[i].name.m; i++) {
        const char *name = roles[i].name.m;
        host_plsel_setup_role(i, name, (int) strlen(name),
                              roles[i].allow & 0xFFFF);
    }
    for (i = 0; races[i].noun; i++) {
        const char *noun = races[i].noun;
        host_plsel_setup_race(i, noun, (int) strlen(noun),
                              races[i].allow & 0xFFFF);
    }
    /* ROLE_GENDERS = 2 (male, female) */
    for (i = 0; i < ROLE_GENDERS; i++) {
        const char *adj = genders[i].adj;
        host_plsel_setup_gend(i, adj, (int) strlen(adj),
                              genders[i].allow & 0xFFFF);
    }
    /* ROLE_ALIGNS = 3 (lawful, neutral, chaotic) */
    for (i = 0; i < ROLE_ALIGNS; i++) {
        const char *adj = aligns[i].adj;
        host_plsel_setup_align(i, adj, (int) strlen(adj),
                               aligns[i].allow & 0xFFFF);
    }

    /* Show the combined dialog (BLOCKING) */
    status = host_plsel_show();

    if (status < 0) {
        /* Quit requested */
        clearlocks();
        exit(EXIT_SUCCESS);
    }

    /* Read player name (null-terminated chars queued by Lua) */
    for (i = 0; i < PL_NSIZ - 1; i++) {
        ch = host_nhgetch();
        if (ch == '\0' || ch == '\n' || ch == '\r' || ch == '\033')
            break;
        plname[i] = (char) ch;
    }
    plname[i] = '\0';

    if (plname[0] == '\033' || !plname[0])
        Strcpy(plname, "Player");

    /* Read selection indices (queued by Lua after name chars) */
    plsel_role  = host_nhgetch();
    plsel_race  = host_nhgetch();
    plsel_gend  = host_nhgetch();
    plsel_align = host_nhgetch();
}

static void
factorio_get_nh_event()
{
    /* No-op: NetHack calls this to let the window port process pending UI events
       (e.g. X11 expose events, terminal resizes). Factorio handles its own event
       loop, so there's nothing to do here. */
}

static void
factorio_exit_nhwindows(str)
const char *str;
{
    if (str) {
        host_exit_nhwindows(str, (int) strlen(str));
    } else {
        host_exit_nhwindows("", 0);
    }
}

static void
factorio_suspend_nhwindows(str)
const char *str UNUSED;
{
    /* cannot suspend in WASM */
}

static void
factorio_resume_nhwindows()
{
    /* no-op */
}

static winid
factorio_create_nhwindow(type)
int type;
{
    winid wid = (winid) host_create_nhwindow(type);
    if ((int) wid >= 0 && (int) wid < MAX_FACTORIO_WINDOWS)
        factorio_window_types[(int) wid] = type;
    return wid;
}

static void
factorio_clear_nhwindow(window)
winid window;
{
    host_clear_nhwindow((int) window);
}

static void
factorio_display_nhwindow(window, blocking)
winid window;
boolean blocking;
{
    int wtype = ((int) window >= 0 && (int) window < MAX_FACTORIO_WINDOWS)
                ? factorio_window_types[(int) window] : 0;
    host_display_nhwindow((int) window, (int) blocking);
    if (blocking && (wtype == NHW_TEXT || wtype == NHW_MESSAGE
                     || wtype == NHW_MENU)) {
        /* Wait for user acknowledgment (like --More-- in tty).
         * nhgetch blocks WASM execution until the player presses a key.
         * NHW_MENU is included because questpgr.c delivers some quest text
         * via NHW_MENU windows (com_pager msgnum==1). */
        (void) host_nhgetch();
    }
}

static void
factorio_destroy_nhwindow(window)
winid window;
{
    if ((int) window >= 0 && (int) window < MAX_FACTORIO_WINDOWS)
        factorio_window_types[(int) window] = 0;
    host_destroy_nhwindow((int) window);
}

static void
factorio_curs(window, x, y)
winid window;
int x, y;
{
    host_curs((int) window, x, y);
}

static void
factorio_putstr(window, attr, str)
winid window;
int attr;
const char *str;
{
    if (str) {
        host_putstr((int) window, attr, str, (int) strlen(str));
    }
}

static void
factorio_putmixed(window, attr, str)
winid window;
int attr;
const char *str;
{
    if (str) {
        char buf[BUFSZ * 2];
        decode_glyph_to_sprite(buf, str);
        host_putstr((int) window, attr, buf, (int) strlen(buf));
    }
}

static void
factorio_display_file(fname, complain)
const char *fname;
boolean complain;
{
    dlb *f;
    char buf[BUFSZ];
    winid win;

    if (!fname || !*fname)
        return;

    f = dlb_fopen(fname, "r");
    if (!f) {
        if (complain) {
            char msgbuf[BUFSZ];
            Sprintf(msgbuf, "Cannot display file: %s", fname);
            factorio_raw_print(msgbuf);
        }
        return;
    }

    win = factorio_create_nhwindow(NHW_TEXT);
    while (dlb_fgets(buf, BUFSZ, f)) {
        int len = (int) strlen(buf);
        if (len > 0 && buf[len - 1] == '\n')
            buf[len - 1] = '\0';
        factorio_putstr(win, 0, buf);
    }
    dlb_fclose(f);

    factorio_display_nhwindow(win, TRUE);
    factorio_destroy_nhwindow(win);
}

static void
factorio_start_menu(window)
winid window;
{
    host_start_menu((int) window);
}

static void
factorio_add_menu(window, glyph, identifier, ch, gch, attr, str, preselected)
winid window;
int glyph;
const anything *identifier;
char ch, gch;
int attr;
const char *str;
boolean preselected;
{
    int id_val = identifier ? identifier->a_int : 0;
    int tile = (glyph >= 0 && glyph < MAX_GLYPH) ? (int) glyph2tile[glyph] : -1;

    if (str) {
        host_add_menu_item((int) window, tile, id_val,
                           (int) ch, (int) gch, attr,
                           str, (int) strlen(str), (int) preselected);
    }
}

static void
factorio_end_menu(window, prompt)
winid window;
const char *prompt;
{
    if (prompt) {
        host_end_menu((int) window, prompt, (int) strlen(prompt));
    } else {
        host_end_menu((int) window, "", 0);
    }
}

static int
factorio_select_menu(window, how, menu_list)
winid window;
int how;
menu_item **menu_list;
{
    int result;

    *menu_list = (menu_item *) 0;
    result = host_select_menu((int) window, how);

    if (result > 0) {
        /* Read all selections from the host via nhgetch.
         * For PICK_ANY menus, result may be > 1. */
        int i;
        *menu_list = (menu_item *) alloc(result * sizeof(menu_item));
        for (i = 0; i < result; i++) {
            (*menu_list)[i].item.a_int = host_nhgetch();
            (*menu_list)[i].count = -1;
        }
        return result;
    }
    return result; /* 0 = nothing selected, -1 = cancelled */
}

static char
factorio_message_menu(let, how, mesg)
char let UNUSED;
int how UNUSED;
const char *mesg;
{
    if (mesg)
        pline("%s", mesg);
    return 0;
}

static void
factorio_update_inventory()
{
    host_update_inventory();
}

static void
factorio_mark_synch()
{
    host_mark_synch();
}

static void
factorio_wait_synch()
{
    /* no-op: Factorio renders synchronously */
}

#ifdef CLIPPING
static void
factorio_cliparound(x, y)
int x, y;
{
    host_cliparound(x, y);
}
#endif

/*
 * Print a glyph at position (x,y) on the map window.
 * Use mapglyph() to convert the glyph integer to character/color.
 */
static void
factorio_print_glyph(window, x, y, glyph, bkglyph)
winid window UNUSED;
xchar x, y;
int glyph;
int bkglyph UNUSED;
{
    int ch;
    int color;
    unsigned special;

    (void) mapglyph(glyph, &ch, &color, &special, x, y, 0);
    host_print_glyph((int) x, (int) y, (int) glyph2tile[glyph],
                     ch, color, (int) special);
}

static void
factorio_raw_print(str)
const char *str;
{
    if (str) {
        host_raw_print(str, (int) strlen(str));
    }
}

static void
factorio_raw_print_bold(str)
const char *str;
{
    /* bold and normal are the same for our port */
    factorio_raw_print(str);
}

static int
factorio_nhgetch()
{
    /* This is the critical input function.
     * In the WASM interpreter, this import triggers a coroutine yield
     * back to the Lua host, which waits for player input. */
    return host_nhgetch();
}

static int
factorio_nh_poskey(x, y, mod)
int *x, *y, *mod;
{
    int ch = host_nhgetch();
    if (ch == 0) {
        /* Click event: read coordinates from non-blocking imports */
        *x = host_poskey_x();
        *y = host_poskey_y();
        *mod = host_poskey_mod();
        return 0;
    }
    *x = 0;
    *y = 0;
    *mod = 0;
    return ch;
}

static void
factorio_nhbell()
{
    /* no-op: no bell in Factorio */
}

static int
factorio_doprev_message()
{
    if (WIN_MESSAGE != WIN_ERR)
        display_nhwindow(WIN_MESSAGE, TRUE);
    return 0;
}

static char
factorio_yn_function(query, resp, def)
const char *query, *resp;
char def;
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
factorio_getlin(prompt, outbuf)
const char *prompt;
char *outbuf;
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
factorio_get_ext_cmd()
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
factorio_number_pad(mode)
int mode UNUSED;
{
    /* no-op */
}

static void
factorio_delay_output()
{
    host_delay_output();
}

static void
factorio_start_screen()
{
    /* no-op */
}

static void
factorio_end_screen()
{
    /* no-op */
}

static void
factorio_outrip(tmpwin, how, when)
winid tmpwin;
int how;
time_t when;
{
    genl_outrip(tmpwin, how, when);
}

static void
factorio_preference_update(pref)
const char *pref UNUSED;
{
    /* no-op */
}

static char *
factorio_getmsghistory(init)
boolean init UNUSED;
{
    return (char *) 0;
}

static void
factorio_putmsghistory(msg, is_restoring)
const char *msg UNUSED;
boolean is_restoring UNUSED;
{
    /* no-op */
}

static void
factorio_status_init()
{
    /* no-op */
}

static void
factorio_status_finish()
{
    /* no-op */
}

static void
factorio_status_enablefield(fieldidx, nm, fmt, enable)
int fieldidx UNUSED;
const char *nm UNUSED;
const char *fmt UNUSED;
boolean enable UNUSED;
{
    /* no-op */
}

static void
factorio_status_update(idx, ptr, chg, percent, color, colormasks)
int idx;
genericptr_t ptr;
int chg UNUSED;
int percent;
int color;
unsigned long *colormasks UNUSED;
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

    if (idx == BL_LEVELDESC) {
        /* Format dungeon level like the Qt GUI: "Dungeons of Doom, level 1" */
        char dlbuf[BUFSZ];
        if (!describe_level(dlbuf)) {
            /* Main dungeon - reconstruct long-form name */
            Sprintf(dlbuf, "%s, level %d", dungeons[u.uz.dnum].dname, depth(&u.uz));
        } else {
            /* Special dungeon - trim trailing space from describe_level */
            char *end = dlbuf + strlen(dlbuf) - 1;
            while (end > dlbuf && *end == ' ') *end-- = '\0';
        }
        host_status_update(idx, dlbuf, (int) strlen(dlbuf), color, percent);
    } else if (idx != BL_CONDITION) {
        /* Decode any \G glyph sequences in the value string */
        char decoded[BUFSZ * 2];
        decode_glyph_to_sprite(decoded, val);
        host_status_update(idx, decoded, (int) strlen(decoded), color, percent);
    } else {
        host_status_update(idx, val, (int) strlen(val), color, percent);
    }
}

static boolean
factorio_can_suspend()
{
    return FALSE;
}

/* ================================================================
 * Exported helper: describe a map position using lookat()
 * Called from Lua via WASM to get tile descriptions for hover tooltip.
 * ================================================================ */

extern struct permonst *lookat(int, int, char *, char *);
extern void checkfile(char *, struct permonst *, BOOLEAN_P, BOOLEAN_P, char *);

__attribute__((export_name("nh_describe_pos")))
void
nh_describe_pos(int x, int y, int full)
{
    char buf[BUFSZ];
    char monbuf[BUFSZ];
    struct permonst *pm = (struct permonst *) 0;

    buf[0] = '\0';
    monbuf[0] = '\0';

    if (x >= 1 && x < COLNO && y >= 0 && y < ROWNO) {
        pm = lookat(x, y, buf, monbuf);
    }

    host_describe_result(buf, (int) strlen(buf), monbuf, (int) strlen(monbuf));

    /* Look up extended description from data file.
     * checkfile() creates a text window and calls putstr/display_nhwindow;
     * the Lua side intercepts these in "capture mode". */
    if (full && buf[0]) {
        checkfile(buf, pm, FALSE, TRUE, (char *) 0);
    }
}

/* winfactorio.c */
