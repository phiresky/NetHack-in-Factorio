-- gui.lua: NetHack Qt-style GUI for Factorio
-- Layout: top panel (messages | status) + toolbar, action panel on right side
local Gui = {}

-- Window type constants (from NetHack)
local NHW_MESSAGE = 1
local NHW_STATUS  = 2
local NHW_MAP     = 3
local NHW_MENU    = 4
local NHW_TEXT    = 5

local MAX_MESSAGES = 50

-- BL_ field indices (from NetHack botl.h)
local BL_TITLE   = 0
local BL_STR     = 1
local BL_DX      = 2
local BL_CO      = 3
local BL_IN      = 4
local BL_WI      = 5
local BL_CH      = 6
local BL_ALIGN   = 7
local BL_SCORE   = 8
local BL_CAP     = 9
local BL_GOLD    = 10
local BL_ENE     = 11
local BL_ENEMAX  = 12
local BL_XP      = 13
local BL_AC      = 14
local BL_HD      = 15
local BL_TIME    = 16
local BL_HUNGER  = 17
local BL_HP      = 18
local BL_HPMAX   = 19
local BL_DLEVEL  = 20
local BL_FLUSH   = 34
local BL_RESET   = 35

-- Fields where lower is better (for highlight direction)
local LOW_IS_GOOD = {[BL_AC] = true}

-- Stat label definitions: {name, prefix, field_idx}
local STAT_LABELS = {
  {name = "str", prefix = "St:", idx = BL_STR},
  {name = "dx",  prefix = "Dx:", idx = BL_DX},
  {name = "co",  prefix = "Co:", idx = BL_CO},
  {name = "in",  prefix = "In:", idx = BL_IN},
  {name = "wi",  prefix = "Wi:", idx = BL_WI},
  {name = "ch",  prefix = "Ch:", idx = BL_CH},
}

-- Vital label definitions
local VITAL_LABELS = {
  {name = "gold", prefix = "Au:", idx = BL_GOLD},
  {name = "hp",   prefix = "HP:", idx = BL_HP, idx2 = BL_HPMAX},
  {name = "pw",   prefix = "Pw:", idx = BL_ENE, idx2 = BL_ENEMAX},
  {name = "ac",   prefix = "AC:", idx = BL_AC},
  {name = "xlvl", prefix = "Lvl:", idx = BL_HD},
  {name = "xp",   prefix = "Xp:", idx = BL_XP},
}

-- Condition field indices (22-32)
local COND_FIELDS = {22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32}

-- Toolbar buttons (Qt-style horizontal bar)
local TOOLBAR_BUTTONS = {
  {name = "again", label = "Again", key = 0x01},          -- ctrl-A (repeat)
  {name = "get",   label = "Get",   key = string.byte(",")},
  {name = "kick",  label = "Kick",  key = 0x04},          -- ctrl-D
  {name = "throw", label = "Throw", key = string.byte("t")},
  {name = "fire",  label = "Fire",  key = string.byte("f")},
  {name = "drop",  label = "Drop",  key = string.byte("d")},
  {name = "eat",   label = "Eat",   key = string.byte("e")},
  {name = "rest",  label = "Rest",  key = string.byte(".")},
}

-- Action panel buttons (comprehensive, for side panel)
local ACTION_BUTTONS = {
  {header = "Move"},
  {label = "Wait",      key = string.byte(".")},
  {label = "Search",    key = string.byte("s")},
  {label = "Up <",      key = string.byte("<")},
  {label = "Down >",    key = string.byte(">")},
  {header = "Items"},
  {label = "Inventory", key = string.byte("i")},
  {label = "Pickup",    key = string.byte(",")},
  {label = "Drop",      key = string.byte("d")},
  {label = "Apply",     key = string.byte("a")},
  {header = "Equip"},
  {label = "Wield",     key = string.byte("w")},
  {label = "Wear",      key = 87},  -- W
  {label = "Takeoff",   key = 84},  -- T
  {label = "Put on",    key = 80},  -- P
  {label = "Remove",    key = 82},  -- R
  {header = "Combat"},
  {label = "Fire",      key = string.byte("f")},
  {label = "Throw",     key = string.byte("t")},
  {label = "Kick",      key = 4},   -- ^D
  {label = "Zap",       key = string.byte("z")},
  {label = "Cast",      key = 90},  -- Z
  {header = "Use"},
  {label = "Eat",       key = string.byte("e")},
  {label = "Quaff",     key = string.byte("q")},
  {label = "Read",      key = string.byte("r")},
  {header = "Info"},
  {label = "Look",      key = string.byte(":")},
  {label = "Far-look",  key = string.byte(";")},
  {label = "What here", key = string.byte("/")},
  {header = "Other"},
  {label = "Open",      key = string.byte("o")},
  {label = "Close",     key = string.byte("c")},
  {label = "Pay",       key = string.byte("p")},
  {label = "Pray",      key = 16},  -- ^P
  {label = "Engrave",   key = 69},  -- E
  {label = "Enhance",   key = 5},   -- ^E
  {header = "Prompt"},
  {label = "Space",     key = string.byte(" ")},
  {label = "Enter",     key = 13},
  {label = "Escape",    key = 27},
  {label = "Yes",       key = string.byte("y")},
  {label = "No",        key = string.byte("n")},
}

-----------------------------------------------------
-- HP color by ratio
-----------------------------------------------------

local function get_hp_color(hp, hpmax)
  if hpmax <= 0 then return {r = 1, g = 1, b = 1} end
  local ratio = hp / hpmax
  if ratio > 0.75 then return {r = 1, g = 1, b = 1} end       -- white
  if ratio > 0.50 then return {r = 1, g = 1, b = 0} end       -- yellow
  if ratio > 0.25 then return {r = 1, g = 0.75, b = 0} end    -- orange
  if ratio > 0.10 then return {r = 1, g = 0.2, b = 0.2} end   -- red
  return {r = 1, g = 0.3, b = 1}                                -- magenta
end

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

  -- Top panel frame (vertical: content row + toolbar row)
  local top_frame = screen.add{
    type = "frame",
    name = "nh_top_frame",
    direction = "vertical",
    style = "nh_top_frame",
  }
  top_frame.location = {x = 0, y = 0}
  top_frame.style.width = ui_width - 150  -- leave room for action panel

  -- Content row (horizontal: messages | separator | status)
  local content_flow = top_frame.add{
    type = "flow",
    name = "nh_content_flow",
    direction = "horizontal",
  }

  -- Message scroll pane (left side, ~45% of panel width)
  local msg_width = math.max(300, math.floor((ui_width - 150) * 0.45))
  local msg_scroll = content_flow.add{
    type = "scroll-pane",
    name = "nh_msg_scroll",
    horizontal_scroll_policy = "never",
    vertical_scroll_policy = "auto-and-reserve-space",
    style = "nh_msg_scroll",
  }
  msg_scroll.style.width = msg_width

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

  -- Vertical separator
  content_flow.add{type = "line", direction = "vertical"}

  -- Status panel (right side)
  local status_flow = content_flow.add{
    type = "flow",
    name = "nh_status_flow",
    direction = "vertical",
    style = "nh_status_flow",
  }

  -- Player name (large bold)
  status_flow.add{
    type = "label",
    name = "nh_st_name",
    caption = "",
    style = "nh_status_name_label",
  }

  -- Dungeon level
  status_flow.add{
    type = "label",
    name = "nh_st_dlevel",
    caption = "",
    style = "nh_status_dlevel_label",
  }

  -- Separator
  status_flow.add{type = "line", direction = "horizontal"}

  -- Stats row: STR DEX CON INT WIS CHA
  local stats_flow = status_flow.add{
    type = "flow",
    name = "nh_st_stats",
    direction = "horizontal",
  }
  for _, stat in ipairs(STAT_LABELS) do
    stats_flow.add{
      type = "label",
      name = "nh_st_" .. stat.name,
      caption = "",
      style = "nh_status_label",
    }
  end

  -- Separator
  status_flow.add{type = "line", direction = "horizontal"}

  -- Vitals row: Au HP Pw AC Lvl Xp
  local vitals_flow = status_flow.add{
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
      style = style,
    }
  end

  -- Separator
  status_flow.add{type = "line", direction = "horizontal"}

  -- Misc row: Time Score
  local misc_flow = status_flow.add{
    type = "flow",
    name = "nh_st_misc",
    direction = "horizontal",
  }
  misc_flow.add{type = "label", name = "nh_st_time", caption = "", style = "nh_status_label"}
  misc_flow.add{type = "label", name = "nh_st_score", caption = "", style = "nh_status_label"}

  -- Conditions row: Align + Hunger + Encumbrance + dynamic conditions
  local cond_flow = status_flow.add{
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

  -- Horizontal separator before toolbar
  top_frame.add{type = "line", direction = "horizontal"}

  -- Toolbar row
  local toolbar = top_frame.add{
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

  -- Action panel (right side of screen)
  local action_frame = screen.add{
    type = "frame",
    name = "nh_action_panel",
    direction = "vertical",
    style = "nh_action_panel_frame",
  }
  action_frame.location = {x = ui_width - 140, y = 10}

  local action_scroll = action_frame.add{
    type = "scroll-pane",
    name = "nh_action_scroll",
    horizontal_scroll_policy = "never",
    vertical_scroll_policy = "auto-and-reserve-space",
    style = "nh_action_scroll",
  }

  for _, entry in ipairs(ACTION_BUTTONS) do
    if entry.header then
      action_scroll.add{
        type = "label",
        caption = entry.header,
        style = "nh_action_header",
      }
    else
      action_scroll.add{
        type = "button",
        name = "nh_action_" .. entry.key,
        caption = entry.label,
        style = "nh_action_button",
      }
    end
  end

  gui_data.player_frames[player.index] = true

  -- Render current status if available
  Gui.render_status(player)
end

function Gui.destroy_player_gui(player)
  local gui_data = storage.nh_gui
  local screen = player.gui.screen

  -- Destroy all our top-level screen elements
  local names = {
    "nh_top_frame", "nh_action_panel",
    "nh_menu_frame", "nh_yn_frame", "nh_getlin_frame",
    -- Old GUI element names (for upgrades)
    "nh_status_frame", "nh_msg_frame",
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
  local top = screen.nh_top_frame
  if not top then return end
  local content = top.nh_content_flow
  if not content then return end
  local scroll = content.nh_msg_scroll
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

-- Flying text at player position
function Gui.show_flying_text(player, text)
  if player.character then
    player.create_local_flying_text{
      text = text,
      position = player.character.position,
      time_to_live = 120,
      speed = 0.5,
    }
  end
end

-----------------------------------------------------
-- Status Bar Updates
-----------------------------------------------------

function Gui.update_status(idx, value_str, color)
  local gui_data = storage.nh_gui
  local old = gui_data.status_fields[idx]
  local old_val = old and old.value or ""

  gui_data.status_fields[idx] = {value = value_str, color = color}

  -- Track changes for stat highlighting (numeric fields only)
  if idx >= BL_STR and idx <= BL_HPMAX and idx ~= BL_ALIGN
     and idx ~= BL_CAP and idx ~= BL_HUNGER then
    if old_val ~= "" and value_str ~= "" and old_val ~= value_str then
      local old_num = tonumber(old_val)
      local new_num = tonumber(value_str)
      if old_num and new_num and old_num ~= new_num then
        local improved
        if LOW_IS_GOOD[idx] then
          improved = new_num < old_num
        else
          improved = new_num > old_num
        end
        gui_data.highlight_timers[idx] = {count = 3, good = improved}
      end
    end
  end
end

function Gui.flush_status()
  local gui_data = storage.nh_gui

  -- Render first (so highlights are visible this cycle)
  for _, player in pairs(game.connected_players) do
    Gui.render_status(player)
  end

  -- Then decrement highlight timers
  for idx, timer in pairs(gui_data.highlight_timers) do
    timer.count = timer.count - 1
    if timer.count <= 0 then
      gui_data.highlight_timers[idx] = nil
    end
  end
end

function Gui.render_status(player)
  local gui_data = storage.nh_gui
  local screen = player.gui.screen
  local top = screen.nh_top_frame
  if not top then return end
  local content = top.nh_content_flow
  if not content then return end
  local sf = content.nh_status_flow
  if not sf then return end

  local fields = gui_data.status_fields
  local timers = gui_data.highlight_timers

  local function get_val(idx)
    local f = fields[idx]
    return f and f.value or ""
  end

  local function get_style(idx)
    local timer = timers[idx]
    if timer then
      if timer.good == true then return "nh_status_label_good" end
      if timer.good == false then return "nh_status_label_bad" end
    end
    return "nh_status_label"
  end

  local function set_label(parent, name, text, style)
    local label = parent[name]
    if label then
      label.caption = text
      if style then label.style = style end
    end
  end

  -- Name and dungeon level
  set_label(sf, "nh_st_name", get_val(BL_TITLE), "nh_status_name_label")
  set_label(sf, "nh_st_dlevel", get_val(BL_DLEVEL), "nh_status_dlevel_label")

  -- Stats row: STR DEX CON INT WIS CHA
  local stats = sf.nh_st_stats
  if stats then
    for _, stat in ipairs(STAT_LABELS) do
      local v = get_val(stat.idx)
      local text = v ~= "" and (stat.prefix .. v) or ""
      set_label(stats, "nh_st_" .. stat.name, text, get_style(stat.idx))
    end
  end

  -- Vitals row
  local vitals = sf.nh_st_vitals
  if vitals then
    -- Gold
    local gold = get_val(BL_GOLD)
    set_label(vitals, "nh_st_gold", gold ~= "" and ("Au:" .. gold) or "", "nh_gold_label")

    -- HP with ratio-based color
    local hp_str = get_val(BL_HP)
    local hpmax_str = get_val(BL_HPMAX)
    local hp_text = ""
    if hp_str ~= "" then
      hp_text = "HP:" .. hp_str
      if hpmax_str ~= "" then
        hp_text = hp_text .. "(" .. hpmax_str .. ")"
      end
    end
    local hp_label = vitals.nh_st_hp
    if hp_label then
      hp_label.caption = hp_text
      -- Apply HP ratio color (overrides highlight)
      local hp_num = tonumber(hp_str)
      local hpmax_num = tonumber(hpmax_str)
      if hp_num and hpmax_num then
        local color = get_hp_color(hp_num, hpmax_num)
        hp_label.style = "nh_status_label"
        hp_label.style.font_color = color
      end
    end

    -- Power
    local pw = get_val(BL_ENE)
    local pwmax = get_val(BL_ENEMAX)
    local pw_text = ""
    if pw ~= "" then
      pw_text = "Pw:" .. pw
      if pwmax ~= "" then pw_text = pw_text .. "(" .. pwmax .. ")" end
    end
    set_label(vitals, "nh_st_pw", pw_text, get_style(BL_ENE))

    -- AC
    local ac = get_val(BL_AC)
    set_label(vitals, "nh_st_ac", ac ~= "" and ("AC:" .. ac) or "", get_style(BL_AC))

    -- Level
    local hd = get_val(BL_HD)
    set_label(vitals, "nh_st_xlvl", hd ~= "" and ("Lvl:" .. hd) or "", get_style(BL_HD))

    -- XP
    local xp = get_val(BL_XP)
    set_label(vitals, "nh_st_xp", xp ~= "" and ("Xp:" .. xp) or "", get_style(BL_XP))
  end

  -- Misc row: Time Score
  local misc = sf.nh_st_misc
  if misc then
    local time_val = get_val(BL_TIME)
    set_label(misc, "nh_st_time", time_val ~= "" and ("T:" .. time_val) or "")
    local score_val = get_val(BL_SCORE)
    set_label(misc, "nh_st_score", score_val ~= "" and ("S:" .. score_val) or "")
  end

  -- Conditions row
  local cond = sf.nh_st_cond
  if cond then
    -- Alignment
    set_label(cond, "nh_st_align", get_val(BL_ALIGN))

    -- Hunger with color
    local hunger = get_val(BL_HUNGER)
    local hunger_label = cond.nh_st_hunger
    if hunger_label then
      hunger_label.caption = hunger
      if hunger == "Satiated" then
        hunger_label.style = "nh_status_label"
        hunger_label.style.font_color = {r = 0.2, g = 0.8, b = 0.2}
      elseif hunger == "Hungry" then
        hunger_label.style = "nh_status_label"
        hunger_label.style.font_color = {r = 1, g = 1, b = 0}
      elseif hunger ~= "" then
        -- Weak/Fainting/Fainted
        hunger_label.style = "nh_status_label_bad"
      else
        hunger_label.style = "nh_status_label"
      end
    end

    -- Encumbrance with color
    local cap = get_val(BL_CAP)
    local cap_label = cond.nh_st_cap
    if cap_label then
      cap_label.caption = cap
      if cap == "Burdened" then
        cap_label.style = "nh_status_label"
        cap_label.style.font_color = {r = 1, g = 1, b = 0}
      elseif cap ~= "" then
        cap_label.style = "nh_status_label_bad"
      else
        cap_label.style = "nh_status_label"
      end
    end

    -- Dynamic conditions (fly, lev, poly, deaf, blind, stun, conf, hallu, slime, petrify, strangl)
    local dyn = cond.nh_st_cond_dynamic
    if dyn then
      dyn.clear()
      for _, idx in ipairs(COND_FIELDS) do
        local v = get_val(idx)
        if v ~= "" then
          -- Dangerous conditions (slime, petrify, strangl) in red; others in orange
          local color = (idx >= 30) and {r = 1, g = 0.3, b = 0.3}
                                     or {r = 1, g = 0.8, b = 0.3}
          local lbl = dyn.add{
            type = "label",
            caption = v,
            style = "nh_status_label",
          }
          lbl.style.font_color = color
        end
      end
    end
  end
end

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

  if win.type == NHW_TEXT then
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
  frame.location = {x = 200, y = 100}

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
    }
  end

  frame.add{
    type = "button",
    name = "nh_close_text_" .. winid,
    caption = "OK",
  }
end

-----------------------------------------------------
-- Menu System
-----------------------------------------------------

function Gui.start_menu(winid)
  local gui_data = storage.nh_gui
  local win = gui_data.windows[winid]
  if win then
    win.items = {}
  end
end

function Gui.add_menu_item(winid, glyph, identifier, accelerator, group_accel, attr, text, preselected)
  local gui_data = storage.nh_gui
  local win = gui_data.windows[winid]
  if not win then return end

  win.items[#win.items + 1] = {
    glyph = glyph,
    identifier = identifier,
    accelerator = accelerator,
    group_accel = group_accel,
    attr = attr,
    text = text,
    preselected = (preselected ~= 0),
    selected = (preselected ~= 0),
  }
end

function Gui.end_menu(winid, prompt)
  local gui_data = storage.nh_gui
  local win = gui_data.windows[winid]
  if win then
    win.prompt = prompt or ""
  end
end

function Gui.show_menu(player, winid, how)
  local gui_data = storage.nh_gui
  local win = gui_data.windows[winid]
  if not win then return end

  gui_data.pending_menu = {
    winid = winid,
    how = how,
    player_index = player.index,
  }

  local screen = player.gui.screen
  if screen.nh_menu_frame then
    screen.nh_menu_frame.destroy()
  end

  local frame = screen.add{
    type = "frame",
    name = "nh_menu_frame",
    direction = "vertical",
    caption = win.prompt ~= "" and win.prompt or "Select",
    style = "nh_menu_frame",
  }
  frame.location = {x = 200, y = 50}

  local scroll = frame.add{
    type = "scroll-pane",
    name = "nh_menu_scroll",
    horizontal_scroll_policy = "never",
    vertical_scroll_policy = "auto-and-reserve-space",
    style = "nh_menu_scroll",
  }

  for i, item in ipairs(win.items) do
    if item.identifier == 0 then
      -- Header / non-selectable
      scroll.add{
        type = "label",
        name = "nh_menu_header_" .. i,
        caption = item.text or "",
        style = "nh_menu_header_label",
      }
    else
      local accel_char = ""
      if item.accelerator and item.accelerator > 0 then
        accel_char = string.char(item.accelerator)
      end

      if how == 0 then
        -- PICK_NONE - just display
        local flow = scroll.add{
          type = "flow",
          name = "nh_menu_flow_" .. i,
          direction = "horizontal",
        }
        if accel_char ~= "" then
          flow.add{
            type = "label",
            caption = accel_char,
            style = "nh_menu_accel_label",
          }
        end
        flow.add{
          type = "label",
          caption = item.text or "",
        }

      elseif how == 1 then
        -- PICK_ONE - clickable button with accelerator
        local caption = item.text or ""
        if accel_char ~= "" then
          caption = accel_char .. " - " .. caption
        end
        scroll.add{
          type = "button",
          name = "nh_menu_pick_" .. i,
          caption = caption,
          style = "nh_menu_item_button_style",
        }

      else
        -- PICK_ANY - checkbox + accelerator + text
        local flow = scroll.add{
          type = "flow",
          name = "nh_menu_flow_" .. i,
          direction = "horizontal",
        }
        flow.add{
          type = "checkbox",
          name = "nh_menu_check_" .. i,
          state = item.selected or false,
        }
        if accel_char ~= "" then
          flow.add{
            type = "label",
            caption = accel_char,
            style = "nh_menu_accel_label",
          }
        end
        flow.add{
          type = "label",
          caption = item.text or "",
        }
      end
    end
  end

  -- Button bar
  local button_flow = frame.add{
    type = "flow",
    name = "nh_menu_buttons",
    direction = "horizontal",
  }

  if how == 2 then
    -- PICK_ANY: All / None / Invert buttons
    button_flow.add{type = "button", name = "nh_menu_all", caption = "All"}
    button_flow.add{type = "button", name = "nh_menu_none", caption = "None"}
    button_flow.add{type = "button", name = "nh_menu_invert", caption = "Invert"}
  end

  if how ~= 0 then
    button_flow.add{type = "button", name = "nh_menu_confirm", caption = "OK"}
  end
  button_flow.add{
    type = "button",
    name = "nh_menu_cancel",
    caption = how == 0 and "OK" or "Cancel",
  }
end

-- Handle menu clicks
function Gui.handle_menu_click(player, element_name)
  local gui_data = storage.nh_gui
  local pending = gui_data.pending_menu
  if not pending then return nil end

  local win = gui_data.windows[pending.winid]
  if not win then return nil end

  -- Cancel
  if element_name == "nh_menu_cancel" then
    gui_data.pending_menu = nil
    if player.gui.screen.nh_menu_frame then
      player.gui.screen.nh_menu_frame.destroy()
    end
    return {cancelled = true, selections = {}}
  end

  -- Confirm (PICK_ANY)
  if element_name == "nh_menu_confirm" then
    local selections = {}
    for _, item in ipairs(win.items) do
      if item.selected and item.identifier ~= 0 then
        selections[#selections + 1] = {
          identifier = item.identifier,
          count = -1,
        }
      end
    end
    gui_data.pending_menu = nil
    if player.gui.screen.nh_menu_frame then
      player.gui.screen.nh_menu_frame.destroy()
    end
    return {cancelled = false, selections = selections}
  end

  -- PICK_ONE button click
  local pick_match = element_name:match("^nh_menu_pick_(%d+)$")
  if pick_match then
    local idx = tonumber(pick_match)
    local item = win.items[idx]
    if item then
      gui_data.pending_menu = nil
      if player.gui.screen.nh_menu_frame then
        player.gui.screen.nh_menu_frame.destroy()
      end
      return {cancelled = false, selections = {{identifier = item.identifier, count = -1}}}
    end
  end

  -- PICK_ANY checkbox toggle
  local check_match = element_name:match("^nh_menu_check_(%d+)$")
  if check_match then
    local idx = tonumber(check_match)
    local item = win.items[idx]
    if item then
      item.selected = not item.selected
    end
    return nil -- don't close menu yet
  end

  -- All / None / Invert
  if element_name == "nh_menu_all" or element_name == "nh_menu_none"
     or element_name == "nh_menu_invert" then
    Gui.handle_menu_action(player, element_name:match("nh_menu_(.+)"))
    return nil
  end

  return nil
end

-- Handle All/None/Invert for PICK_ANY menus
function Gui.handle_menu_action(player, action)
  local gui_data = storage.nh_gui
  local pending = gui_data.pending_menu
  if not pending then return end

  local win = gui_data.windows[pending.winid]
  if not win then return end

  local screen = player.gui.screen
  local menu_frame = screen.nh_menu_frame
  if not menu_frame then return end
  local scroll = menu_frame.nh_menu_scroll
  if not scroll then return end

  for i, item in ipairs(win.items) do
    if item.identifier ~= 0 then
      if action == "all" then
        item.selected = true
      elseif action == "none" then
        item.selected = false
      elseif action == "invert" then
        item.selected = not item.selected
      end

      -- Update checkbox in GUI
      local flow = scroll["nh_menu_flow_" .. i]
      if flow then
        local cb = flow["nh_menu_check_" .. i]
        if cb then
          cb.state = item.selected
        end
      end
    end
  end
end

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

  -- For simple prompts (short resp string), show inline in messages.
  -- The user responds via keyboard or action panel buttons.
  if resp and #resp > 0 and #resp <= 10 then
    -- Inline: add the question as a bold message
    Gui.add_message(query, 1)
    return
  end

  -- For complex prompts or empty resp, show popup dialog
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
  frame.location = {x = 300, y = 200}

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
  frame.location = {x = 300, y = 200}

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

  -- Built-in message window
  if winid == NHW_MESSAGE or winid == 1 then
    Gui.add_message(text, attr)
    for _, player in pairs(game.connected_players) do
      Gui.show_flying_text(player, text)
    end
    return
  end

  -- Other windows: accumulate text
  local win = gui_data.windows[winid]
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

-- Action panel button click -> key code
function Gui.handle_action_click(element_name)
  local key_str = element_name:match("^nh_action_(%d+)$")
  if key_str then
    return tonumber(key_str)
  end
  return nil
end

return Gui
