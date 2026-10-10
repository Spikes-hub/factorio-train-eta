-- Train ETA. GUI: train groups + fuel + two-point picking on the map.
-- Current result is a LOWER BOUND (path length / top speed); acceleration physics + fuel come next.

local FRAME = "train_eta_frame"
local RAIL_TYPES = {
  "straight-rail", "curved-rail-a", "curved-rail-b", "half-diagonal-rail", "rail-ramp",
  "elevated-straight-rail", "elevated-curved-rail-a", "elevated-curved-rail-b",
  "elevated-half-diagonal-rail", "train-stop",
}

-- Selected train types and fuel live in hidden per-player mod settings, so they persist across saves.
local SEP = "|"

local function player_state(player_index)
  local s = storage.players[player_index]
  if not s then
    s = { selected = {}, fuel = nil, picking = false, points = {}, message = nil, result = {} }
    local settings = game.get_player(player_index).mod_settings
    local fuel = settings["train-eta-fuel"].value
    if fuel ~= "" then s.fuel = fuel end
    for key in settings["train-eta-selected"].value:gmatch("[^" .. SEP .. "]+") do
      s.selected[key] = true
    end
    storage.players[player_index] = s
  end
  return s
end

local function save_selected(player_index)
  local keys = {}
  for key in pairs(player_state(player_index).selected) do keys[#keys + 1] = key end
  table.sort(keys)
  game.get_player(player_index).mod_settings["train-eta-selected"] = { value = table.concat(keys, SEP) }
end

local function save_fuel(player_index)
  game.get_player(player_index).mod_settings["train-eta-fuel"] = { value = player_state(player_index).fuel or "" }
end

-- Group all trains by composition.
local function collect_groups()
  local groups = {}
  for _, train in pairs(game.train_manager.get_trains({})) do
    local counts, order = {}, {}
    for _, c in pairs(train.carriages) do
      if not counts[c.name] then
        counts[c.name] = 0
        order[#order + 1] = c.name
      end
      counts[c.name] = counts[c.name] + 1
    end
    table.sort(order)
    local parts = {}
    for _, n in ipairs(order) do parts[#parts + 1] = n .. " x" .. counts[n] end
    local key = table.concat(parts, " + ")
    local g = groups[key]
    if not g then
      g = { key = key, count = 0, sample = train, order = order, counts = counts }
      groups[key] = g
    end
    g.count = g.count + 1
  end
  local list = {}
  for _, g in pairs(groups) do list[#list + 1] = g end
  table.sort(list, function(a, b) return a.key < b.key end)
  return list
end

-- Localised "1× Locomotive + 4× Cargo wagon  (150)".
local function group_caption(g)
  local cap = { "" }
  for i, n in ipairs(g.order) do
    if i > 1 then cap[#cap + 1] = " + " end
    cap[#cap + 1] = { "train-eta.carriage", g.counts[n], prototypes.entity[n].localised_name }
  end
  cap[#cap + 1] = { "train-eta.group-count", g.count }
  return cap
end

local function fuel_items()
  -- Every item that any locomotive's burner accepts (by fuel category), not just "chemical".
  local categories = {}
  for _, loco in pairs(prototypes.get_entity_filtered { { filter = "type", type = "locomotive" } }) do
    local burner = loco.burner_prototype
    if burner then
      for cat in pairs(burner.fuel_categories) do categories[cat] = true end
    end
  end
  local names, items = {}, {}
  for name, proto in pairs(prototypes.item) do
    if proto.fuel_value > 0 and proto.fuel_category and categories[proto.fuel_category] then
      names[#names + 1] = name
    end
  end
  table.sort(names, function(a, b)
    local fa, fb = prototypes.item[a].fuel_value, prototypes.item[b].fuel_value
    if fa ~= fb then return fa < fb end
    return a < b
  end)
  for _, n in ipairs(names) do
    items[#items + 1] = { "", "[item=" .. n .. "] ", prototypes.item[n].localised_name }
  end
  return names, items
end

local function fmt_time(seconds)
  seconds = math.ceil(seconds)
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function point_caption(p)
  return p and p.label or { "train-eta.point-none" }
end

-- Resolve a click position to a rail point {rail, label}; returns nil, error_key on failure.
local function resolve_point(surface, position)
  local best, best_d
  for _, e in pairs(surface.find_entities_filtered { position = position, radius = 5, type = RAIL_TYPES }) do
    local d = (e.position.x - position.x) ^ 2 + (e.position.y - position.y) ^ 2
    if not best_d or d < best_d then best, best_d = e, d end
  end
  if not best then return nil, "no-rail" end
  if best.type == "train-stop" then
    local rail = best.connected_rail
    if not rail then return nil, "no-stop-rail" end
    return { rail = rail, label = best.backer_name }
  end
  return { rail = best, label = { "train-eta.rail-name", math.floor(best.position.x), math.floor(best.position.y) } }
end

local function both_ends(rail)
  return { rail = rail, direction = defines.rail_direction.front }, { rail = rail, direction = defines.rail_direction.back }
end

-- Tick-by-tick run over `length` tiles with the wiki train physics (friction, air resistance, fuel
-- acceleration/top speed bonuses, braking). Weight is the EMPTY train weight (cargo not counted).
-- Fuel use: engines burn in proportion to the share of their boost actually used each tick.
local function estimate(train, fuel, length, force)
  local locos = train.locomotives
  local movers = #locos.front_movers > 0 and locos.front_movers or locos.back_movers
  local n = #movers
  if n == 0 then return nil, { "train-eta.no-loco" } end

  local weight, friction, brake = 0, 0, 0
  for _, c in pairs(train.carriages) do
    local p = c.prototype
    weight = weight + (p.weight or 0)
    friction = friction + (p.friction_force or 0)
    brake = brake + (p.braking_force or 0)
  end
  brake = brake * (1 + force.train_braking_force_bonus)
  local air = train.front_stock.prototype.air_resistance or 0

  local lp = movers[1].prototype
  local e = lp.get_max_energy_usage()
  local e_tick = e >= 100000 and e / 60 or e -- J per tick (600 kW = 10000)
  local effectivity = lp.burner_prototype and lp.burner_prototype.effectivity or 1
  local cap = lp.speed * fuel.fuel_top_speed_multiplier

  local fr = friction / weight
  local decel = brake / weight
  local boost = (e_tick / 1000) * n * fuel.fuel_acceleration_multiplier / weight
  local air_k = 1 - air / (weight / 1000)
  if boost * air_k <= fr then return nil, { "train-eta.cannot-move" } end

  local v, d, ticks, energy = 0, 0, 0, 0
  while d < length and ticks < 2000000 do
    local braking_dist = v * v / (2 * decel)
    if length - d <= braking_dist + v then
      v = math.max(0, v - decel)
      if v == 0 then break end
    else
      local v1 = math.max(0, v - fr)
      local base = v1 * air_k
      local full = (v1 + boost) * air_k
      v = math.min(full, cap)
      energy = energy + n * e_tick * math.max(0, math.min(1, (v - base) / (full - base)))
    end
    d = d + v
    ticks = ticks + 1
  end
  if ticks >= 2000000 then return nil, { "train-eta.cannot-move" } end

  return {
    seconds = ticks / 60,
    top_kmh = cap * 60 * 3.6,
    energy = energy,
    fuel_count = energy / (fuel.fuel_value * effectivity),
  }
end

local function compute(player_index)
  local state = player_state(player_index)
  state.result, state.message = {}, nil
  if #state.points < 2 then return end

  local fuel = state.fuel and prototypes.item[state.fuel]
  if not fuel then
    state.message = { "train-eta.no-fuel" }
    return
  end
  local force = game.get_player(player_index).force
  local groups, any = collect_groups(), false
  local a, b = state.points[1].rail, state.points[2].rail
  if not (a.valid and b.valid) then
    state.points, state.message = {}, { "train-eta.no-rail" }
    return
  end
  local sa1, sa2 = both_ends(a)
  local gb1, gb2 = both_ends(b)

  local length
  for _, g in ipairs(groups) do
    if state.selected[g.key] and g.sample.valid then
      any = true
      local ok, res = pcall(game.train_manager.request_train_path, {
        train = g.sample,
        type = "path",
        starts = { sa1, sa2 },
        goals = { gb1, gb2 },
        shortest_path = true,
      })
      if not ok then
        state.message = tostring(res)
        return
      end
      if not res.found_path then
        state.message = { "train-eta.no-path" }
        return
      end
      length = res.total_length
      local est_ok, est, err = pcall(estimate, g.sample, fuel, length, force)
      if not est_ok then
        state.message = tostring(est)
        return
      elseif not est then
        state.message = err
        return
      end
      state.result[#state.result + 1] = {
        "train-eta.result-line", group_caption(g), fmt_time(est.seconds), string.format("%.0f", est.top_kmh),
      }
      state.result[#state.result + 1] = {
        "train-eta.fuel-line", "[item=" .. fuel.name .. "]", string.format("%.1f", est.fuel_count),
        string.format("%.1f", est.energy / 1e6),
      }
    end
  end
  if not any then
    state.message = { "train-eta.no-group" }
  else
    table.insert(state.result, 1, { "train-eta.path-length", string.format("%.0f", length) })
  end
end

local function destroy_gui(player)
  local f = player.gui.screen[FRAME]
  if f then f.destroy() end
end

local function build_gui(player)
  local state = player_state(player.index)
  local old = player.gui.screen[FRAME]
  local location = old and old.location or { 10, 100 }
  destroy_gui(player)

  local frame = player.gui.screen.add { type = "frame", name = FRAME, direction = "vertical" }
  frame.auto_center = false
  frame.location = location

  local bar = frame.add { type = "flow", direction = "horizontal" }
  bar.drag_target = frame
  bar.add { type = "label", caption = { "train-eta.title" }, style = "frame_title", ignored_by_interaction = true }
  local filler = bar.add { type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true }
  filler.style.horizontally_stretchable = true
  filler.style.height = 24
  bar.add { type = "sprite-button", name = "train_eta_refresh", style = "frame_action_button",
            sprite = "utility/refresh", tooltip = { "train-eta.refresh" } }
  bar.add { type = "sprite-button", name = "train_eta_close", style = "frame_action_button",
            sprite = "utility/close", tooltip = { "gui.close" } }

  local inner = frame.add { type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" }

  local fuel_names, fuel_loc = fuel_items()
  local fuel_row = inner.add { type = "flow", direction = "horizontal" }
  fuel_row.style.vertical_align = "center"
  fuel_row.add { type = "label", caption = { "train-eta.fuel" } }
  local sel = 1
  for i, n in ipairs(fuel_names) do
    if n == state.fuel then sel = i end
  end
  state.fuel = fuel_names[sel]
  local dd = fuel_row.add { type = "drop-down", name = "train_eta_fuel", items = fuel_loc, selected_index = sel }
  dd.tags = { names = fuel_names }

  inner.add { type = "line" }
  inner.add { type = "label", caption = { "train-eta.trains" }, style = "caption_label" }

  local scroll = inner.add { type = "scroll-pane", direction = "vertical" }
  scroll.style.maximal_height = 300
  local groups = collect_groups()
  if #groups == 0 then
    scroll.add { type = "label", caption = { "train-eta.no-trains" } }
  end
  for i, g in ipairs(groups) do
    local cb = scroll.add { type = "checkbox", name = "train_eta_group_" .. i,
      caption = group_caption(g), state = state.selected[g.key] == true }
    cb.tags = { key = g.key }
  end

  inner.add { type = "line" }
  local row = inner.add { type = "flow", direction = "horizontal" }
  row.add { type = "button", name = "train_eta_pick",
    caption = state.picking and { "train-eta.pick-stop" } or { "train-eta.pick" } }
  row.add { type = "button", name = "train_eta_reset", caption = { "train-eta.reset" } }
  if state.picking then
    inner.add { type = "label", caption = { "train-eta.pick-hint", #state.points } }
  end
  inner.add { type = "label", caption = { "train-eta.points", point_caption(state.points[1]), point_caption(state.points[2]) } }

  if state.message then
    inner.add { type = "label", caption = state.message }
  end
  for _, line in ipairs(state.result) do
    inner.add { type = "label", caption = line }
  end
end

local function toggle_gui(player)
  if player.gui.screen[FRAME] then
    destroy_gui(player)
    player.set_shortcut_toggled("train-eta-toggle", false)
    player_state(player.index).picking = false
  else
    build_gui(player)
    player.set_shortcut_toggled("train-eta-toggle", true)
  end
end

script.on_init(function() storage.players = {} end)
script.on_configuration_changed(function() storage.players = storage.players or {} end)
script.on_event(defines.events.on_player_removed, function(e) storage.players[e.player_index] = nil end)

script.on_event(defines.events.on_lua_shortcut, function(e)
  if e.prototype_name == "train-eta-toggle" then toggle_gui(game.get_player(e.player_index)) end
end)
script.on_event("train-eta-toggle-input", function(e)
  toggle_gui(game.get_player(e.player_index))
end)

-- Map click while picking.
script.on_event("train-eta-click", function(e)
  local state = storage.players[e.player_index]
  local player = game.get_player(e.player_index)
  if not (state and state.picking and player.gui.screen[FRAME]) then return end
  if state.ignore_tick == game.tick then return end -- the same click that hit a GUI button

  local point, err = resolve_point(player.surface, e.cursor_position)
  if not point then
    state.message = { "train-eta." .. err }
    build_gui(player)
    return
  end
  -- One physical click can arrive twice (press/release); drop repeats of the same point.
  local first = state.points[1]
  if #state.points == 1 and first.rail == point.rail then return end
  if state.last_click_tick and game.tick - state.last_click_tick < 15 then return end
  state.last_click_tick = game.tick
  state.message = nil
  if #state.points >= 2 then state.points = {} end
  state.points[#state.points + 1] = point
  if #state.points == 2 then
    state.picking = false
    compute(e.player_index)
  else
    state.result = {}
  end
  build_gui(player)
end)

script.on_event(defines.events.on_gui_click, function(e)
  local name = e.element.name
  if not name:find("^train_eta_") then return end
  local player = game.get_player(e.player_index)
  local state = player_state(e.player_index)
  state.ignore_tick = game.tick

  if name == "train_eta_close" then
    toggle_gui(player)
  elseif name == "train_eta_refresh" then
    build_gui(player)
  elseif name == "train_eta_pick" then
    state.picking = not state.picking
    if state.picking then state.points, state.result, state.message = {}, {}, nil end
    build_gui(player)
  elseif name == "train_eta_reset" then
    state.points, state.result, state.message, state.picking = {}, {}, nil, false
    build_gui(player)
  end
end)

script.on_event(defines.events.on_gui_checked_state_changed, function(e)
  if e.element.name:find("^train_eta_group_") then
    local state = player_state(e.player_index)
    state.selected[e.element.tags.key] = e.element.state or nil
    save_selected(e.player_index)
    if #state.points == 2 then
      compute(e.player_index)
      build_gui(game.get_player(e.player_index))
    end
  end
end)

script.on_event(defines.events.on_gui_selection_state_changed, function(e)
  if e.element.name == "train_eta_fuel" then
    player_state(e.player_index).fuel = e.element.tags.names[e.element.selected_index]
    save_fuel(e.player_index)
    if #player_state(e.player_index).points == 2 then
      compute(e.player_index)
      build_gui(game.get_player(e.player_index))
    end
  end
end)
