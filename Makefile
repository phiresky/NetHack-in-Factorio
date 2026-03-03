# NetHack-in-Factorio — unified build
#
# Usage:
#   make              # full build (clone + host tools + WASM + sprites)
#   make wasm         # recompile WASM + regenerate Lua modules
#   make sprites      # regenerate sprites only
#   make verify       # check all generated files exist
#   make clean        # remove all generated files
#
# Prerequisites (Arch Linux):
#   pacman -S clang wasi-libc wasi-compiler-rt binaryen oxipng \
#             lib32-glibc lib32-gcc-libs lib32-ncurses python python-pillow

# ================================================================
# Paths
# ================================================================

NETHACK      := NetHack
NETHACK_TAG  := NetHack-3.6.7_Released
NETHACK_REPO := https://github.com/NetHack/NetHack.git
STAMPS       := .stamps

# ================================================================
# WASM cross-compiler settings
# ================================================================

WASM_CC  := clang
SYSROOT  := /usr/share/wasi-sysroot
TARGET   := --target=wasm32-wasi --sysroot=$(SYSROOT)

CFLAGS  := -Os -g0
CFLAGS  += $(TARGET)
CFLAGS  += -mbulk-memory -msign-ext -mnontrapping-fptoint
CFLAGS  += -I$(NETHACK)/include
CFLAGS  += -Ibuild

# NetHack configuration (defines live in build/factorioconf.h)
# WASI compatibility stubs (defines live in build/wasi_compat.h)
CFLAGS  += -include build/factorioconf.h
CFLAGS  += -include build/wasi_compat.h

# Suppress warnings from NetHack's old-style C
CFLAGS  += -Wno-implicit-function-declaration
CFLAGS  += -Wno-format
CFLAGS  += -Wno-parentheses
CFLAGS  += -Wno-deprecated-non-prototype

LDFLAGS := $(TARGET)
LDFLAGS += -mbulk-memory -msign-ext -mnontrapping-fptoint
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

NH_SRC := \
	$(NETHACK)/src/allmain.c \
	$(NETHACK)/src/alloc.c \
	$(NETHACK)/src/apply.c \
	$(NETHACK)/src/artifact.c \
	$(NETHACK)/src/attrib.c \
	$(NETHACK)/src/ball.c \
	$(NETHACK)/src/bones.c \
	$(NETHACK)/src/botl.c \
	$(NETHACK)/src/cmd.c \
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
	$(NETHACK)/src/hack.c \
	$(NETHACK)/src/hacklib.c \
	$(NETHACK)/src/invent.c \
	$(NETHACK)/src/isaac64.c \
	$(NETHACK)/src/light.c \
	$(NETHACK)/src/lock.c \
	$(NETHACK)/src/mail.c \
	$(NETHACK)/src/makemon.c \
	$(NETHACK)/src/mapglyph.c \
	$(NETHACK)/src/mcastu.c \
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
	$(NETHACK)/src/restore.c \
	$(NETHACK)/src/rip.c \
	$(NETHACK)/src/rnd.c \
	$(NETHACK)/src/role.c \
	$(NETHACK)/src/rumors.c \
	$(NETHACK)/src/save.c \
	$(NETHACK)/src/shk.c \
	$(NETHACK)/src/shknam.c \
	$(NETHACK)/src/sit.c \
	$(NETHACK)/src/sounds.c \
	$(NETHACK)/src/sp_lev.c \
	$(NETHACK)/src/spell.c \
	$(NETHACK)/src/steal.c \
	$(NETHACK)/src/steed.c \
	$(NETHACK)/src/sys.c \
	$(NETHACK)/src/teleport.c \
	$(NETHACK)/src/timeout.c \
	$(NETHACK)/src/topten.c \
	$(NETHACK)/src/track.c \
	$(NETHACK)/src/trap.c \
	$(NETHACK)/src/uhitm.c \
	$(NETHACK)/src/u_init.c \
	$(NETHACK)/src/vault.c \
	$(NETHACK)/src/version.c \
	$(NETHACK)/src/vision.c \
	$(NETHACK)/src/vis_tab.c \
	$(NETHACK)/src/weapon.c \
	$(NETHACK)/src/were.c \
	$(NETHACK)/src/wield.c \
	$(NETHACK)/src/windows.c \
	$(NETHACK)/src/wizard.c \
	$(NETHACK)/src/worm.c \
	$(NETHACK)/src/worn.c \
	$(NETHACK)/src/write.c \
	$(NETHACK)/src/zap.c \
	$(NETHACK)/win/share/safeproc.c \
	$(NETHACK)/sys/share/posixregex.c \
	$(NETHACK)/src/tile.c \
	build/winfactorio.c \
	build/sysfactorio.c

# ================================================================
# Output files
# ================================================================

WASM         := build/nethack.wasm
WASM_LUA     := scripts/nethack_wasm.lua
DATA_LUA     := scripts/nethack_data.lua
COMPILED_LUA := scripts/nethack_compiled.lua
TILE_CONFIG  := scripts/tile_config.lua

SPRITE_SHEETS := \
	graphics/sheets/nh-monsters.png \
	graphics/sheets/nh-objects.png \
	graphics/sheets/nh-other.png

TILE_SOURCES := \
	$(NETHACK)/win/share/monsters.txt \
	$(NETHACK)/win/share/objects.txt \
	$(NETHACK)/win/share/other.txt

# ================================================================
# Phony targets
# ================================================================

.PHONY: all wasm sprites clean verify

all: wasm sprites

wasm: $(WASM_LUA) $(DATA_LUA) $(COMPILED_LUA)

sprites: $(STAMPS)/sprites-optimized

# ================================================================
# Stage 1 — Clone NetHack
# ================================================================

$(NETHACK):
	git clone --depth 1 --branch $(NETHACK_TAG) $(NETHACK_REPO) $@

# ================================================================
# Stage 2 — Build 32-bit host tools
# ================================================================

$(STAMPS)/host-tools: | $(NETHACK)
	@mkdir -p $(STAMPS)
	cd $(NETHACK)/sys/unix && bash setup.sh hints/linux-minimal
	$(MAKE) -C $(NETHACK) CC="cc -m32 -std=gnu89" all
	@touch $@

# ================================================================
# Stage 3 — Patch pager.c (make lookat/checkfile non-static)
# ================================================================

$(STAMPS)/pager-patched: $(STAMPS)/host-tools
	sed -i \
		-e 's/^STATIC_DCL struct permonst \*FDECL(lookat/struct permonst *FDECL(lookat/' \
		-e 's/^STATIC_OVL struct permonst \*$$/struct permonst */' \
		-e 's/^STATIC_DCL void FDECL(checkfile/void FDECL(checkfile/' \
		-e '/^STATIC_OVL void$$/{N;/\ncheckfile(/s/STATIC_OVL //;}' \
		$(NETHACK)/src/pager.c
	@touch $@

# ================================================================
# Stage 4 — Build tilemap → generate tile.c
# ================================================================

$(NETHACK)/src/tile.c: $(STAMPS)/host-tools
	cc -m32 -std=gnu89 -I$(NETHACK)/include -o $(NETHACK)/util/tilemap \
		$(NETHACK)/win/share/tilemap.c \
		$(NETHACK)/src/objects.o $(NETHACK)/src/monst.o $(NETHACK)/src/drawing.o
	cd $(NETHACK)/util && ./tilemap

# ================================================================
# Stage 5 — Cross-compile to WASM
# ================================================================

$(WASM): $(NH_SRC) $(STAMPS)/pager-patched $(NETHACK)/src/tile.c build/factorioconf.h
	$(WASM_CC) $(CFLAGS) $(LDFLAGS) $(NH_SRC) -o $@
	wasm-opt -Oz --enable-exception-handling -o $@ $@
	@echo "Build complete: $@ ($$(stat -c%s $@ 2>/dev/null || stat -f%z $@) bytes)"

# ================================================================
# Stage 6 — Generate Lua modules
# ================================================================

$(WASM_LUA): $(WASM)
	python3 build/wasm_to_lua.py $< $@

$(DATA_LUA): $(STAMPS)/host-tools
	python3 build/embed_data.py $@ $(NETHACK)/dat

$(COMPILED_LUA): $(WASM_LUA) scripts/wasm/compiler.lua scripts/wasm/init.lua
	lua5.2 build/compile_wasm.lua $(WASM_LUA) $@

# ================================================================
# Stage 7 — Convert tile art to sprites
# ================================================================

$(TILE_CONFIG): $(TILE_SOURCES) build/convert_tiles.py | $(NETHACK)
	python3 build/convert_tiles.py $(NETHACK)

# Sprite sheets are co-produced with tile_config
$(SPRITE_SHEETS): $(TILE_CONFIG)

# ================================================================
# Stage 8 — Optimize PNGs
# ================================================================

$(STAMPS)/sprites-optimized: $(TILE_CONFIG)
	@mkdir -p $(STAMPS)
	find graphics/sheets graphics/tiles graphics/icons/monsters graphics/icons/objects graphics/icons/other -name '*.png' \
		-print0 | xargs -0 -P$$(nproc) oxipng --opt max --zopfli
	@touch $@

# ================================================================
# Verify all outputs exist
# ================================================================

GENERATED_FILES := $(WASM) $(WASM_LUA) $(DATA_LUA) $(COMPILED_LUA) $(TILE_CONFIG)
GENERATED_DIRS  := graphics/sheets graphics/tiles graphics/icons/monsters graphics/icons/objects graphics/icons/other

verify:
	@ok=true; \
	for f in $(GENERATED_FILES); do \
		if [ -f "$$f" ]; then \
			sz=$$(stat -c%s "$$f" 2>/dev/null || stat -f%z "$$f"); \
			printf '  %-40s \033[1;32mOK\033[0m (%s bytes)\n' "$$f" "$$sz"; \
		else \
			printf '  %-40s \033[1;31mMISSING\033[0m\n' "$$f"; \
			ok=false; \
		fi; \
	done; \
	for d in $(GENERATED_DIRS); do \
		if [ -d "$$d" ]; then \
			cnt=$$(find "$$d" -name '*.png' | wc -l); \
			printf '  %-40s \033[1;32mOK\033[0m (%s PNGs)\n' "$$d/" "$$cnt"; \
		else \
			printf '  %-40s \033[1;31mMISSING\033[0m\n' "$$d/"; \
			ok=false; \
		fi; \
	done; \
	echo; \
	$$ok && printf '\033[1;32mAll generated files present.\033[0m\n' \
	    || { printf '\033[1;31mSome files are missing. Run make to generate them.\033[0m\n'; exit 1; }

# ================================================================
# Clean
# ================================================================

clean:
	rm -f $(WASM)
	rm -f $(WASM_LUA) $(DATA_LUA) $(COMPILED_LUA) $(TILE_CONFIG)
	rm -rf graphics/sheets graphics/tiles graphics/icons/monsters graphics/icons/objects graphics/icons/other
	rm -rf $(STAMPS)
