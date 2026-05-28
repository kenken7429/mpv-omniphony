--[[
  omniphony-overlay.lua

  Front-view object overlay driven by omniphony-studio.

  Studio writes a compact `<id>,x,y,z,rms;…` payload to the user-data
  property `user-data/omniphony/overlay/frame` over the JSON IPC. We
  observe that property and re-render an ASS overlay through libass.

  Mapping (front view, listener looking at the screen):
    screen X  ← X (left/right, [-1, 1])
    screen Y  ← -Z (up/down, [-1, 1])
    colour    ← Y (front/back, [-1, 1])
                  Y = +1 green, Y = 0 blue, Y = -1 red
    radius    ← RMS dBFS  (0.5x .. 2.4x of base)

  Position/size/colour are quantised so libass's drawing cache has a small
  bounded set of unique events to manage.
]]

local OVERLAY_ID = 47
local BASE_RADIUS_RATIO = 0.015  -- fraction of screen height
local HEADER_FONT_SIZE = 14
local COLOR_STEP = 32
local CINEMA_ASPECT = 2.35       -- pseudo-3D depth squeezes Y=+1 into this band

-- Bezier-approximated unit circle of radius 100, scaled per object via
-- \fscx/\fscy so libass keeps the path parse cached.
local UNIT_CIRCLE = "m -100 0 b -100 -55 -55 -100 0 -100 "
               .. "b 55 -100 100 -55 100 0 "
               .. "b 100 55 55 100 0 100 "
               .. "b -55 100 -100 55 -100 0"

local enabled = true
local last_frame_payload = ""

-- ── helpers ──────────────────────────────────────────────────────────────

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function dbfs_to_scale(dbfs, min_scale, max_scale)
  local c = clamp(dbfs or -100, -100, 0)
  local n = (c + 100) / 100
  return min_scale + n * (max_scale - min_scale)
end

local function quantise_channel(v)
  local q = math.floor((v + COLOR_STEP / 2) / COLOR_STEP) * COLOR_STEP
  if q < 0 then return 0 end
  if q > 255 then return 255 end
  return q
end

-- y ∈ [-1, +1] → r,g,b ∈ [0, 255], quantised to 32-step channels.
--   y = +1 → green (0, 255, 0)
--   y =  0 → blue  (0, 128, 255)
--   y = -1 → red   (255, 0, 64)
local function color_for_y(y)
  y = clamp(y or 0, -1, 1)
  local r, g, b
  if y >= 0 then
    local t = y
    r = 0
    g = math.floor(128 + 127 * t)
    b = math.floor(255 * (1 - t))
  else
    local t = -y
    r = math.floor(255 * t)
    g = math.floor(128 * (1 - t))
    b = math.floor(255 * (1 - t) + 64 * t)
  end
  return quantise_channel(r), quantise_channel(g), quantise_channel(b)
end

local function ass_color(r, g, b)
  return string.format("&H%02X%02X%02X&", b, g, r)
end

local SEMI = string.byte(";")
local COMMA = string.byte(",")

local function for_each_field(s, sep, cb)
  local start = 1
  local len = #s
  for i = 1, len do
    if string.byte(s, i) == sep then
      cb(string.sub(s, start, i - 1))
      start = i + 1
    end
  end
  if start <= len then
    cb(string.sub(s, start, len))
  end
end

-- ── core ─────────────────────────────────────────────────────────────────

local function build_ass(payload)
  local res_x = mp.get_property_number("osd-width", 0) or 0
  local res_y = mp.get_property_number("osd-height", 0) or 0
  if res_x <= 0 or res_y <= 0 then
    return nil, 0, 0, 0
  end

  -- Pseudo-3D front view, anchored on (X=0, Z=0.5) = screen centre:
  --   X ∈ [-1, +1], Z ∈ [0, +1], Y ∈ [-1, +1].
  --   Y = -1 (rear / wrap-around) → spatial cube fills the whole screen.
  --   Y = +1 (at the screen)      → spatial cube fits inside the 2.35
  --                                  letterbox band.
  --   Same depth ratio scales X, Z and the circle radius so the cube
  --   stays square as it recedes.
  local cx = res_x / 2
  local cy = res_y / 2
  -- Vertical fraction the 2.35 band takes on this display, clamped at
  -- 1.0 for displays wider than 2.35:1 (band fills the height).
  local band_h_frac = math.min(1.0, (res_x / res_y) / CINEMA_ASPECT)
  local depth_span = 1.0 - band_h_frac
  local base_radius = math.max(8, res_y * BASE_RADIUS_RATIO)

  local out = {}
  local n_obj = 0

  for_each_field(payload, SEMI, function(obj)
    if obj == "" then return end
    local id, x, y, z, rms
    local idx = 0
    for_each_field(obj, COMMA, function(field)
      idx = idx + 1
      if idx == 1 then id = field
      elseif idx == 2 then x = tonumber(field)
      elseif idx == 3 then y = tonumber(field)
      elseif idx == 4 then z = tonumber(field)
      elseif idx == 5 then rms = tonumber(field) end
    end)
    if not (x and y and z) then return end
    n_obj = n_obj + 1

    -- Depth factor s ∈ [band_h_frac, 1].  Quantise to 5 % buckets so
    -- libass's drawing cache keeps a small bounded set of unique
    -- (s, level) combinations.
    local depth_t = clamp((y + 1) * 0.5, 0, 1)
    local s = 1.0 - depth_t * depth_span
    s = math.floor(s * 20 + 0.5) / 20
    local sx = cx + x * (res_x / 2) * s
    local sy = cy - (z - 0.5) * res_y * s

    local level_scale = dbfs_to_scale(rms, 0.5, 2.4)
    level_scale = math.floor(level_scale * 20 + 0.5) / 20
    local pct = base_radius * level_scale * s
    local r, g, b = color_for_y(y)
    local col = ass_color(r, g, b)

    out[#out + 1] = string.format(
      "{\\an7\\pos(%.1f,%.1f)\\bord1\\fscx%.1f\\fscy%.1f\\1c%s\\3c&H000000&\\1a&H30&\\3a&H80&\\p1}%s{\\p0}",
      sx, sy, pct, pct, col, UNIT_CIRCLE
    )
  end)

  local header = string.format(
    "{\\an9\\pos(%.1f,%.1f)\\bord1\\fs%d\\1c&HFFFFFF&\\3c&H000000&}%d objects",
    res_x - 12, 10, HEADER_FONT_SIZE, n_obj
  )

  return table.concat(out, "\n") .. "\n" .. header, res_x, res_y, n_obj
end

local function redraw()
  if not enabled then return end
  local text, res_x, res_y = build_ass(last_frame_payload)
  if not text then return end
  mp.command_native({
    name = "osd-overlay",
    id = OVERLAY_ID,
    format = "ass-events",
    data = text,
    res_x = res_x,
    res_y = res_y,
    z = 0,
    hidden = false,
  })
end

local function hide()
  mp.command_native({
    name = "osd-overlay",
    id = OVERLAY_ID,
    format = "none",
    data = "",
    res_x = 0,
    res_y = 0,
    z = 0,
    hidden = true,
  })
end

-- ── wiring ───────────────────────────────────────────────────────────────

mp.observe_property(
  "user-data/omniphony/overlay/frame",
  "string",
  function(_, value)
    if value == nil then return end
    enabled = true
    last_frame_payload = value
    redraw()
  end
)

-- Manual control (keybind or external client).
mp.register_script_message("omniphony-overlay", function(cmd)
  if cmd == "enable" then
    enabled = true
    redraw()
  elseif cmd == "disable" then
    enabled = false
    hide()
  end
end)

-- Redraw on window resize so the overlay stays correctly scaled.
mp.observe_property("osd-width", "number", function() redraw() end)
mp.observe_property("osd-height", "number", function() redraw() end)

-- Clear on shutdown so a still-streaming Studio cannot keep the OSD busy
-- past quit.
mp.register_event("shutdown", function()
  enabled = false
  hide()
end)
