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
-- All letter commands use ALT+ to avoid conflicts with Factorio's WASD movement
-- and other default keybinds (E=inventory, F=pickup, Q=crafting, R=rotate, etc.)
inp("nh-inventory",   "ALT + I")
inp("nh-eat",         "ALT + E")
inp("nh-drop",        "ALT + D")
inp("nh-wield",       "ALT + W")
inp("nh-wear",        "ALT + SHIFT + W")
inp("nh-takeoff",     "ALT + SHIFT + T")
inp("nh-puton",       "ALT + SHIFT + P")
inp("nh-remove",      "ALT + SHIFT + R")

-- Item interaction
inp("nh-pickup",      "ALT + COMMA")
inp("nh-wait",        "ALT + PERIOD")
inp("nh-search",      "ALT + S")
inp("nh-open",        "ALT + O")
inp("nh-close",       "ALT + C")

-- Stairs
inp("nh-go-up",       "SHIFT + COMMA")    -- <
inp("nh-go-down",     "SHIFT + PERIOD")   -- >

-- Magic / ranged
inp("nh-zap",         "ALT + Z")
inp("nh-cast",        "ALT + SHIFT + Z")
inp("nh-fire",        "ALT + F")
inp("nh-throw",       "ALT + T")
inp("nh-apply",       "ALT + A")

-- Information
inp("nh-look-here",   "SHIFT + ;")        -- :
inp("nh-far-look",    "ALT + SEMICOLON")        -- ;
inp("nh-whatis",      "ALT + SLASH")            -- /

-- Consumables
inp("nh-quaff",       "ALT + Q")
inp("nh-read",        "ALT + R")

-- Special actions
inp("nh-pay",        "ALT + P")
inp("nh-kick",       "CONTROL + D")
inp("nh-pray",       "SHIFT + 3")          -- # (extended command prefix)
inp("nh-engrave",    "ALT + SHIFT + E")
inp("nh-enhance",    "CONTROL + E")
inp("nh-force",      "CONTROL + F")
inp("nh-confirm-yes","ALT + Y", "none")
inp("nh-confirm-no", "ALT + N", "none")

-- Menu / prompt responses
inp("nh-confirm",     "RETURN",  "game-only")
inp("nh-space",       "SPACE",   "game-only")
inp("nh-escape",      "ESCAPE",  "none")

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
  inp("nh-menu-" .. ch, "ALT + " .. string.upper(ch), "none")
end

-- Click-to-travel: left click on distant tile triggers NetHack travel command
inp("nh-click-move",  "mouse-button-1", "none")

-- Display mode cycle (tiles/factorio -> tiles/nethack -> ascii/factorio -> ascii/nethack)
inp("nh-cycle-display", "ALT + 0", "none")

data:extend(inputs)
