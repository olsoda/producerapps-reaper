-- @noindex
-- Reap Detective: draw lines directly on the arrange view (needs js_ReaScriptAPI).
--
-- Same technique as other arrange-overlay scripts: every line is a 1x1 LICE bitmap that
-- js_ReaScriptAPI composites, stretched, onto the arrange window (child 1000 of the main
-- window). Lines are only re-composited when the view, the tracks or the lines change.

local O = {}

local r = reaper
O.available = r.JS_Composite ~= nil and r.JS_LICE_CreateBitmap ~= nil and r.JS_Window_FindChildByID ~= nil

-- opaque ARGB colors (Windows composites don't premultiply alpha)
O.COLORS = {
  hit = 0xFFFFC400, active = 0xFFFFFFFF, ghost = 0xFF8C8C8C, split = 0xFF6A5520,
  flag = 0xFFE64545, risk = 0xFFF2992E,
}

local view          -- arrange view HWND
local pool, pool_color, used = {}, {}, 0
local last_sig = nil

function O.arrange()
  if not view then view = r.JS_Window_FindChildByID(r.GetMainHwnd(), 1000) end
  return view
end

local function bitmap(i, color)
  local bm = pool[i]
  if not bm then
    bm = r.JS_LICE_CreateBitmap(true, 1, 1)
    pool[i], pool_color[i] = bm, nil
  end
  if pool_color[i] ~= color then
    r.JS_LICE_Clear(bm, color)
    pool_color[i] = color
  end
  return bm
end

-- Vertical spans (arrange pixels) covered by `tracks`; neighboring tracks merge into one span.
-- Tracks scrolled under pinned tracks are clipped to below the pinned area.
function O.spans(tracks)
  local list = {}
  for _, tr in ipairs(tracks) do
    local h = r.GetMediaTrackInfo_Value(tr, 'I_TCPH')
    if h > 0 then
      list[#list + 1] = {
        n = r.GetMediaTrackInfo_Value(tr, 'IP_TRACKNUMBER'),
        y = r.GetMediaTrackInfo_Value(tr, 'I_TCPY'), h = h,
        wh = r.GetMediaTrackInfo_Value(tr, 'I_WNDH'),
        pinned = r.GetMediaTrackInfo_Value(tr, 'B_TCPPIN') == 1,
      }
    end
  end
  table.sort(list, function(a, b) return a.n < b.n end)
  local pin_bottom = 0
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    if r.GetMediaTrackInfo_Value(tr, 'B_TCPPIN') == 1 then
      pin_bottom = math.max(pin_bottom, r.GetMediaTrackInfo_Value(tr, 'I_TCPY') + r.GetMediaTrackInfo_Value(tr, 'I_WNDH'))
    end
  end
  local spans = {}
  for _, t in ipairs(list) do
    local top, bottom = t.y, t.y + t.h
    if not t.pinned and top < pin_bottom then top = pin_bottom end
    if bottom > top then
      local last = spans[#spans]
      if last and last.last_n == t.n - 1 and math.abs(last.wbottom - t.y) <= 1 then
        last.bottom, last.wbottom, last.last_n = bottom, t.y + t.wh, t.n
      else
        spans[#spans + 1] = { top = top, bottom = bottom, wbottom = t.y + t.wh, last_n = t.n }
      end
    end
  end
  return spans
end

-- Current mapping between time and arrange pixels.
function O.geometry(tracks)
  local hwnd = O.arrange()
  if not hwnd then return nil end
  local t0, t1 = r.GetSet_ArrangeView2(0, false, 0, 0, 0, 0)
  local _, cw, ch = r.JS_Window_GetClientSize(hwnd)
  return { hwnd = hwnd, t0 = t0, t1 = t1, zoom = r.GetHZoomLevel(), cw = cw, ch = ch, spans = O.spans(tracks) }
end

local function first_at_or_after(lines, t)
  local lo, hi = 1, #lines
  while lo <= hi do
    local mid = (lo + hi) // 2
    if lines[mid].t < t then lo = mid + 1 else hi = mid - 1 end
  end
  return lo
end

-- Lines for the hits: amber, the hovered/selected one white and thicker, the split point
-- (trigger pad) as a dim line when zoomed in, and an optional grey "add here" preview.
function O.hit_lines(hits, pad, active_key, ghost_t)
  local lines = {}
  for _, h in ipairs(hits) do
    lines[#lines + 1] = { t = h.t - pad, w = 1, color = O.COLORS.split, min_zoom = 4 / math.max(pad, 1e-4) }
    local act = h.key == active_key
    lines[#lines + 1] = { t = h.t, w = act and 2 or 1, color = act and O.COLORS.active or O.COLORS.hit }
  end
  if ghost_t then lines[#lines + 1] = { t = ghost_t, w = 1, color = O.COLORS.ghost } end
  table.sort(lines, function(a, b) return a.t < b.t end)
  return lines
end

-- Draw `lines` (sorted by t) across `tracks`. `key` must change whenever the lines do.
-- Returns the number of rectangles drawn (nil when nothing changed).
function O.update(lines, tracks, key)
  local g = O.geometry(tracks)
  if not g then return end
  local parts = { key, ('%.6f'):format(g.t0), ('%.4f'):format(g.zoom), g.cw, g.ch }
  for _, s in ipairs(g.spans) do parts[#parts + 1] = s.top .. ':' .. s.bottom end
  local sig = table.concat(parts, '|')
  if sig == last_sig then return end
  last_sig = sig

  local hwnd, cw, ch = g.hwnd, g.cw, g.ch
  for _, s in ipairs(g.spans) do -- keep every rectangle inside the arrange client area
    s.top = math.max(0, math.floor(s.top))
    s.bottom = math.min(ch, math.floor(s.bottom))
  end
  local first = first_at_or_after(lines, g.t0 - 1)
  local last = first_at_or_after(lines, g.t1 + 1 / g.zoom) - 1
  local n = 0
  if #g.spans > 0 and last - first + 1 <= cw * 2 / 3 then
    for i = first, last do
      local l = lines[i]
      if not l.min_zoom or g.zoom >= l.min_zoom then
        local x = math.floor((l.t - g.t0) * g.zoom + 0.5)
        if x >= 0 and x + l.w <= cw then
          for _, s in ipairs(g.spans) do
            if s.bottom > s.top then
              n = n + 1
              r.JS_Composite(hwnd, x, s.top, l.w, s.bottom - s.top, bitmap(n, l.color), 0, 0, 1, 1, true)
            end
          end
        end
      end
    end
  end
  for i = n + 1, used do r.JS_Composite_Unlink(hwnd, pool[i], false) end
  used = n
  r.JS_Window_InvalidateRect(hwnd, 0, 0, cw, ch, false)
  return n
end

-- Remove every line (window closing, display switched off, ...).
function O.clear()
  local hwnd = view
  for i, bm in ipairs(pool) do
    r.JS_LICE_DestroyBitmap(bm)
    pool[i], pool_color[i] = nil, nil
  end
  used, last_sig = 0, nil
  if hwnd then
    local _, cw, ch = r.JS_Window_GetClientSize(hwnd)
    r.JS_Window_InvalidateRect(hwnd, 0, 0, cw, ch, false)
  end
end

return O
