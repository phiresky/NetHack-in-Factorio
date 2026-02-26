-- NetHack Qt-style GUI styles for Factorio 2.0
-- Extends the default GuiStyle with custom styles for the top panel layout.

local default_gui = data.raw["gui-style"]["default"]

-----------------------------------------------------
-- Top Panel (contains messages, status, toolbar)
-----------------------------------------------------

default_gui["nh_top_frame"] = {
  type = "frame_style",
  top_padding = 4,
  bottom_padding = 4,
  left_padding = 8,
  right_padding = 8,
  vertical_spacing = 2,
  graphical_set = {
    base = {
      position = {0, 0},
      corner_size = 8,
      opacity = 0.85,
    },
  },
}


default_gui["nh_msg_scroll"] = {
  type = "scroll_pane_style",
  maximal_height = 120,
  minimal_height = 60,
  extra_padding_when_activated = 0,
  vertical_spacing = 1,
}

default_gui["nh_message_label"] = {
  type = "label_style",
  font = "default",
  font_color = {r = 1, g = 1, b = 1},
  single_line = false,
  left_padding = 2,
  right_padding = 2,
  rich_text_setting = "enabled",
}

default_gui["nh_message_label_bold"] = {
  type = "label_style",
  font = "default-bold",
  font_color = {r = 1, g = 1, b = 0.7},
  single_line = false,
  left_padding = 2,
  right_padding = 2,
  rich_text_setting = "enabled",
}

-----------------------------------------------------
-- Status (inside top panel, right side)
-----------------------------------------------------

default_gui["nh_status_flow"] = {
  type = "vertical_flow_style",
  vertical_spacing = 1,
}

default_gui["nh_status_name_label"] = {
  type = "label_style",
  font = "default-large-bold",
  font_color = {r = 1, g = 1, b = 1},
}

default_gui["nh_status_dlevel_label"] = {
  type = "label_style",
  font = "default-bold",
  font_color = {r = 0.8, g = 0.8, b = 1},
}

default_gui["nh_status_label"] = {
  type = "label_style",
  font = "default-bold",
  font_color = {r = 1, g = 1, b = 1},
  left_padding = 4,
  right_padding = 4,
  rich_text_setting = "enabled",
}

default_gui["nh_status_label_good"] = {
  type = "label_style",
  font = "default-bold",
  font_color = {r = 0.2, g = 1, b = 0.2},
  left_padding = 4,
  right_padding = 4,
  rich_text_setting = "enabled",
}

default_gui["nh_status_label_bad"] = {
  type = "label_style",
  font = "default-bold",
  font_color = {r = 1, g = 0.2, b = 0.2},
  left_padding = 4,
  right_padding = 4,
  rich_text_setting = "enabled",
}

default_gui["nh_gold_label"] = {
  type = "label_style",
  font = "default-bold",
  font_color = {r = 1, g = 0.85, b = 0},
  left_padding = 4,
  right_padding = 4,
  rich_text_setting = "enabled",
}

-----------------------------------------------------
-- Menu Bar (Qt-style dropdown menus)
-----------------------------------------------------

default_gui["nh_menubar_flow"] = {
  type = "horizontal_flow_style",
  horizontal_spacing = 2,
}

default_gui["nh_menubar_dropdown"] = {
  type = "dropdown_style",
  width = 150,
}

-----------------------------------------------------
-- Toolbar (quick-access button bar below menu bar)
-----------------------------------------------------

default_gui["nh_toolbar_flow"] = {
  type = "horizontal_flow_style",
  horizontal_spacing = 4,
  top_padding = 2,
}

default_gui["nh_toolbar_button"] = {
  type = "button_style",
  font = "default-small-bold",
  minimal_width = 50,
  left_padding = 6,
  right_padding = 6,
  top_padding = 2,
  bottom_padding = 2,
  height = 28,
  rich_text_setting = "enabled",
}

default_gui["nh_top_content_flow"] = {
  type = "horizontal_flow_style",
  horizontal_spacing = 4,
}

-----------------------------------------------------
-- Menu System
-----------------------------------------------------

default_gui["nh_menu_frame"] = {
  type = "frame_style",
  top_padding = 8,
  bottom_padding = 8,
  left_padding = 12,
  right_padding = 12,
  minimal_width = 300,
  maximal_width = 600,
  maximal_height = 600,
  graphical_set = {
    base = {
      position = {0, 0},
      corner_size = 8,
      opacity = 0.92,
    },
  },
}

default_gui["nh_menu_scroll"] = {
  type = "scroll_pane_style",
  maximal_height = 500,
  extra_padding_when_activated = 0,
}

default_gui["nh_menu_item_button_style"] = {
  type = "button_style",
  font = "default",
  left_padding = 8,
  right_padding = 8,
  top_padding = 2,
  bottom_padding = 2,
  horizontal_align = "left",
  horizontally_stretchable = "on",
  rich_text_setting = "enabled",
}

default_gui["nh_menu_header_label"] = {
  type = "label_style",
  font = "default-bold",
  font_color = {r = 1, g = 0.85, b = 0.4},
  bottom_padding = 4,
}

default_gui["nh_menu_accel_label"] = {
  type = "label_style",
  font = "default-bold",
  font_color = {r = 0.7, g = 0.9, b = 1},
  minimal_width = 24,
  left_padding = 2,
  right_padding = 4,
}

-----------------------------------------------------
-- Loading Progress Bar (shown during startup)
-----------------------------------------------------

default_gui["nh_loading_frame"] = {
  type = "frame_style",
  top_padding = 12,
  bottom_padding = 12,
  left_padding = 20,
  right_padding = 20,
  minimal_width = 350,
  graphical_set = {
    base = {
      position = {0, 0},
      corner_size = 8,
      opacity = 0.92,
    },
  },
}

default_gui["nh_loading_label"] = {
  type = "label_style",
  font = "default-large-bold",
  font_color = {r = 1, g = 1, b = 1},
  bottom_padding = 4,
}

default_gui["nh_loading_progressbar"] = {
  type = "progressbar_style",
  bar_width = 20,
  color = {r = 0.3, g = 0.8, b = 0.3},
  minimal_width = 310,
}

default_gui["nh_loading_count_label"] = {
  type = "label_style",
  font = "default",
  font_color = {r = 0.8, g = 0.8, b = 0.8},
  top_padding = 4,
}

-----------------------------------------------------
-- Player Selection Dialog
-----------------------------------------------------

default_gui["nh_plsel_frame"] = {
  type = "frame_style",
  top_padding = 12,
  bottom_padding = 12,
  left_padding = 16,
  right_padding = 16,
  minimal_width = 520,
  maximal_width = 620,
  graphical_set = {
    base = {
      position = {0, 0},
      corner_size = 8,
      opacity = 0.95,
    },
  },
}

default_gui["nh_plsel_name_field"] = {
  type = "textbox_style",
  minimal_width = 200,
  maximal_width = 300,
}

default_gui["nh_plsel_columns_flow"] = {
  type = "horizontal_flow_style",
  horizontal_spacing = 8,
  top_padding = 4,
}

default_gui["nh_plsel_list_frame"] = {
  type = "frame_style",
  top_padding = 4,
  bottom_padding = 4,
  left_padding = 4,
  right_padding = 4,
  graphical_set = {
    base = {
      position = {17, 0},
      corner_size = 8,
      opacity = 0.6,
    },
  },
}

default_gui["nh_plsel_list_scroll"] = {
  type = "scroll_pane_style",
  maximal_height = 260,
  minimal_width = 120,
  extra_padding_when_activated = 0,
  vertical_spacing = 0,
}

default_gui["nh_plsel_list_button"] = {
  type = "button_style",
  font = "default",
  font_color = {r = 0.9, g = 0.9, b = 0.9},
  minimal_width = 112,
  maximal_width = 140,
  left_padding = 4,
  right_padding = 4,
  top_padding = 1,
  bottom_padding = 1,
  height = 26,
}

default_gui["nh_plsel_list_button_selected"] = {
  type = "button_style",
  font = "default-bold",
  font_color = {r = 1, g = 1, b = 1},
  default_font_color = {r = 1, g = 1, b = 1},
  minimal_width = 112,
  maximal_width = 140,
  left_padding = 4,
  right_padding = 4,
  top_padding = 1,
  bottom_padding = 1,
  height = 26,
  default_graphical_set = {
    base = {position = {34, 17}, corner_size = 8},
  },
}

default_gui["nh_plsel_group_frame"] = {
  type = "frame_style",
  top_padding = 4,
  bottom_padding = 4,
  left_padding = 8,
  right_padding = 8,
  graphical_set = {
    base = {
      position = {17, 0},
      corner_size = 8,
      opacity = 0.6,
    },
  },
}

default_gui["nh_plsel_radio_flow"] = {
  type = "vertical_flow_style",
  vertical_spacing = 2,
}

default_gui["nh_plsel_play_button"] = {
  type = "button_style",
  font = "default-bold",
  minimal_width = 120,
  left_padding = 8,
  right_padding = 8,
  top_padding = 4,
  bottom_padding = 4,
}

default_gui["nh_plsel_button"] = {
  type = "button_style",
  font = "default",
  minimal_width = 120,
  left_padding = 8,
  right_padding = 8,
  top_padding = 2,
  bottom_padding = 2,
}

default_gui["nh_plsel_info_label"] = {
  type = "label_style",
  font = "default",
  font_color = {r = 0.7, g = 0.7, b = 0.7},
}

-----------------------------------------------------
-- Tips Popup (shown on first game start)
-----------------------------------------------------

default_gui["nh_tips_frame"] = {
  type = "frame_style",
  top_padding = 12,
  bottom_padding = 12,
  left_padding = 20,
  right_padding = 20,
  minimal_width = 400,
  maximal_width = 480,
  graphical_set = {
    base = {
      position = {0, 0},
      corner_size = 8,
      opacity = 0.95,
    },
  },
}

default_gui["nh_tips_label"] = {
  type = "label_style",
  font = "default",
  font_color = {r = 0.95, g = 0.95, b = 0.9},
  single_line = false,
  left_padding = 2,
  right_padding = 2,
  bottom_padding = 4,
}

default_gui["nh_tips_heading_label"] = {
  type = "label_style",
  font = "default-bold",
  font_color = {r = 1, g = 0.9, b = 0.5},
  single_line = false,
  top_padding = 6,
  bottom_padding = 2,
}

-----------------------------------------------------
-- Text Windows (help, info popups)
-----------------------------------------------------

default_gui["nh_text_label"] = {
  type = "label_style",
  font = "nh-mono",
  font_color = {r = 1, g = 1, b = 1},
  single_line = false,
  left_padding = 2,
  right_padding = 2,
}

-----------------------------------------------------
-- Engine State (right-aligned in menu bar)
-----------------------------------------------------

default_gui["nh_engine_spacer"] = {
  type = "empty_widget_style",
  horizontally_stretchable = "on",
}

default_gui["nh_engine_state_label"] = {
  type = "label_style",
  font = "default-small-bold",
  font_color = {r = 0.7, g = 0.7, b = 0.7},
  right_padding = 8,
}

default_gui["nh_engine_count_label"] = {
  type = "label_style",
  font = "default-small",
  font_color = {r = 0.65, g = 0.65, b = 0.65},
}

-----------------------------------------------------
-- Hover Info (separate frame below top panel)
-----------------------------------------------------

default_gui["nh_hover_frame"] = {
  type = "frame_style",
  top_padding = 6,
  bottom_padding = 6,
  left_padding = 10,
  right_padding = 10,
  maximal_width = 400,
  vertical_spacing = 2,
  graphical_set = {
    base = {
      position = {0, 0},
      corner_size = 8,
      opacity = 0.88,
    },
  },
}

default_gui["nh_hover_short_label"] = {
  type = "label_style",
  font = "default-bold",
  font_color = {r = 1, g = 1, b = 1},
  single_line = false,
  maximal_width = 380,
}

default_gui["nh_hover_long_label"] = {
  type = "label_style",
  font = "default",
  font_color = {r = 0.85, g = 0.85, b = 0.75},
  single_line = false,
  maximal_width = 380,
}
