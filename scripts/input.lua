-- input.lua: Maps Factorio player movement and custom inputs to NetHack key codes
local Input = {}

-- Direction deltas -> NetHack vi-keys
-- NetHack coordinate system: y increases downward (same as Factorio)
local DIR_TO_KEY = {
  -- {dx, dy} -> ASCII key code
  ["-1,-1"] = string.byte("y"),  -- northwest
  ["0,-1"]  = string.byte("k"),  -- north (up)
  ["1,-1"]  = string.byte("u"),  -- northeast
  ["-1,0"]  = string.byte("h"),  -- west (left)
  ["1,0"]   = string.byte("l"),  -- east (right)
  ["-1,1"]  = string.byte("b"),  -- southwest
  ["0,1"]   = string.byte("j"),  -- south (down)
  ["1,1"]   = string.byte("n"),  -- southeast
}

-- Custom input name -> NetHack key code
local INPUT_TO_KEY = {
  ["nh-inventory"]     = string.byte("i"),
  ["nh-pickup"]        = string.byte(","),
  ["nh-wait"]          = string.byte("."),
  ["nh-search"]        = string.byte("s"),
  ["nh-go-up"]         = string.byte("<"),
  ["nh-go-down"]       = string.byte(">"),
  ["nh-eat"]           = string.byte("e"),
  ["nh-drop"]          = string.byte("d"),
  ["nh-open"]          = string.byte("o"),
  ["nh-close"]         = string.byte("c"),
  ["nh-look-here"]     = string.byte(":"),
  ["nh-far-look"]      = string.byte(";"),
  ["nh-whatis"]        = string.byte("/"),
  ["nh-wield"]         = string.byte("w"),
  ["nh-wear"]          = string.byte("W"),
  ["nh-takeoff"]       = string.byte("T"),
  ["nh-puton"]         = string.byte("P"),
  ["nh-remove"]        = string.byte("R"),
  ["nh-quaff"]         = string.byte("q"),
  ["nh-read"]          = string.byte("r"),
  ["nh-zap"]           = string.byte("z"),
  ["nh-cast"]          = string.byte("Z"),
  ["nh-fire"]          = string.byte("f"),
  ["nh-throw"]         = string.byte("t"),
  ["nh-apply"]         = string.byte("a"),
  ["nh-pay"]           = string.byte("p"),
  ["nh-kick"]          = 0x04, -- ctrl-D
  ["nh-pray"]          = 0x10, -- ctrl-P (pray, but actually #pray)
  ["nh-engrave"]       = string.byte("E"),
  ["nh-enhance"]       = 0x05, -- ctrl-E (or #enhance)
  ["nh-force"]         = 0x06, -- ctrl-F (or #force)
  ["nh-confirm-yes"]   = string.byte("y"),
  ["nh-confirm-no"]    = string.byte("n"),
  ["nh-escape"]        = 27, -- ESC
  ["nh-space"]         = string.byte(" "),
  ["nh-confirm"]       = 13, -- CR (RETURN key)
  -- Number keys
  ["nh-key-0"]         = string.byte("0"),
  ["nh-key-1"]         = string.byte("1"),
  ["nh-key-2"]         = string.byte("2"),
  ["nh-key-3"]         = string.byte("3"),
  ["nh-key-4"]         = string.byte("4"),
  ["nh-key-5"]         = string.byte("5"),
  ["nh-key-6"]         = string.byte("6"),
  ["nh-key-7"]         = string.byte("7"),
  ["nh-key-8"]         = string.byte("8"),
  ["nh-key-9"]         = string.byte("9"),
}

-- Menu letter keys (a-z) -> ASCII codes
for i = 0, 25 do
  local ch = string.char(string.byte("a") + i)
  INPUT_TO_KEY["nh-menu-" .. ch] = string.byte(ch)
end

-- Convert movement delta to NetHack direction key
function Input.direction_to_key(dx, dy)
  -- Clamp to -1, 0, 1
  if dx > 0 then dx = 1 elseif dx < 0 then dx = -1 end
  if dy > 0 then dy = 1 elseif dy < 0 then dy = -1 end

  local key_str = dx .. "," .. dy
  return DIR_TO_KEY[key_str]
end

-- Convert custom input event name to NetHack key
function Input.custom_input_to_key(input_name)
  return INPUT_TO_KEY[input_name]
end

-- Get list of all custom input names (for event registration)
function Input.get_custom_input_names()
  local names = {}
  for name, _ in pairs(INPUT_TO_KEY) do
    names[#names + 1] = name
  end
  return names
end

function Input.init()
  if not storage.nh_input then
    storage.nh_input = {
      processing = false,  -- flag to prevent re-entrant movement handling
    }
  end
end
function Input.is_processing()
  return storage.nh_input.processing
end

function Input.set_processing(val)
  storage.nh_input.processing = val
end

return Input
