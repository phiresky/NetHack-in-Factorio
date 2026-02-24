-- NetHack custom input bindings for Factorio 2.0
-- Key sequences use Factorio's naming: letters are uppercase, special keys are named.
-- "consuming = game-only" prevents the key from also triggering built-in Factorio actions.

local inputs = {}

-- Helper to define a custom input
local function inp(name, key, consuming)
  inputs[#inputs + 1] = {
    type = "custom-input",
    name = name,
    key_sequence = key,
    consuming = consuming or "game-only",
  }
end

-- Inventory / equipment management
inp("nh-inventory",   "I")
inp("nh-eat",         "E")
inp("nh-drop",        "D")
inp("nh-wield",       "W")
inp("nh-wear",        "SHIFT + W")
inp("nh-takeoff",     "SHIFT + T")
inp("nh-puton",       "SHIFT + P")
inp("nh-remove",      "SHIFT + R")

-- Item interaction
inp("nh-pickup",      "COMMA")
inp("nh-wait",        "PERIOD")
inp("nh-search",      "S")
inp("nh-open",        "O")
inp("nh-close",       "C")

-- Stairs
inp("nh-go-up",       "SHIFT + COMMA")    -- <
inp("nh-go-down",     "SHIFT + PERIOD")   -- >

-- Magic / ranged
inp("nh-zap",         "Z")
inp("nh-cast",        "SHIFT + Z")
inp("nh-fire",        "F")
inp("nh-throw",       "T")
inp("nh-apply",       "A")

-- Information
inp("nh-look-here",   "SHIFT + ;")        -- :
inp("nh-far-look",    "SEMICOLON")        -- ;
inp("nh-whatis",      "SLASH")            -- /

-- Consumables
inp("nh-quaff",       "Q")
inp("nh-read",        "R")

-- Special actions
inp("nh-pay",        "P")
inp("nh-kick",       "CONTROL + D")
inp("nh-pray",       "SHIFT + 3")          -- # (extended command prefix)
inp("nh-engrave",    "SHIFT + E")
inp("nh-enhance",    "CONTROL + E")
inp("nh-force",      "CONTROL + F")
inp("nh-confirm-yes","Y", "none")
inp("nh-confirm-no", "N", "none")

-- Menu / prompt responses
inp("nh-confirm",     "RETURN",  "game-only")
inp("nh-space",       "SPACE",   "game-only")
inp("nh-escape",      "ESCAPE",  "game-only")

-- Number keys for menu selection
inp("nh-key-1",       "1",  "game-only")
inp("nh-key-2",       "2",  "game-only")
inp("nh-key-3",       "3",  "game-only")
inp("nh-key-4",       "4",  "game-only")
inp("nh-key-5",       "5",  "game-only")
inp("nh-key-6",       "6",  "game-only")
inp("nh-key-7",       "7",  "game-only")
inp("nh-key-8",       "8",  "game-only")
inp("nh-key-9",       "9",  "game-only")
inp("nh-key-0",       "0",  "game-only")

-- Letter keys for menu selection (a-z)
for i = 0, 25 do
  local ch = string.char(string.byte("a") + i)
  inp("nh-menu-" .. ch, string.upper(ch), "none")
end

data:extend(inputs)
