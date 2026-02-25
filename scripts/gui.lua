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

-- Estimated instructions for NetHack startup (first input prompt)
local ESTIMATED_STARTUP_INSTRUCTIONS = 1770000

-- Format a number with commas: 1234567 -> "1,234,567"
local function format_number(n)
  local s = tostring(math.floor(n))
  local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  if formatted:sub(1, 1) == "," then
    formatted = formatted:sub(2)
  end
  return formatted
end

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
-- BL_FLUSH=-1 and BL_RESET=-2 in C (botl.h); handled in bridge.lua as unsigned i32

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

-- BL_CONDITION (idx 22) is a single bitmask, decoded into individual conditions
local BL_CONDITION = 22
local CONDITION_BITS = {
  {mask = 0x00000001, name = "Stone",    dangerous = true},
  {mask = 0x00000002, name = "Slime",    dangerous = true},
  {mask = 0x00000004, name = "Strngl",   dangerous = true},
  {mask = 0x00000008, name = "FoodPois", dangerous = true},
  {mask = 0x00000010, name = "TermIll",  dangerous = true},
  {mask = 0x00000020, name = "Blind"},
  {mask = 0x00000040, name = "Deaf"},
  {mask = 0x00000080, name = "Stun"},
  {mask = 0x00000100, name = "Conf"},
  {mask = 0x00000200, name = "Hallu"},
  {mask = 0x00000400, name = "Lev"},
  {mask = 0x00000800, name = "Fly"},
  {mask = 0x00001000, name = "Ride"},
}

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
  local ui_height = player.display_resolution.height / player.display_scale

  -- Layout constants
  local ACTION_WIDTH = 150
  local STATUS_WIDTH = 320
  local GAP = 4
  -- Messages: ~40% of screen, capped to reasonable bounds
  local msg_frame_width = math.min(650, math.max(450, math.floor(ui_width * 0.40)))
  -- Panels positioned adjacently: [messages][status][action]
  local status_x = msg_frame_width + GAP
  local action_x = status_x + STATUS_WIDTH + GAP

  -------------------------------------------------
  -- Message frame (top-left)
  -------------------------------------------------
  local msg_frame = screen.add{
    type = "frame",
    name = "nh_msg_frame",
    direction = "vertical",
    style = "nh_top_frame",
  }
  msg_frame.location = {x = 0, y = 0}
  msg_frame.style.width = msg_frame_width

  local msg_scroll = msg_frame.add{
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

  -- Horizontal separator before toolbar
  msg_frame.add{type = "line", direction = "horizontal"}

  -- Toolbar row
  local toolbar = msg_frame.add{
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

  -------------------------------------------------
  -- Status frame (top-right, next to messages)
  -------------------------------------------------
  local status_frame = screen.add{
    type = "frame",
    name = "nh_status_frame",
    direction = "vertical",
    style = "nh_top_frame",
  }
  status_frame.location = {x = status_x, y = 0}
  status_frame.style.width = STATUS_WIDTH

  local status_flow = status_frame.add{
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

  -------------------------------------------------
  -- Action panel (right side of screen)
  -------------------------------------------------
  local action_frame = screen.add{
    type = "frame",
    name = "nh_action_panel",
    direction = "vertical",
    style = "nh_action_panel_frame",
  }
  action_frame.location = {x = action_x, y = 0}

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

  -------------------------------------------------
  -- Engine state widget (bottom-left corner)
  -------------------------------------------------
  local engine_frame = screen.add{
    type = "frame",
    name = "nh_engine_frame",
    direction = "horizontal",
    style = "nh_engine_frame",
  }
  engine_frame.location = {x = 10, y = ui_height - 36}

  engine_frame.add{
    type = "label",
    name = "nh_engine_state",
    caption = "Initializing",
    style = "nh_engine_state_label",
  }
  engine_frame.add{
    type = "label",
    name = "nh_engine_count",
    caption = "",
    style = "nh_engine_count_label",
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
    "nh_msg_frame", "nh_status_frame", "nh_action_panel",
    "nh_engine_frame",
    "nh_menu_frame", "nh_yn_frame", "nh_getlin_frame",
    "nh_loading_frame", "nh_plsel_frame",
    -- Old layout (migration cleanup)
    "nh_top_frame",
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
  local msg_frame = screen.nh_msg_frame
  if not msg_frame then return end
  local scroll = msg_frame.nh_msg_scroll
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
  local status_frame = screen.nh_status_frame
  if not status_frame then return end
  local sf = status_frame.nh_status_flow
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

    -- Dynamic conditions from BL_CONDITION bitmask
    local dyn = cond.nh_st_cond_dynamic
    if dyn then
      dyn.clear()
      local cond_str = get_val(BL_CONDITION)
      local cond_mask = tonumber(cond_str) or 0
      for _, cond_def in ipairs(CONDITION_BITS) do
        if bit32.band(cond_mask, cond_def.mask) ~= 0 then
          local clr = cond_def.dangerous and {r = 1, g = 0.3, b = 0.3}
                                          or {r = 1, g = 0.8, b = 0.3}
          local lbl = dyn.add{
            type = "label",
            caption = cond_def.name,
            style = "nh_status_label",
          }
          lbl.style.font_color = clr
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

-- Action panel button click -> key code
function Gui.handle_action_click(element_name)
  local key_str = element_name:match("^nh_action_(%d+)$")
  if key_str then
    return tonumber(key_str)
  end
  return nil
end

-----------------------------------------------------
-- Loading Progress Bar
-----------------------------------------------------

function Gui.create_loading_bar(player)
  local screen = player.gui.screen
  if screen.nh_loading_frame then return end

  local ui_width = player.display_resolution.width / player.display_scale
  local ui_height = player.display_resolution.height / player.display_scale

  local frame = screen.add{
    type = "frame",
    name = "nh_loading_frame",
    direction = "vertical",
    caption = "NetHack",
    style = "nh_loading_frame",
  }
  frame.location = {
    x = math.floor((ui_width - 350) / 2),
    y = math.floor((ui_height - 120) / 2),
  }

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
-- Engine State Display
-----------------------------------------------------

function Gui.update_engine_state(state_text, instructions, color)
  local count_text = format_number(instructions) .. " inst"

  for _, player in pairs(game.connected_players) do
    local screen = player.gui.screen
    local frame = screen.nh_engine_frame
    if frame then
      local state_label = frame.nh_engine_state
      if state_label then
        state_label.caption = state_text
        if color then
          state_label.style = "nh_engine_state_label"
          state_label.style.font_color = color
        end
      end
      local count_label = frame.nh_engine_count
      if count_label then
        count_label.caption = count_text
      end
    end
  end
end

-----------------------------------------------------
-- Player Selection Dialog
-----------------------------------------------------

-- NetHack role/race/gender/alignment bitmask fields
local ROLE_RACEMASK  = 0x0FF8
local ROLE_GENDMASK  = 0xF000
local ROLE_ALIGNMASK = 0x0007

local function validrace(role_allow, race_allow)
  return bit32.band(role_allow, race_allow, ROLE_RACEMASK) ~= 0
end

local function validgend(role_allow, race_allow, gend_allow)
  return bit32.band(role_allow, race_allow, gend_allow, ROLE_GENDMASK) ~= 0
end

local function validalign(role_allow, race_allow, align_allow)
  return bit32.band(role_allow, race_allow, align_allow, ROLE_ALIGNMASK) ~= 0
end

-- Get the plsel data from bridge storage
local function get_plsel_data()
  local bridge = storage.nh_bridge
  return bridge and bridge.plsel
end

-- Get current plsel UI state, initializing if needed
local function get_plsel_state()
  if not storage.nh_gui.plsel then
    storage.nh_gui.plsel = {
      selected_role = -1,
      selected_race = -1,
      selected_gend = -1,
      selected_align = -1,
    }
  end
  return storage.nh_gui.plsel
end

-- BFS search for a named GUI element within a frame tree
local function plsel_find_in_frame(frame, target_name)
  local queue = {frame}
  for depth = 1, 5 do
    local next_queue = {}
    for _, elem in ipairs(queue) do
      if elem.name == target_name then return elem end
      local ok, children = pcall(function() return elem.children end)
      if ok and children then
        for _, child in ipairs(children) do
          if child.name == target_name then return child end
          next_queue[#next_queue + 1] = child
        end
      end
    end
    queue = next_queue
    if #queue == 0 then break end
  end
  return nil
end

-- Update enabled/disabled states and auto-fix invalid selections.
-- Uses BFS to find nested scroll panes since Factorio GUI elements
-- are only accessible by name on their direct parent.
local function plsel_update_validity(player)
  local plsel = get_plsel_data()
  local sel = get_plsel_state()
  if not plsel then return end

  local screen = player.gui.screen
  local frame = screen.nh_plsel_frame
  if not frame then return end

  local role_allow = 0xFFFF
  if sel.selected_role >= 0 and plsel.roles[sel.selected_role] then
    role_allow = plsel.roles[sel.selected_role].allow
  end

  local race_allow = 0xFFFF
  if sel.selected_race >= 0 and plsel.races[sel.selected_race] then
    race_allow = plsel.races[sel.selected_race].allow
  end

  local race_scroll = plsel_find_in_frame(frame, "nh_plsel_race_scroll")
  if race_scroll then
    local first_valid_race = nil
    local current_race_valid = false
    local race_indices = {}
    for idx, _ in pairs(plsel.races) do race_indices[#race_indices + 1] = idx end
    table.sort(race_indices)

    for _, idx in ipairs(race_indices) do
      local race = plsel.races[idx]
      local btn = race_scroll["nh_plsel_race_" .. idx]
      if btn then
        local valid = validrace(role_allow, race.allow)
        btn.enabled = valid
        if valid and not first_valid_race then first_valid_race = idx end
        if idx == sel.selected_race and valid then current_race_valid = true end
        btn.style = (idx == sel.selected_race and valid) and "nh_plsel_list_button_selected"
                                                          or "nh_plsel_list_button"
      end
    end
    if not current_race_valid and first_valid_race then
      sel.selected_race = first_valid_race
      race_allow = plsel.races[first_valid_race].allow
      for _, idx in ipairs(race_indices) do
        local btn = race_scroll["nh_plsel_race_" .. idx]
        if btn then
          btn.style = (idx == sel.selected_race) and "nh_plsel_list_button_selected"
                                                   or "nh_plsel_list_button"
        end
      end
    end
  end

  -- Re-read race_allow after potential auto-fix
  if sel.selected_race >= 0 and plsel.races[sel.selected_race] then
    race_allow = plsel.races[sel.selected_race].allow
  end

  local role_scroll = plsel_find_in_frame(frame, "nh_plsel_role_scroll")
  if role_scroll then
    local first_valid_role = nil
    local current_role_valid = false
    local role_indices = {}
    for idx, _ in pairs(plsel.roles) do role_indices[#role_indices + 1] = idx end
    table.sort(role_indices)

    for _, idx in ipairs(role_indices) do
      local role = plsel.roles[idx]
      local btn = role_scroll["nh_plsel_role_" .. idx]
      if btn then
        local valid = validrace(role.allow, race_allow)
        btn.enabled = valid
        if valid and not first_valid_role then first_valid_role = idx end
        if idx == sel.selected_role and valid then current_role_valid = true end
        btn.style = (idx == sel.selected_role and valid) and "nh_plsel_list_button_selected"
                                                          or "nh_plsel_list_button"
      end
    end
    if not current_role_valid and first_valid_role then
      sel.selected_role = first_valid_role
      role_allow = plsel.roles[first_valid_role].allow
      for _, idx in ipairs(role_indices) do
        local btn = role_scroll["nh_plsel_role_" .. idx]
        if btn then
          btn.style = (idx == sel.selected_role) and "nh_plsel_list_button_selected"
                                                   or "nh_plsel_list_button"
        end
      end
    end
  end

  -- Re-read role_allow after potential auto-fix
  if sel.selected_role >= 0 and plsel.roles[sel.selected_role] then
    role_allow = plsel.roles[sel.selected_role].allow
  end

  local gend_flow = plsel_find_in_frame(frame, "nh_plsel_gend_flow")
  if gend_flow then
    local first_valid_gend = nil
    local current_gend_valid = false
    local gend_indices = {}
    for idx, _ in pairs(plsel.genders) do gend_indices[#gend_indices + 1] = idx end
    table.sort(gend_indices)

    for _, idx in ipairs(gend_indices) do
      local gend = plsel.genders[idx]
      local cb = gend_flow["nh_plsel_gend_" .. idx]
      if cb then
        local valid = validgend(role_allow, race_allow, gend.allow)
        cb.enabled = valid
        if valid and not first_valid_gend then first_valid_gend = idx end
        if idx == sel.selected_gend and valid then current_gend_valid = true end
        cb.state = (idx == sel.selected_gend)
      end
    end
    if not current_gend_valid and first_valid_gend then
      sel.selected_gend = first_valid_gend
      for _, idx in ipairs(gend_indices) do
        local cb = gend_flow["nh_plsel_gend_" .. idx]
        if cb then cb.state = (idx == sel.selected_gend) end
      end
    end
  end

  local align_flow = plsel_find_in_frame(frame, "nh_plsel_align_flow")
  if align_flow then
    local first_valid_align = nil
    local current_align_valid = false
    local align_indices = {}
    for idx, _ in pairs(plsel.aligns) do align_indices[#align_indices + 1] = idx end
    table.sort(align_indices)

    for _, idx in ipairs(align_indices) do
      local al = plsel.aligns[idx]
      local cb = align_flow["nh_plsel_align_" .. idx]
      if cb then
        local valid = validalign(role_allow, race_allow, al.allow)
        cb.enabled = valid
        if valid and not first_valid_align then first_valid_align = idx end
        if idx == sel.selected_align and valid then current_align_valid = true end
        cb.state = (idx == sel.selected_align)
      end
    end
    if not current_align_valid and first_valid_align then
      sel.selected_align = first_valid_align
      for _, idx in ipairs(align_indices) do
        local cb = align_flow["nh_plsel_align_" .. idx]
        if cb then cb.state = (idx == sel.selected_align) end
      end
    end
  end
end

function Gui.show_plsel_dialog(player)
  local plsel = get_plsel_data()
  if not plsel then return end

  local sel = get_plsel_state()
  local screen = player.gui.screen

  if screen.nh_plsel_frame then
    screen.nh_plsel_frame.destroy()
  end

  local ui_width = player.display_resolution.width / player.display_scale
  local ui_height = player.display_resolution.height / player.display_scale

  local frame = screen.add{
    type = "frame",
    name = "nh_plsel_frame",
    direction = "vertical",
    caption = "NetHack - Choose Your Character",
    style = "nh_plsel_frame",
  }
  frame.location = {
    x = math.floor((ui_width - 560) / 2),
    y = math.floor((ui_height - 420) / 2),
  }

  -- Name field
  local name_flow = frame.add{
    type = "flow",
    direction = "horizontal",
  }
  name_flow.add{
    type = "label",
    caption = "Name: ",
    style = "caption_label",
  }
  name_flow.add{
    type = "textfield",
    name = "nh_plsel_name",
    text = "Player",
    style = "nh_plsel_name_field",
  }

  -- Main columns: Race | Role | Gender+Align+buttons
  local columns = frame.add{
    type = "flow",
    name = "nh_plsel_columns",
    direction = "horizontal",
    style = "nh_plsel_columns_flow",
  }

  -- Race column
  local race_col = columns.add{
    type = "frame",
    caption = "Race",
    direction = "vertical",
    style = "nh_plsel_list_frame",
  }
  local race_scroll = race_col.add{
    type = "scroll-pane",
    name = "nh_plsel_race_scroll",
    horizontal_scroll_policy = "never",
    vertical_scroll_policy = "auto-and-reserve-space",
    style = "nh_plsel_list_scroll",
  }
  -- Sort race indices
  local race_indices = {}
  for idx, _ in pairs(plsel.races) do
    race_indices[#race_indices + 1] = idx
  end
  table.sort(race_indices)

  for _, idx in ipairs(race_indices) do
    local race = plsel.races[idx]
    race_scroll.add{
      type = "button",
      name = "nh_plsel_race_" .. idx,
      caption = race.name,
      style = "nh_plsel_list_button",
    }
  end

  -- Role column
  local role_col = columns.add{
    type = "frame",
    caption = "Role",
    direction = "vertical",
    style = "nh_plsel_list_frame",
  }
  local role_scroll = role_col.add{
    type = "scroll-pane",
    name = "nh_plsel_role_scroll",
    horizontal_scroll_policy = "never",
    vertical_scroll_policy = "auto-and-reserve-space",
    style = "nh_plsel_list_scroll",
  }

  local role_indices = {}
  for idx, _ in pairs(plsel.roles) do
    role_indices[#role_indices + 1] = idx
  end
  table.sort(role_indices)

  for _, idx in ipairs(role_indices) do
    local role = plsel.roles[idx]
    role_scroll.add{
      type = "button",
      name = "nh_plsel_role_" .. idx,
      caption = role.name,
      style = "nh_plsel_list_button",
    }
  end

  -- Right column: Gender + Alignment + info + buttons
  local right_col = columns.add{
    type = "flow",
    direction = "vertical",
  }

  -- Gender group
  local gend_group = right_col.add{
    type = "frame",
    caption = "Gender",
    direction = "vertical",
    style = "nh_plsel_group_frame",
  }
  local gend_flow = gend_group.add{
    type = "flow",
    name = "nh_plsel_gend_flow",
    direction = "vertical",
    style = "nh_plsel_radio_flow",
  }

  local gend_indices = {}
  for idx, _ in pairs(plsel.genders) do
    gend_indices[#gend_indices + 1] = idx
  end
  table.sort(gend_indices)

  for _, idx in ipairs(gend_indices) do
    local gend = plsel.genders[idx]
    gend_flow.add{
      type = "checkbox",
      name = "nh_plsel_gend_" .. idx,
      caption = gend.name,
      state = false,
    }
  end

  -- Alignment group
  local align_group = right_col.add{
    type = "frame",
    caption = "Alignment",
    direction = "vertical",
    style = "nh_plsel_group_frame",
  }
  local align_flow = align_group.add{
    type = "flow",
    name = "nh_plsel_align_flow",
    direction = "vertical",
    style = "nh_plsel_radio_flow",
  }

  local align_indices = {}
  for idx, _ in pairs(plsel.aligns) do
    align_indices[#align_indices + 1] = idx
  end
  table.sort(align_indices)

  for _, idx in ipairs(align_indices) do
    local al = plsel.aligns[idx]
    align_flow.add{
      type = "checkbox",
      name = "nh_plsel_align_" .. idx,
      caption = al.name,
      state = false,
    }
  end

  -- Info text
  right_col.add{
    type = "label",
    caption = "NetHack 3.6.7",
    style = "nh_plsel_info_label",
  }

  -- Buttons
  local btn_flow = right_col.add{
    type = "flow",
    direction = "vertical",
  }
  btn_flow.add{
    type = "button",
    name = "nh_plsel_random",
    caption = "Random",
    style = "nh_plsel_button",
  }
  btn_flow.add{
    type = "button",
    name = "nh_plsel_play",
    caption = "Play",
    style = "nh_plsel_play_button",
  }
  btn_flow.add{
    type = "button",
    name = "nh_plsel_quit",
    caption = "Quit",
    style = "nh_plsel_button",
  }

  -- Set initial valid state
  plsel_update_validity(player)
end

function Gui.handle_plsel_click(player, element_name)
  local plsel = get_plsel_data()
  local sel = get_plsel_state()
  if not plsel then return nil end

  -- Role button
  local role_match = element_name:match("^nh_plsel_role_(%d+)$")
  if role_match then
    sel.selected_role = tonumber(role_match)
    plsel_update_validity(player)
    return nil
  end

  -- Race button
  local race_match = element_name:match("^nh_plsel_race_(%d+)$")
  if race_match then
    sel.selected_race = tonumber(race_match)
    plsel_update_validity(player)
    return nil
  end

  -- Gender checkbox (mutual exclusion)
  local gend_match = element_name:match("^nh_plsel_gend_(%d+)$")
  if gend_match then
    sel.selected_gend = tonumber(gend_match)
    plsel_update_validity(player)
    return nil
  end

  -- Alignment checkbox (mutual exclusion)
  local align_match = element_name:match("^nh_plsel_align_(%d+)$")
  if align_match then
    sel.selected_align = tonumber(align_match)
    plsel_update_validity(player)
    return nil
  end

  -- Random button
  if element_name == "nh_plsel_random" then
    -- Pick random valid combo
    local valid_roles = {}
    for idx, _ in pairs(plsel.roles) do valid_roles[#valid_roles + 1] = idx end
    if #valid_roles > 0 then
      sel.selected_role = valid_roles[math.random(#valid_roles)]
    end

    local role_allow = 0xFFFF
    if sel.selected_role >= 0 and plsel.roles[sel.selected_role] then
      role_allow = plsel.roles[sel.selected_role].allow
    end

    local valid_races = {}
    for idx, race in pairs(plsel.races) do
      if validrace(role_allow, race.allow) then
        valid_races[#valid_races + 1] = idx
      end
    end
    if #valid_races > 0 then
      sel.selected_race = valid_races[math.random(#valid_races)]
    end

    local race_allow = 0xFFFF
    if sel.selected_race >= 0 and plsel.races[sel.selected_race] then
      race_allow = plsel.races[sel.selected_race].allow
    end

    local valid_gends = {}
    for idx, gend in pairs(plsel.genders) do
      if validgend(role_allow, race_allow, gend.allow) then
        valid_gends[#valid_gends + 1] = idx
      end
    end
    if #valid_gends > 0 then
      sel.selected_gend = valid_gends[math.random(#valid_gends)]
    end

    local valid_aligns = {}
    for idx, al in pairs(plsel.aligns) do
      if validalign(role_allow, race_allow, al.allow) then
        valid_aligns[#valid_aligns + 1] = idx
      end
    end
    if #valid_aligns > 0 then
      sel.selected_align = valid_aligns[math.random(#valid_aligns)]
    end

    plsel_update_validity(player)
    return nil
  end

  -- Play button
  if element_name == "nh_plsel_play" then
    -- Read the name from the textfield
    local screen = player.gui.screen
    local frame = screen.nh_plsel_frame
    local name = "Player"
    if frame then
      local name_field = plsel_find_in_frame(frame, "nh_plsel_name")
      if name_field then
        name = name_field.text or ""
        if name == "" then name = "Player" end
      end
      frame.destroy()
    end
    return {
      action = "play",
      name = name,
      role = sel.selected_role,
      race = sel.selected_race,
      gend = sel.selected_gend,
      align = sel.selected_align,
    }
  end

  -- Quit button
  if element_name == "nh_plsel_quit" then
    local screen = player.gui.screen
    if screen.nh_plsel_frame then
      screen.nh_plsel_frame.destroy()
    end
    return {action = "quit"}
  end

  return nil
end

-- Handle checkbox state change for plsel (mutual exclusion for radio-button behavior)
function Gui.handle_plsel_checkbox(player, element_name, new_state)
  local sel = get_plsel_state()
  local plsel = get_plsel_data()
  if not plsel then return end

  local gend_match = element_name:match("^nh_plsel_gend_(%d+)$")
  if gend_match then
    local idx = tonumber(gend_match)
    if new_state then
      sel.selected_gend = idx
    else
      -- Don't allow unchecking - re-check it
      sel.selected_gend = idx
    end
    plsel_update_validity(player)
    return
  end

  local align_match = element_name:match("^nh_plsel_align_(%d+)$")
  if align_match then
    local idx = tonumber(align_match)
    if new_state then
      sel.selected_align = idx
    else
      sel.selected_align = idx
    end
    plsel_update_validity(player)
    return
  end
end

return Gui
