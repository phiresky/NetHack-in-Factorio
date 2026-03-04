-- gui.lua: NetHack Qt-style GUI for Factorio
-- Layout: single top panel with menu bar + [messages | status], matching Qt port
local Gui = {}

-- Window type constants (from NetHack) — exported for use by bridge.lua
local NHW_MESSAGE = 1
local NHW_STATUS  = 2
local NHW_MAP     = 3
local NHW_MENU    = 4
local NHW_TEXT    = 5
Gui.NHW_MESSAGE = NHW_MESSAGE
Gui.NHW_STATUS  = NHW_STATUS
Gui.NHW_MAP     = NHW_MAP
Gui.NHW_MENU    = NHW_MENU
Gui.NHW_TEXT    = NHW_TEXT

local TC = require("scripts.tile_config")
local TOTAL_TILES = TC.n_monsters + TC.n_objects + TC.n_other

-- Submodules
local GuiStatus = require("scripts.gui_status")
local GuiEquip = require("scripts.gui_equip")
local GuiMenus = require("scripts.gui_menus")
local GuiPlsel = require("scripts.gui_plsel")

-- Initialize submodules with shared helpers (sorted_keys defined below)
-- Deferred to after sorted_keys is defined.

-- Re-export status data tables for create_player_gui
local STAT_LABELS = GuiStatus.STAT_LABELS
local VITAL_LABELS = GuiStatus.VITAL_LABELS

-- Re-export submodule functions on Gui table
Gui.update_status = GuiStatus.update_status
Gui.flush_status = GuiStatus.flush_status
Gui.render_status = GuiStatus.render_status
Gui.render_equipment = GuiEquip.render_equipment
Gui.handle_equip_click = GuiEquip.handle_click

Gui.start_menu = GuiMenus.start_menu
Gui.add_menu_item = GuiMenus.add_menu_item
Gui.end_menu = GuiMenus.end_menu
Gui.show_menu = GuiMenus.show_menu
Gui.handle_menu_click = GuiMenus.handle_menu_click
Gui.handle_menu_action = GuiMenus.handle_menu_action
Gui.handle_menu_key = GuiMenus.handle_menu_key

Gui.show_plsel_dialog = GuiPlsel.show_plsel_dialog
Gui.handle_plsel_click = GuiPlsel.handle_plsel_click
Gui.handle_plsel_checkbox = GuiPlsel.handle_plsel_checkbox

local MAX_MESSAGES = 50

-- Estimated instructions for NetHack startup (first input prompt)
local ESTIMATED_STARTUP_INSTRUCTIONS = 1770000

-- Destroy a modal GUI frame and optionally clear associated pending state.
function Gui.destroy_modal(player, frame_name, pending_key)
  if player then
    local frame = player.gui.screen[frame_name]
    if frame then frame.destroy() end
  end
  if pending_key and storage.nh_gui then
    storage.nh_gui[pending_key] = nil
  end
end

-- Return sorted numeric keys from a table (for plsel index lists).
local function sorted_keys(tbl)
  local keys = {}
  for k, _ in pairs(tbl) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

-- Format a number with commas: 1234567 -> "1,234,567"
local function format_number(n)
  local s = tostring(math.floor(n))
  local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  if formatted:sub(1, 1) == "," then
    formatted = formatted:sub(2)
  end
  return formatted
end

-- BL_* constants and stat/vital/condition data tables are in gui_status.lua

-- Toolbar buttons (Qt-style quick-access bar below menu bar)
local TOOLBAR_BUTTONS = {
  {name = "again", label = "[img=nh-icon-tb-again] Again", key = 0x01},
  {name = "get",   label = "[img=nh-icon-tb-get] Get",     key = string.byte(",")},
  {name = "kick",  label = "[img=nh-icon-tb-kick] Kick",   key = 0x04},
  {name = "throw", label = "[img=nh-icon-tb-throw] Throw", key = string.byte("t")},
  {name = "fire",  label = "[img=nh-icon-tb-fire] Fire",   key = string.byte("f")},
  {name = "drop",  label = "[img=nh-icon-tb-drop] Drop",   key = string.byte("d")},
  -- {name = "eat",   label = "[img=nh-icon-tb-eat] Eat",     key = string.byte("e")},
  {name = "rest",  label = "[img=nh-icon-tb-rest] Rest",   key = string.byte(".")},
  {name = "search",label = "[img=nh-icon-tb-search] Search", key = string.byte("s")},
}

-- Menu bar definitions (matches Qt menu bar: Game, Gear, Action, Magic, Info, Help)
-- ext = extended command name (for # commands that need getlin follow-up)
local MENU_BAR = {
  {name = "game", label = "Game", items = {
    {label = "Version",       key = string.byte("v"), shortcut = "Alt+v"},
    {label = "History",       key = string.byte("V")},
    {label = "Options",       key = string.byte("O")},
    {label = "Explore mode",  key = string.byte("#"), ext = "exploremode"},
    {separator = true},
    {label = "Toggle player mode", action = "toggle_player_mode"},
    -- {label = "Save",          key = string.byte("S")},
    -- {label = "Quit",          key = string.byte("#"), ext = "quit"},
  }},
  {name = "gear", label = "Gear", items = {
    {label = "Wield weapon",      key = string.byte("w"), shortcut = "Alt+w"},
    {label = "Exchange weapons",  key = string.byte("x"), shortcut = "Alt+x"},
    {label = "Two weapon combat", key = string.byte("#"), ext = "twoweapon"},
    {label = "Load quiver",       key = string.byte("Q")},
    {separator = true},
    {label = "Wear armour",       key = string.byte("W"), shortcut = "Alt+Shift+w"},
    {label = "Take off armour",   key = string.byte("T"), shortcut = "Alt+Shift+t"},
    {separator = true},
    {label = "Put on",            key = string.byte("P"), shortcut = "Alt+Shift+p"},
    {label = "Remove",            key = string.byte("R"), shortcut = "Alt+Shift+r"},
  }},
  {name = "action", label = "Action", items = {
    {label = "Again",            key = 0x01},  -- ^A
    {label = "Apply",            key = string.byte("a"), shortcut = "Alt+a"},
    {label = "Chat",             key = string.byte("#"), ext = "chat"},
    {label = "Close door",       key = string.byte("c"), shortcut = "Alt+c"},
    {label = "Down",             key = string.byte(">"), shortcut = "Shift+."},
    {label = "Drop",             key = string.byte("d"), shortcut = "Alt+d"},
    {label = "Drop many",        key = string.byte("D")},
    {label = "Eat",              key = string.byte("e"), shortcut = "Alt+e"},
    {label = "Engrave",          key = string.byte("E"), shortcut = "Alt+Shift+e"},
    {label = "Fire from quiver", key = string.byte("f"), shortcut = "Alt+f"},
    {label = "Force",            key = string.byte("#"), ext = "force", shortcut = "Ctrl+f"},
    {label = "Get",              key = string.byte(","), shortcut = "Alt+,"},
    {label = "Jump",             key = string.byte("#"), ext = "jump"},
    {label = "Kick",             key = 0x04, shortcut = "Ctrl+d"},  -- ^D
    {label = "Loot",             key = string.byte("#"), ext = "loot"},
    {label = "Open door",        key = string.byte("o"), shortcut = "Alt+o"},
    {label = "Pay",              key = string.byte("p"), shortcut = "Alt+p"},
    {label = "Rest",             key = string.byte("."), shortcut = "Alt+."},
    {label = "Ride",             key = string.byte("#"), ext = "ride"},
    {label = "Search",           key = string.byte("s"), shortcut = "Alt+s"},
    {label = "Sit",              key = string.byte("#"), ext = "sit"},
    {label = "Throw",            key = string.byte("t"), shortcut = "Alt+t"},
    {label = "Untrap",           key = string.byte("#"), ext = "untrap"},
    {label = "Up",               key = string.byte("<"), shortcut = "Shift+,"},
    {label = "Wipe face",        key = string.byte("#"), ext = "wipe"},
  }},
  {name = "magic", label = "Magic", items = {
    {label = "Quaff potion",     key = string.byte("q"), shortcut = "Alt+q"},
    {label = "Read scroll/book", key = string.byte("r"), shortcut = "Alt+r"},
    {label = "Zap wand",         key = string.byte("z"), shortcut = "Alt+z"},
    {label = "Zap spell",        key = string.byte("Z"), shortcut = "Alt+Shift+z"},
    {label = "Dip",              key = string.byte("#"), ext = "dip"},
    {label = "Rub",              key = string.byte("#"), ext = "rub"},
    {label = "Invoke",           key = string.byte("#"), ext = "invoke"},
    {separator = true},
    {label = "Offer",            key = string.byte("#"), ext = "offer"},
    {label = "Pray",             key = string.byte("#"), ext = "pray"},
    {separator = true},
    {label = "Teleport",         key = 0x14},  -- ^T
    {label = "Monster action",   key = string.byte("#"), ext = "monster"},
    {label = "Turn undead",      key = string.byte("#"), ext = "turn"},
  }},
  {name = "info", label = "Info", items = {
    {label = "Inventory",          key = string.byte("i"), shortcut = "Alt+i"},
    {label = "Conduct",            key = string.byte("#"), ext = "conduct"},
    {label = "Discoveries",        key = string.byte("\\")},
    {label = "List/reorder spells",key = string.byte("+")},
    {label = "Adjust letters",     key = string.byte("#"), ext = "adjust"},
    {separator = true},
    {label = "Name object",        key = string.byte("#"), ext = "name"},
    {separator = true},
    {label = "Skills",             key = string.byte("#"), ext = "enhance", shortcut = "Ctrl+e"},
  }},
  {name = "help", label = "Help", items = {
    {label = "Help",              key = string.byte("?")},
    {separator = true},
    {label = "What is here",      key = string.byte(":"), shortcut = "Shift+;"},
    {label = "What is there",     key = string.byte(";"), shortcut = "Alt+;"},
    {label = "What is...",        key = string.byte("/"), shortcut = "Alt+/"},
  }},
}

-- Build dropdown item lists and index->action lookup for each menu
local MENU_DD_ITEMS = {}   -- menu.name -> {item strings}
local MENU_DD_LOOKUP = {}  -- menu.name -> {[dropdown_index] -> {key, ext}}

for _, menu in ipairs(MENU_BAR) do
  local items = {menu.label}  -- index 1 = header (shown when closed)
  local lookup = {}
  for _, item in ipairs(menu.items) do
    if item.separator then
      items[#items + 1] = "───"
      -- no lookup entry for separators
    else
      local display = item.label
      if item.shortcut then
        display = display .. "  [color=gray](" .. item.shortcut .. ")[/color]"
      end
      items[#items + 1] = display
      lookup[#items] = {key = item.key, ext = item.ext, action = item.action}
    end
  end
  MENU_DD_ITEMS[menu.name] = items
  MENU_DD_LOOKUP[menu.name] = lookup
end

-----------------------------------------------------
-- HP color by ratio
-----------------------------------------------------

-- Initialize submodules with shared helpers (deferred until sorted_keys is defined)
GuiMenus.init(TOTAL_TILES, sorted_keys)
GuiPlsel.init(sorted_keys)

-----------------------------------------------------
-- Initialization
-----------------------------------------------------

function Gui.init()
  if not storage.nh_gui then
    storage.nh_gui = {
      messages = {},         -- message history (chronological, oldest first)
      status_fields = {},    -- idx -> {value, color}
      highlight_timers = {}, -- idx -> {count, good}
      windows = {},          -- winid -> {type, items, prompt, ...}
      next_winid = 10,
      pending_menu = nil,
      pending_yn = nil,
      pending_getlin = nil,
      player_frames = {},
    }
  end
  -- Ensure fields exist on saves from older versions
  if not storage.nh_gui.highlight_timers then
    storage.nh_gui.highlight_timers = {}
  end
end

-----------------------------------------------------
-- GUI Creation / Destruction
-----------------------------------------------------

function Gui.create_player_gui(player)
  local gui_data = storage.nh_gui
  Gui.destroy_player_gui(player)

  local screen = player.gui.screen
  local ui_width = player.display_resolution.width / player.display_scale
  local ui_height = player.display_resolution.height / player.display_scale

  local minimap_width = 256
  local total_width = ui_width - minimap_width

  -------------------------------------------------
  -- Top panel: menu bar, then [toolbar+messages | stats | equipment]
  -------------------------------------------------
  local top_panel = screen.add{
    type = "frame",
    name = "nh_top_panel",
    direction = "vertical",
    style = "nh_top_frame",
  }
  top_panel.location = {x = 0, y = 0}
  top_panel.style.width = total_width

  -- Menu bar row
  local menubar = top_panel.add{
    type = "flow",
    name = "nh_menubar",
    direction = "horizontal",
    style = "nh_menubar_flow",
  }
  for _, menu in ipairs(MENU_BAR) do
    menubar.add{
      type = "drop-down",
      name = "nh_mb_dd_" .. menu.name,
      items = MENU_DD_ITEMS[menu.name],
      selected_index = 1,
      style = "nh_menubar_dropdown",
    }
  end

  -- Separator below menu bar
  top_panel.add{type = "line", direction = "horizontal"}

  -- Content area: [toolbar+messages | stats | equipment]
  local content = top_panel.add{
    type = "flow",
    name = "nh_top_content",
    direction = "horizontal",
    style = "nh_top_content_flow",
  }

  -------------------------------------------------
  -- Left column: toolbar + messages
  -------------------------------------------------
  local msg_pane = content.add{
    type = "flow",
    name = "nh_msg_pane",
    direction = "vertical",
  }
  msg_pane.style.maximal_width = 620

  -- Toolbar (quick-access buttons)
  local toolbar = msg_pane.add{
    type = "flow",
    name = "nh_toolbar",
    direction = "horizontal",
    style = "nh_toolbar_flow",
  }
  for _, btn in ipairs(TOOLBAR_BUTTONS) do
    toolbar.add{
      type = "button",
      name = "nh_tb_" .. btn.key,
      caption = btn.label,
      style = "nh_toolbar_button",
    }
  end

  -- Messages scroll
  local msg_scroll = msg_pane.add{
    type = "scroll-pane",
    name = "nh_msg_scroll",
    horizontal_scroll_policy = "never",
    vertical_scroll_policy = "auto-and-reserve-space",
    style = "nh_msg_scroll",
  }

  -- Populate with existing messages
  for _, msg in ipairs(gui_data.messages) do
    local style = (msg.attr == 1) and "nh_message_label_bold" or "nh_message_label"
    msg_scroll.add{
      type = "label",
      caption = msg.text,
      style = style,
    }
  end
  if #gui_data.messages > 0 then
    msg_scroll.scroll_to_bottom()
  end

  -------------------------------------------------
  -- Middle column: stats
  -------------------------------------------------
  local status_flow = content.add{
    type = "flow",
    name = "nh_status_flow",
    direction = "horizontal",
    style = "nh_st_lower_flow",
  }

  local left_col = status_flow.add{
    type = "flow",
    name = "nh_st_left",
    direction = "vertical",
    style = "nh_st_left_flow",
  }

  -- Player name (large bold)
  left_col.add{
    type = "label",
    name = "nh_st_name",
    caption = "",
    style = "nh_status_name_label",
  }

  -- Dungeon level
  left_col.add{
    type = "label",
    name = "nh_st_dlevel",
    caption = "",
    style = "nh_status_dlevel_label",
  }

  -- Separator
  left_col.add{type = "line", direction = "horizontal"}

  -- Stats row: STR DEX CON INT WIS CHA
  local stats_flow = left_col.add{
    type = "flow",
    name = "nh_st_stats",
    direction = "horizontal",
  }
  for _, stat in ipairs(STAT_LABELS) do
    stats_flow.add{
      type = "label",
      name = "nh_st_" .. stat.name,
      caption = "",
      tooltip = stat.tip,
      style = "nh_status_label",
    }
  end

  -- Separator
  left_col.add{type = "line", direction = "horizontal"}

  -- Vitals row: Au HP Pw AC Lvl Xp
  local vitals_flow = left_col.add{
    type = "flow",
    name = "nh_st_vitals",
    direction = "horizontal",
  }
  for _, vital in ipairs(VITAL_LABELS) do
    local style = "nh_status_label"
    if vital.name == "gold" then style = "nh_gold_label" end
    vitals_flow.add{
      type = "label",
      name = "nh_st_" .. vital.name,
      caption = "",
      tooltip = vital.tip,
      style = style,
    }
  end

  -- Separator
  left_col.add{type = "line", direction = "horizontal"}

  -- Misc row: Time Score
  local misc_flow = left_col.add{
    type = "flow",
    name = "nh_st_misc",
    direction = "horizontal",
  }
  misc_flow.add{type = "label", name = "nh_st_time", caption = "", style = "nh_status_label"}
  misc_flow.add{type = "label", name = "nh_st_score", caption = "", style = "nh_status_label"}

  -- Conditions row: Align + Hunger + Encumbrance + dynamic conditions
  local cond_flow = left_col.add{
    type = "flow",
    name = "nh_st_cond",
    direction = "horizontal",
  }
  cond_flow.add{type = "label", name = "nh_st_align", caption = "", style = "nh_status_label"}
  cond_flow.add{type = "label", name = "nh_st_hunger", caption = "", style = "nh_status_label"}
  cond_flow.add{type = "label", name = "nh_st_cap", caption = "", style = "nh_status_label"}
  -- Dynamic condition labels go in a sub-flow (rebuilt on each flush)
  cond_flow.add{
    type = "flow",
    name = "nh_st_cond_dynamic",
    direction = "horizontal",
  }

  -------------------------------------------------
  -- Right column: equipment (paperdoll grid)
  -------------------------------------------------
  local right_col = content.add{
    type = "flow",
    name = "nh_st_right",
    direction = "vertical",
    style = "nh_st_right_flow",
  }
  right_col.add{
    type = "label",
    name = "nh_equip_header",
    caption = "Equipment",
    style = "nh_equip_header_label",
  }
  local equip_frame = right_col.add{
    type = "frame",
    name = "nh_equip_frame",
    style = "deep_frame_in_shallow_frame",
  }
  equip_frame.add{
    type = "table",
    name = "nh_equip_table",
    column_count = 5,
    style = "nh_equip_table",
  }

  -- Engine state (right-aligned in menu bar)
  local engine_spacer = menubar.add{
    type = "empty-widget",
    name = "nh_engine_spacer",
    style = "nh_engine_spacer",
  }
  engine_spacer.style.horizontally_stretchable = true
  menubar.add{
    type = "label",
    name = "nh_engine_label",
    caption = "Initializing",
    style = "nh_engine_state_label",
  }

  -- Hover info frame (separate frame below top panel)
  local hover_frame = screen.add{
    type = "frame",
    name = "nh_hover_frame",
    direction = "vertical",
    style = "nh_hover_frame",
  }
  hover_frame.location = {x = 0, y = math.floor(220 * player.display_scale)}
  hover_frame.visible = false
  hover_frame.add{
    type = "label",
    name = "nh_hover_short",
    caption = "",
    style = "nh_hover_short_label",
  }
  hover_frame.add{
    type = "label",
    name = "nh_hover_long",
    caption = "",
    style = "nh_hover_long_label",
  }

  gui_data.player_frames[player.index] = true

  -- Render current status if available
  Gui.render_status(player)
end

function Gui.destroy_player_gui(player)
  local gui_data = storage.nh_gui
  local screen = player.gui.screen

  -- Destroy all our top-level screen elements
  local names = {
    "nh_top_panel", "nh_hover_frame",
    "nh_menu_frame", "nh_yn_frame", "nh_getlin_frame",
    "nh_loading_frame", "nh_plsel_frame",
    -- Old layout (migration cleanup)
    "nh_top_frame", "nh_msg_frame", "nh_status_frame", "nh_action_panel",
  }
  for _, name in ipairs(names) do
    if screen[name] then
      screen[name].destroy()
    end
  end

  gui_data.player_frames[player.index] = nil
end

-----------------------------------------------------
-- Message Display
-----------------------------------------------------

function Gui.add_message(text, attr)
  local gui_data = storage.nh_gui

  -- Store chronologically (oldest first, newest last)
  gui_data.messages[#gui_data.messages + 1] = {
    text = text, attr = attr or 0, tick = game.tick,
  }

  -- Trim oldest
  while #gui_data.messages > MAX_MESSAGES do
    table.remove(gui_data.messages, 1)
  end

  -- Update display for all players
  for _, player in pairs(game.connected_players) do
    Gui.append_message_label(player, text, attr)
  end
end

-- Add a single message label to the scroll pane (incremental update)
function Gui.append_message_label(player, text, attr)
  local screen = player.gui.screen
  local top_panel = screen.nh_top_panel
  if not top_panel then return end
  local content = top_panel.nh_top_content
  if not content then return end
  local msg_pane = content.nh_msg_pane
  if not msg_pane then return end
  local scroll = msg_pane.nh_msg_scroll
  if not scroll then return end

  local style = (attr and attr == 1) and "nh_message_label_bold" or "nh_message_label"
  scroll.add{
    type = "label",
    caption = text or "",
    style = style,
  }

  -- Trim oldest labels if over limit
  local children = scroll.children
  while #children > MAX_MESSAGES do
    children[1].destroy()
    children = scroll.children
  end

  scroll.scroll_to_bottom()
end

-- Flying text at player position, staggered to avoid overlap
-- Tracks recent flying texts and offsets Y so multiple messages don't pile up
local FLYING_TEXT_STAGGER_TICKS = 3 * 60  -- match time_to_live so entries aren't cleaned up while still visible
local FLYING_TEXT_Y_OFFSET = 0.4      -- vertical spacing between stacked texts

function Gui.show_flying_text(player, text)
  if not player.character then return end

  local gui_data = storage.nh_gui
  if not gui_data.flying_text_queue then
    gui_data.flying_text_queue = {}
  end

  -- Clean up expired entries
  local now = game.tick
  local queue = gui_data.flying_text_queue
  local i = 1
  while i <= #queue do
    if now - queue[i] >= FLYING_TEXT_STAGGER_TICKS then
      table.remove(queue, i)
    else
      i = i + 1
    end
  end

  -- Count how many active flying texts exist (determines Y offset)
  local offset_index = #queue
  queue[#queue + 1] = now

  local pos = player.character.position
  player.create_local_flying_text{
    text = text,
    position = {x = pos.x, y = pos.y + offset_index * FLYING_TEXT_Y_OFFSET},
    time_to_live = 3 * 60,
    speed = 0.1,
  }
end

-- Status bar functions (update_status, flush_status, render_status) are in gui_status.lua

-----------------------------------------------------
-- Window Management
-----------------------------------------------------

function Gui.create_window(win_type)
  local gui_data = storage.nh_gui
  local winid = gui_data.next_winid
  gui_data.next_winid = winid + 1

  gui_data.windows[winid] = {
    type = win_type,
    items = {},
    prompt = "",
    visible = false,
  }

  return winid
end

function Gui.clear_window(winid)
  local gui_data = storage.nh_gui
  local win = gui_data.windows[winid]
  if win then
    win.items = {}
    win.prompt = ""
  end
end

function Gui.destroy_window(winid)
  local gui_data = storage.nh_gui
  local win = gui_data.windows[winid]

  -- If a visible text-display window exists, leave the GUI element for the
  -- user to dismiss via the OK button. This covers two patterns:
  --   1. display_nhwindow(TEXT, TRUE) + destroy: our display is non-blocking,
  --      so destroy fires before the user sees it.
  --   2. checkfile/com_pager use NHW_MENU for text: display_nhwindow(MENU, FALSE)
  --      + immediate destroy. Normal menus (via select_menu) never call
  --      display_nhwindow, so win.visible stays false and this guard is skipped.
  if win and win.visible and (win.type == NHW_TEXT or win.type == NHW_MENU) then
    gui_data.windows[winid] = nil
    return
  end

  for _, player in pairs(game.connected_players) do
    local screen = player.gui.screen
    local frame_name = "nh_win_" .. winid
    if screen[frame_name] then
      screen[frame_name].destroy()
    end
  end

  gui_data.windows[winid] = nil
end

function Gui.display_window(winid, blocking)
  local gui_data = storage.nh_gui
  local win = gui_data.windows[winid]
  if not win then return end

  win.visible = true

  -- Show text windows and menu windows used for text (e.g. quest intro text
  -- delivered via NHW_MENU by com_pager msgnum==1 in questpgr.c)
  if win.type == NHW_TEXT or (win.type == NHW_MENU and #win.items > 0) then
    for _, player in pairs(game.connected_players) do
      Gui.show_text_window(player, winid, win)
    end
  end
end

function Gui.show_text_window(player, winid, win)
  local screen = player.gui.screen
  local frame_name = "nh_win_" .. winid

  if screen[frame_name] then
    screen[frame_name].destroy()
  end

  local frame = screen.add{
    type = "frame",
    name = frame_name,
    direction = "vertical",
    caption = win.prompt ~= "" and win.prompt or "Information",
  }
  frame.auto_center = true

  local scroll = frame.add{
    type = "scroll-pane",
    name = "scroll",
    horizontal_scroll_policy = "never",
    vertical_scroll_policy = "auto-and-reserve-space",
  }
  scroll.style.maximal_height = 400
  scroll.style.minimal_width = 400

  for _, item in ipairs(win.items) do
    scroll.add{
      type = "label",
      caption = item.text or "",
      style = "nh_text_label",
    }
  end

  frame.add{
    type = "button",
    name = "nh_close_text_" .. winid,
    caption = "OK",
  }
end

-- Menu system (start_menu through handle_menu_key) is in gui_menus.lua

-----------------------------------------------------
-- yn_function prompt
-----------------------------------------------------

function Gui.show_yn_prompt(player, query, resp, def)
  local gui_data = storage.nh_gui

  gui_data.pending_yn = {
    query = query,
    resp = resp,
    def = def,
    player_index = player.index,
  }

  -- Always show query in message log for history
  Gui.add_message(query, 1)

  -- Show popup dialog
  local screen = player.gui.screen
  if screen.nh_yn_frame then
    screen.nh_yn_frame.destroy()
  end

  local frame = screen.add{
    type = "frame",
    name = "nh_yn_frame",
    direction = "vertical",
    caption = "Question",
  }
  frame.auto_center = true

  frame.add{
    type = "label",
    name = "nh_yn_query",
    caption = query or "",
  }

  local button_flow = frame.add{
    type = "flow",
    name = "nh_yn_buttons",
    direction = "horizontal",
  }

  if resp and #resp > 0 then
    for i = 1, #resp do
      local c = resp:sub(i, i)
      button_flow.add{
        type = "button",
        name = "nh_yn_btn_" .. string.byte(c),
        caption = c,
      }
    end
  else
    button_flow.add{type = "button", name = "nh_yn_btn_121", caption = "y"}
    button_flow.add{type = "button", name = "nh_yn_btn_110", caption = "n"}
  end
end

function Gui.handle_yn_click(player, element_name)
  local gui_data = storage.nh_gui
  if not gui_data.pending_yn then return nil end

  local match = element_name:match("^nh_yn_btn_(%d+)$")
  if match then
    local key_code = tonumber(match)
    gui_data.pending_yn = nil
    if player.gui.screen.nh_yn_frame then
      player.gui.screen.nh_yn_frame.destroy()
    end
    return key_code
  end

  return nil
end

-----------------------------------------------------
-- getlin prompt
-----------------------------------------------------

function Gui.show_getlin_prompt(player, prompt)
  local gui_data = storage.nh_gui

  gui_data.pending_getlin = {
    prompt = prompt,
    player_index = player.index,
  }

  local screen = player.gui.screen
  if screen.nh_getlin_frame then
    screen.nh_getlin_frame.destroy()
  end

  local frame = screen.add{
    type = "frame",
    name = "nh_getlin_frame",
    direction = "vertical",
    caption = prompt or "Input",
  }
  frame.auto_center = true

  frame.add{
    type = "textfield",
    name = "nh_getlin_textfield",
    text = "",
  }

  local button_flow = frame.add{
    type = "flow",
    direction = "horizontal",
  }

  button_flow.add{type = "button", name = "nh_getlin_ok", caption = "OK"}
  button_flow.add{type = "button", name = "nh_getlin_cancel", caption = "Cancel"}
end

function Gui.handle_getlin_click(player, element_name)
  local gui_data = storage.nh_gui
  if not gui_data.pending_getlin then return nil end

  if element_name == "nh_getlin_ok" then
    local screen = player.gui.screen
    local text = ""
    if screen.nh_getlin_frame and screen.nh_getlin_frame.nh_getlin_textfield then
      text = screen.nh_getlin_frame.nh_getlin_textfield.text
    end
    gui_data.pending_getlin = nil
    if screen.nh_getlin_frame then
      screen.nh_getlin_frame.destroy()
    end
    return text
  elseif element_name == "nh_getlin_cancel" then
    gui_data.pending_getlin = nil
    if player.gui.screen.nh_getlin_frame then
      player.gui.screen.nh_getlin_frame.destroy()
    end
    return "\027" -- ESC
  end

  return nil
end

-----------------------------------------------------
-- putstr: route to message or window
-----------------------------------------------------

function Gui.putstr(winid, attr, text)
  local gui_data = storage.nh_gui
  local win = gui_data.windows[winid]

  -- Message-type window: built-in winid 1 or any created message window
  if winid == NHW_MESSAGE or (win and win.type == NHW_MESSAGE) then
    Gui.add_message(text, attr)
    for _, player in pairs(game.connected_players) do
      Gui.show_flying_text(player, text)
    end
    return
  end

  -- Other windows: accumulate text
  if win then
    win.items[#win.items + 1] = {
      text = text,
      attr = attr,
      identifier = 0,
    }
  end
end

-----------------------------------------------------
-- Click Handlers
-----------------------------------------------------

-- Toolbar button click -> key code
function Gui.handle_toolbar_click(element_name)
  local key_str = element_name:match("^nh_tb_(%d+)$")
  if key_str then
    return tonumber(key_str)
  end
  return nil
end

-- Menu bar dropdown selection -> key code, ext command, action (or nil).
-- Always resets dropdown to show the menu label (index 1).
-- For action items (no key), returns nil, nil, action_name.
function Gui.handle_menubar_selection(element)
  local menu_name = element.name:match("^nh_mb_dd_(.+)$")
  if not menu_name then return nil end

  local idx = element.selected_index
  element.selected_index = 1  -- reset to header

  if idx <= 1 then return nil end  -- clicked the header itself

  local lookup = MENU_DD_LOOKUP[menu_name]
  if not lookup or not lookup[idx] then return nil end  -- separator or unknown

  local entry = lookup[idx]
  if entry.action then
    return nil, nil, entry.action
  end
  return entry.key, entry.ext
end

-----------------------------------------------------
-- Loading Progress Bar
-----------------------------------------------------

function Gui.create_loading_bar(player)
  local screen = player.gui.screen
  if screen.nh_loading_frame then return end

  local frame = screen.add{
    type = "frame",
    name = "nh_loading_frame",
    direction = "vertical",
    caption = "NetHack",
    style = "nh_loading_frame",
  }
  frame.auto_center = true

  frame.add{
    type = "label",
    name = "nh_loading_label",
    caption = "Loading...",
    style = "nh_loading_label",
  }

  frame.add{
    type = "progressbar",
    name = "nh_loading_bar",
    value = 0,
    style = "nh_loading_progressbar",
  }

  frame.add{
    type = "label",
    name = "nh_loading_count",
    caption = "0 / " .. format_number(ESTIMATED_STARTUP_INSTRUCTIONS) .. " instructions",
    style = "nh_loading_count_label",
  }
end

function Gui.update_loading_progress(instructions)
  local progress = math.min(1, instructions / ESTIMATED_STARTUP_INSTRUCTIONS)
  local pct = math.floor(progress * 100)
  local count_text = format_number(instructions) .. " / " .. format_number(ESTIMATED_STARTUP_INSTRUCTIONS) .. " instructions"

  for _, player in pairs(game.connected_players) do
    local screen = player.gui.screen
    local frame = screen.nh_loading_frame
    if frame then
      local bar = frame.nh_loading_bar
      if bar then bar.value = progress end
      local label = frame.nh_loading_label
      if label then label.caption = "Loading... " .. pct .. "%" end
      local count = frame.nh_loading_count
      if count then count.caption = count_text end
    end
  end
end

function Gui.destroy_loading_bar()
  for _, player in pairs(game.connected_players) do
    local screen = player.gui.screen
    if screen.nh_loading_frame then
      screen.nh_loading_frame.destroy()
    end
  end
end

-----------------------------------------------------
-- Tips Popup (shown once on first game start)
-----------------------------------------------------

function Gui.show_tips_popup(player)
  local screen = player.gui.screen
  if screen.nh_tips_frame then return end

  local frame = screen.add{
    type = "frame",
    name = "nh_tips_frame",
    direction = "vertical",
    caption = "Never played NetHack?",
    style = "nh_tips_frame",
  }
  frame.auto_center = true

  local tips = {
    {heading = "Movement", text = "Some things interact by walking into them: monsters to fight, doors to open, items to pick up. Others need an Action - 'Down' to descend, 'Read' to understand text."},
    {heading = "Search", text = "Some actions need to be repeated to work. If a corridor seems to suspiciously end, try Search (Alt+S)"},

    {heading = "Controls", text = "WASD to move. You can pass obstacles diagonally. Click distant tiles to auto-travel. Press Esc to cancel an action."},
    {heading = "Items", text = "Auto-pickup is enabled by default. Open Inventory (Alt+i) to see what you carry."},
    {heading = "Survival", text = "Eat food before you starve (Eat button). Read scrolls, quaff potions, zap wands -- experiment! You will die a lot, that's normal."},
  }

  for _, tip in ipairs(tips) do
    frame.add{
      type = "label",
      caption = tip.heading,
      style = "nh_tips_heading_label",
    }
    frame.add{
      type = "label",
      caption = tip.text,
      style = "nh_tips_label",
    }
  end

  frame.add{
    type = "button",
    name = "nh_tips_ok",
    caption = "Got it!",
    style = "nh_plsel_play_button",
  }
end

function Gui.destroy_tips_popup(player)
  local screen = player.gui.screen
  if screen.nh_tips_frame then
    screen.nh_tips_frame.destroy()
  end
end

-----------------------------------------------------
-- Engine State Display
-----------------------------------------------------

function Gui.update_engine_state(state_text, instructions, color)
  local caption = state_text .. " | " .. format_number(instructions) .. " inst"

  for _, player in pairs(game.connected_players) do
    local screen = player.gui.screen
    local top = screen.nh_top_panel
    if top then
      local menubar = top.nh_menubar
      if menubar then
        local label = menubar.nh_engine_label
        if label then
          label.caption = caption
          if color then
            label.style = "nh_engine_state_label"
            label.style.font_color = color
          end
        end
      end
    end
  end
end

-- Show/hide the cancel button on the toolbar
function Gui.set_cancel_visible(visible)
  -- no-op: cancel button removed
end

-----------------------------------------------------
-- Hover Info (in menu bar)
-----------------------------------------------------

function Gui.update_hover_info(player, info)
  local hover = player.gui.screen.nh_hover_frame
  if not hover then return end

  if not info then
    hover.visible = false
    return
  end

  local short_label = hover.nh_hover_short
  local long_label = hover.nh_hover_long

  short_label.caption = info.short or ""
  short_label.visible = (info.short ~= nil and info.short ~= "")

  if info.long and info.long ~= "" then
    long_label.caption = info.long
    long_label.visible = true
  else
    long_label.caption = ""
    long_label.visible = false
  end

  hover.visible = short_label.visible or long_label.visible
end

return Gui
