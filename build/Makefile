# Makefile for NetHack-Factorio WASM build
# Compiles NetHack C source to WebAssembly via clang + wasi-libc,
# with the Factorio window port.

CC = clang
NETHACK = ../NetHack
SYSROOT = /usr/share/wasi-sysroot
TARGET = --target=wasm32-wasi --sysroot=$(SYSROOT)

# ================================================================
# Compiler flags
# ================================================================

CFLAGS = -Os -g0
CFLAGS += $(TARGET)
CFLAGS += -I$(NETHACK)/include
CFLAGS += -I$(NETHACK)/submodules/lua
CFLAGS += -I.

# NetHack configuration: use Unix config as base, override with our defines
CFLAGS += -DFACTORIO_GRAPHICS
CFLAGS += -DSAFEPROCS
# CLIPPING is already defined in config.h, don't re-define here
CFLAGS += -DNO_SIGNAL
CFLAGS += -DNOTPARMDECL
CFLAGS += -DNOTTYGRAPHICS
CFLAGS += -DDEFAULT_WINDOW_SYS=\"factorio\"
CFLAGS += -DGCC_WARN
CFLAGS += -DNOMAIL
CFLAGS += -DNO_FILE_LINKS
CFLAGS += -DSYSCF

# Build Lua as a library (not standalone interpreter) to avoid duplicate main()
CFLAGS += -DMAKE_LIB

# wasi-libc compatibility: L_tmpnam not defined, clock() needs emulation
CFLAGS += -DL_tmpnam=32
CFLAGS += -D_WASI_EMULATED_PROCESS_CLOCKS
CFLAGS += -D_WASI_EMULATED_SIGNAL
CFLAGS += -D_WASI_EMULATED_GETPID
CFLAGS += -DCROSS_TO_WASM
CFLAGS += -include wasi_compat.h

# Suppress warnings from NetHack's old-style C code
CFLAGS += -Wno-implicit-function-declaration
CFLAGS += -Wno-format
CFLAGS += -Wno-parentheses

# ================================================================
# Linker flags (clang + WASI)
# ================================================================

LDFLAGS = $(TARGET)
LDFLAGS += -Wl,--allow-undefined
LDFLAGS += -Wl,--initial-memory=4194304
LDFLAGS += -Wl,--export=memory
LDFLAGS += -mllvm -wasm-enable-sjlj
LDFLAGS += -lsetjmp
LDFLAGS += -lwasi-emulated-process-clocks
LDFLAGS += -lwasi-emulated-signal
LDFLAGS += -lwasi-emulated-getpid
LDFLAGS += -mllvm -wasm-use-legacy-eh=false

# ================================================================
# Source files
# ================================================================

# NetHack core sources (from src/)
NH_SRC = \
	$(NETHACK)/src/allmain.c \
	$(NETHACK)/src/alloc.c \
	$(NETHACK)/src/apply.c \
	$(NETHACK)/src/artifact.c \
	$(NETHACK)/src/attrib.c \
	$(NETHACK)/src/ball.c \
	$(NETHACK)/src/bones.c \
	$(NETHACK)/src/botl.c \
	$(NETHACK)/src/calendar.c \
	$(NETHACK)/src/cfgfiles.c \
	$(NETHACK)/src/cmd.c \
	$(NETHACK)/src/coloratt.c \
	$(NETHACK)/src/dbridge.c \
	$(NETHACK)/src/decl.c \
	$(NETHACK)/src/detect.c \
	$(NETHACK)/src/dig.c \
	$(NETHACK)/src/display.c \
	$(NETHACK)/src/dlb.c \
	$(NETHACK)/src/do.c \
	$(NETHACK)/src/do_name.c \
	$(NETHACK)/src/do_wear.c \
	$(NETHACK)/src/dog.c \
	$(NETHACK)/src/dogmove.c \
	$(NETHACK)/src/dokick.c \
	$(NETHACK)/src/dothrow.c \
	$(NETHACK)/src/drawing.c \
	$(NETHACK)/src/dungeon.c \
	$(NETHACK)/src/eat.c \
	$(NETHACK)/src/end.c \
	$(NETHACK)/src/engrave.c \
	$(NETHACK)/src/exper.c \
	$(NETHACK)/src/explode.c \
	$(NETHACK)/src/extralev.c \
	$(NETHACK)/src/files.c \
	$(NETHACK)/src/fountain.c \
	$(NETHACK)/src/getpos.c \
	$(NETHACK)/src/glyphs.c \
	$(NETHACK)/src/hack.c \
	$(NETHACK)/src/hacklib.c \
	$(NETHACK)/src/iactions.c \
	$(NETHACK)/src/insight.c \
	$(NETHACK)/src/invent.c \
	$(NETHACK)/src/isaac64.c \
	$(NETHACK)/src/light.c \
	$(NETHACK)/src/lock.c \
	$(NETHACK)/src/mail.c \
	$(NETHACK)/src/makemon.c \
	$(NETHACK)/src/mcastu.c \
	$(NETHACK)/src/mdlib.c \
	$(NETHACK)/src/mhitm.c \
	$(NETHACK)/src/mhitu.c \
	$(NETHACK)/src/minion.c \
	$(NETHACK)/src/mklev.c \
	$(NETHACK)/src/mkmap.c \
	$(NETHACK)/src/mkmaze.c \
	$(NETHACK)/src/mkobj.c \
	$(NETHACK)/src/mkroom.c \
	$(NETHACK)/src/mon.c \
	$(NETHACK)/src/mondata.c \
	$(NETHACK)/src/monmove.c \
	$(NETHACK)/src/monst.c \
	$(NETHACK)/src/mplayer.c \
	$(NETHACK)/src/mthrowu.c \
	$(NETHACK)/src/muse.c \
	$(NETHACK)/src/music.c \
	$(NETHACK)/src/nhmd4.c \
	$(NETHACK)/src/nhlobj.c \
	$(NETHACK)/src/nhlsel.c \
	$(NETHACK)/src/nhlua.c \
	$(NETHACK)/src/objects.c \
	$(NETHACK)/src/objnam.c \
	$(NETHACK)/src/o_init.c \
	$(NETHACK)/src/options.c \
	$(NETHACK)/src/pager.c \
	$(NETHACK)/src/pickup.c \
	$(NETHACK)/src/pline.c \
	$(NETHACK)/src/polyself.c \
	$(NETHACK)/src/potion.c \
	$(NETHACK)/src/pray.c \
	$(NETHACK)/src/priest.c \
	$(NETHACK)/src/quest.c \
	$(NETHACK)/src/questpgr.c \
	$(NETHACK)/src/read.c \
	$(NETHACK)/src/rect.c \
	$(NETHACK)/src/region.c \
	$(NETHACK)/src/report.c \
	$(NETHACK)/src/restore.c \
	$(NETHACK)/src/rip.c \
	$(NETHACK)/src/rnd.c \
	$(NETHACK)/src/role.c \
	$(NETHACK)/src/rumors.c \
	$(NETHACK)/src/save.c \
	$(NETHACK)/src/selvar.c \
	$(NETHACK)/src/sfbase.c \
	$(NETHACK)/src/sfstruct.c \
	$(NETHACK)/src/shk.c \
	$(NETHACK)/src/shknam.c \
	$(NETHACK)/src/sit.c \
	$(NETHACK)/src/sounds.c \
	$(NETHACK)/src/sp_lev.c \
	$(NETHACK)/src/spell.c \
	$(NETHACK)/src/stairs.c \
	$(NETHACK)/src/steal.c \
	$(NETHACK)/src/steed.c \
	$(NETHACK)/src/strutil.c \
	$(NETHACK)/src/symbols.c \
	$(NETHACK)/src/sys.c \
	$(NETHACK)/src/teleport.c \
	$(NETHACK)/src/timeout.c \
	$(NETHACK)/src/topten.c \
	$(NETHACK)/src/track.c \
	$(NETHACK)/src/trap.c \
	$(NETHACK)/src/uhitm.c \
	$(NETHACK)/src/u_init.c \
	$(NETHACK)/src/utf8map.c \
	$(NETHACK)/src/vault.c \
	$(NETHACK)/src/version.c \
	$(NETHACK)/src/vision.c \
	$(NETHACK)/src/weapon.c \
	$(NETHACK)/src/were.c \
	$(NETHACK)/src/wield.c \
	$(NETHACK)/src/windows.c \
	$(NETHACK)/src/wizard.c \
	$(NETHACK)/src/wizcmds.c \
	$(NETHACK)/src/worm.c \
	$(NETHACK)/src/worn.c \
	$(NETHACK)/src/write.c \
	$(NETHACK)/src/zap.c

# date.c needs special handling (generated during build normally)
# We include it but may need to generate it first
NH_SRC += $(NETHACK)/src/date.c

# Shared window port code (safeproc.c provides fallback implementations)
WIN_SHARE_SRC = $(NETHACK)/win/share/safeproc.c

# System shared code (POSIX regex for pattern matching)
SYS_SHARE_SRC = $(NETHACK)/sys/share/posixregex.c

# Lua 5.4 (bundled with NetHack as a submodule)
# onelua.c is a single-file build of the full Lua library
LUA_SRC = $(NETHACK)/submodules/lua/onelua.c

# Our custom sources
FACTORIO_SRC = winfactorio.c sysfactorio.c

# All sources
ALL_SRC = $(NH_SRC) $(WIN_SHARE_SRC) $(SYS_SHARE_SRC) $(FACTORIO_SRC) $(LUA_SRC)

# ================================================================
# Build targets
# ================================================================

.PHONY: all clean

all: nethack.wasm

nethack.wasm: $(ALL_SRC) factorioconf.h
	$(CC) $(CFLAGS) $(LDFLAGS) $(ALL_SRC) -o nethack.wasm
	@echo "Build complete: nethack.wasm"

# Convert WASM to Lua module for embedding in Factorio mod
lua: nethack.wasm
	python3 wasm_to_lua.py nethack.wasm ../scripts/nethack_wasm.lua
	@echo "Lua module generated: ../scripts/nethack_wasm.lua"

clean:
	rm -f nethack.wasm
	rm -f ../scripts/nethack_wasm.lua
