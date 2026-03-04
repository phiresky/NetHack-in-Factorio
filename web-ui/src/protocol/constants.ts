// NetHack window types
export const NHW_MESSAGE = 1;
export const NHW_STATUS = 2;
export const NHW_MAP = 3;
export const NHW_MENU = 4;
export const NHW_TEXT = 5;

// Menu selection modes
export const PICK_NONE = 0;
export const PICK_ONE = 1;
export const PICK_ANY = 2;

// BL_ field indices (from botl.h)
export const BL_TITLE = 0;
export const BL_STR = 1;
export const BL_DX = 2;
export const BL_CO = 3;
export const BL_IN = 4;
export const BL_WI = 5;
export const BL_CH = 6;
export const BL_ALIGN = 7;
export const BL_SCORE = 8;
export const BL_CAP = 9;
export const BL_GOLD = 10;
export const BL_ENE = 11;
export const BL_ENEMAX = 12;
export const BL_XP = 13;
export const BL_AC = 14;
export const BL_HD = 15;
export const BL_TIME = 16;
export const BL_HUNGER = 17;
export const BL_HP = 18;
export const BL_HPMAX = 19;
export const BL_DLEVEL = 20;
export const BL_CONDITION = 22;
export const BL_FLUSH = 0xFFFFFFFF;
export const BL_RESET = 0xFFFFFFFE;

// Glyph special flags
export const MG_PET = 0x0002;
export const MG_DETECT = 0x0004;
export const MG_INVIS = 0x0008;
export const MG_STATUE = 0x0010;
export const MG_OBJPILE = 0x0020;
export const MG_BW_LAVA = 0x0040;
export const MG_BW_ICE = 0x0080;
export const MG_BW_WATER = 0x0100;

// NetHack colors (0-15), matching tty
export const NH_COLORS: string[] = [
  '#000000', // 0 black
  '#aa0000', // 1 red
  '#00aa00', // 2 green
  '#aa5500', // 3 brown
  '#0000aa', // 4 blue
  '#aa00aa', // 5 magenta
  '#00aaaa', // 6 cyan
  '#aaaaaa', // 7 gray
  '#555555', // 8 dark gray (no strstrength)
  '#ff5555', // 9 orange/bright red
  '#55ff55', // 10 bright green
  '#ffff55', // 11 yellow
  '#5555ff', // 12 bright blue
  '#ff55ff', // 13 bright magenta
  '#55ffff', // 14 bright cyan
  '#ffffff', // 15 white
];

// Condition bits for BL_CONDITION
export const CONDITION_BITS = [
  { mask: 0x00000001, name: 'Stone', dangerous: true },
  { mask: 0x00000002, name: 'Slime', dangerous: true },
  { mask: 0x00000004, name: 'Strngl', dangerous: true },
  { mask: 0x00000008, name: 'FoodPois', dangerous: true },
  { mask: 0x00000010, name: 'TermIll', dangerous: true },
  { mask: 0x00000020, name: 'Blind', dangerous: false },
  { mask: 0x00000040, name: 'Deaf', dangerous: false },
  { mask: 0x00000080, name: 'Stun', dangerous: false },
  { mask: 0x00000100, name: 'Conf', dangerous: false },
  { mask: 0x00000200, name: 'Hallu', dangerous: false },
  { mask: 0x00000400, name: 'Lev', dangerous: false },
  { mask: 0x00000800, name: 'Fly', dangerous: false },
  { mask: 0x00001000, name: 'Ride', dangerous: false },
];

// Stat labels for status panel
export const STAT_LABELS = [
  { name: 'str', prefix: 'Str:', idx: BL_STR, icon: '/icons/nh-icon-str.png' },
  { name: 'dx', prefix: 'Dex:', idx: BL_DX, icon: '/icons/nh-icon-dex.png' },
  { name: 'co', prefix: 'Con:', idx: BL_CO, icon: '/icons/nh-icon-con.png' },
  { name: 'in', prefix: 'Int:', idx: BL_IN, icon: '/icons/nh-icon-int.png' },
  { name: 'wi', prefix: 'Wis:', idx: BL_WI, icon: '/icons/nh-icon-wis.png' },
  { name: 'ch', prefix: 'Cha:', idx: BL_CH, icon: '/icons/nh-icon-cha.png' },
];

export const BL_EXP = 21;

export const VITAL_LABELS = [
  { name: 'gold', prefix: '', idx: BL_GOLD },
  { name: 'hp', prefix: 'HP:', idx: BL_HP, idx2: BL_HPMAX },
  { name: 'pw', prefix: 'Pw:', idx: BL_ENE, idx2: BL_ENEMAX },
  { name: 'ac', prefix: 'AC:', idx: BL_AC },
  { name: 'xlvl', prefix: 'Lvl:', idx: BL_XP },
  { name: 'xp', prefix: 'Xp:', idx: BL_EXP },
];

// Toolbar buttons
export const TOOLBAR_BUTTONS = [
  { name: 'again', label: 'Again', key: 0x01, icon: '/icons/nh-icon-tb-again.png' },
  { name: 'get', label: 'Get', key: 44 /* , */, icon: '/icons/nh-icon-tb-get.png' },
  { name: 'kick', label: 'Kick', key: 0x04, icon: '/icons/nh-icon-tb-kick.png' },
  { name: 'throw', label: 'Throw', key: 116 /* t */, icon: '/icons/nh-icon-tb-throw.png' },
  { name: 'fire', label: 'Fire', key: 102 /* f */, icon: '/icons/nh-icon-tb-fire.png' },
  { name: 'drop', label: 'Drop', key: 100 /* d */, icon: '/icons/nh-icon-tb-drop.png' },
  { name: 'rest', label: 'Rest', key: 46 /* . */, icon: '/icons/nh-icon-tb-rest.png' },
  { name: 'search', label: 'Search', key: 115 /* s */, icon: '/icons/nh-icon-tb-search.png' },
];

// Menu bar definitions
export interface MenuItem {
  label: string;
  key?: number;
  ext?: string;
  action?: string;
  shortcut?: string;
  separator?: boolean;
}

export interface MenuDef {
  name: string;
  label: string;
  items: MenuItem[];
}

export const MENU_BAR: MenuDef[] = [
  { name: 'game', label: 'Game', items: [
    { label: 'Version', key: 118 /* v */ },
    { label: 'History', key: 86 /* V */ },
    { label: 'Options', key: 79 /* O */ },
    { label: 'Explore mode', key: 35 /* # */, ext: 'exploremode' },
    { separator: true, label: '' },
    { label: 'Toggle ASCII mode', action: 'toggle_ascii' },
  ]},
  { name: 'gear', label: 'Gear', items: [
    { label: 'Wield weapon', key: 119 /* w */ },
    { label: 'Exchange weapons', key: 120 /* x */ },
    { label: 'Two weapon combat', key: 35, ext: 'twoweapon' },
    { label: 'Load quiver', key: 81 /* Q */ },
    { separator: true, label: '' },
    { label: 'Wear armour', key: 87 /* W */ },
    { label: 'Take off armour', key: 84 /* T */ },
    { separator: true, label: '' },
    { label: 'Put on', key: 80 /* P */ },
    { label: 'Remove', key: 82 /* R */ },
  ]},
  { name: 'action', label: 'Action', items: [
    { label: 'Again', key: 0x01 },
    { label: 'Apply', key: 97 /* a */ },
    { label: 'Chat', key: 35, ext: 'chat' },
    { label: 'Close door', key: 99 /* c */ },
    { label: 'Down', key: 62 /* > */ },
    { label: 'Drop', key: 100 /* d */ },
    { label: 'Eat', key: 101 /* e */ },
    { label: 'Engrave', key: 69 /* E */ },
    { label: 'Fire from quiver', key: 102 /* f */ },
    { label: 'Force', key: 35, ext: 'force' },
    { label: 'Get', key: 44 /* , */ },
    { label: 'Jump', key: 35, ext: 'jump' },
    { label: 'Kick', key: 0x04 },
    { label: 'Loot', key: 35, ext: 'loot' },
    { label: 'Open door', key: 111 /* o */ },
    { label: 'Pay', key: 112 /* p */ },
    { label: 'Rest', key: 46 /* . */ },
    { label: 'Ride', key: 35, ext: 'ride' },
    { label: 'Search', key: 115 /* s */ },
    { label: 'Throw', key: 116 /* t */ },
    { label: 'Untrap', key: 35, ext: 'untrap' },
    { label: 'Up', key: 60 /* < */ },
    { label: 'Wipe face', key: 35, ext: 'wipe' },
  ]},
  { name: 'magic', label: 'Magic', items: [
    { label: 'Quaff potion', key: 113 /* q */ },
    { label: 'Read scroll/book', key: 114 /* r */ },
    { label: 'Zap wand', key: 122 /* z */ },
    { label: 'Zap spell', key: 90 /* Z */ },
    { label: 'Dip', key: 35, ext: 'dip' },
    { label: 'Rub', key: 35, ext: 'rub' },
    { label: 'Invoke', key: 35, ext: 'invoke' },
    { separator: true, label: '' },
    { label: 'Offer', key: 35, ext: 'offer' },
    { label: 'Pray', key: 35, ext: 'pray' },
    { separator: true, label: '' },
    { label: 'Teleport', key: 0x14 },
    { label: 'Monster action', key: 35, ext: 'monster' },
    { label: 'Turn undead', key: 35, ext: 'turn' },
  ]},
  { name: 'info', label: 'Info', items: [
    { label: 'Inventory', key: 105 /* i */ },
    { label: 'Conduct', key: 35, ext: 'conduct' },
    { label: 'Discoveries', key: 92 /* \\ */ },
    { label: 'List/reorder spells', key: 43 /* + */ },
    { label: 'Adjust letters', key: 35, ext: 'adjust' },
    { separator: true, label: '' },
    { label: 'Name object', key: 35, ext: 'name' },
    { separator: true, label: '' },
    { label: 'Skills', key: 35, ext: 'enhance' },
  ]},
  { name: 'help', label: 'Help', items: [
    { label: 'Help', key: 63 /* ? */ },
    { separator: true, label: '' },
    { label: 'What is here', key: 58 /* : */ },
    { label: 'What is there', key: 59 /* ; */ },
    { label: 'What is...', key: 47 /* / */ },
  ]},
];

// Map dimensions
export const MAP_COLS = 80;
export const MAP_ROWS = 21;
export const TILE_SIZE = 32;
export const SHEET_COLS = 32;
