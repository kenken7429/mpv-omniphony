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

local function ass_color(r, g, b)
  return string.format("&H%02X%02X%02X&", b, g, r)
end

-- Parse a 6-char RRGGBB hex string into r, g, b bytes. Falls back to a
-- neutral mid-grey on garbage input so a malformed payload doesn't kill
-- the whole frame.
local function parse_hex_color(hex)
  if type(hex) ~= "string" or #hex < 6 then
    return 128, 128, 128
  end
  local r = tonumber(string.sub(hex, 1, 2), 16)
  local g = tonumber(string.sub(hex, 3, 4), 16)
  local b = tonumber(string.sub(hex, 5, 6), 16)
  return r or 128, g or 128, b or 128
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

-- ── trails ───────────────────────────────────────────────────────────────

-- Mirror of Studio's TRAIL_MIN_POINT_INTERVAL_MS (70 ms) so the overlay
-- samples at the same rate as the 3D view.
local TRAIL_MIN_POINT_INTERVAL_S = 0.07
local TRAIL_MAX_POINTS = 60

local trail_cfg = { enabled = false, ttl_s = 7.0, mode = "line" }
-- Diffuse-mode rendering parameters.
--   DIFFUSE_SPACING_FACTOR : desired dot spacing as a fraction of the
--     active circle's base radius; smaller = denser = smoother trail.
--   DIFFUSE_MAX_SUBDIV     : per-segment subdivision cap; protects against
--     a single very fast move flooding libass.
--   DIFFUSE_TOTAL_CAP      : whole-trail cap, ditto.
--   DIFFUSE_BLUR           : Gaussian blur (in ASS pixels) for the glow
--     effect; quantised constant so libass caches the bitmap once.
local DIFFUSE_SPACING_FACTOR = 0.65
local DIFFUSE_MAX_SUBDIV = 16
local DIFFUSE_TOTAL_CAP = 96
local DIFFUSE_BLUR = 4
local trails = {}  -- [id] = { points = {{x,y,z,t}, ...}, last_t = number }

local function trail_append(id, x, y, z)
  if not trail_cfg.enabled then
    trails[id] = nil
    return
  end
  local now = mp.get_time()
  local t = trails[id]
  if not t then
    t = { points = {}, last_t = 0 }
    trails[id] = t
  end
  if now - t.last_t < TRAIL_MIN_POINT_INTERVAL_S then return end
  t.last_t = now
  t.points[#t.points + 1] = { x, y, z, now }
  -- Prune by TTL + cap. Keep the tail because new points were appended.
  local cutoff = now - trail_cfg.ttl_s
  local first = 1
  while first <= #t.points and t.points[first][4] < cutoff do
    first = first + 1
  end
  if first > 1 or #t.points > TRAIL_MAX_POINTS then
    local lo = math.max(first, #t.points - TRAIL_MAX_POINTS + 1)
    local pruned = {}
    for i = lo, #t.points do pruned[#pruned + 1] = t.points[i] end
    t.points = pruned
  end
end

-- Project a trail point [x_norm, y_norm, z_norm] into screen pixels using
-- the same depth-quantised pseudo-3D formula as the active circles.
local function project_trail_point(p, cx, cy, res_x, res_y, depth_span)
  local depth_t = clamp((p[2] + 1) * 0.5, 0, 1)
  local s = 1.0 - depth_t * depth_span
  s = math.floor(s * 20 + 0.5) / 20
  local sx = cx + p[1] * (res_x / 2) * s
  local sy = cy - (p[3] - 0.5) * res_y * s
  return sx, sy, s
end

local function build_trail_line(t, cx, cy, res_x, res_y, depth_span, color_hex)
  -- libass auto-closes filled (`\p1`) paths, which made a single connected
  -- polyline render as a closed polygon. Emit each consecutive pair as its
  -- own subpath (separated by `m`) so the border only traces the segment
  -- itself.
  local segs = {}
  for i = 1, #t.points - 1 do
    local x1, y1 = project_trail_point(t.points[i],     cx, cy, res_x, res_y, depth_span)
    local x2, y2 = project_trail_point(t.points[i + 1], cx, cy, res_x, res_y, depth_span)
    segs[#segs + 1] = string.format("m %.1f %.1f l %.1f %.1f", x1, y1, x2, y2)
  end
  local r, g, b = parse_hex_color(color_hex)
  return string.format(
    "{\\an7\\pos(0,0)\\bord1\\1a&HFF&\\3c%s\\3a&H70&\\p1}%s{\\p0}",
    ass_color(r, g, b), table.concat(segs, " ")
  )
end

-- Diffuse mode: blurred glowing dots fading in size + alpha with age.
-- Subdivision count per segment is chosen from the *screen* distance
-- between two consecutive stored buffer points, so fast-moving objects
-- get more interpolated dots than still ones — the trail stays nearly
-- continuous regardless of the buffer sample rate.
local function emit_diffuse_dot(events, sx, sy, t_along, age_fade,
                                base_radius, depth_scale, col)
  -- Quantise size + alpha to 4 buckets each so the libass drawing cache
  -- stays bounded (≤ 16 unique (radius, alpha) tuples per colour).
  local r_factor = 0.30 + 0.70 * t_along
  r_factor = math.floor(r_factor * 4 + 0.5) / 4
  local dot_r = base_radius * r_factor * depth_scale
  local alpha = 1.0 - 0.70 * t_along * age_fade
  local alpha_q = math.floor(alpha * 4 + 0.5) / 4
  local alpha_hex = math.floor(alpha_q * 255 + 0.5)
  events[#events + 1] = string.format(
    "{\\an7\\pos(%.1f,%.1f)\\bord0\\blur%d\\fscx%.1f\\fscy%.1f\\1c%s\\1a&H%02X&\\p1}%s{\\p0}",
    sx, sy, DIFFUSE_BLUR, dot_r, dot_r, col, alpha_hex, UNIT_CIRCLE
  )
end

local function build_trail_diffuse(t, cx, cy, res_x, res_y, depth_span, color_hex, base_radius)
  local count = #t.points
  if count < 2 then return nil end
  local now = mp.get_time()
  local r, g, b = parse_hex_color(color_hex)
  local col = ass_color(r, g, b)

  -- Pre-project every stored buffer point to screen pixels once.
  local pts = {}
  for i = 1, count do
    local p = t.points[i]
    local sx, sy, s = project_trail_point(p, cx, cy, res_x, res_y, depth_span)
    pts[i] = { sx = sx, sy = sy, s = s, t = p[4] }
  end

  local target_spacing = math.max(2.0, base_radius * DIFFUSE_SPACING_FACTOR)
  local events = {}
  local total = 0

  for i = 1, count - 1 do
    if total >= DIFFUSE_TOTAL_CAP then break end
    local p1, p2 = pts[i], pts[i + 1]
    local dx, dy = p2.sx - p1.sx, p2.sy - p1.sy
    local seg_len = math.sqrt(dx * dx + dy * dy)
    local subdiv = math.max(1, math.ceil(seg_len / target_spacing))
    if subdiv > DIFFUSE_MAX_SUBDIV then subdiv = DIFFUSE_MAX_SUBDIV end
    for sub = 0, subdiv - 1 do
      if total >= DIFFUSE_TOTAL_CAP then break end
      local frac = sub / subdiv
      local sx = p1.sx + frac * dx
      local sy = p1.sy + frac * dy
      local s = p1.s + frac * (p2.s - p1.s)
      local pt = p1.t + frac * (p2.t - p1.t)
      local age = now - pt
      if age <= trail_cfg.ttl_s then
        local age_fade = 1.0 - (age / trail_cfg.ttl_s)
        local trail_t = (i - 1 + frac) / (count - 1)
        emit_diffuse_dot(events, sx, sy, trail_t, age_fade,
          base_radius, s, col)
        total = total + 1
      end
    end
  end

  -- Always emit the newest point so the trail kisses the active circle.
  if total < DIFFUSE_TOTAL_CAP then
    local pn = pts[count]
    local age = now - pn.t
    if age <= trail_cfg.ttl_s then
      emit_diffuse_dot(events, pn.sx, pn.sy, 1.0,
        1.0 - (age / trail_cfg.ttl_s), base_radius, pn.s, col)
    end
  end

  if #events == 0 then return nil end
  return table.concat(events, "\n")
end

-- Vertical depth indicator: a coloured line at the object's current
-- (X, Z) that spans the entire Y range [-1, +1]. Drawn underneath the
-- object so the active circle marks where on that depth axis the object
-- actually sits. Uses `\bord` on a degenerate 2-point path → libass
-- strokes both sides of the line, giving a clean ~2·bord-pixel-wide bar.
local Y_LINE_BORD = 3
local function build_y_axis_line(x, z, cx, cy, res_x, res_y, depth_span, color_hex)
  local x1, y1 = project_trail_point({ x, -1, z, 0 }, cx, cy, res_x, res_y, depth_span)
  local x2, y2 = project_trail_point({ x,  1, z, 0 }, cx, cy, res_x, res_y, depth_span)
  local r, g, b = parse_hex_color(color_hex)
  return string.format(
    "{\\an7\\pos(0,0)\\bord%d\\blur1\\1a&HFF&\\3c%s\\3a&H80&\\p1}m %.1f %.1f l %.1f %.1f{\\p0}",
    Y_LINE_BORD, ass_color(r, g, b), x1, y1, x2, y2
  )
end

local function build_trail_event(id, cx, cy, res_x, res_y, depth_span, color_hex, base_radius)
  if not trail_cfg.enabled then return nil end
  local t = trails[id]
  if not t or #t.points < 2 then return nil end
  if trail_cfg.mode == "diffuse" then
    return build_trail_diffuse(t, cx, cy, res_x, res_y, depth_span, color_hex, base_radius)
  end
  return build_trail_line(t, cx, cy, res_x, res_y, depth_span, color_hex)
end

mp.observe_property(
  "user-data/omniphony/overlay/trail-config",
  "native",
  function(_, value)
    if type(value) ~= "string" or #value == 0 then return end
    local en, ttl, mode = value:match("^(%d+)|(%d+)|(%w+)$")
    if not en then return end
    trail_cfg.enabled = (en == "1")
    trail_cfg.ttl_s = (tonumber(ttl) or 7000) / 1000
    trail_cfg.mode = (mode == "diffuse") and "diffuse" or "line"
    if not trail_cfg.enabled then trails = {} end
  end
)

-- ── wireframe cube ───────────────────────────────────────────────────────

-- 8 edges of the unit cube X∈{-1,+1} × Y∈{-1,+1} × Z∈{0,+1}, listed as
-- (x1,y1,z1, x2,y2,z2). The Y=-1 face (large outer rectangle, listener's
-- rear) is omitted — its edges trace the screen border anyway and the
-- four diagonals already convey the depth structure.
local CUBE_EDGES = {
  -- front face (Y=+1) — sits inside the 2.35 letterbox band
  {-1, 1,0,  1, 1,0}, {-1, 1,1,  1, 1,1},
  {-1, 1,0, -1, 1,1}, { 1, 1,0,  1, 1,1},
  -- four edges along Y connecting the implicit rear corners to the
  -- visible front face
  {-1,-1,0, -1, 1,0}, { 1,-1,0,  1, 1,0},
  {-1,-1,1, -1, 1,1}, { 1,-1,1,  1, 1,1},
}

local function project_vertex(vx, vy, vz, cx, cy, res_x, res_y, depth_span)
  local depth_t = clamp((vy + 1) * 0.5, 0, 1)
  local s = 1.0 - depth_t * depth_span
  -- Same depth ratio as the objects, no quantisation: the cube is static
  -- per screen size, so libass caches the whole event as one entry.
  local sx = cx + vx * (res_x / 2) * s
  local sy = cy - (vz - 0.5) * res_y * s
  return sx, sy
end

local function build_wireframe(cx, cy, res_x, res_y, depth_span)
  local segs = {}
  for i = 1, #CUBE_EDGES do
    local e = CUBE_EDGES[i]
    local x1, y1 = project_vertex(e[1], e[2], e[3], cx, cy, res_x, res_y, depth_span)
    local x2, y2 = project_vertex(e[4], e[5], e[6], cx, cy, res_x, res_y, depth_span)
    segs[#segs + 1] = string.format("m %.1f %.1f l %.1f %.1f", x1, y1, x2, y2)
  end
  -- Transparent fill + visible white border so the polyline is the only
  -- thing libass actually rasterises.
  return string.format(
    "{\\an7\\pos(0,0)\\bord1\\1a&HFF&\\3c&HFFFFFF&\\3a&H80&\\p1}%s{\\p0}",
    table.concat(segs, " ")
  )
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
  -- Static wireframe of the spatial cube, drawn first so the objects sit
  -- on top of it. Uses the same depth projection as the objects.
  out[#out + 1] = build_wireframe(cx, cy, res_x, res_y, depth_span)
  local n_obj = 0

  for_each_field(payload, SEMI, function(obj)
    if obj == "" then return end
    local id, x, y, z, rms, color_hex
    local idx = 0
    for_each_field(obj, COMMA, function(field)
      idx = idx + 1
      if idx == 1 then id = field
      elseif idx == 2 then x = tonumber(field)
      elseif idx == 3 then y = tonumber(field)
      elseif idx == 4 then z = tonumber(field)
      elseif idx == 5 then rms = tonumber(field)
      elseif idx == 6 then color_hex = field end
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
    -- Same palette/tag logic as Studio (mirrored Rust-side); colour comes
    -- ready-quantised from the wire so libass's cache stays bounded.
    local r, g, b = parse_hex_color(color_hex)
    local col = ass_color(r, g, b)

    -- Sample current position into the trail buffer, then emit the trail
    -- (line or diffuse) before the active circle so it draws underneath.
    trail_append(id, x, y, z)
    local trail_evt = build_trail_event(
      id, cx, cy, res_x, res_y, depth_span, color_hex, base_radius)
    if trail_evt then out[#out + 1] = trail_evt end

    -- Depth indicator (Y axis at the object's X, Z), drawn under the
    -- circle so the circle marks its position on the line.
    out[#out + 1] = build_y_axis_line(x, z, cx, cy, res_x, res_y, depth_span, color_hex)

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
  "native",
  function(_, value)
    if type(value) ~= "string" then return end
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
