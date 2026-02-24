-- NetHack GUI styles for Factorio 2.0
-- Extends the default GuiStyle with custom frame and label styles.

local default_gui = data.raw["gui-style"]["default"]

-- Message log frame (top of screen)
default_gui["nh_message_frame"] = {
  type = "frame_style",
  top_padding = 4,
  bottom_padding = 4,
  left_padding = 8,
  right_padding = 8,
  maximal_height = 200,
  graphical_set = {
    base = {
      position = {0, 0},
      corner_size = 8,
      opacity = 0.85,
    },
  },
}

-- Status bar frame (bottom of screen)
default_gui["nh_status_frame"] = {
  type = "frame_style",
  top_padding = 2,
  bottom_padding = 2,
  left_padding = 8,
  right_padding = 8,
  maximal_height = 60,
  graphical_set = {
    base = {
      position = {0, 0},
      corner_size = 8,
      opacity = 0.85,
    },
  },
}

-- Menu frame (inventory, selections)
default_gui["nh_menu_frame"] = {
  type = "frame_style",
  top_padding = 8,
  bottom_padding = 8,
  left_padding = 12,
  right_padding = 12,
  minimal_width = 300,
  maximal_width = 500,
  maximal_height = 600,
  graphical_set = {
    base = {
      position = {0, 0},
      corner_size = 8,
      opacity = 0.9,
    },
  },
}

-- Status label for HP, AC, etc.
default_gui["nh_status_label"] = {
  type = "label_style",
  font = "default-bold",
  font_color = {r = 1, g = 1, b = 1},
  left_padding = 4,
  right_padding = 4,
}

-- HP label (turns red at low HP)
default_gui["nh_hp_label"] = {
  type = "label_style",
  font = "default-bold",
  font_color = {r = 0.2, g = 1, b = 0.2},
  left_padding = 4,
  right_padding = 4,
}

-- HP label when critically low
default_gui["nh_hp_critical_label"] = {
  type = "label_style",
  font = "default-bold",
  font_color = {r = 1, g = 0.2, b = 0.2},
  left_padding = 4,
  right_padding = 4,
}

-- Gold display label
default_gui["nh_gold_label"] = {
  type = "label_style",
  font = "default-bold",
  font_color = {r = 1, g = 0.85, b = 0},
  left_padding = 4,
  right_padding = 4,
}

-- Message text label
default_gui["nh_message_label"] = {
  type = "label_style",
  font = "default",
  font_color = {r = 1, g = 1, b = 1},
  single_line = false,
}

-- Menu item button (for PICK_ONE menus)
default_gui["nh_menu_item_button_style"] = {
  type = "button_style",
  font = "default",
  font_color = {r = 0.9, g = 0.9, b = 0.9},
  left_padding = 4,
  right_padding = 4,
  top_padding = 2,
  bottom_padding = 2,
  minimal_width = 200,
}

-- Menu item label
default_gui["nh_menu_item_label"] = {
  type = "label_style",
  font = "default",
  font_color = {r = 0.9, g = 0.9, b = 0.9},
  left_padding = 4,
  right_padding = 4,
  top_padding = 2,
  bottom_padding = 2,
}

-- Menu header label
default_gui["nh_menu_header_label"] = {
  type = "label_style",
  font = "default-bold",
  font_color = {r = 1, g = 0.85, b = 0.4},
  bottom_padding = 4,
}

-- Horizontal flow for status bar items
default_gui["nh_status_flow"] = {
  type = "horizontal_flow_style",
  horizontal_spacing = 12,
  vertical_align = "center",
}

-- Vertical flow for message log
default_gui["nh_message_flow"] = {
  type = "vertical_flow_style",
  vertical_spacing = 2,
}

-- Scroll pane for menu
default_gui["nh_menu_scroll"] = {
  type = "scroll_pane_style",
  maximal_height = 500,
  extra_padding_when_activated = 0,
}

-- Action panel frame (right side of screen)
default_gui["nh_action_panel_frame"] = {
  type = "frame_style",
  top_padding = 4,
  bottom_padding = 4,
  left_padding = 4,
  right_padding = 4,
  graphical_set = {
    base = {
      position = {0, 0},
      corner_size = 8,
      opacity = 0.8,
    },
  },
}

-- Action panel scroll pane
default_gui["nh_action_scroll"] = {
  type = "scroll_pane_style",
  maximal_height = 800,
  minimal_width = 120,
  extra_padding_when_activated = 0,
}

-- Action button (compact)
default_gui["nh_action_button"] = {
  type = "button_style",
  font = "default-small",
  font_color = {r = 0.9, g = 0.9, b = 0.9},
  minimal_width = 112,
  maximal_width = 112,
  left_padding = 2,
  right_padding = 2,
  top_padding = 1,
  bottom_padding = 1,
  height = 24,
}

-- Action group header label
default_gui["nh_action_header"] = {
  type = "label_style",
  font = "default-small-bold",
  font_color = {r = 1, g = 0.85, b = 0.4},
  top_padding = 4,
  bottom_padding = 0,
}
