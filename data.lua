data:extend({
  {
    type = "shortcut",
    name = "train-eta-toggle",
    action = "lua",
    toggleable = true,
    associated_control_input = "train-eta-toggle-input",
    icon = "__base__/graphics/icons/locomotive.png",
    icon_size = 64,
    small_icon = "__base__/graphics/icons/locomotive.png",
    small_icon_size = 64,
  },
  {
    type = "custom-input",
    name = "train-eta-toggle-input",
    key_sequence = "CONTROL + SHIFT + Y",
    action = "lua",
  },
  -- Left mouse click anywhere (does not consume the click); used only while "pick points" mode is on.
  {
    type = "custom-input",
    name = "train-eta-click",
    key_sequence = "mouse-button-1",
    consuming = "none",
    action = "lua",
  },
})
