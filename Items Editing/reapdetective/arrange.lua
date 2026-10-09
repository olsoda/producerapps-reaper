-- @noindex
-- Reap Detective: edit hits with the mouse directly in the arrange view (needs js_ReaScriptAPI).
--
--   drag a hit line              move the hit
--   Option/Alt-click a line      delete the hit
--   Option/Alt-click elsewhere   add a hit (on the tracks being cut, inside the analysis range)
--
-- Clicks are only taken from REAPER while the mouse is on a hit line, or while Option/Alt is
-- held over the tracks being cut. Everywhere else REAPER behaves as usual. Capturing never
-- starts while a mouse button is already down, so REAPER's own drags are never cut short.

local O = require 'reapdetective.overlay'

local M = {}
local r = reaper

M.available = O.available and r.JS_WindowMessage_InterceptList ~= nil and r.JS_WindowMessage_Peek ~= nil
  and r.JS_WindowMessage_Release ~= nil and r.JS_Mouse_GetState ~= nil and r.JS_Window_ScreenToClient ~= nil
  and r.JS_Window_FromPoint ~= nil and r.JS_Window_AddressFromHandle ~= nil

M.GRAB_PX = 5
local MSGS = 'WM_LBUTTONDOWN,WM_LBUTTONDBLCLK,WM_LBUTTONUP,WM_SETCURSOR'
local CLICKS = { 'WM_LBUTTONDOWN', 'WM_LBUTTONDBLCLK' }
local CURSOR = { move = 32644, delete = 32648, add = 32515 } -- size W-E, "no", crosshair

local armed, last_click, drag = false, 0, nil
M.log = function() end -- set by the window: M.log(fmt, ...)
local cursors = {}

local function set_cursor(kind)
  local n = CURSOR[kind]
  if not cursors[n] then cursors[n] = r.JS_Mouse_LoadCursor(n) end
  if cursors[n] then r.JS_Mouse_SetCursor(cursors[n]) end
end

local function addr(h) return h and r.JS_Window_AddressFromHandle(h) or nil end

local function newest_click(hwnd)
  local best_t, best_x
  for _, m in ipairs(CLICKS) do
    local ok, _, time, _, _, x = r.JS_WindowMessage_Peek(hwnd, m)
    if ok and time and time > last_click and (not best_t or time > best_t) then best_t, best_x = time, x end
  end
  if best_t then
    last_click = best_t
    return best_x
  end
end

local function arm(hwnd, on)
  if on == armed then return end
  if on then
    local spec = MSGS:gsub(',', ':block,') .. ':block'
    if r.JS_WindowMessage_InterceptList(hwnd, spec) ~= 1 then
      r.JS_WindowMessage_Release(hwnd, MSGS) -- another script owns one of them: back off
      if not M.busy_logged then M.log('arrange: could not capture clicks (another script holds them)') end
      M.busy_logged = true
      return
    end
    armed = true
    for _, m in ipairs(CLICKS) do -- only react to clicks from now on
      local ok, _, time = r.JS_WindowMessage_Peek(hwnd, m)
      if ok and time and time > last_click then last_click = time end
    end
  else
    r.JS_WindowMessage_Release(hwnd, MSGS)
    armed = false
  end
end

-- Stop capturing (leaving the step, closing the window, errors).
function M.release()
  drag = nil
  if armed then arm(O.arrange(), false) end
end

function M.is_armed() return armed end

-- Index of the hit nearest to t within tol seconds.
local function nearest(hits, t, tol)
  local lo, hi = 1, #hits
  while lo <= hi do
    local mid = (lo + hi) // 2
    if hits[mid].t < t then lo = mid + 1 else hi = mid - 1 end
  end
  local best, best_d
  for i = math.max(1, lo - 1), math.min(#hits, lo) do
    local d = math.abs(hits[i].t - t)
    if d <= tol and (not best_d or d < best_d) then best, best_d = i, d end
  end
  return best
end

-- One defer cycle.
--   hits   sorted by t (each has .t and .key)
--   tracks the tracks the lines cover
--   ops    { select(hit), move(key, t), delete(hit), add(t), rs, re }
-- Returns the key of the hit under the mouse (or being dragged), and the time of the
-- "add here" preview when Option/Alt is held over an empty spot.
function M.update(hits, tracks, ops)
  local g = O.geometry(tracks)
  if not g then return end
  local hwnd = g.hwnd
  local mx, my = r.GetMousePosition()
  local cx, cy = r.JS_Window_ScreenToClient(hwnd, mx, my)
  local over = addr(r.JS_Window_FromPoint(mx, my)) == addr(hwnd)
  local in_span = false
  for _, s in ipairs(g.spans) do
    if cy >= s.top and cy < s.bottom then in_span = true end
  end
  local state = r.JS_Mouse_GetState(1 | 16)
  local lmb, alt = (state & 1) ~= 0, (state & 16) ~= 0
  local tol = M.GRAB_PX / g.zoom
  local t = g.t0 + cx / g.zoom
  local hov = (over and in_span) and nearest(hits, t, tol) or nil

  if drag then
    if lmb then
      ops.move(drag.key, t + drag.grab)
    else
      M.log('arrange: drop at %.4f', t + drag.grab)
      drag = nil
    end
  end

  if armed and not drag then
    local x = newest_click(hwnd)
    if x then
      local tc = g.t0 + x / g.zoom
      local hc = nearest(hits, tc, tol)
      if alt and hc then
        M.log('arrange: delete hit at %.4f', hits[hc].t)
        ops.delete(hits[hc])
      elseif alt then
        if tc >= ops.rs and tc <= ops.re then
          M.log('arrange: add hit at %.4f', tc)
          ops.add(tc)
        end
      elseif hc then
        M.log('arrange: drag hit at %.4f (click x=%d, mouse x=%d y=%d)', hits[hc].t, x, cx, cy)
        ops.select(hits[hc])
        drag = { key = hits[hc].key, grab = hits[hc].t - tc }
      end
    end
  end

  local want = drag ~= nil or (armed and lmb) or (not lmb and over and in_span and (hov ~= nil or alt))
  arm(hwnd, want)

  local ghost
  if armed then
    if drag or (hov and not alt) then
      set_cursor('move')
    elseif hov then
      set_cursor('delete')
    elseif alt then
      set_cursor('add')
      if t >= ops.rs and t <= ops.re then ghost = t end
    end
  end
  return (drag and drag.key) or (hov and hits[hov].key) or nil, ghost
end

return M
