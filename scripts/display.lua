-- display.lua: Manages Factorio surfaces, tiles, and entities to render the NetHack dungeon
local Display = {}

-- NetHack map dimensions
local MAP_W = 80
local MAP_H = 21

-- NetHack color index -> Factorio color {r,g,b,a}
local NH_COLORS = {
  [0]  = {r=0.1, g=0.1, b=0.1, a=1},       -- CLR_BLACK (dark gray)
  [1]  = {r=0.9, g=0.2, b=0.2, a=1},       -- CLR_RED
  [2]  = {r=0.2, g=0.8, b=0.2, a=1},       -- CLR_GREEN
  [3]  = {r=0.7, g=0.5, b=0.2, a=1},       -- CLR_BROWN
  [4]  = {r=0.3, g=0.3, b=0.9, a=1},       -- CLR_BLUE
  [5]  = {r=0.8, g=0.2, b=0.8, a=1},       -- CLR_MAGENTA
  [6]  = {r=0.2, g=0.8, b=0.8, a=1},       -- CLR_CYAN
  [7]  = {r=0.7, g=0.7, b=0.7, a=1},       -- CLR_GRAY
  [8]  = {r=0.5, g=0.5, b=0.5, a=1},       -- NO_COLOR
  [9]  = {r=1.0, g=0.6, b=0.1, a=1},       -- CLR_ORANGE
  [10] = {r=0.3, g=1.0, b=0.3, a=1},       -- CLR_BRIGHT_GREEN
  [11] = {r=1.0, g=1.0, b=0.2, a=1},       -- CLR_YELLOW
  [12] = {r=0.4, g=0.4, b=1.0, a=1},       -- CLR_BRIGHT_BLUE
  [13] = {r=1.0, g=0.4, b=1.0, a=1},       -- CLR_BRIGHT_MAGENTA
  [14] = {r=0.4, g=1.0, b=1.0, a=1},       -- CLR_BRIGHT_CYAN
  [15] = {r=1.0, g=1.0, b=1.0, a=1},       -- CLR_WHITE
}

-- Character -> tile type mapping for dungeon features
local CHAR_TO_TILE = {
  [string.byte(".")] = "nh-floor",
  [string.byte("#")] = "nh-corridor",
  [string.byte(" ")] = "nh-void",
  [string.byte("}")] = "nh-water",
}

-- Characters that represent walls
local WALL_CHARS = {
  [string.byte("-")] = true,
  [string.byte("|")] = true,
}

-- Characters that represent doors
local DOOR_CHARS = {
  [string.byte("+")] = true,
}

-- Characters that represent stairs
local STAIR_CHARS = {
  [string.byte("<")] = "up",
  [string.byte(">")] = "down",
}

-- Glyph special flags (from NetHack glyph_info.gm.glyphflags)
local MG_MONSTER  = 0x0001
local MG_PET      = 0x0002
local MG_DETECT   = 0x0004
local MG_INVIS    = 0x0008
local MG_STATUE   = 0x0010
local MG_OBJPILE  = 0x0020
local MG_BW_LAVA  = 0x0040
local MG_BW_ICE   = 0x0080
local MG_BW_WATER = 0x0100
local MG_CORPSE   = 0x0200
local MG_FEMALE   = 0x0400
local MG_RIDDEN   = 0x0800

-- State per dungeon level
-- global.nh_levels[level_name] = { surface, grid, entities }

function Display.init()
  if not storage.nh_display then
    storage.nh_display = {
      levels = {},          -- level_name -> { surface_name, grid }
      current_level = nil,  -- current level name
      player_pos = {x = 0, y = 0},
      entity_map = {},      -- [level_name][y][x] -> entity reference data
    }
  end
end

-- Create or get a dungeon level surface
function Display.get_or_create_level(level_name)
  local disp = storage.nh_display
  if disp.levels[level_name] then
    return game.surfaces[disp.levels[level_name].surface_name]
  end

  local surface_name = "nh-" .. level_name
  local surface = game.create_surface(surface_name, {
    default_enable_all_autoplace_controls = false,
    property_expression_names = {
      -- Disable all resource/entity generation
      cliffiness = 0,
      ["enemy-base-frequency"] = 0,
      ["enemy-base-radius"] = 0,
      ["enemy-base-intensity"] = 0,
    },
    autoplace_settings = {
      entity = { treat_missing_as_default = false },
      tile = { treat_missing_as_default = false },
      decorative = { treat_missing_as_default = false },
    },
    width = MAP_W + 4,
    height = MAP_H + 4,
    starting_area = 0,
  })

  -- Request chunk generation for the play area
  surface.request_to_generate_chunks({x = MAP_W / 2, y = MAP_H / 2}, 3)
  surface.force_generate_chunk_requests()

  -- Fill the entire area with void tiles
  local tiles = {}
  for y = -2, MAP_H + 1 do
    for x = -2, MAP_W + 1 do
      tiles[#tiles + 1] = {name = "nh-void", position = {x = x, y = y}}
    end
  end
  surface.set_tiles(tiles)

  -- Disable day/night cycle - always bright
  surface.always_day = true

  disp.levels[level_name] = {
    surface_name = surface_name,
    grid = {},  -- [y][x] = {ch, color, special}
  }
  disp.entity_map[level_name] = {}

  return surface
end

-- Switch to a dungeon level
function Display.switch_level(level_name, player)
  local disp = storage.nh_display
  local surface = Display.get_or_create_level(level_name)
  disp.current_level = level_name

  if player then
    local pos = disp.player_pos
    player.teleport({x = pos.x + 0.5, y = pos.y + 0.5}, surface)
  end

  return surface
end

-- Get current surface
function Display.get_current_surface()
  local disp = storage.nh_display
  if not disp.current_level then return nil end
  local level = disp.levels[disp.current_level]
  if not level then return nil end
  return game.surfaces[level.surface_name]
end

-- Destroy entity at a grid position if one exists
local function destroy_entity_at(level_name, x, y)
  local disp = storage.nh_display
  local emap = disp.entity_map[level_name]
  if not emap then return end
  if not emap[y] then return end
  local ent_data = emap[y][x]
  if ent_data and ent_data.entity and ent_data.entity.valid then
    ent_data.entity.destroy()
  end
  if emap[y] then
    emap[y][x] = nil
  end
end

-- Place or update an entity at grid position
local function place_entity(surface, level_name, x, y, entity_name, color_idx)
  local disp = storage.nh_display
  destroy_entity_at(level_name, x, y)

  local ent = surface.create_entity{
    name = entity_name,
    position = {x = x + 0.5, y = y + 0.5},
    force = "player",
  }

  if ent then
    -- Apply color tinting if we have a color
    if color_idx and NH_COLORS[color_idx] then
      ent.color = NH_COLORS[color_idx]
    end

    if not disp.entity_map[level_name][y] then
      disp.entity_map[level_name][y] = {}
    end
    disp.entity_map[level_name][y][x] = {
      entity = ent,
      name = entity_name,
    }
  end

  return ent
end

-- Determine entity name for a monster character
local function monster_entity_name(ch)
  local c = string.char(ch)
  if c:match("[a-z]") then
    return "nh-mon-" .. c
  elseif c:match("[A-Z]") then
    return "nh-mon-upper-" .. c
  elseif c == "@" then
    return "nh-mon-at"
  elseif c == "&" then
    return "nh-mon-amp"
  elseif c == ";" then
    return "nh-mon-semi"
  elseif c == ":" then
    return "nh-mon-colon"
  elseif c == "'" then
    return "nh-mon-apos"
  elseif c == "~" then
    return "nh-mon-tilde"
  elseif c == "]" then
    return "nh-mon-bracket"
  else
    return "nh-mon-generic"
  end
end

-- Determine entity name for an item character
local function item_entity_name(ch)
  -- Items use a generic entity with color tinting
  return "nh-item"
end

-- Core function: handle a print_glyph call from NetHack
-- ch = ASCII character, color = color index, special = glyphflags
function Display.print_glyph(x, y, ch, color, special)
  local disp = storage.nh_display
  if not disp.current_level then return end

  local level_name = disp.current_level
  local level = disp.levels[level_name]
  local surface = game.surfaces[level.surface_name]
  if not surface then return end

  -- Store grid state
  if not level.grid[y] then level.grid[y] = {} end
  local old = level.grid[y][x]
  level.grid[y][x] = {ch = ch, color = color, special = special}

  -- Skip if nothing changed
  if old and old.ch == ch and old.color == color and old.special == special then
    return
  end

  local is_monster = (special and bit32.band(special, MG_MONSTER) ~= 0)

  -- Handle the player character '@'
  if ch == string.byte("@") and is_monster then
    -- This is the player - update position but don't place entity
    disp.player_pos = {x = x, y = y}
    -- Set floor tile underneath
    surface.set_tiles({{name = "nh-floor", position = {x = x, y = y}}})
    destroy_entity_at(level_name, x, y)
    return
  end

  -- Walls
  if WALL_CHARS[ch] then
    local wall_type
    if ch == string.byte("|") then
      wall_type = "nh-wall-v"
    else
      wall_type = "nh-wall-h"
    end
    surface.set_tiles({{name = "nh-floor", position = {x = x, y = y}}})
    place_entity(surface, level_name, x, y, wall_type, color)
    return
  end

  -- Doors
  if DOOR_CHARS[ch] then
    surface.set_tiles({{name = "nh-floor", position = {x = x, y = y}}})
    if color == 3 then -- CLR_BROWN = closed door
      place_entity(surface, level_name, x, y, "nh-door-closed", color)
    else
      destroy_entity_at(level_name, x, y)
    end
    return
  end

  -- Stairs
  if STAIR_CHARS[ch] then
    surface.set_tiles({{name = "nh-floor", position = {x = x, y = y}}})
    if STAIR_CHARS[ch] == "up" then
      place_entity(surface, level_name, x, y, "nh-stairs-up", color)
    else
      place_entity(surface, level_name, x, y, "nh-stairs-down", color)
    end
    return
  end

  -- Monsters (non-player)
  if is_monster then
    -- Don't change the underlying tile for monsters
    local ent_name = monster_entity_name(ch)
    place_entity(surface, level_name, x, y, ent_name, color)
    return
  end

  -- Dungeon features (floor, corridor, water, etc.)
  local tile_name = CHAR_TO_TILE[ch]
  if tile_name then
    surface.set_tiles({{name = tile_name, position = {x = x, y = y}}})
    destroy_entity_at(level_name, x, y)
    return
  end

  -- Lava
  if ch == string.byte("}") and color == 1 then -- CLR_RED = lava
    surface.set_tiles({{name = "nh-lava", position = {x = x, y = y}}})
    destroy_entity_at(level_name, x, y)
    return
  end

  -- Ice
  if ch == string.byte(".") and color == 6 then -- CLR_CYAN = ice
    surface.set_tiles({{name = "nh-ice", position = {x = x, y = y}}})
    destroy_entity_at(level_name, x, y)
    return
  end

  -- Traps (^ character)
  if ch == string.byte("^") then
    surface.set_tiles({{name = "nh-floor", position = {x = x, y = y}}})
    place_entity(surface, level_name, x, y, "nh-item", color)
    return
  end

  -- Items (anything else that's not a space or dungeon feature)
  if ch ~= string.byte(" ") and ch > 32 then
    -- Check for item-like characters
    local item_chars = {
      [string.byte(")")] = true, [string.byte("[")] = true,
      [string.byte("=")] = true, [string.byte('"')] = true,
      [string.byte("(")] = true, [string.byte("%")] = true,
      [string.byte("!")] = true, [string.byte("?")] = true,
      [string.byte("/")] = true, [string.byte("$")] = true,
      [string.byte("*")] = true, [string.byte("`")] = true,
      [string.byte("0")] = true, [string.byte("_")] = true,
      [string.byte("{")] = true,
    }
    if item_chars[ch] then
      -- Don't change the tile - items sit on top
      place_entity(surface, level_name, x, y, "nh-item", color)
      return
    end
  end

  -- Fallback: void tile, no entity
  if ch == string.byte(" ") then
    surface.set_tiles({{name = "nh-void", position = {x = x, y = y}}})
    destroy_entity_at(level_name, x, y)
  end
end

-- Clear the entire map display (called on level change)
function Display.clear_map()
  local disp = storage.nh_display
  if not disp.current_level then return end

  local level_name = disp.current_level
  local level = disp.levels[level_name]
  local surface = game.surfaces[level.surface_name]
  if not surface then return end

  -- Destroy all entities
  local emap = disp.entity_map[level_name]
  if emap then
    for y, row in pairs(emap) do
      for x, ent_data in pairs(row) do
        if ent_data.entity and ent_data.entity.valid then
          ent_data.entity.destroy()
        end
      end
    end
  end
  disp.entity_map[level_name] = {}

  -- Reset grid
  level.grid = {}

  -- Fill with void
  local tiles = {}
  for y = 0, MAP_H - 1 do
    for x = 0, MAP_W - 1 do
      tiles[#tiles + 1] = {name = "nh-void", position = {x = x, y = y}}
    end
  end
  surface.set_tiles(tiles)
end

-- Get the player's expected position from the display
function Display.get_player_pos()
  local disp = storage.nh_display
  return disp.player_pos
end

-- Get current level name
function Display.get_current_level()
  local disp = storage.nh_display
  return disp.current_level
end

return Display
