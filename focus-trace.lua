-- focus-trace: when focus moves between windows, the border colour drains out
-- of the old window towards the new one and fills the new window from the side
-- you came from. Written for Hyprland's Lua config (0.55+), tested on Omarchy.
--
-- https://github.com/Jok8675/omarchy-focus-trace

local settings = {
  -- Fill speed: one step per this many pixels of window outline, so larger
  -- windows take longer. Lower is slower.
  px_per_step = 196,
  -- Shortest and longest fill, in steps.
  min_steps = 6,
  max_steps = 40,
  -- Length of the drain on the window losing focus, in steps. Not scaled.
  drain_steps = 8,
  -- Milliseconds per step (one frame at 60Hz).
  step_ms = 16,
  -- Colour stops in the moving gradient. Hyprland allows at most 10.
  stops = 8,
  -- Extra outline on the focused window, in pixels: at rest and while filling.
  -- Set both to 0 to leave Hyprland's shadow settings alone.
  ring_focused = 1,
  ring_filling = 2,
  -- Rebind SUPER + arrow focus keys so a wrap-around animates the way the key
  -- points. The keys keep their normal action.
  rebind_focus_keys = true,
}

local omarchy = type(rawget(_G, "o")) == "table"
local ring = settings.ring_focused > 0 or settings.ring_filling > 0

local trace = { step = 0, fill_steps = 16, filling = false, running = false }

-- Hyprland's own border colour fade is off: it blends from the previous colour
-- on every change, which shows the solid colour for a frame before the fill.
hl.animation({ leaf = "border", enabled = false })

-- "0xAARRGGBB" -> { a, r, g, b }
local function channels(colour)
  local n = tonumber(colour)
  return { math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256 }
end

local function mix(from, to, t)
  local out = "0x"
  for c = 1, 4 do
    out = out .. string.format("%02X", math.floor(from[c] + (to[c] - from[c]) * t + 0.5))
  end
  return out
end

-- Per-window inactive border. Hyprland (0.56) skips the first token of a
-- multi-token value here, hence the leading "0". There is no way to clear this
-- override, so windows end on an explicit copy of the theme's inactive colour.
local function set_inactive_border(address, value)
  pcall(hl.dispatch, hl.dsp.window.set_prop({
    prop = "inactive_border_color",
    value = "0 " .. value,
    window = "address:" .. address,
  }))
end

-- Extra thickness on the focused window is a tight shadow: a ring drawn just
-- outside the border. Unlike a larger border it does not resize the window, so
-- its contents stay put. It is one flat colour, so it cannot follow the
-- direction of the fill.
if ring then
  hl.config({ decoration = { shadow = {
    -- Not "sharp": a sharp shadow is also painted behind the window and tints
    -- see-through contents. render_power 1 keeps the soft one near-solid.
    enabled = true, sharp = false, render_power = 1, range = math.max(1, settings.ring_focused),
    color = "0x00000000", color_inactive = "0x00000000",
  } } })
  hl.animation({ leaf = "fadeShadow", enabled = false })
end

local function set_ring(range, strength)
  if not ring then return end
  local clear = { 0, trace.to[2], trace.to[3], trace.to[4] }
  if range < 1 then range, strength = 1, 0 end
  hl.config({ decoration = { shadow = { range = range, color = mix(clear, trace.to, strength) } } })
end

local function read_colours()
  trace.base = hl.get_config("general.col.active_border")
  trace.to = channels(trace.base.colors[1])
  trace.from = channels(hl.get_config("general.col.inactive_border").colors[1])
end

local function draw()
  local fill_t = math.min(1, trace.step / trace.fill_steps)
  local drain_t = math.min(1, trace.step / settings.drain_steps)
  local edge = 1 / (settings.stops - 1) -- Softness of the fill line.
  local fill_level = (1 - (1 - fill_t) ^ 3) * (1 + edge) -- Fill: fast start, slow finish.
  local drain_level = drain_t * (1 + edge) -- Drain: steady, no ease.
  local fill, drain = {}, {}
  for i = 0, settings.stops - 1 do -- Stops run along the direction of travel.
    local distance = i / (settings.stops - 1)
    fill[#fill + 1] = mix(trace.from, trace.to, math.max(0, math.min(1, (fill_level - distance) / edge)))
    drain[#drain + 1] = mix(trace.to, trace.from, math.max(0, math.min(1, (drain_level - distance) / edge)))
  end
  -- Newly focused window: colour enters from the side you came from.
  if trace.filling then
    hl.config({ general = { col = { active_border = { colors = fill, angle = trace.angle } } } })
    -- The ring is one flat colour all the way round, so it comes in late:
    -- early on it would hide the directional fill behind a full outline.
    set_ring(settings.ring_filling, fill_t ^ 4)
  end
  -- Window that lost focus: colour empties towards the window you moved to.
  if trace.out then set_inactive_border(trace.out, table.concat(drain, " ") .. " " .. trace.angle .. "deg") end
  -- Land the colour in this pass; otherwise it applies a frame later and the
  -- newly focused window shows the solid colour for one frame first.
  hl.exec_scheduled_prop_refresh_immediately()
end

local function centre(window)
  local at, size = window.at, window.size
  return (at.x or at[1]) + (size.x or size[1]) / 2, (at.y or at[2]) + (size.y or size[2]) / 2
end

-- Gradient angle pointing from the previous window to the new one (0 = left
-- to right, 90 = top to bottom), snapped to the nearest of right, down, left
-- and up. Nil when there is no previous window on the same workspace.
local function travel_angle(from_address, to)
  local ok, angle = pcall(function()
    local from = hl.get_window("address:" .. from_address)
    if from.workspace.id ~= to.workspace.id then return nil end
    local fx, fy = centre(from)
    local tx, ty = centre(to)
    if fx == tx and fy == ty then return nil end
    return math.floor(math.deg((math.atan2 or math.atan)(ty - fy, tx - fx)) / 90 + 0.5) * 90 % 360
  end)
  return ok and angle or nil
end

-- Fill length in steps for a window, from the length of its outline.
local function steps_for(window)
  local ok, steps = pcall(function()
    local size = window.size
    local perimeter = 2 * ((size.x or size[1]) + (size.y or size[2]))
    return math.floor(perimeter / settings.px_per_step + 0.5)
  end)
  return math.max(settings.min_steps, math.min(settings.max_steps, ok and steps or 16))
end

local function finish_out()
  if not trace.out then return end
  set_inactive_border(trace.out, mix(trace.from, trace.from, 0))
  trace.out = nil
end

-- Omarchy's floating workspaces keep their stock look: no fill, no ring, the
-- usual border fade, and the soft drop shadow Omarchy gives floating windows
-- (it only sets that up itself when shadows are off, which the ring prevents,
-- so the values from its workspace-modes.lua are applied here instead).
local FLOATING_TAG = "omarchy-floating-workspace"

local function on_floating_workspace(window)
  local tags = window.tags
  if type(tags) == "string" then tags = { tags } end
  for _, tag in ipairs(tags or {}) do
    if tag:sub(1, #FLOATING_TAG) == FLOATING_TAG then return true end
  end
  return false
end

local function set_paused(paused)
  if not trace.running then read_colours() end
  trace.paused = paused
  if paused then
    finish_out()
    trace.timer:set_enabled(false)
    trace.filling, trace.running = false, false
    hl.config({ general = { col = { active_border = trace.base } } })
    if ring then
      hl.config({ decoration = { shadow = {
        range = 16, render_power = 3, color = "rgba(00000035)", color_inactive = "rgba(00000035)",
      } } })
    end
    hl.animation({ leaf = "border", enabled = true, speed = 5.39, bezier = "easeOutQuint" })
  else
    if ring then hl.config({ decoration = { shadow = { render_power = 1, color_inactive = "0x00000000" } } }) end
    set_ring(settings.ring_focused, 1)
    hl.animation({ leaf = "border", enabled = false })
  end
  hl.exec_scheduled_prop_refresh_immediately()
end

-- Switches the effect off or on to suit the window; true when it is off.
local function paused_for(window)
  local floating = on_floating_workspace(window)
  if floating ~= (trace.paused or false) then set_paused(floating) end
  if floating then trace.last = nil end -- Nothing drains when leaving one.
  return floating
end

trace.timer = hl.timer(function()
  trace.step = trace.step + 1
  if trace.out and trace.step >= settings.drain_steps then finish_out() end
  if trace.filling and trace.step >= trace.fill_steps then
    trace.filling = false
    set_ring(settings.ring_focused, 1)
    hl.config({ general = { col = { active_border = trace.base } } })
  end
  if not trace.filling and not trace.out then
    trace.timer:set_enabled(false)
    trace.running = false
    hl.exec_scheduled_prop_refresh_immediately()
    return
  end
  draw()
end, { type = "repeat", timeout = settings.step_ms })
trace.timer:set_enabled(false)

hl.on("window.active", function(window)
  if not window then return end
  if paused_for(window) then return end
  if not trace.running then
    read_colours()
    trace.running = true
  end
  finish_out() -- Settle a drain that was still in flight.
  local travel = nil
  if trace.last and trace.last ~= window.address then
    trace.out = trace.last
    travel = travel_angle(trace.last, window)
  end
  trace.angle = travel or 270 -- Bottom-up when there is nothing to come from.
  -- A focus key always animates the way it points, wrap-arounds included.
  if trace.pressed then trace.angle = trace.pressed end
  trace.fill_steps = steps_for(window)
  trace.filling = true
  trace.last = window.address
  trace.step = 0
  draw() -- First frame right away, so the solid colour never flashes.
  trace.timer:set_enabled(true)
end)

-- A window joining or leaving a floating workspace is tagged after it gains
-- focus, so check again when the focused window's rules change.
hl.on("window.update_rules", function(window)
  if not window or not window.active then return end
  if not paused_for(window) and not trace.last then trace.last = window.address end
end)

-- Keep every window's explicit inactive colour in step with the theme.
hl.on("config.reloaded", function()
  read_colours()
  local active = hl.get_active_window()
  trace.last = active and active.address or nil
  set_ring(settings.ring_focused, 1)
  for _, window in ipairs(hl.get_windows()) do
    set_inactive_border(window.address, mix(trace.from, trace.from, 0))
  end
  if active then paused_for(active) end
end)

-- Directional focus keys note which way was pressed, so a wrap-around animates
-- in the direction of the key.
local function focus_direction(direction)
  trace.pressed = ({ r = 0, d = 90, l = 180, u = 270 })[direction]
  hl.dispatch(hl.dsp.focus({ direction = direction }))
  trace.pressed = nil
end

if settings.rebind_focus_keys then
  for key, bind in pairs({
    LEFT = { "l", "Focus on left window" },
    RIGHT = { "r", "Focus on right window" },
    UP = { "u", "Focus on above window" },
    DOWN = { "d", "Focus on below window" },
  }) do
    local function focus() focus_direction(bind[1]) end
    if omarchy then
      -- Lets Omarchy's keybindings menu run the bind too.
      o.bind_expressions[focus] = 'hl.dsp.focus({ direction = "' .. bind[1] .. '" })'
      o.rebind("SUPER + " .. key, bind[2], focus)
    else
      pcall(hl.unbind, "SUPER + " .. key)
      hl.bind("SUPER + " .. key, focus, { description = bind[2] })
    end
  end
end

-- For your own binds: focus_trace.focus("l" | "r" | "u" | "d")
focus_trace = { focus = focus_direction }
