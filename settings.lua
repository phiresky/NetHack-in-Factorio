-- NetHack options exposed as Factorio mod startup settings.
-- These are passed to NetHack via the NETHACKOPTIONS environment variable
-- at game start. Changing them requires creating a new map.

local order_counter = 0
local function next_order()
  order_counter = order_counter + 1
  return string.format("nethack-%03d", order_counter)
end

-- Helper to define a boolean NetHack option
local function bool_opt(nh_name, default, description)
  return {
    type = "bool-setting",
    name = "nethack-" .. nh_name:gsub("_", "-"),
    setting_type = "startup",
    default_value = default,
    order = next_order(),
    localised_name = {"", "NetHack: " .. nh_name},
    localised_description = {"", description},
  }
end

-- Helper to define a string NetHack option
local function string_opt(nh_name, default, description, allowed)
  local s = {
    type = "string-setting",
    name = "nethack-" .. nh_name:gsub("_", "-"),
    setting_type = "startup",
    default_value = default,
    order = next_order(),
    localised_name = {"", "NetHack: " .. nh_name},
    localised_description = {"", description},
    allow_blank = true,
  }
  if allowed then
    s.allowed_values = allowed
  end
  return s
end

data:extend{
  ---------------------------------------------------------------------------
  -- Boolean options
  ---------------------------------------------------------------------------
  bool_opt("acoustics",         true,  "Hear distant sounds (strumming, digging, etc.)"),
  bool_opt("autodig",           false, "Automatically dig when moving with a pick-axe or mattock"),
  bool_opt("autoopen",          true,  "Automatically open doors when walking into them"),
  bool_opt("autopickup",        true,  "Automatically pick up items you walk over"),
  bool_opt("autoquiver",        false, "Automatically fill quiver with suitable ranged ammunition"),
  bool_opt("bones",             true,  "Allow loading bones files (remains of previous deaths)"),
  bool_opt("checkpoint",        true,  "Save game state periodically for crash recovery"),
  bool_opt("cmdassist",         true,  "Show tips when using commands incorrectly"),
  bool_opt("confirm",           true,  "Ask for confirmation before attacking peaceful monsters"),
  bool_opt("dark_room",         true,  "Use shading to show dark areas vs lit areas"),
  bool_opt("fixinv",            true,  "Keep fixed inventory letters for items"),
  bool_opt("force_invmenu",     false, "Always display inventory as a menu (not a list)"),
  bool_opt("help",              true,  "Show help messages and command assistance"),
  bool_opt("hilite_pet",        false, "Visually highlight your pets"),
  bool_opt("hilite_pile",       false, "Visually highlight piles of multiple items"),
  bool_opt("implicit_uncursed", true,  "Don't show 'uncursed' label on items (show only cursed/blessed)"),
  bool_opt("legacy",            true,  "Show the introductory message when starting a new game"),
  bool_opt("lit_corridor",      false, "Distinguish between lit and unlit corridors"),
  bool_opt("lootabc",           false, "Use a/b/c menu letters in loot and tip prompts"),
  bool_opt("mention_walls",     false, "Show a message when you walk into a wall"),
  bool_opt("pickup_thrown",     true,  "Automatically pick up items you previously threw"),
  bool_opt("pushweapon",        false, "When wielding a new weapon, push the old one to the swap slot"),
  bool_opt("rest_on_space",     false, "Space key causes you to rest (wait one turn)"),
  bool_opt("safe_pet",          true,  "Prevent you from accidentally attacking your pets"),
  bool_opt("showexp",           false, "Show experience points in the status line"),
  bool_opt("showrace",          false, "Show your race instead of role symbol in the status line"),
  bool_opt("silent",            true,  "Suppress terminal beep sounds"),
  bool_opt("sortpack",          true,  "Sort inventory by object type"),
  bool_opt("sparkle",           true,  "Show sparkle animation when a monster resists an attack"),
  bool_opt("time",              false, "Show the elapsed game time (turns) in the status line"),
  bool_opt("tombstone",         true,  "Display a tombstone when you die"),
  bool_opt("travel",            true,  "Enable the travel command (click-to-move to distant squares)"),
  bool_opt("verbose",           true,  "Show detailed messages during combat and other actions"),

  ---------------------------------------------------------------------------
  -- Compound / string options
  ---------------------------------------------------------------------------
  string_opt("catname",    "", "Name for your first cat (e.g. Tabby)"),
  string_opt("dogname",    "", "Name for your first dog (e.g. Fang)"),
  string_opt("horsename",  "", "Name for your first horse (e.g. Silver)"),
  string_opt("fruit",      "slime mold", "The name of a fruit you enjoy eating"),
  string_opt("pettype",    "", "Preferred starting pet type", {"", "cat", "dog", "none"}),
  string_opt("menustyle",  "full", "User interface style for object selection menus",
             {"traditional", "combination", "partial", "full"}),
  string_opt("pickup_burden", "stressed",
             "Maximum encumbrance level before prompting on autopickup",
             {"unencumbered", "burdened", "stressed", "strained", "overtaxed", "overloaded"}),
  string_opt("pickup_types", "",
             "Item types to auto-pickup (letter codes, e.g. \"$?!/\" for gold, scrolls, potions, wands). Blank = all."),
  string_opt("runmode", "run",
             "How map updates are shown while running/travelling",
             {"teleport", "run", "walk", "crawl"}),
  string_opt("sortloot", "loot",
             "Sort object selection lists",
             {"full", "loot", "none"}),
  string_opt("pile_limit", "5",
             "Number of items in a pile before showing \"there are several objects here\" (0 = always show menu)"),
  string_opt("packorder", "",
             "Inventory display order by item class. Default: \")[]%?+!=/(*`0_\""),
  string_opt("paranoid_confirmation", "pray",
             "Require extra confirmation for dangerous actions. Space-separated list of: pray attack wand-break Remove die swim"),
  string_opt("disclose", "",
             "What info to show at end of game. Format: +/-/y/n prefix for each of i(nventory), a(ttributes), v(anquished), g(enocide), c(onduct). E.g. \"+i +a +v +g +c\""),
  string_opt("msghistory", "20",
             "Number of messages to keep in the message history buffer"),
  string_opt("statushilites", "0",
             "Duration in turns to show status line highlights (0 = disabled)"),
}
