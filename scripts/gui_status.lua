-- gui_status.lua: Status bar rendering for NetHack GUI
-- Extracted from gui.lua. Handles update_status, flush_status, render_status.

local bit32 = bit32

local Status = {}
local GuiEquip = require("scripts.gui_equip")

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

-- Stat label definitions: {name, prefix, field_idx, icon}
-- Exported for use by create_player_gui in gui.lua
Status.STAT_LABELS = {
  {name = "str", prefix = "Str:", idx = BL_STR, icon = "nh-icon-str"},
  {name = "dx",  prefix = "Dex:", idx = BL_DX,  icon = "nh-icon-dex"},
  {name = "co",  prefix = "Con:", idx = BL_CO,   icon = "nh-icon-con"},
  {name = "in",  prefix = "Int:", idx = BL_IN,   icon = "nh-icon-int"},
  {name = "wi",  prefix = "Wis:", idx = BL_WI,   icon = "nh-icon-wis"},
  {name = "ch",  prefix = "Cha:", idx = BL_CH,   icon = "nh-icon-cha"},
}

-- Vital label definitions
Status.VITAL_LABELS = {
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

local STAT_LABELS = Status.STAT_LABELS
local VITAL_LABELS = Status.VITAL_LABELS

local function get_hp_color(hp, hpmax)
  if hpmax <= 0 then return {r = 1, g = 1, b = 1} end
  local ratio = hp / hpmax
  if ratio > 0.75 then return {r = 1, g = 1, b = 1} end       -- white
  if ratio > 0.50 then return {r = 1, g = 1, b = 0} end       -- yellow
  if ratio > 0.25 then return {r = 1, g = 0.75, b = 0} end    -- orange
  if ratio > 0.10 then return {r = 1, g = 0.2, b = 0.2} end   -- red
  return {r = 1, g = 0.3, b = 1}                                -- magenta
end

function Status.update_status(idx, value_str, color)
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

function Status.flush_status()
  local gui_data = storage.nh_gui

  -- Render first (so highlights are visible this cycle)
  for _, player in pairs(game.connected_players) do
    Status.render_status(player)
  end

  -- Then decrement highlight timers
  for idx, timer in pairs(gui_data.highlight_timers) do
    timer.count = timer.count - 1
    if timer.count <= 0 then
      gui_data.highlight_timers[idx] = nil
    end
  end
end

function Status.render_status(player)
  local gui_data = storage.nh_gui
  local screen = player.gui.screen
  local top_panel = screen.nh_top_panel
  if not top_panel then return end
  local content = top_panel.nh_top_content
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

  -- All stat elements are inside nh_st_left
  local left_col = sf.nh_st_left
  if not left_col then return end

  -- Name and dungeon level
  set_label(left_col, "nh_st_name", get_val(BL_TITLE), "nh_status_name_label")
  set_label(left_col, "nh_st_dlevel", get_val(BL_DLEVEL), "nh_status_dlevel_label")

  -- Stats row: STR DEX CON INT WIS CHA
  local stats = left_col.nh_st_stats
  if stats then
    for _, stat in ipairs(STAT_LABELS) do
      local v = get_val(stat.idx)
      local text = ""
      if v ~= "" then
        text = "[img=" .. stat.icon .. "] " .. stat.prefix .. v
      end
      set_label(stats, "nh_st_" .. stat.name, text, get_style(stat.idx))
    end
  end

  -- Vitals row
  local vitals = left_col.nh_st_vitals
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
  local misc = left_col.nh_st_misc
  if misc then
    local time_val = get_val(BL_TIME)
    set_label(misc, "nh_st_time", time_val ~= "" and ("T:" .. time_val) or "")
    local score_val = get_val(BL_SCORE)
    set_label(misc, "nh_st_score", score_val ~= "" and ("S:" .. score_val) or "")
  end

  -- Conditions row
  local cond = left_col.nh_st_cond
  if cond then
    -- Alignment with icon
    local align_val = get_val(BL_ALIGN)
    local align_text = align_val
    if align_val == "Lawful" then
      align_text = "[img=nh-icon-lawful] Lawful"
    elseif align_val == "Neutral" then
      align_text = "[img=nh-icon-neutral] Neutral"
    elseif align_val == "Chaotic" then
      align_text = "[img=nh-icon-chaotic] Chaotic"
    end
    set_label(cond, "nh_st_align", align_text)

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

  -- Equipment display (below conditions)
  GuiEquip.render_equipment(player)
end

return Status
