-- Hidden per-player settings, used only as persistent storage (survive across saves and games).
data:extend({
  {
    type = "string-setting",
    name = "train-eta-fuel",
    setting_type = "runtime-per-user",
    default_value = "",
    allow_blank = true,
    hidden = true,
  },
  {
    type = "string-setting",
    name = "train-eta-selected",
    setting_type = "runtime-per-user",
    default_value = "",
    allow_blank = true,
    hidden = true,
  },
})
