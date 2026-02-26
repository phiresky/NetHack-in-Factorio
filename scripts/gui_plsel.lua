-- gui_plsel.lua: Player selection dialog for NetHack GUI
-- Extracted from gui.lua. Handles show_plsel_dialog, handle_plsel_click,
-- handle_plsel_checkbox and all associated validation helpers.

local bit32 = bit32

local Plsel = {}

-- Set by init() from gui.lua
local sorted_keys  -- function

function Plsel.init(sorted_keys_fn)
  sorted_keys = sorted_keys_fn
end

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

-- Validate and auto-fix a button-style list (race or role).
-- Returns the updated allow mask for the selected entry.
local function plsel_validate_list(frame, data_table, sel_key, sel, prefix, elem_name, validate_fn)
  local container = plsel_find_in_frame(frame, elem_name)
  if not container then return end

  local indices = sorted_keys(data_table)
  local first_valid, current_valid = nil, false

  for _, idx in ipairs(indices) do
    local entry = data_table[idx]
    local btn = container[prefix .. idx]
    if btn then
      local valid = validate_fn(entry.allow)
      btn.enabled = valid
      if valid and not first_valid then first_valid = idx end
      if idx == sel[sel_key] and valid then current_valid = true end
      btn.style = (idx == sel[sel_key] and valid) and "nh_plsel_list_button_selected"
                                                    or "nh_plsel_list_button"
    end
  end

  if not current_valid and first_valid then
    sel[sel_key] = first_valid
    for _, idx in ipairs(indices) do
      local btn = container[prefix .. idx]
      if btn then
        btn.style = (idx == sel[sel_key]) and "nh_plsel_list_button_selected"
                                             or "nh_plsel_list_button"
      end
    end
  end
end

-- Validate and auto-fix a checkbox group (gender or alignment).
local function plsel_validate_checkboxes(frame, data_table, sel_key, sel, prefix, elem_name, validate_fn)
  local container = plsel_find_in_frame(frame, elem_name)
  if not container then return end

  local indices = sorted_keys(data_table)
  local first_valid, current_valid = nil, false

  for _, idx in ipairs(indices) do
    local entry = data_table[idx]
    local cb = container[prefix .. idx]
    if cb then
      local valid = validate_fn(entry.allow)
      cb.enabled = valid
      if valid and not first_valid then first_valid = idx end
      if idx == sel[sel_key] and valid then current_valid = true end
      cb.state = (idx == sel[sel_key])
    end
  end

  if not current_valid and first_valid then
    sel[sel_key] = first_valid
    for _, idx in ipairs(indices) do
      local cb = container[prefix .. idx]
      if cb then cb.state = (idx == sel[sel_key]) end
    end
  end
end

-- Helper to read the current allow mask for a selection.
local function get_allow(data_table, selected_idx)
  if selected_idx >= 0 and data_table[selected_idx] then
    return data_table[selected_idx].allow
  end
  return 0xFFFF
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

  local role_allow = get_allow(plsel.roles, sel.selected_role)
  local race_allow = get_allow(plsel.races, sel.selected_race)

  plsel_validate_list(frame, plsel.races, "selected_race", sel,
    "nh_plsel_race_", "nh_plsel_race_scroll",
    function(allow) return validrace(role_allow, allow) end)

  -- Re-read after potential auto-fix
  race_allow = get_allow(plsel.races, sel.selected_race)

  plsel_validate_list(frame, plsel.roles, "selected_role", sel,
    "nh_plsel_role_", "nh_plsel_role_scroll",
    function(allow) return validrace(allow, race_allow) end)

  -- Re-read after potential auto-fix
  role_allow = get_allow(plsel.roles, sel.selected_role)

  plsel_validate_checkboxes(frame, plsel.genders, "selected_gend", sel,
    "nh_plsel_gend_", "nh_plsel_gend_flow",
    function(allow) return validgend(role_allow, race_allow, allow) end)

  plsel_validate_checkboxes(frame, plsel.aligns, "selected_align", sel,
    "nh_plsel_align_", "nh_plsel_align_flow",
    function(allow) return validalign(role_allow, race_allow, allow) end)
end

function Plsel.show_plsel_dialog(player)
  local plsel = get_plsel_data()
  if not plsel then return end

  local sel = get_plsel_state()
  local screen = player.gui.screen

  if screen.nh_plsel_frame then
    screen.nh_plsel_frame.destroy()
  end

  local frame = screen.add{
    type = "frame",
    name = "nh_plsel_frame",
    direction = "vertical",
    caption = "NetHack - Choose Your Character",
    style = "nh_plsel_frame",
  }
  frame.auto_center = true

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
    text = player.name,
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
  for _, idx in ipairs(sorted_keys(plsel.races)) do
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

  for _, idx in ipairs(sorted_keys(plsel.roles)) do
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

  for _, idx in ipairs(sorted_keys(plsel.genders)) do
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

  for _, idx in ipairs(sorted_keys(plsel.aligns)) do
    local al = plsel.aligns[idx]
    align_flow.add{
      type = "checkbox",
      name = "nh_plsel_align_" .. idx,
      caption = al.name,
      state = false,
    }
  end

  -- Attribution (matches Qt port's nh_attribution)
  right_col.add{
    type = "label",
    caption = "NetHack 3.6.7",
    style = "nh_plsel_info_label",
  }
  right_col.add{
    type = "label",
    caption = "by the NetHack DevTeam",
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

function Plsel.handle_plsel_click(player, element_name)
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
    local all_roles = sorted_keys(plsel.roles)
    if #all_roles > 0 then
      sel.selected_role = all_roles[math.random(#all_roles)]
    end
    local role_allow = get_allow(plsel.roles, sel.selected_role)

    local valid_races = {}
    for _, idx in ipairs(sorted_keys(plsel.races)) do
      if validrace(role_allow, plsel.races[idx].allow) then
        valid_races[#valid_races + 1] = idx
      end
    end
    if #valid_races > 0 then
      sel.selected_race = valid_races[math.random(#valid_races)]
    end
    local race_allow = get_allow(plsel.races, sel.selected_race)

    local valid_gends = {}
    for _, idx in ipairs(sorted_keys(plsel.genders)) do
      if validgend(role_allow, race_allow, plsel.genders[idx].allow) then
        valid_gends[#valid_gends + 1] = idx
      end
    end
    if #valid_gends > 0 then
      sel.selected_gend = valid_gends[math.random(#valid_gends)]
    end

    local valid_aligns = {}
    for _, idx in ipairs(sorted_keys(plsel.aligns)) do
      if validalign(role_allow, race_allow, plsel.aligns[idx].allow) then
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
function Plsel.handle_plsel_checkbox(player, element_name, new_state)
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

return Plsel
