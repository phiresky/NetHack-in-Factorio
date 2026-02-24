-- gui.lua: NetHack GUI elements (status bar, messages, menus, prompts)
local Gui = {}

-- Window type constants (from NetHack)
local NHW_MESSAGE = 1
local NHW_STATUS  = 2
local NHW_MAP     = 3
local NHW_MENU    = 4
local NHW_TEXT    = 5

-- Maximum message history
local MAX_MESSAGES = 50

-- Action buttons: groups of NetHack commands shown as clickable buttons
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
  {label = "What here",  key = string.byte("/")},
  {header = "Other"},
  {label = "Open",      key = string.byte("o")},
  {label = "Close",     key = string.byte("c")},
  {label = "Pay",       key = string.byte("p")},
  {label = "Pray",      key = 16},  -- ^P (mapped to #pray)
  {label = "Engrave",   key = 69},  -- E
  {label = "Enhance",   key = 5},   -- ^E
  {header = "Prompt"},
  {label = "Space",     key = string.byte(" ")},
  {label = "Enter",     key = 13},
  {label = "Escape",    key = 27},
  {label = "Yes",       key = string.byte("y")},
  {label = "No",        key = string.byte("n")},
}

function Gui.init()
  if not storage.nh_gui then
    storage.nh_gui = {
      messages = {},         -- message history (newest first)
      status_fields = {},    -- idx -> {value, color}
      windows = {},          -- winid -> {type, items, prompt, ...}
      next_winid = 10,       -- window ID counter (skip built-in IDs)
      pending_menu = nil,    -- menu awaiting selection
      pending_yn = nil,      -- yn_function awaiting response
      pending_getlin = nil,  -- getlin awaiting response
      player_frames = {},    -- player_index -> frame references
    }
  end
end

-- Status field names (from NetHack botl.h BL_ indices)
local STATUS_NAMES = {
  [0]  = "title",
  [1]  = "str",
  [2]  = "dx",
  [3]  = "co",
  [4]  = "in",
  [5]  = "wi",
  [6]  = "ch",
  [7]  = "align",
  [8]  = "score",
  [9]  = "cap",
  [10] = "gold",
  [11] = "ene",
  [12] = "enemax",
  [13] = "xp",
  [14] = "ac",
  [15] = "hd",      -- HD or Xlvl
  [16] = "time",
  [17] = "hunger",
  [18] = "hp",
  [19] = "hpmax",
  [20] = "dlevel",
  [21] = "vers",
  [22] = "fly",
  [23] = "lev",
  [24] = "poly",
  [25] = "deaf",
  [26] = "blind",
  [27] = "stun",
  [28] = "conf",
  [29] = "hallu",
  [30] = "slime",
  [31] = "petrify",
  [32] = "strangl",
  [33] = "condition",  -- BL_CONDITION bitmask
  [34] = "flush",      -- BL_FLUSH
  [35] = "reset",      -- BL_RESET
}

-----------------------------------------------------
-- GUI Creation / Destruction for a player
-----------------------------------------------------

function Gui.create_player_gui(player)
  local gui_data = storage.nh_gui

  -- Destroy existing if present
  Gui.destroy_player_gui(player)

  local screen = player.gui.screen

  -- Status bar at bottom
  local status_frame = screen.add{
    type = "frame",
    name = "nh_status_frame",
    direction = "vertical",
    style = "nh_status_frame",
  }
  status_frame.location = {x = 0, y = player.display_resolution.height - 120}

  local status_line1 = status_frame.add{
    type = "flow",
    name = "nh_status_line1",
    direction = "horizontal",
  }

  local status_line2 = status_frame.add{
    type = "flow",
    name = "nh_status_line2",
    direction = "horizontal",
  }

  -- Line 1: Title, Str, Dx, Co, In, Wi, Ch, Align
  for _, field in ipairs({"title", "str", "dx", "co", "in", "wi", "ch", "align"}) do
    status_line1.add{
      type = "label",
      name = "nh_st_" .. field,
      caption = "",
      style = "nh_status_label",
    }
  end

  -- Line 2: Dlevel, Gold, HP, HPmax, AC, Xp, Hunger + conditions
  for _, field in ipairs({"dlevel", "gold", "hp", "hpmax", "ac", "xp", "hunger", "conditions"}) do
    status_line2.add{
      type = "label",
      name = "nh_st_" .. field,
      caption = "",
      style = "nh_status_label",
    }
  end

  -- Message area at top
  local msg_frame = screen.add{
    type = "frame",
    name = "nh_msg_frame",
    direction = "vertical",
    style = "nh_message_frame",
  }
  msg_frame.location = {x = 0, y = 0}

  local msg_label = msg_frame.add{
    type = "label",
    name = "nh_msg_current",
    caption = "",
    style = "nh_message_label",
  }

  -- Action button panel on the right side
  local action_frame = screen.add{
    type = "frame",
    name = "nh_action_panel",
    direction = "vertical",
    style = "nh_action_panel_frame",
  }
  action_frame.location = {x = player.display_resolution.width - 140, y = 10}

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

  gui_data.player_frames[player.index] = {
    status_frame = status_frame,
    msg_frame = msg_frame,
    action_frame = action_frame,
  }
end

function Gui.destroy_player_gui(player)
  local gui_data = storage.nh_gui
  local screen = player.gui.screen

  if screen.nh_status_frame then
    screen.nh_status_frame.destroy()
  end
  if screen.nh_msg_frame then
    screen.nh_msg_frame.destroy()
  end
  if screen.nh_menu_frame then
    screen.nh_menu_frame.destroy()
  end
  if screen.nh_yn_frame then
    screen.nh_yn_frame.destroy()
  end
  if screen.nh_getlin_frame then
    screen.nh_getlin_frame.destroy()
  end
  if screen.nh_action_panel then
    screen.nh_action_panel.destroy()
  end

  gui_data.player_frames[player.index] = nil
end

-----------------------------------------------------
-- Message Display
-----------------------------------------------------

function Gui.add_message(text, attr)
  local gui_data = storage.nh_gui
  table.insert(gui_data.messages, 1, {text = text, attr = attr or 0, tick = game.tick})

  -- Trim history
  while #gui_data.messages > MAX_MESSAGES do
    table.remove(gui_data.messages)
  end

  -- Update display for all players
  for _, player in pairs(game.connected_players) do
    Gui.update_message_display(player)
  end
end

function Gui.update_message_display(player)
  local gui_data = storage.nh_gui
  local screen = player.gui.screen
  local msg_frame = screen.nh_msg_frame
  if not msg_frame then return end

  local msg_label = msg_frame.nh_msg_current
  if not msg_label then return end

  -- Show most recent message
  if #gui_data.messages > 0 then
    msg_label.caption = gui_data.messages[1].text
  else
    msg_label.caption = ""
  end
end

-- Also show as flying text at player position
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
  gui_data.status_fields[idx] = {value = value_str, color = color}
end

function Gui.flush_status()
  local gui_data = storage.nh_gui

  for _, player in pairs(game.connected_players) do
    Gui.render_status(player)
  end
end

function Gui.render_status(player)
  local gui_data = storage.nh_gui
  local screen = player.gui.screen
  local status_frame = screen.nh_status_frame
  if not status_frame then return end

  local line1 = status_frame.nh_status_line1
  local line2 = status_frame.nh_status_line2
  if not line1 or not line2 then return end

  local fields = gui_data.status_fields

  -- Line 1 fields
  local function get_field(idx)
    local f = fields[idx]
    return f and f.value or ""
  end

  local function set_label(parent, name, text)
    local label = parent[name]
    if label then
      label.caption = text
    end
  end

  -- Line 1: Title Str:xx Dx:xx Co:xx In:xx Wi:xx Ch:xx Align
  set_label(line1, "nh_st_title", get_field(0))
  set_label(line1, "nh_st_str", get_field(1) ~= "" and ("St:" .. get_field(1)) or "")
  set_label(line1, "nh_st_dx", get_field(2) ~= "" and ("Dx:" .. get_field(2)) or "")
  set_label(line1, "nh_st_co", get_field(3) ~= "" and ("Co:" .. get_field(3)) or "")
  set_label(line1, "nh_st_in", get_field(4) ~= "" and ("In:" .. get_field(4)) or "")
  set_label(line1, "nh_st_wi", get_field(5) ~= "" and ("Wi:" .. get_field(5)) or "")
  set_label(line1, "nh_st_ch", get_field(6) ~= "" and ("Ch:" .. get_field(6)) or "")
  set_label(line1, "nh_st_align", get_field(7))

  -- Line 2: Dlevel $:gold HP:hp/max AC:ac Xp:xp Hunger Conditions
  set_label(line2, "nh_st_dlevel", get_field(20))
  set_label(line2, "nh_st_gold", get_field(10) ~= "" and ("$:" .. get_field(10)) or "")
  local hp = get_field(18)
  local hpmax = get_field(19)
  set_label(line2, "nh_st_hp", hp ~= "" and ("HP:" .. hp) or "")
  set_label(line2, "nh_st_hpmax", hpmax ~= "" and ("(" .. hpmax .. ")") or "")
  set_label(line2, "nh_st_ac", get_field(14) ~= "" and ("AC:" .. get_field(14)) or "")
  set_label(line2, "nh_st_xp", get_field(13) ~= "" and ("Xp:" .. get_field(13)) or "")
  set_label(line2, "nh_st_hunger", get_field(17))

  -- Conditions
  local conds = {}
  for _, idx in ipairs({22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32}) do
    local v = get_field(idx)
    if v ~= "" then
      conds[#conds + 1] = v
    end
  end
  set_label(line2, "nh_st_conditions", table.concat(conds, " "))
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

  -- Close any visible GUI for this window
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

  -- For text windows, show content to players
  if win.type == NHW_TEXT then
    for _, player in pairs(game.connected_players) do
      Gui.show_text_window(player, winid, win)
    end
  end
end

function Gui.show_text_window(player, winid, win)
  local screen = player.gui.screen
  local frame_name = "nh_win_" .. winid

  -- Destroy if exists
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

  -- Close button
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

-- Show menu GUI and return selection
-- how: 0 = PICK_NONE, 1 = PICK_ONE, 2 = PICK_ANY
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
  }
  frame.location = {x = 200, y = 50}

  local scroll = frame.add{
    type = "scroll-pane",
    name = "nh_menu_scroll",
    horizontal_scroll_policy = "never",
    vertical_scroll_policy = "auto-and-reserve-space",
  }
  scroll.style.maximal_height = 500
  scroll.style.minimal_width = 400

  for i, item in ipairs(win.items) do
    if item.identifier == 0 then
      -- Header / non-selectable
      scroll.add{
        type = "label",
        name = "nh_menu_header_" .. i,
        caption = item.text or "",
        style = "caption_label",
      }
    else
      local accel_str = ""
      if item.accelerator and item.accelerator > 0 then
        accel_str = string.char(item.accelerator) .. " - "
      end

      if how == 0 then
        -- PICK_NONE - just display
        scroll.add{
          type = "label",
          name = "nh_menu_item_" .. i,
          caption = accel_str .. (item.text or ""),
        }
      elseif how == 1 then
        -- PICK_ONE - buttons
        scroll.add{
          type = "button",
          name = "nh_menu_pick_" .. i,
          caption = accel_str .. (item.text or ""),
          style = "nh_menu_item_button_style",
        }
      else
        -- PICK_ANY - checkboxes
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
        flow.add{
          type = "label",
          caption = accel_str .. (item.text or ""),
        }
      end
    end
  end

  -- Confirm / Cancel buttons
  local button_flow = frame.add{
    type = "flow",
    name = "nh_menu_buttons",
    direction = "horizontal",
  }

  if how ~= 0 then
    button_flow.add{
      type = "button",
      name = "nh_menu_confirm",
      caption = "OK",
    }
  end
  button_flow.add{
    type = "button",
    name = "nh_menu_cancel",
    caption = how == 0 and "OK" or "Cancel",
  }
end

-- Handle menu selection (called from GUI click events)
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

  -- Confirm (for PICK_ANY)
  if element_name == "nh_menu_confirm" then
    local selections = {}
    for i, item in ipairs(win.items) do
      if item.selected and item.identifier ~= 0 then
        selections[#selections + 1] = {
          identifier = item.identifier,
          count = -1, -- all
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

  return nil
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

  -- Create a button for each valid response character
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
    -- Default: just y/n
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

  button_flow.add{
    type = "button",
    name = "nh_getlin_ok",
    caption = "OK",
  }
  button_flow.add{
    type = "button",
    name = "nh_getlin_cancel",
    caption = "Cancel",
  }
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
    -- Also show as flying text for the most important messages
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
-- Action Button Click Handler
-----------------------------------------------------

function Gui.handle_action_click(element_name)
  local key_str = element_name:match("^nh_action_(%d+)$")
  if key_str then
    return tonumber(key_str)
  end
  return nil
end

return Gui
