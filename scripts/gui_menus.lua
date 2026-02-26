-- gui_menus.lua: Menu system for NetHack GUI
-- Extracted from gui.lua. Handles start_menu through handle_menu_key.

local Menus = {}

-- Set by init() from gui.lua
local TOTAL_TILES = 0
local sorted_keys  -- function

function Menus.init(total_tiles, sorted_keys_fn)
  TOTAL_TILES = total_tiles
  sorted_keys = sorted_keys_fn
end

function Menus.start_menu(winid)
  local gui_data = storage.nh_gui
  local win = gui_data.windows[winid]
  if win then
    win.items = {}
  end
end

function Menus.add_menu_item(winid, glyph, identifier, accelerator, group_accel, attr, text, preselected)
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

function Menus.end_menu(winid, prompt)
  local gui_data = storage.nh_gui
  local win = gui_data.windows[winid]
  if win then
    win.prompt = prompt or ""
  end
end

function Menus.show_menu(player, winid, how)
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
    caption = (win.prompt ~= "" and win.prompt)
              or (storage.nh_bridge and storage.nh_bridge.inventory_prompt)
              or "Select",
    style = "nh_menu_frame",
  }
  frame.auto_center = true

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

      -- Sprite prefix for items with valid tile indices
      local sprite_prefix = ""
      if item.glyph and item.glyph < TOTAL_TILES then
        sprite_prefix = "[img=nh-sprite-" .. item.glyph .. "] "
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
          caption = sprite_prefix .. (item.text or ""),
        }

      elseif how == 1 then
        -- PICK_ONE - clickable button with accelerator
        local caption = item.text or ""
        if accel_char ~= "" then
          caption = accel_char .. " - " .. sprite_prefix .. caption
        else
          caption = sprite_prefix .. caption
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
          caption = sprite_prefix .. (item.text or ""),
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
function Menus.handle_menu_click(player, element_name)
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
    Menus.handle_menu_action(player, element_name:match("nh_menu_(.+)"))
    return nil
  end

  return nil
end

-- Handle All/None/Invert for PICK_ANY menus
function Menus.handle_menu_action(player, action)
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

-- Handle keyboard input for menus (accelerator keys)
function Menus.handle_menu_key(player, key_code)
  local gui_data = storage.nh_gui
  local pending = gui_data.pending_menu
  if not pending then return nil end

  local win = gui_data.windows[pending.winid]
  if not win then return nil end

  -- PICK_ONE: accelerator key selects the item immediately
  if pending.how == 1 then
    for _, item in ipairs(win.items) do
      if item.accelerator == key_code and item.identifier ~= 0 then
        gui_data.pending_menu = nil
        if player and player.gui.screen.nh_menu_frame then
          player.gui.screen.nh_menu_frame.destroy()
        end
        return {cancelled = false, selections = {{identifier = item.identifier, count = -1}}}
      end
    end
  end

  -- PICK_ANY: accelerator key toggles the item's checkbox
  if pending.how == 2 then
    for i, item in ipairs(win.items) do
      if item.accelerator == key_code and item.identifier ~= 0 then
        item.selected = not item.selected
        -- Update checkbox in GUI
        if player and player.gui.screen.nh_menu_frame then
          local scroll = player.gui.screen.nh_menu_frame.nh_menu_scroll
          if scroll then
            local flow = scroll["nh_menu_flow_" .. i]
            if flow then
              local cb = flow["nh_menu_check_" .. i]
              if cb then cb.state = item.selected end
            end
          end
        end
        return nil -- don't close menu yet
      end
    end
  end

  return nil
end

return Menus
