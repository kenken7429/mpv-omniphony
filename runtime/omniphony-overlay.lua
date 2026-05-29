--[[
  omniphony-overlay.lua

  Minimal shim that displays orender's spatial object overlay.

  The overlay used to be assembled here in Lua from a CSV payload that
  omniphony-studio pushed over the JSON IPC socket. It is now generated
  entirely in Rust, inside the renderer (`liborender.so`), which already owns
  the object positions and meter levels first-hand. This script only:

    1. pulls the finished ASS markup from the library over LuaJIT FFI, and
    2. hands it to mpv's `osd-overlay` command.

  The mpv decoder thread cannot issue `osd-overlay` itself (no client handle,
  wrong thread), so this tiny script is the only residual host-side code. No
  socket, no studio dependency: the overlay works as long as orender is
  decoding, whether or not studio is running. Studio still *configures* the
  overlay (trails, A/B tags) — over OSC, into the renderer.
]]

local mp = require("mp")

local OVERLAY_ID = 47
local REDRAW_HZ = 30
-- Generous fixed buffer: the ASS payload is bounded (cube + capped objects and
-- trails). If a frame ever exceeds it we grow and skip that one redraw.
local INITIAL_CAP = 64 * 1024

-- ── FFI binding ────────────────────────────────────────────────────────────

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then
  mp.msg.error("LuaJIT FFI unavailable; omniphony overlay disabled")
  return
end

ffi.cdef([[
  size_t orender_overlay_ass(uint32_t res_x, uint32_t res_y, uint8_t *out, size_t cap);
  void orender_overlay_set_enabled(int enabled);
]])

-- liborender is already resident in the mpv process: the patched mpv links it
-- via DT_NEEDED (liborender.so.0), so its symbols are in the global namespace
-- and the default `ffi.C` namespace resolves them directly — no dlopen, no
-- RUNPATH/LD_LIBRARY_PATH guesswork. Fall back to ffi.load only if mpv was
-- built to dlopen the library privately.
local function resolves(ns)
  return ns and pcall(function() return ns.orender_overlay_ass end)
end

local C
if resolves(ffi.C) then
  C = ffi.C
else
  for _, name in ipairs({ "orender", "liborender.so.0", "liborender.so", "liborender" }) do
    local ok, lib = pcall(ffi.load, name)
    if ok and resolves(lib) then
      C = lib
      break
    end
  end
end
if not C then
  mp.msg.error("liborender symbols not found; omniphony overlay disabled")
  return
end

-- ── state ────────────────────────────────────────────────────────────────

local enabled = true
local shown = false
local cap = INITIAL_CAP
local buf = ffi.new("uint8_t[?]", cap)

-- ── drawing ────────────────────────────────────────────────────────────────

local function hide()
  if not shown then return end
  shown = false
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

local function redraw()
  if not enabled then return end
  local res_x = mp.get_property_number("osd-width", 0) or 0
  local res_y = mp.get_property_number("osd-height", 0) or 0
  if res_x <= 0 or res_y <= 0 then return end

  -- One call == one overlay redraw: the library rebuilds the scene and
  -- advances the motion trails on each call, so we must call exactly once.
  local n = tonumber(C.orender_overlay_ass(res_x, res_y, buf, cap))
  if n == 0 then
    -- Nothing to draw (disabled, non-spatial, or empty) → clear the OSD.
    hide()
    return
  end
  if n > cap then
    -- Outgrew the buffer (very unlikely): grow for next time, skip this frame.
    cap = n
    buf = ffi.new("uint8_t[?]", cap)
    return
  end

  shown = true
  mp.command_native({
    name = "osd-overlay",
    id = OVERLAY_ID,
    format = "ass-events",
    data = ffi.string(buf, n),
    res_x = res_x,
    res_y = res_y,
    z = 0,
    hidden = false,
  })
end

-- ── wiring ───────────────────────────────────────────────────────────────

mp.add_periodic_timer(1 / REDRAW_HZ, redraw)

-- Redraw immediately on resize so the overlay tracks the window snappily.
mp.observe_property("osd-width", "number", function() redraw() end)
mp.observe_property("osd-height", "number", function() redraw() end)

local function set_active(on)
  enabled = on
  C.orender_overlay_set_enabled(on and 1 or 0)
  if on then redraw() else hide() end
end

-- Manual control (external client / script-message).
mp.register_script_message("omniphony-overlay", function(cmd)
  if cmd == "enable" then
    set_active(true)
  elseif cmd == "disable" then
    set_active(false)
  elseif cmd == "toggle" then
    set_active(not enabled)
  end
end)

-- Default keybind so the overlay can be toggled without studio (rebindable in
-- input.conf via the `omniphony-overlay-toggle` command name).
mp.add_key_binding("Ctrl+o", "omniphony-overlay-toggle", function()
  set_active(not enabled)
end)

-- Clear on shutdown so the OSD doesn't linger past quit.
mp.register_event("shutdown", function()
  enabled = false
  hide()
end)
