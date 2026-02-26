# NetHack Qt GUI — Detailed Description

## Overview

The Qt window port for NetHack (originally by Warwick Allison, 1999; Qt4 conversion by Ray Chason, 2012-2014) is a graphical tile-based interface that replaces the traditional TTY terminal display. It exists in two versions in the source: a legacy Qt2/3 monolithic port (`win/Qt/qt_win.cpp`, ~5300 lines) and a refactored Qt4+ port (`win/Qt4/`, ~20 files). Both implement the same visual design. There is also a "compact mode" for handheld devices (Sharp Zaurus/QPE) that swaps the layout to a stacked widget view.

## Two Operating Modes

- **Desktop mode** (`qt_compact_mode = 0`): All three main panes visible simultaneously, arranged with splitters.
- **Compact/Handheld mode** (`qt_compact_mode = 1`): A `QStackedWidget` shows one pane at a time (map, messages, or status), switchable via the Info menu.

## Window Architecture

The Qt port implements NetHack's `window_procs` interface — a vtable of ~40 function pointers that NetHack's core calls to create windows, display glyphs, get input, show menus, etc. The binding class `NetHackQtBind` (subclass of `QApplication`) provides static methods for every entry in this vtable, dispatching to the appropriate widget.

### Fundamental Design Tension

As noted in the header comment: *"NetHack is fundamentally a getkey-type program rather than being event driven"*. The Qt port bridges this by using a **key buffer** and **click buffer** — Qt events (key presses, mouse clicks) are enqueued, and the blocking `nhgetch()` spins `qApp->exec()` in a loop until input arrives. Each key press or map click calls `qApp->exit()` to break out of the event loop and return the input.

## Main Window Layout (Desktop Mode)

```
+------------------------------------------------------------------+
| [Menu Bar: Game | Gear | Action | Magic | Info |   | Help]       |
| [Toolbar: Again | Get | Kick | Throw | Fire | Drop | Eat | Rest]|
+------------------------------------------------------------------+
|  Messages (scrollable list) | Inv Usage | Status Panel           |
|  "The gnome hits you."     | [H][B]    | Phire the Valkyrie     |
|  "You kill the gnome!"     | [s][""][w] | Dungeons of Doom, L:3  |
|                             | [g][C][g] | ---------------------- |
|                             | [=][A][=] | STR DEX CON INT WIS CHA|
|                             | [ ][T][ ] | ---------------------- |
|                             | [ ][S][ ] | Au  HP  Pow AC Lvl Exp |
|                             |           | ---------------------- |
|                             |           | Time   Score           |
|                             |           | Lawful Hungry Confused |
+-----------------------------+-----------+------------------------+
| Map (scrollable tile grid, COLNO x ROWNO)                        |
| Black background, tiles rendered from sprite sheet                |
| Player position marked with HP-colored cursor rectangle           |
| Pet/pile annotations overlaid as small pixmaps                    |
+------------------------------------------------------------------+
```

The layout uses `QSplitter` widgets:
- A **vertical splitter** (`vsplitter`) separates the top panel from the map
- A **horizontal splitter** (`hsplitter`) divides the top into: messages (left), inventory usage (center), status (right)

## Component Details

### 1. Map Window (`qt4map.cpp`)

The map is a `QScrollArea` containing a `NetHackQtMapViewport` widget sized exactly to `COLNO * tile_width` by `ROWNO * tile_height` (typically 80x21 tiles).

**Tile rendering**: The `NetHackQtGlyphs` class loads a tile image file (`nhtiles.bmp` or `x11tiles`), a sprite sheet with all tiles in a grid (default 40 tiles per row, 16x16 pixels each). `glyph2tile[]` maps NetHack glyph indices to tile positions. On paint, each cell calls `drawGlyph()` which copies the relevant sub-rectangle from a pre-scaled `QPixmap`.

**Two rendering modes**:
- **Tile mode** (normal): Draws tiles from the sprite sheet via `glyphs.drawCell()`
- **ASCII/Rogue mode** (`Is_rogue_level()` or `wc_ascii_map`): Black background with colored text characters. Automatically finds the largest monospace font that fits within tile dimensions. Wall characters (Unicode box-drawing: U+2500-U+256C) are drawn as line segments rather than font glyphs, supporting both single and double-line walls. Solid block characters (U+2591-U+2593) are drawn as shaded rectangles.

**Cursor**: A colored rectangle outline around the player's position. The color reflects HP percentage:
- >75%: white
- >50%: yellow
- >25%: orange (`#ffbf00`)
- >10%: red
- <=10%: magenta

**Annotations**: Small pixmap overlays for:
- Pets (`pet_mark_xpm`): drawn on tiles with `MG_PET` flag when `hilite_pet` is on
- Object piles (`pile_mark_xpm`): drawn on tiles with `MG_OBJPILE` flag when `hilite_pile` is on

**Scrolling**: `ClipAround()` calls `ensureVisible()` to keep the player centered with 45% margins, so the viewport scrolls smoothly as the player moves.

**Dirty rectangle optimization**: The `Clusterizer` class tracks which cells have changed since the last paint, and only repaints those tile-aligned rectangles.

**Mouse input**: Left-click sends `CLICK_1`, right-click sends `CLICK_2`, mapped to map coordinates by dividing pixel position by tile dimensions.

**Tile resizing**: Tiles can be resized via the Qt Settings dialog (spin boxes for width/height, 6-128 pixels). The glyph class keeps two cached pre-scaled pixmaps for quick zoom toggling.

### 2. Message Window (`qt4msg.cpp`)

A `QListWidget` that appends game messages as list items. Features:
- Automatically scrolls to the bottom on new messages (`setCurrentRow(count-1)`)
- Respects `msg_history` limit — old messages are deleted when the cap is reached
- Unicode symbol translation: if a line starts with a character + 3 spaces (the `/` look-command format), the first character is translated via `cp437()` to display the proper symbol
- Font controlled by the global settings (normal font)
- In compact mode, messages are also forwarded to the map window for overlay display
- Supports `ATR_BOLD`, `ATR_ULINE`, `ATR_DIM`, `ATR_INVERSE` text attributes (though some are commented out in the Qt4 version)

### 3. Status Window (`qt4stat.cpp`)

A panel of `NetHackQtLabelledIcon` widgets arranged in a vertical layout:

```
[Name] "Phire the Valkyrie"              (large font)
[Dungeon Level] "Dungeons of Doom, 3"    (large font)
─────────────────────────────────────────
[STR icon] STR:18/03 [DEX] [CON] [INT] [WIS] [CHA]
─────────────────────────────────────────
[Gold] Au:42 [HP] HP:16/16 [Pow] Pow:4/4 [AC] AC:6 [Lvl] Level:1 [Exp] Exp:0
─────────────────────────────────────────
[Time] Time:123   [Score] Score:0
[Alignment icon] Lawful  [Hunger icon] Hungry  Confused  Sick  Blind  Stunned  Hallu  [Encumbrance icon]
```

Each stat has a custom XPM icon (the ability score icons are small pixel-art images: STR shows a flexing arm, DEX a hand, etc.). Status conditions (confused, blind, stunned, hallucinating, sick — food poisoning vs illness as separate indicators) and encumbrance levels (5 tiers: Slight, Moderate, Heavy, Extreme, Overloaded) each have distinct icons.

**Highlighting**: When a stat value changes, the `NetHackQtLabelledIcon` briefly highlights it — green for improvements, red for declines (configurable via `lowIsGood()` for AC). The highlighting fades over turns via `dissipateHighlight()`, called from `fadeHighlighting()` on each `nhgetch`.

Alignment has three icons (lawful/neutral/chaotic). The HP display shows `current/max` format. When polymorphed, shows monster name and HD instead of class/level.

### 4. Inventory Usage Window (`qt4inv.cpp`)

A small 3x6 tile grid showing currently worn/wielded equipment in a paper-doll layout:

```
Col:  0    1    2
Row 0: [Swap] [Helm] [Blind]
Row 1: [Shld] [Amul] [Weap]
Row 2: [GlvL] [Clok] [GlvR]
Row 3: [RngL] [Armr] [RngR]
Row 4:        [Shrt]
Row 5:        [Boot]
```

Each slot renders the glyph of the equipped item (`obj_to_glyph`), or a room tile (`.`) if the slot is empty but equippable, or a stone tile (wall) if the slot is not applicable. The window is `Fixed` size policy at `3 * tile_width` by `6 * tile_height`.

### 5. Menu Window (`qt4menu.cpp`)

A `QDialog` with a `QTableWidget` of 5 columns:

| Column | Content |
|--------|---------|
| 0 | Pick count (for "how many?") |
| 1 | Checkbox (selection) |
| 2 | Glyph icon (item/monster image) |
| 3 | Accelerator letter ("a - ") |
| 4 | Item description text |

**Selection modes**:
- `PICK_NONE`: Display-only (Ok button only)
- `PICK_ONE`: Select one item, auto-closes on selection
- `PICK_ANY`: Multi-select with All/None/Invert/Search buttons

**Button bar**: Ok, Cancel, All, None, Invert, Search — enabled/disabled based on selection mode.

**Keyboard shortcuts**: Type an accelerator letter to toggle that item. Menu-wide shortcuts: `.` (select all), `-` (deselect all), `@` (invert), `/` (search), `0-9` + backspace for count entry. Enter/Space accepts, Escape cancels.

**Count input**: Typing digits enters a count, displayed as "Count: 123" in the prompt area. Selecting an item with a count active applies that count.

**Menu coloring**: Supports `MENUCOLOR` entries from `.nethackrc` — items matching patterns get custom foreground colors and text attributes (bold, underline, inverse, dim).

**Column alignment**: Tab-separated text in menu items is aligned into columns by measuring and padding to consistent widths.

### 6. Text Window (`qt4menu.cpp` — `NetHackQtTextWindow`)

A `QDialog` with a `QListWidget` for text content, plus Dismiss and Search buttons. Used for:
- Displaying files (help, guidebook, etc.)
- Long text output (inventory listings, etc.)
- The **RIP tombstone** (death screen)

If the content contains 4+ consecutive spaces, it switches to a fixed-width font. Large text windows are shown maximized; small ones are centered.

The **Search** function finds and highlights text within the list, wrapping around.

### 7. Yes/No Dialog (`qt4yndlg.cpp`)

Two modes based on the `ynInMessages` setting:

**Inline mode** (default on desktop): The question is printed to the message window as bold text, then `nhgetch()` waits for a key press. Invalid choices beep. This mimics the TTY experience.

**Popup mode** (compact or `popup_dialog` option): A `QDialog` with a grid of square buttons, one per choice character. For "yn"/"ynq" prompts, buttons are labeled "Yes"/"No"/"Cancel". For direction prompts, buttons are arranged in a 3x3+2 compass layout matching `Cmd.dirchars`. Includes an optional count entry field when `#` is a valid choice.

### 8. String Requestor (`qt4streq.cpp`)

A `QDialog` with a prompt label, a `QLineEdit` for text input, and Ok/Cancel buttons. Used for `getlin()` calls (naming items, entering extended commands, etc.).

### 9. Extended Command Requestor (`qt4xcmd.cpp`)

A dialog listing all extended commands (like `#enhance`, `#pray`, etc.) for selection, used when the player presses `#`.

### 10. Player Selector (`qt4plsel.cpp`)

A character creation dialog with:

```
+-- Name ------------------------------------------------+
| [text input field]                                      |
+--------------------------------------------------------+
+-- Race ---+  +-- Role ---+  +-- Gender ------+
| * Human   |  | * Valkyrie|  | (*) Male       |
|   Elf     |  |   Wizard  |  | ( ) Female     |
|   Dwarf   |  |   Rogue   |  +----------------+
|   Gnome   |  |   Samurai |  +-- Alignment ---+
|   Orc     |  |   ...     |  | (*) Lawful     |
|           |  |           |  | ( ) Neutral    |
|           |  |           |  | ( ) Chaotic    |
|           |  |           |  +----------------+
|           |  |           |  NetHack 3.6.7
|           |  |           |  [Random]
|           |  |           |  [Play]
+-----------+  +-----------+  [Quit]
```

- Race and Role lists are `QTableWidget` with glyph icons (monster tiles for each race/role)
- Gender and Alignment are `QRadioButton` groups
- Invalid combinations are grayed out dynamically as you select (e.g., selecting Elf disables roles Elves can't play)
- "Random" button randomizes all unspecified choices while respecting constraints
- `QT_CHOOSE_RACE_FIRST` compile-time option swaps which column is primary
- If all options were fully specified in `.nethackrc`, the dialog is skipped entirely

### 11. Saved Game Selector (`qt4svsel.cpp`)

If saved games exist, a dialog lets you choose to restore one or start new.

### 12. Splash Screen

On startup, a frameless `QFrame` with `nhsplash.xpm` and "Loading..." text is shown centered, dismissed once the main window becomes visible.

### 13. RIP Tombstone (`qt4rip.cpp`)

Loads `rip.xpm` (a pixel-art gravestone image) and overlays the player's name, gold amount, cause of death (word-wrapped to 16 chars/line), and year in the stone area at hardcoded coordinates.

## Menu Bar Structure

| Menu | Contents |
|------|----------|
| **Game** | Qt settings..., Version, Compilation, History, Options, Explore mode, ---, Save, Quit |
| **Gear** | Remove all, ---, Wield weapon, Exchange weapons, Two weapon combat, Load quiver, ---, Wear armour, Take off armour, ---, Put on, Remove |
| **Action** | Apply, Chat, Close door, Down, Drop/Drop many, Eat, Engrave, Fire from quiver, Force, Get, Jump, Kick, Loot, Open door, Pay, Rest, Ride, Search, Sit, Throw, Untrap, Up, Wipe face |
| **Magic** | Quaff potion, Read scroll/book, Zap wand, Zap spell, Dip, Rub, Invoke, ---, Offer, Pray, ---, Teleport, Monster action, Turn undead |
| **Info** | Inventory, Conduct, Discoveries, List/reorder spells, Adjust letters, ---, Name object/creature, ---, Skills |
| **Help** | Help, ---, What is here, What is there, What is... |

Each menu item shows its keyboard shortcut on the right (e.g., "Apply	a"). Menu items inject their corresponding command character into the key buffer via `doKeys()`.

In compact mode, Action is split into "A-J" and "K-Z" submenus, and Info gets extra entries for "Map", "Messages", "Status" to switch the stacked view.

## Toolbar

Eight icon buttons with small XPM pixel art:
- **Again** (circular arrow): repeats last command
- **Get** (down arrow + box): pickup items
- **Kick** (boot + lines): kick
- **Throw** (box + arrow right): throw
- **Fire** (arrow with fletching): fire from quiver
- **Drop** (box + down arrow): drop items
- **Eat** (fork + knife): eat
- **Rest** (Zzz): wait one turn

Each button sends the corresponding command character to the key buffer.

## Keyboard Handling

Arrow keys use a **chord system** for diagonal movement: pressing Up then Right (while Up is held) produces a northeast direction. This is implemented via `dirkey` tracking in the main window's key events — `keyPressEvent` sets `dirkey` based on current direction state, and `keyReleaseEvent` sends the accumulated direction character.

**Key macros**: F1 = rest 100 turns (`n100.`), F2 = search 20 times (`n20s`), Tab = repeat last command.

All unhandled key events are caught by `NetHackQtBind::notify()`, which converts them to ASCII (with Alt adding 128 for meta-commands) and puts them in the key buffer.

## Settings Dialog

Accessible from Game menu, a small dialog with:
- **Tile width/height** spin boxes (6-128 pixels, persisted via `QSettings`)
- **Zoomed** checkbox: toggles between two saved tile sizes
- **Font size** dropdown: Huge/Large/Medium/Small/Tiny (maps to point sizes 18/14/12/10/8)

Changes emit signals that cause the map to re-scale tiles and all text widgets to update fonts.

## Glyph/Tile System

`NetHackQtGlyphs` manages the tile sheet:
1. Loads the image file (`nhtiles.bmp` at 40 tiles/row, or `x11tiles` at `TILES_PER_ROW`)
2. Determines native tile size from image dimensions
3. Pre-scales to the configured tile size, caching two scale levels for quick zoom toggle
4. `glyph2tile[]` (from `tile.c`) maps glyph ID -> tile index -> row/column in the sheet
5. `drawGlyph()` blits the relevant sub-rectangle from the cached `QPixmap`
