-- @description Reap Detective: Beat Detective-style multitrack drum editing
-- @author ProducerApps
-- @version 0.2.0
-- @changelog
--   Track priority anchor: when hits on several key tracks merge into one (e.g. a kick/snare
--   flam), the onset from the highest-priority track goes on the grid. Snare, then kick, then
--   toms by default; reorder with the Priority button next to Anchor. Now the default anchor.
-- @link https://github.com/olsoda/producerapps-reaper/blob/main/docs/reap-detective.md
-- @about
--   # Reap Detective
--
--   Beat Detective-style editing for multitrack drums in REAPER.
--
--   1. **Detect**: find the hits on your key tracks (kick, snare, toms), with a flam window
--      that merges onsets within and across tracks. Fix hits by dragging, adding and deleting
--      them directly in the arrange view.
--   2. **Separate**: split the key tracks plus any other tracks (overheads, rooms...) at every
--      hit, a trigger pad before each transient, with tails trimmed so slices can move. Every
--      slice is grouped across tracks.
--   3. **Quantize**: snap slices to the grid; far moves and collisions are listed for review.
--   4. **Smooth**: fill the gaps and crossfade every boundary, with the fade placed before the
--      transient and without replaying the next hit.
--
--   Requires **ReaImGui** and **js_ReaScriptAPI** (both in the ReaTeam Extensions repository).
-- @provides
--   [nomain] reapdetective/*.lua
--   [main] ReapDetective - Quantize slices.lua
--   [main] ReapDetective - Smooth (fill gaps and crossfade).lua
--   [main] ReapDetective - Go to next flagged slice.lua
--   [main] ReapDetective - Go to previous flagged slice.lua
--   [main] ReapDetective - Clear review flags.lua

local r = reaper

if not r.ImGui_GetBuiltinPath then
  r.MB('Reap Detective needs the ReaImGui extension (0.9 or newer).\n\n' ..
    'Install "ReaImGui: ReaScript binding for Dear ImGui" from ReaPack, then restart REAPER.',
    'Reap Detective', 0)
  if r.ReaPack_BrowsePackages then r.ReaPack_BrowsePackages('ReaImGui: ReaScript binding for Dear ImGui') end
  return
end

local script_path = debug.getinfo(1, 'S').source:match('^@?(.*[/\\])') or ''
package.path = script_path .. '?.lua;' .. r.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path

local ImGui = require 'imgui' '0.9'
local core = require 'reapdetective.core'
local S = require 'reapdetective.settings'
local A = require 'reapdetective.analysis'
local E = require 'reapdetective.edit'
local K = require 'reapdetective.keys'
local O = require 'reapdetective.overlay'
local U = require 'reapdetective.ui'
local AR = require 'reapdetective.arrange'

do -- troubleshooting log: <REAPER resource path>/Data/ReapDetective/debug.log
  local dir = r.GetResourcePath() .. '/Data/ReapDetective'
  r.RecursiveCreateDirectory(dir, 0)
  A.log_path = dir .. '/debug.log'
end
AR.log = A.log

local ctx = ImGui.CreateContext('Reap Detective')
local cfg = S.load()

U.init(ImGui, ctx)
local COL = U.C
COL.dim = COL.text3

local RULER_H = 22

local st = {
  an = nil, reading = false,
  auto = {}, edits = core.new_edits(), hits = {}, by_key = {},
  sel = nil, drag = nil, mouse_down = false,
  detect_due = nil, markers_due = nil, markers_shown = false, cfg_due = nil,
  hits_version = 0, tab = 1, lines_shown = false, line_tracks = {}, line_tracks_at = 0,
  view = { t0 = 0, t1 = 10 },
  msg = 'Select your key tracks (kick, snare, toms...) and a time selection, then press Analyze.',
  msg_col = COL.dim,
  separated = false, view_info = nil,
}

----------------------------------------------------------------------------------------
-- State helpers
----------------------------------------------------------------------------------------

local function set_msg(s, col) st.msg, st.msg_col = s, col or COL.dim end
local function now() return r.time_precise() end
local function cfg_changed() st.cfg_due = now() + 1.0 end
local function detect_soon() st.detect_due = now() + 0.05 end

local function fmt_pos(t) return r.format_timestr_pos(t, '', -1) end
local function fmt_bars(t) return r.format_timestr_pos(t, '', 2) end

local function params()
  return { thr = cfg.thr_db, sens = cfg.sens_db, retrig = cfg.retrig_ms / 1000, anchor = cfg.anchor }
end

local function rebuild()
  st.hits = core.apply_edits(st.auto, st.edits)
  st.by_key = {}
  for i, h in ipairs(st.hits) do st.by_key[h.key] = i end
  st.hits_version = st.hits_version + 1
  if cfg.arrange_view == 2 then st.markers_due = now() + 0.15 end
end

local function run_detection()
  st.detect_due = nil
  if not (st.an and st.an.done) then return end
  st.auto = A.detect(st.an, params())
  rebuild()
end

local function track_order(a, b)
  return r.GetMediaTrackInfo_Value(a, 'IP_TRACKNUMBER') < r.GetMediaTrackInfo_Value(b, 'IP_TRACKNUMBER')
end

-- Key tracks: the selected tracks plus the tracks of any selected items.
local function selected_key_tracks()
  local tracks, seen = {}, {}
  local function add(tr)
    if tr and not seen[tr] then seen[tr] = true; tracks[#tracks + 1] = tr end
  end
  for i = 0, r.CountSelectedTracks(0) - 1 do add(r.GetSelectedTrack(0, i)) end
  for i = 0, r.CountSelectedMediaItems(0) - 1 do add(r.GetMediaItem_Track(r.GetSelectedMediaItem(0, i))) end
  table.sort(tracks, track_order)
  return tracks
end

local function analysis_range(tracks)
  local ts, te = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  if te - ts > 0.01 then return ts, te, 'time selection' end
  local s, e
  local function add(it)
    local p = r.GetMediaItemInfo_Value(it, 'D_POSITION')
    local q = p + r.GetMediaItemInfo_Value(it, 'D_LENGTH')
    s, e = math.min(s or p, p), math.max(e or q, q)
  end
  for i = 0, r.CountSelectedMediaItems(0) - 1 do add(r.GetSelectedMediaItem(0, i)) end
  if s then return s, e, 'selected items' end
  for _, tr in ipairs(tracks) do
    for i = 0, r.CountTrackMediaItems(tr) - 1 do add(r.GetTrackMediaItem(tr, i)) end
  end
  if s then return s, e, 'all items on the key tracks' end
end

local function start_analysis()
  local tracks = selected_key_tracks()
  local names = {}
  for _, tr in ipairs(tracks) do names[#names + 1] = select(2, r.GetTrackName(tr)) end
  local ts, te = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  A.log('---- Analyze (REAPER %s): selected tracks=%d items=%d time sel=%.3f-%.3f -> key tracks: %s',
    r.GetAppVersion(), r.CountSelectedTracks(0), r.CountSelectedMediaItems(0), ts, te, table.concat(names, ', '))
  if #tracks == 0 then return set_msg('Select the key tracks first (kick, snare, toms...).', COL.err) end
  local rs, re, how = analysis_range(tracks)
  if not rs then return set_msg('No time selection and no items on the key tracks.', COL.err) end
  A.log('range %.3f - %.3f from %s', rs, re, how)

  local old = st.an
  local same = old ~= nil and math.abs(old.rs - rs) < 1e-6 and math.abs(old.re - re) < 1e-6
    and #old.tracks == #tracks
  local prev = {}
  if old then for _, kt in ipairs(old.tracks) do prev[kt.guid] = kt end end
  A.destroy(old)

  local an = A.new(tracks, rs, re)
  for _, kt in ipairs(an.tracks) do
    local p = prev[kt.guid]
    if p then kt.offset, kt.enabled = p.offset, p.enabled else same = false end
  end
  local _, saved = r.GetProjExtState(0, 'ReapDetective', 'priority')
  local guids = {}
  for g in (saved or ''):gmatch('%S+') do guids[#guids + 1] = g end
  A.set_priority(an, guids)
  if not same or st.separated then st.edits = core.new_edits() end
  st.separated = false
  st.an, st.auto, st.hits, st.by_key, st.sel = an, {}, {}, {}, nil
  A.begin_read(an)
  st.reading = true
  st.view.t0, st.view.t1 = rs, math.min(re, rs + 12)
  set_msg(('Analyzing %d track(s) over the %s...'):format(#tracks, how))
end

local function target_tracks()
  local list, seen = {}, {}
  local function add(tr)
    if tr and not seen[tr] and r.ValidatePtr2(0, tr, 'MediaTrack*') then
      seen[tr] = true
      list[#list + 1] = tr
    end
  end
  if st.an then for _, kt in ipairs(st.an.tracks) do add(kt.track) end end
  for i = 0, r.CountSelectedTracks(0) - 1 do add(r.GetSelectedTrack(0, i)) end
  for i = 0, r.CountSelectedMediaItems(0) - 1 do add(r.GetMediaItem_Track(r.GetSelectedMediaItem(0, i))) end
  table.sort(list, track_order)
  return list
end

-- Separated pieces and review flags in the project, rescanned when the project changes.
local scan_cache = { state = -1, at = 0, data = { tagged = 0, flagged = {} } }

local function project_scan()
  local t = now()
  if t >= scan_cache.at then
    scan_cache.at = t + 0.5
    local sc = r.GetProjectStateChangeCount(0)
    if sc ~= scan_cache.state then
      scan_cache.state = sc
      scan_cache.data = E.scan()
    end
  end
  return scan_cache.data
end

local function refresh_scan() scan_cache.at, scan_cache.state = 0, -1 end

local function focus_slice(f)
  st.focus = f.sid .. ':' .. f.idx
  E.focus_slice(f.sid, f.idx, f.t)
end

----------------------------------------------------------------------------------------
-- Operations
----------------------------------------------------------------------------------------

local function do_separate()
  local an = st.an
  if not (an and an.done) or #st.hits == 0 then return set_msg('Analyze first: there are no hits to separate at.', COL.err) end
  if st.separated and r.MB('These hits were already used to separate in this session.\n' ..
      'Separating again re-splits the same items. Continue?', 'Reap Detective', 1) ~= 1 then return end
  local tracks = target_tracks()
  local trim = cfg.trim_ms / 1000
  local slices, dropped = core.split_plan(st.hits, cfg.pad_ms / 1000, trim + 0.002, an.rs, an.re)
  local s = E.separate(tracks, slices, an.rs, an.re, trim)
  st.separated = true
  refresh_scan()
  local extra = ''
  if dropped > 0 then extra = extra .. (' %d hit(s) too close together were skipped.'):format(dropped) end
  if s.stretch > 0 then extra = extra .. (' %d item(s) have stretch markers: check them.'):format(s.stretch) end
  if s.skipped > 0 then extra = extra .. (' %d MIDI/empty/hidden-lane item(s) skipped.'):format(s.skipped) end
  set_msg(('Separated %d item(s) on %d track(s) into %d pieces at %d hits.%s Next: Quantize.')
    :format(s.items, #tracks, s.pieces, #slices, extra), dropped + s.stretch > 0 and COL.warn or COL.ok)
end

local function do_quantize()
  local s = E.quantize(cfg)
  if s.slices == 0 then return set_msg('No separated slices found. Run Separate first.', COL.err) end
  refresh_scan()
  set_msg(('Quantized %d of %d %sslices; %d flagged for review%s%s.')
    :format(s.moved, s.slices, s.scoped and 'selected ' or '', s.flagged,
      s.collisions > 0 and (', %d of them landing on the same grid line as a neighbor'):format(s.collisions) or '',
      s.flagged > 0 and not cfg.move_flagged and ', left in place' or ''),
    s.flagged > 0 and COL.warn or COL.ok)
end

local function do_smooth()
  local s = E.smooth(cfg)
  if s.joins + s.skipped == 0 then return set_msg('No separated slices found to smooth.', COL.err) end
  refresh_scan()
  set_msg(('Smoothed %d %sboundaries; %d flagged where a double hit could not be avoided%s.')
    :format(s.joins, s.scoped and 'selected ' or '', s.flagged,
      s.skipped > 0 and (', %d skipped (slices overlap too far)'):format(s.skipped) or ''),
    (s.flagged + s.skipped) > 0 and COL.warn or COL.ok)
end

----------------------------------------------------------------------------------------
-- Hit editing helpers
----------------------------------------------------------------------------------------

local function first_at_or_after(t)
  local lo, hi = 1, #st.hits
  while lo <= hi do
    local mid = (lo + hi) // 2
    if st.hits[mid].t < t then lo = mid + 1 else hi = mid - 1 end
  end
  return lo
end

local function delete_hit(i)
  local h = st.hits[i]
  if not h then return end
  core.edit_delete(st.edits, h)
  local nxt = st.hits[i + 1]
  st.sel = nxt and nxt.key or nil
  rebuild()
end

local function nudge_hit(i, d)
  local h = st.hits[i]
  if not h then return end
  core.edit_move(st.edits, h, h.t + d)
  rebuild()
end

local function center_on(t)
  local span = st.view.t1 - st.view.t0
  st.view.t0 = t - span / 2
  st.view.t1 = t + span / 2
end

local function select_step(dir)
  if #st.hits == 0 then return end
  local i = st.sel and st.by_key[st.sel]
  if not i then
    i = first_at_or_after(r.GetCursorPosition() + (dir > 0 and 1e-4 or -1e-4))
    if dir < 0 then i = i - 1 end
  else
    i = i + dir
  end
  i = math.max(1, math.min(#st.hits, i))
  local h = st.hits[i]
  st.sel = h.key
  r.SetEditCurPos2(0, h.t, false, false)
  if h.t < st.view.t0 or h.t > st.view.t1 then center_on(h.t) end
end

local function fit_view()
  if not st.an then return end
  local pad = (st.an.re - st.an.rs) * 0.01
  st.view.t0, st.view.t1 = st.an.rs - pad, st.an.re + pad
end

local function zoom(at, factor)
  local v = st.view
  local span = (v.t1 - v.t0) * factor
  local full = st.an and (st.an.re - st.an.rs) * 1.5 or 60
  span = math.max(0.02, math.min(full, span))
  local frac = (at - v.t0) / (v.t1 - v.t0)
  v.t0 = at - frac * span
  v.t1 = v.t0 + span
end

local function scroll(dt)
  st.view.t0 = st.view.t0 + dt
  st.view.t1 = st.view.t1 + dt
end

----------------------------------------------------------------------------------------
-- Widgets bound to cfg
----------------------------------------------------------------------------------------

local tip = U.tip

local function set_cfg(key, v, on_change)
  cfg[key] = v
  cfg_changed()
  if on_change then on_change() end
end

-- Column layout (label left, control right): Quantize and Smooth settings.
local function slider(label, key, lo, hi, fmt, help, on_change)
  U.row(label, help)
  local rv, v = ImGui.SliderDouble(ctx, '##' .. key, cfg[key], lo, hi, fmt)
  if rv then set_cfg(key, v, on_change) end
  tip(help)
end

-- Toolbar layout ("Label [control]" groups that wrap): Detect and Separate.
local function tslider(label, key, lo, hi, fmt, width, help, on_change)
  U.inline(label, width, help)
  local rv, v = ImGui.SliderDouble(ctx, '##' .. key, cfg[key], lo, hi, fmt)
  if rv then set_cfg(key, v, on_change) end
  tip(help)
end

local function checkbox(label, key, help, on_change)
  local rv, v = ImGui.Checkbox(ctx, label, cfg[key])
  if rv then set_cfg(key, v, on_change) end
  tip(help)
end

-- cfg[key] is a 1-based index when one_based, else 0-based.
local function combo_value(key, items, one_based, help, on_change)
  local cur = one_based and cfg[key] - 1 or cfg[key]
  local rv, v = ImGui.Combo(ctx, '##' .. key, cur, items)
  if rv then set_cfg(key, one_based and v + 1 or v, on_change) end
  tip(help)
end

local function combo(label, key, items, one_based, help, on_change, width)
  U.row(label, help, width)
  combo_value(key, items, one_based, help, on_change)
end

local function tcombo(label, key, items, one_based, width, help, on_change)
  U.inline(label, width, help)
  combo_value(key, items, one_based, help, on_change)
end

local function labels(list)
  local t = {}
  for i, g in ipairs(list) do t[i] = g.label end
  return table.concat(t, '\0') .. '\0'
end

local SETTINGS_W = U.LABEL_W + U.CONTROL_W

-- Settings in a fixed column on the left, a list or notes stretching on the right.
local function begin_columns(id)
  if not ImGui.BeginTable(ctx, id, 2) then return false end
  ImGui.TableSetupColumn(ctx, 'settings', ImGui.TableColumnFlags_WidthFixed, SETTINGS_W + 40)
  ImGui.TableSetupColumn(ctx, 'list', ImGui.TableColumnFlags_WidthStretch)
  ImGui.TableNextColumn(ctx)
  return true
end

local function right_aligned(s, col)
  local w = ImGui.CalcTextSize(ctx, s)
  local avail = ImGui.GetContentRegionAvail(ctx)
  ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + math.max(0, avail - w))
  ImGui.TextColored(ctx, col, s)
end

local function join(names, sep, max)
  if #names <= max then return table.concat(names, sep) end
  local t = {}
  for i = 1, max do t[i] = names[i] end
  return table.concat(t, sep) .. ('  +%d more'):format(#names - max)
end

local function track_names(tracks)
  local t = {}
  for i, tr in ipairs(tracks) do t[i] = select(2, r.GetTrackName(tr)) end
  return t
end

local function same_tracks(a, b)
  if #a ~= #b then return false end
  local set = {}
  for _, kt in ipairs(b) do set[kt.track] = true end
  for _, tr in ipairs(a) do if not set[tr] then return false end end
  return true
end

local function bars(t) return fmt_bars(t):match('^[^.]+%.[^.]+') or fmt_bars(t) end


----------------------------------------------------------------------------------------
-- Hit view (Detect and Separate)
----------------------------------------------------------------------------------------

local HEAD_W = 184

local function draw_grid(dl, x0, y0, w, h, X)
  local v = st.view
  local qn0, qn1 = r.TimeMap2_timeToQN(0, v.t0), r.TimeMap2_timeToQN(0, v.t1)
  if qn1 <= qn0 then return end
  local px_per_qn = w / (qn1 - qn0)
  local step = S.grid_qn(cfg)
  while step * px_per_qn < 8 do step = step * 2 end
  local _, ms, me = r.TimeMap_QNToMeasures(0, qn0)
  local label_every = 1
  while (me - ms) * px_per_qn * label_every < 40 do label_every = label_every * 2 end
  local bar_i, guard = 0, 0
  while ms <= qn1 and guard < 4000 do
    guard = guard + 1
    local bar_px = (me - ms) * px_per_qn
    if bar_px >= 3 or bar_i % label_every == 0 then
      local q = ms
      while q < me - 1e-9 and q <= qn1 do
        if q >= qn0 - 1e-9 then
          local t = r.TimeMap2_QNToTime(0, q)
          local x = X(t)
          if q == ms then
            ImGui.DrawList_AddLine(dl, x, y0 + RULER_H, x, y0 + h, U.C.bar)
            if bar_i % label_every == 0 then
              ImGui.DrawList_AddLine(dl, x, y0 + RULER_H - 6, x, y0 + RULER_H, U.C.text3)
              ImGui.DrawList_AddText(dl, x + 4, y0 + 3, U.C.text3, fmt_bars(t):match('^(-?%d+)') or '')
            end
          else
            local on_beat = math.abs(q - math.floor(q + 0.5)) < 1e-6
            ImGui.DrawList_AddLine(dl, x, y0 + RULER_H, x, y0 + h, on_beat and U.C.beat or U.C.sub)
          end
        end
        if bar_px < 3 then break end
        q = q + step
      end
    end
    bar_i = bar_i + 1
    local nxt = me
    _, ms, me = r.TimeMap_QNToMeasures(0, nxt + 1e-6)
    if ms < nxt - 1e-6 then ms = nxt end
    if me <= ms then break end
  end
end

-- Envelope drawn mirrored around the lane's center line, on a 60 dB scale.
local function draw_lane(dl, kt, lx0, ly0, lw, lh)
  local env = kt.env
  local v = st.view
  local span_db = 60
  local floor_db = env.peak - span_db
  local spp = (v.t1 - v.t0) / lw
  local bpp = spp / env.hop
  local L = 1
  while L < #env.mip and (1 << L) <= bpp do L = L + 1 end
  local m, sz, scale = env.mip[L], env.sizes[L], 1 << (L - 1)
  local col = kt.enabled and U.C.wave or U.C.wave_off
  local cy = ly0 + lh / 2
  local amp = lh / 2 - 4
  for px = 0, math.floor(lw) - 1 do
    local ta = v.t0 + px * spp
    local ka = math.floor((ta - env.t0) / env.hop)
    local kb = math.floor((ta + spp - env.t0) / env.hop)
    if kb >= 0 and ka < env.n then
      local ia = math.max(1, ka // scale + 1)
      local ib = math.min(sz, math.max(ia, kb // scale + 1))
      local val = -1e9
      for i = ia, ib do
        local x = m[i]
        if x > val then val = x end
      end
      if val > floor_db then
        local a = (val - floor_db) / span_db * amp
        ImGui.DrawList_AddLine(dl, lx0 + px + 0.5, cy - a, lx0 + px + 0.5, cy + a + 1, col)
      end
    end
  end
  local thr = cfg.thr_db + kt.offset
  if kt.enabled and thr > -span_db then
    local a = (span_db + thr) / span_db * amp
    for x = lx0, lx0 + lw, 10 do
      local x2 = math.min(x + 5, lx0 + lw)
      ImGui.DrawList_AddLine(dl, x, cy - a, x2, cy - a, U.C.thr)
      ImGui.DrawList_AddLine(dl, x, cy + a, x2, cy + a, U.C.thr)
    end
  end
end

-- Track header on the left of each lane: enable, name, onset count, threshold offset.
local function draw_lane_header(dl, i, kt, x, y, lh)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + HEAD_W, y + lh, i % 2 == 0 and U.C.head_alt or U.C.head)
  ImGui.PushID(ctx, i)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 6, 2)
  local fh = ImGui.GetFrameHeight(ctx)
  local two_rows = lh >= fh * 2 + 14
  local top = two_rows and (y + (lh - fh * 2 - 4) / 2) or (y + (lh - fh) / 2)
  ImGui.SetCursorScreenPos(ctx, x + 8, top)
  local rv, v = ImGui.Checkbox(ctx, '##en', kt.enabled)
  if rv then kt.enabled = v; detect_soon() end
  tip('Use this track to find hits.')
  local pk = kt.env and kt.env.peak or core.SILENCE_DB
  local count = pk > -120 and tostring(kt.count) or 'no audio'
  local cw = ImGui.CalcTextSize(ctx, count)
  ImGui.SameLine(ctx, 0, 6)
  U.bold(function()
    U.text(U.truncate(kt.name, HEAD_W - 8 - fh - 6 - 6 - cw - 12), kt.enabled and U.C.text or U.C.text3)
  end)
  ImGui.SameLine(ctx, 0, 6)
  ImGui.TextColored(ctx, pk > -120 and U.C.text3 or U.C.err, count)
  if pk <= -120 then tip('Nothing could be read from this track in the range.\nIs it a folder or bus, or are its items muted or offline?') end
  if two_rows then
    ImGui.SetCursorScreenPos(ctx, x + 8, top + fh + 4)
    ImGui.SetNextItemWidth(ctx, HEAD_W - 16)
    rv, v = ImGui.DragDouble(ctx, '##off', kt.offset, 0.1, -30, 30, 'threshold %+.1f dB')
    if rv then kt.offset = v; detect_soon() end
    tip('Threshold offset for this track: drag sideways, or double-click to type.\nRaise it for tracks with lots of bleed (toms).')
  end
  ImGui.PopStyleVar(ctx)
  ImGui.PopID(ctx)
end

local key_map = nil

-- Keys the window uses itself; everything else is passed on to REAPER's shortcuts.
local function handle_view_keys()
  if not ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows) then return end
  if ImGui.IsAnyItemActive(ctx) then return end -- typing into a field, or dragging
  local consumed = {}
  local function pressed(key, rep)
    if ImGui.IsKeyPressed(ctx, key, rep) then consumed[key] = true; return true end
  end
  if st.an and st.an.done and st.tab <= 2 then
    local mods = ImGui.GetKeyMods(ctx)
    local shift = (mods & ImGui.Mod_Shift) ~= 0
    local alt = (mods & ImGui.Mod_Alt) ~= 0
    local i = st.sel and st.by_key[st.sel]
    if i then
      if pressed(ImGui.Key_Delete, false) or pressed(ImGui.Key_Backspace, false) then
        delete_hit(i)
        i = nil
      else
        local step = shift and 0.005 or (alt and 0.0001 or 0.001)
        if pressed(ImGui.Key_LeftArrow) then nudge_hit(i, -step) end
        if pressed(ImGui.Key_RightArrow) then nudge_hit(i, step) end
      end
    end
    if pressed(ImGui.Key_Tab) then select_step(shift and -1 or 1) end
    if pressed(ImGui.Key_F, false) then fit_view() end
  end
  key_map = key_map or K.build(ImGui, ctx)
  local ran = K.forward(ImGui, ctx, key_map, consumed)
  if ran then A.log('shortcut passed to REAPER: %s', ran) end
end

-- Centered block of lines (empty and loading states).
local function center_text(dl, x0, y0, w, h, lines)
  local lh = ImGui.GetTextLineHeightWithSpacing(ctx)
  local y = y0 + (h - #lines * lh) / 2
  for _, l in ipairs(lines) do
    local tw = ImGui.CalcTextSize(ctx, l[1])
    ImGui.DrawList_AddText(dl, x0 + (w - tw) / 2, y, l[2], l[1])
    y = y + lh + (l[3] or 0)
  end
end

-- Draws the hit view into the next `h` pixels; sets st.view_info for the status bar.
local function draw_view(h)
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  if w < HEAD_W + 100 then return end
  h = math.max(h, 180)
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, U.C.view_bg, 8)

  local an = st.an
  if not (an and an.done) then
    ImGui.InvisibleButton(ctx, '##view', w, h)
    if st.reading and an then
      center_text(dl, x0, y0, w, h, {
        { 'Reading audio', U.C.text },
        { ('%d%%'):format(math.floor(an.progress * 100 + 0.5)), U.C.text3 },
      })
    else
      center_text(dl, x0, y0, w, h, {
        { 'No analysis yet', U.C.text, 6 },
        { '1   Select the key tracks: kick, snare, toms', U.C.text2 },
        { '2   Make a time selection, or select their items', U.C.text2 },
        { '3   Press Analyze', U.C.text2 },
      })
    end
    return
  end

  local ntr = #an.tracks
  local lane_h = (h - RULER_H) / math.max(1, ntr)
  local cx0, cw = x0 + HEAD_W, w - HEAD_W

  -- track headers and the ruler corner
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + RULER_H, U.C.ruler, 8, U.K('DrawFlags_RoundCornersTop') or 0)
  for i, kt in ipairs(an.tracks) do
    draw_lane_header(dl, i, kt, x0, y0 + RULER_H + (i - 1) * lane_h, lane_h)
  end
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 6, 1)
  ImGui.SetCursorScreenPos(ctx, x0 + 4, y0 + 1)
  if U.tertiary('Fit') then fit_view() end
  tip('Show the whole analysis range (F)')
  ImGui.PopStyleVar(ctx)

  -- canvas
  ImGui.SetCursorScreenPos(ctx, cx0, y0)
  ImGui.InvisibleButton(ctx, '##view', cw, h,
    ImGui.ButtonFlags_MouseButtonLeft | ImGui.ButtonFlags_MouseButtonRight | ImGui.ButtonFlags_MouseButtonMiddle)
  local hovered, active = ImGui.IsItemHovered(ctx), ImGui.IsItemActive(ctx)
  local clicked_l = ImGui.IsItemClicked(ctx, ImGui.MouseButton_Left)
  local clicked_r = ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right)

  local v = st.view
  local pps = cw / (v.t1 - v.t0)
  local function X(t) return cx0 + (t - v.t0) * pps end
  local function T(x) return v.t0 + (x - cx0) / pps end
  local mx = ImGui.GetMousePos(ctx)
  local tm = T(mx)
  local mods = ImGui.GetKeyMods(ctx)
  local shift = (mods & ImGui.Mod_Shift) ~= 0
  local alt = (mods & ImGui.Mod_Alt) ~= 0

  ImGui.DrawList_PushClipRect(dl, cx0, y0, x0 + w, y0 + h, true)
  for i = 2, ntr, 2 do
    local ly = y0 + RULER_H + (i - 1) * lane_h
    ImGui.DrawList_AddRectFilled(dl, cx0, ly, x0 + w, ly + lane_h, U.C.lane_alt)
  end
  draw_grid(dl, cx0, y0, cw, h, X)
  for i, kt in ipairs(an.tracks) do
    if kt.env then draw_lane(dl, kt, cx0, y0 + RULER_H + (i - 1) * lane_h, cw, lane_h) end
  end

  -- outside the analysis range
  if v.t0 < an.rs then ImGui.DrawList_AddRectFilled(dl, cx0, y0 + RULER_H, X(an.rs), y0 + h, U.C.out_range) end
  if v.t1 > an.re then ImGui.DrawList_AddRectFilled(dl, X(an.re), y0 + RULER_H, x0 + w, y0 + h, U.C.out_range) end

  -- hits
  local pad = cfg.pad_ms / 1000
  local first = first_at_or_after(v.t0 - pad - 0.01)
  local last = first_at_or_after(v.t1 + 0.01) - 1
  local dense = (last - first + 1) > cw / 4
  local hov_i, hov_d = nil, 6
  for i = first, last do
    local d = math.abs(mx - X(st.hits[i].t))
    if hovered and d < hov_d then hov_i, hov_d = i, d end
  end
  for i = first, last do
    local h_ = st.hits[i]
    local x = X(h_.t)
    local sel, hov = h_.key == st.sel, i == hov_i
    local col = (sel or hov) and U.C.hit_sel or U.C.hit
    if not dense and pad * pps > 3 then
      local xp = X(h_.t - pad)
      ImGui.DrawList_AddLine(dl, xp, y0 + RULER_H, xp, y0 + h, U.C.pad)
    end
    ImGui.DrawList_AddLine(dl, x, y0 + RULER_H - 6, x, y0 + h, col, (sel or hov) and 2 or 1)
    if not dense or sel or hov then
      local s = (sel or hov) and 6 or 4
      ImGui.DrawList_AddTriangleFilled(dl, x - s, y0 + RULER_H - 2 - s, x + s, y0 + RULER_H - 2 - s, x, y0 + RULER_H - 2, col)
      if math.abs(h_.a - h_.t) > 1e-5 then
        local xa = X(h_.a)
        ImGui.DrawList_AddTriangleFilled(dl, xa - 4, y0 + RULER_H, xa + 4, y0 + RULER_H, xa, y0 + RULER_H + 7, U.C.anchor)
      end
    end
  end

  -- REAPER cursors
  local ec = r.GetCursorPosition()
  if ec >= v.t0 and ec <= v.t1 then ImGui.DrawList_AddLine(dl, X(ec), y0, X(ec), y0 + h, U.C.edit_cur) end
  if (r.GetPlayState() & 1) == 1 then
    local pp = r.GetPlayPosition()
    if pp >= v.t0 and pp <= v.t1 then
      ImGui.DrawList_AddLine(dl, X(pp), y0, X(pp), y0 + h, U.C.play_cur, 2)
    elseif not st.mouse_down and pp > v.t1 and pp < v.t1 + (v.t1 - v.t0) then
      scroll(v.t1 - v.t0) -- page along with playback
    end
  end
  ImGui.DrawList_PopClipRect(dl)

  -- mouse
  if hovered then
    if hov_i then ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_ResizeEW) end
    local wheel, hwheel = ImGui.GetMouseWheel(ctx)
    if wheel ~= 0 then
      if shift then scroll(-wheel * (v.t1 - v.t0) * 0.1) else zoom(tm, 0.85 ^ wheel) end
    end
    if hwheel ~= 0 then scroll(hwheel * (v.t1 - v.t0) * 0.1) end
  end

  local dbl = hovered and ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left)
  if dbl and not hov_i and tm >= an.rs and tm <= an.re then
    st.sel = core.edit_add(st.edits, tm)
    rebuild()
  elseif clicked_l then
    if hov_i and alt then
      delete_hit(hov_i)
    elseif hov_i then
      local h_ = st.hits[hov_i]
      st.sel = h_.key
      st.drag = { key = h_.key, grab = h_.t - tm }
      r.SetEditCurPos2(0, h_.t, false, false)
    else
      st.sel = nil
      r.SetEditCurPos2(0, tm, false, false)
    end
  end
  if clicked_r and hov_i then delete_hit(hov_i) end

  if st.drag then
    if ImGui.IsMouseDown(ctx, ImGui.MouseButton_Left) then
      if ImGui.IsMouseDragging(ctx, ImGui.MouseButton_Left, 3) then
        local i = st.by_key[st.drag.key]
        local h_ = i and st.hits[i]
        local new_t = tm + st.drag.grab
        if h_ and math.abs(new_t - h_.t) > 1e-7 then
          core.edit_move(st.edits, h_, new_t)
          rebuild()
        end
      end
    else
      st.drag = nil
    end
  end

  if active and ImGui.IsMouseDragging(ctx, ImGui.MouseButton_Middle, 0) then
    local dx = ImGui.GetMouseDelta(ctx)
    scroll(-dx / pps)
  end

  if hovered then
    local info = ('%s  ·  %s'):format(fmt_bars(tm), fmt_pos(tm))
    if hov_i then
      local h_ = st.hits[hov_i]
      local anchored = ''
      if (h_.n or 1) > 1 and h_.anchor_tr and st.an.tracks[h_.anchor_tr] then
        anchored = (', %d onsets, on the grid: %s'):format(h_.n, st.an.tracks[h_.anchor_tr].name)
      end
      info = ('hit %d of %d  ·  %s%s  ·  '):format(hov_i, #st.hits, h_.kind, anchored) .. info
    end
    st.view_info = info
  end
end

-- The view takes whatever height is left in the step.
local function fill_with_view()
  ImGui.Dummy(ctx, 0, U.SP.xs)
  local _, h = ImGui.GetContentRegionAvail(ctx)
  draw_view(h)
end

----------------------------------------------------------------------------------------
-- Steps
----------------------------------------------------------------------------------------

local MOD = (r.GetOS():find('OSX') or r.GetOS():find('mac')) and 'Option' or 'Alt'

-- Key tracks: enable, threshold offset, peak, onsets (when the waveform view is hidden).
local function key_track_table()
  U.section('Key tracks', true)
  if not (st.an and st.an.done) then
    U.hint('Key tracks are the close mics that define the hits: kick, snare, toms. ' ..
      'Select them (or their items), make a time selection, then press Analyze.')
    return
  end
  if not ImGui.BeginTable(ctx, '##keys', 4) then return end
  ImGui.TableSetupColumn(ctx, 'Track', ImGui.TableColumnFlags_WidthStretch)
  ImGui.TableSetupColumn(ctx, 'Threshold offset', ImGui.TableColumnFlags_WidthFixed, 140)
  ImGui.TableSetupColumn(ctx, 'Peak', ImGui.TableColumnFlags_WidthFixed, 60)
  ImGui.TableSetupColumn(ctx, 'Onsets', ImGui.TableColumnFlags_WidthFixed, 56)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, U.C.text3)
  ImGui.TableHeadersRow(ctx)
  ImGui.PopStyleColor(ctx)
  for i, kt in ipairs(st.an.tracks) do
    ImGui.PushID(ctx, i)
    ImGui.TableNextRow(ctx)
    ImGui.TableNextColumn(ctx)
    if not kt.enabled then ImGui.PushStyleColor(ctx, ImGui.Col_Text, U.C.text3) end
    local rv, v = ImGui.Checkbox(ctx, kt.name .. '##on', kt.enabled)
    if not kt.enabled then ImGui.PopStyleColor(ctx) end
    if rv then kt.enabled = v; detect_soon() end
    ImGui.TableNextColumn(ctx)
    ImGui.SetNextItemWidth(ctx, -1)
    rv, v = ImGui.DragDouble(ctx, '##off', kt.offset, 0.1, -30, 30, '%+.1f dB')
    if rv then kt.offset = v; detect_soon() end
    tip('Threshold offset for this track: drag sideways, or double-click to type.\nRaise it for tracks with lots of bleed (toms).')
    ImGui.TableNextColumn(ctx)
    ImGui.AlignTextToFramePadding(ctx)
    local pk = kt.env and kt.env.peak or core.SILENCE_DB
    if pk > -120 then
      right_aligned(('%.1f'):format(pk), U.C.text2)
    else
      right_aligned('no audio', U.C.err)
      tip('Nothing could be read from this track in the range.\nIs it a folder or bus, or are its items muted or offline?')
    end
    ImGui.TableNextColumn(ctx)
    ImGui.AlignTextToFramePadding(ctx)
    right_aligned(tostring(kt.count), U.C.text)
    ImGui.PopID(ctx)
  end
  ImGui.EndTable(ctx)
end

-- How to edit hits in the arrange view.
local function arrange_guide()
  U.section('Edit hits in the arrange view', true)
  if cfg.arrange_view ~= 1 or not AR.available then
    U.hint(AR.available and 'Set "In arrange" to Lines to see and edit the hits on your tracks.'
      or 'Install js_ReaScriptAPI (ReaPack) to see and edit the hits on your tracks.')
    return
  end
  for _, row in ipairs({
    { 'Drag a line', 'move a hit' },
    { MOD .. '-click a line', 'delete it' },
    { MOD .. '-click elsewhere', 'add a hit' },
  }) do
    U.text(row[1])
    ImGui.SameLine(ctx, 150)
    U.text2(row[2])
  end
  ImGui.Dummy(ctx, 0, U.SP.xs)
  U.hint('Lines show on every track Separate will cut. Elsewhere, the mouse works as usual.')
end

-- Track priority for the "Track priority" anchor: a button showing the top track, and a
-- popup to reorder the key tracks. The order is saved with the project.
local function priority_button()
  local list = st.an and A.by_priority(st.an) or {}
  local label = #list > 0 and ('Priority: %s'):format(U.truncate(list[1].name, 110)) or 'Priority'
  U.flow(ImGui.CalcTextSize(ctx, label) + 24)
  ImGui.BeginDisabled(ctx, #list == 0)
  if U.secondary(label .. '##prio') then ImGui.OpenPopup(ctx, 'priority') end
  ImGui.EndDisabled(ctx)
  if #list > 0 then
    local names = {}
    for i, kt in ipairs(list) do names[i] = kt.name end
    tip('Order: ' .. table.concat(names, '  >  ') .. '\nClick to change it.')
  else
    tip('Analyze first to set the priority of the key tracks.')
  end
  if ImGui.BeginPopup(ctx, 'priority') then
    U.section('Track priority', true)
    U.text3('Highest first. In a merged hit, the onset from the')
    U.text3('highest track lands on the grid.')
    ImGui.Dummy(ctx, 0, U.SP.xs)
    for i, kt in ipairs(list) do
      ImGui.PushID(ctx, kt.guid)
      ImGui.AlignTextToFramePadding(ctx)
      U.text3(tostring(i))
      ImGui.SameLine(ctx, 28)
      U.text(U.truncate(kt.name, 170), kt.enabled and U.C.text or U.C.text3)
      ImGui.SameLine(ctx, 212)
      for _, b in ipairs({ { '▲', -1, i == 1 }, { '▼', 1, i == #list } }) do
        if b[2] > 0 then ImGui.SameLine(ctx) end
        ImGui.BeginDisabled(ctx, b[3])
        if ImGui.Button(ctx, b[1], 28) then
          local guids = A.move_priority(st.an, kt, b[2])
          r.SetProjExtState(0, 'ReapDetective', 'priority', table.concat(guids, ' '))
          run_detection()
        end
        ImGui.EndDisabled(ctx)
      end
      ImGui.PopID(ctx)
    end
    ImGui.EndPopup(ctx)
  end
end

local function tab_detect()
  local cand = selected_key_tracks()
  local differs = #cand > 0 and not (st.an and same_tracks(cand, st.an.tracks))
  U.flow_begin()
  U.flow(128)
  local label = st.an and 'Re-analyze' or 'Analyze'
  local pressed
  if not st.an or differs then pressed = U.primary(label, 128) else pressed = U.secondary(label, 128) end
  if pressed then start_analysis() end
  tip('Analyze the selected tracks (plus tracks of selected items) over the time\n' ..
    'selection, or over the selected items when there is no time selection.')
  tslider('Threshold', 'thr_db', -60, 0, '%.1f dB', 140,
    'Ignore anything quieter than this, relative to each key track\'s loudest\npeak. Shown as the dashed lines in each lane.', detect_soon)
  tslider('Sensitivity', 'sens_db', 1, 30, '%.1f dB', 140,
    'How sharply the level must jump (within 5 ms) to count as a hit.\nLower finds ghost notes; higher keeps only strong attacks.', detect_soon)
  tslider('Retrigger', 'retrig_ms', 0, 150, '%.0f ms', 120,
    'Flam window: onsets closer than this become one hit, on the same track and across\nkey tracks (kick and snare played slightly apart). The split goes before the first.', detect_soon)
  tcombo('Anchor', 'anchor', 'First onset\0Loudest onset\0Track priority\0', false, 136,
    'Which onset of a merged hit lands on the grid when quantizing (the cut always\n' ..
    'goes before the first onset):\n' ..
    '  First onset: the earliest one.\n' ..
    '  Loudest onset: the main stroke of a flam.\n' ..
    '  Track priority: the onset from the highest-priority track, e.g. snare over kick\n' ..
    '  when the drummer flams them; the loudest one if that track has several.\n' ..
    'Set this before Separate: each slice keeps the anchor it was separated with.', detect_soon)
  if cfg.anchor == 2 then priority_button() end
  tcombo('In arrange', 'arrange_view', O.available and 'Off\0Lines\0Markers\0'
    or 'Off\0Lines (needs js_ReaScriptAPI)\0Markers\0', false, 104,
    'Show the hits in REAPER\'s arrange view. Lines cover every track Separate will cut\n' ..
    'while Detect or Separate is open, and can be edited with the mouse there.\n' ..
    'Markers are added as "RD" project markers (display only).', function()
      if cfg.arrange_view ~= 2 and st.markers_shown then E.clear_markers(); st.markers_shown = false end
      if cfg.arrange_view == 2 then st.markers_due = now() end
    end)
  U.flow(ImGui.CalcTextSize(ctx, 'Waveforms here') + 40)
  checkbox('Waveforms here', 'window_view', 'Also show each key track\'s waveform with its hits in this window.')

  if differs then
    local list = join(track_names(cand), ', ', 5)
    U.text3(st.an and ('Selection changed (%s). Re-analyze to use it.'):format(list)
      or ('Will analyze: %s'):format(list))
  end
  local ne = core.edit_count(st.edits)
  if ne > 0 then
    U.text3(('%d manual edit%s'):format(ne, ne == 1 and '' or 's'))
    ImGui.SameLine(ctx)
    if U.tertiary('Clear') then st.edits = core.new_edits(); rebuild() end
  end
  if cfg.window_view then return fill_with_view() end
  ImGui.Dummy(ctx, 0, U.SP.sm)
  if not ImGui.BeginTable(ctx, '##detect_body', 2) then return end
  ImGui.TableSetupColumn(ctx, 'tracks', ImGui.TableColumnFlags_WidthStretch)
  ImGui.TableSetupColumn(ctx, 'guide', ImGui.TableColumnFlags_WidthFixed, 330)
  ImGui.TableNextColumn(ctx)
  key_track_table()
  ImGui.TableNextColumn(ctx)
  arrange_guide()
  ImGui.EndTable(ctx)
end

local function track_chip(dl, name, is_key)
  local tw = ImGui.CalcTextSize(ctx, name)
  U.flow(tw + 14)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  U.dot(dl, x + 4, y + ImGui.GetTextLineHeight(ctx) / 2 + 1, is_key and U.C.hit or U.C.text3, 3)
  ImGui.SetCursorScreenPos(ctx, x + 12, y)
  ImGui.TextColored(ctx, is_key and U.C.text or U.C.text2, name)
end

local function tab_separate()
  local tracks = target_tracks()
  local ready = st.an and st.an.done and #st.hits > 0
  U.flow_begin()
  tslider('Trigger pad', 'pad_ms', 0, 30, '%.1f ms', 130, 'Split this far before each hit, so the attack is never cut.')
  tslider('Tail trim', 'trim_ms', 0, 60, '%.1f ms', 130,
    'Shorten every slice\'s tail by this much, leaving room to move slices\nwithout overlapping. Smooth fills the gaps later.')
  local label = ('Separate %d track%s'):format(#tracks, #tracks == 1 and '' or 's')
  U.flow(ImGui.CalcTextSize(ctx, label) + 40)
  ImGui.BeginDisabled(ctx, not ready)
  if U.primary(label, ImGui.CalcTextSize(ctx, label) + 40) then do_separate() end
  ImGui.EndDisabled(ctx)
  U.tip(ready and ('Cuts at %d hits, %.1f ms before each one.'):format(#st.hits, cfg.pad_ms) or 'Analyze first (step 1).')

  if not E.grouping_enabled() then
    if U.callout(U.C.warn, 'Item grouping is off, so slices won\'t move together when you nudge them.', 'Turn grouping on') then
      E.enable_grouping()
    end
  end
  if E.ripple_on() then U.callout(U.C.warn, 'Ripple editing is on. Turn it off before nudging slices.') end

  local dl = ImGui.GetWindowDrawList(ctx)
  local keys = {}
  if st.an then for _, kt in ipairs(st.an.tracks) do keys[kt.track] = true end end
  U.flow_begin()
  U.flow(0)
  ImGui.TextColored(ctx, U.C.text3, 'Cuts')
  for i, name in ipairs(track_names(tracks)) do track_chip(dl, name, keys[tracks[i]]) end
  U.flow(200)
  U.text3('· select tracks or items to add more')
  if cfg.window_view then fill_with_view() end
end

-- Clickable list of flagged slices whose flags match `pattern`.
local function flagged_list(id, title, pattern, empty)
  local list = {}
  for _, f in ipairs(project_scan().flagged) do
    if f.kinds:find(pattern) then list[#list + 1] = f end
  end
  U.section(('%s  ·  %d'):format(title, #list), true)
  ImGui.BeginDisabled(ctx, #list == 0)
  for _, b in ipairs({ { 'Previous', -1 }, { 'Next', 1 } }) do
    if b[2] > 0 then ImGui.SameLine(ctx) end
    if U.secondary(b[1]) then
      local f = E.goto_flagged(b[2], pattern)
      if f then st.focus = f.sid .. ':' .. f.idx
      else set_msg(('Nothing flagged %s the edit cursor.'):format(b[2] < 0 and 'before' or 'after')) end
    end
  end
  ImGui.EndDisabled(ctx)
  ImGui.SameLine(ctx)
  if U.tertiary('Clear flags') then
    set_msg(('Cleared the flags on %d item(s).'):format(E.clear_flags()))
    refresh_scan()
  end
  if #list == 0 then
    U.hint(empty)
    return
  end
  local _, avail_h = ImGui.GetContentRegionAvail(ctx)
  local flags = ImGui.TableFlags_ScrollY | ImGui.TableFlags_RowBg
  if ImGui.BeginTable(ctx, id, 3, flags, 0, math.max(160, avail_h - 4)) then
    ImGui.TableSetupScrollFreeze(ctx, 0, 1)
    ImGui.TableSetupColumn(ctx, 'Position', ImGui.TableColumnFlags_WidthFixed, 96)
    ImGui.TableSetupColumn(ctx, 'Issue', ImGui.TableColumnFlags_WidthStretch)
    ImGui.TableSetupColumn(ctx, 'Tracks', ImGui.TableColumnFlags_WidthFixed, 52)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, U.C.text3)
    ImGui.TableHeadersRow(ctx)
    ImGui.PopStyleColor(ctx)
    for i, f in ipairs(list) do
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      if ImGui.Selectable(ctx, bars(f.t) .. '##' .. i, st.focus == f.sid .. ':' .. f.idx,
          ImGui.SelectableFlags_SpanAllColumns) then
        focus_slice(f)
      end
      tip('Select this slice on every track and move the edit cursor to it.')
      ImGui.TableNextColumn(ctx)
      ImGui.TextColored(ctx, f.kinds:find('[qc]') and U.C.err or U.C.warn, E.reasons(f.kinds))
      ImGui.TableNextColumn(ctx)
      right_aligned(tostring(f.tracks), U.C.text3)
    end
    ImGui.EndTable(ctx)
  end
end

local function tab_quantize()
  if not begin_columns('##q') then return end
  U.section('Grid', true)
  ImGui.BeginDisabled(ctx, cfg.use_proj_grid)
  combo('Grid', 'grid', labels(S.GRIDS), true, nil, nil, 90)
  ImGui.SameLine(ctx)
  checkbox('Triplet', 'triplet')
  ImGui.EndDisabled(ctx)
  U.row_blank()
  checkbox('Use project grid', 'use_proj_grid')
  slider('Strength', 'strength', 0, 100, '%.0f %%', '100% snaps to the grid; lower values move hits part of the way.')
  slider('Exclude within', 'exclude_ms', 0, 20, '%.1f ms', 'Hits already this close to the grid are left alone.')
  U.section('Review')
  combo('Flag if move >', 'max_move', labels(S.MAX_MOVES), true,
    'Slices that would move further than this stay put and turn red.\n' ..
    'Two slices landing on the same grid line are always flagged.')
  local mm = S.MAX_MOVES[cfg.max_move]
  if mm and mm.qn and mm.qn >= S.grid_qn(cfg) / 2 - 1e-9 then
    U.callout(U.C.warn, 'No hit is ever this far from its nearest grid line, so only collisions get flagged. Try 1/48 or 1/64.')
  end
  U.row_blank()
  checkbox('Move flagged slices anyway', 'move_flagged', 'Off: flagged slices stay where they are (just colored).')
  ImGui.Dummy(ctx, 0, U.SP.sm)
  if U.primary('Quantize slices', SETTINGS_W) then do_quantize() end
  U.hint('Uses the slices of the selected items, or every slice when no separated item is selected. ' ..
    'All tracks of a slice move together.')

  ImGui.TableNextColumn(ctx)
  flagged_list('##qflags', 'Flagged', '[qc]',
    'Nothing flagged. Quantize checks every slice against the limit and its neighbors; ' ..
    'flagged slices are listed here and marked with red lines in the arrange view.')
  ImGui.EndTable(ctx)
end

local function tab_smooth()
  if not begin_columns('##sm') then return end
  U.section('Gaps', true)
  U.label('Mode')
  local pick = U.segmented({ 'Fill gaps', 'Fill + crossfade' }, cfg.xfade and 2 or 1)
  if pick then set_cfg('xfade', pick == 2) end
  U.section('Crossfade')
  ImGui.BeginDisabled(ctx, not cfg.xfade)
  slider('Length', 'xfade_ms', 0.5, 50, '%.1f ms')
  combo('Shape', 'fade_shape', S.FADE_SHAPE_LABELS, false,
    'REAPER\'s crossfade shapes. Equal power keeps the level steady across audio\n' ..
    'that isn\'t phase-aligned; linear (equal gain) suits identical audio.')
  combo('Position', 'fade_mode', S.FADE_MODE_LABELS, true,
    'Where the crossfade sits relative to the start of the next slice.\n' ..
    '"Before slice start" keeps it entirely in front of the trigger pad.')
  ImGui.EndDisabled(ctx)
  U.row_blank()
  checkbox('Avoid double hits', 'smart_fill',
    'Fill each gap from the earlier slice only as far as its audio is clean; cover the\n' ..
    'rest with the next slice\'s pre-attack audio, so no transient plays twice.')
  local mode = S.FADE_MODES[cfg.fade_mode]
  local after = cfg.xfade and ((mode == 'post' and cfg.xfade_ms) or (mode == 'center' and cfg.xfade_ms / 2) or 0) or 0
  if after > cfg.pad_ms then
    U.callout(U.C.warn, ('The fade reaches %.1f ms into the slice but the pad is %.1f ms.'):format(after, cfg.pad_ms))
  end
  ImGui.Dummy(ctx, 0, U.SP.sm)
  if U.primary('Smooth', SETTINGS_W) then do_smooth() end
  U.hint('Run after quantizing and nudging. Closes every gap and crossfades it, on the selected ' ..
    'slices and their neighbors or on everything. Safe to run again.')

  ImGui.TableNextColumn(ctx)
  flagged_list('##sflags', 'Double-hit risks', 's',
    'Nothing flagged. When a gap can only be filled with audio that contains a hit, Smooth ' ..
    'lists that boundary here and marks it with an orange line in the arrange view.')
  ImGui.EndTable(ctx)
end

----------------------------------------------------------------------------------------
-- Window: step tabs + status bar
----------------------------------------------------------------------------------------

local HELP = 'Arrange view (Detect and Separate)\n' ..
  '  Drag a hit line            move the hit\n' ..
  '  ' .. MOD .. '-click a line        delete it\n' ..
  '  ' .. MOD .. '-click elsewhere     add a hit\n\n' ..
  'Waveform view in this window\n' ..
  '  Double-click            add a hit\n' ..
  '  Drag                    move a hit\n' ..
  '  Alt-click, right-click  delete a hit\n' ..
  '  Arrows                  nudge the selected hit (Shift 5 ms, Alt 0.1 ms)\n' ..
  '  Tab / Shift-Tab         next / previous hit\n' ..
  '  Wheel / Shift-wheel     zoom / scroll        F  fit\n\n' ..
  'Everything else goes to REAPER\'s own shortcuts (Space, Cmd+Z ...).'

local TABS = {
  { name = 'Detect', fn = tab_detect, view = true }, { name = 'Separate', fn = tab_separate, view = true },
  { name = 'Quantize', fn = tab_quantize }, { name = 'Smooth', fn = tab_smooth },
}

local function draw_steps(status_h)
  local scan = project_scan()
  local done = { st.an and st.an.done, scan.tagged > 0 }
  -- session summary, right-aligned on the tab row
  if st.an and st.an.done then
    local s = ('%d hits  ·  bars %s – %s'):format(#st.hits, bars(st.an.rs), bars(st.an.re))
    local x, y = ImGui.GetCursorScreenPos(ctx)
    local aw = ImGui.GetContentRegionAvail(ctx)
    local tw = ImGui.CalcTextSize(ctx, s)
    if aw > tw + 480 then ImGui.DrawList_AddText(ImGui.GetWindowDrawList(ctx), x + aw - tw, y + 5, U.C.text3, s) end
  end
  if not ImGui.BeginTabBar(ctx, '##steps') then return end
  for ti, t in ipairs(TABS) do
    local label = (done[ti] and '✓  ' or (ti .. '   ')) .. t.name .. '##step' .. ti
    if done[ti] then ImGui.PushStyleColor(ctx, ImGui.Col_Text, U.C.ok) end
    local open = ImGui.BeginTabItem(ctx, label)
    if done[ti] then ImGui.PopStyleColor(ctx) end
    if open then
      st.tab = ti
      local _, h = ImGui.GetContentRegionAvail(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, 0x00000000)
      local visible = ImGui.BeginChild(ctx, '##step', 0, h - status_h, 0,
        t.view and ImGui.WindowFlags_NoScrollWithMouse or 0)
      ImGui.PopStyleColor(ctx)
      if visible then
        ImGui.Dummy(ctx, 0, U.SP.xs)
        t.fn()
        ImGui.EndChild(ctx)
      end
      ImGui.EndTabItem(ctx)
    end
  end
  ImGui.EndTabBar(ctx)
end

local function draw_status()
  local dl = ImGui.GetWindowDrawList(ctx)
  local win_w = ImGui.GetWindowWidth(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local neutral = st.msg_col == U.C.text3
  U.dot(dl, x + 4, y + ImGui.GetTextLineHeight(ctx) / 2 + 1, st.msg_col, 3.5)
  local info = st.view_info
  local right_w = (info and ImGui.CalcTextSize(ctx, info) + 24 or 0) + 32
  ImGui.Indent(ctx, 16)
  ImGui.TextColored(ctx, neutral and U.C.text2 or st.msg_col, U.truncate(st.msg, win_w - right_w - 48))
  ImGui.Unindent(ctx, 16)
  if info then
    ImGui.SameLine(ctx, win_w - right_w - 8)
    U.text3(info)
  end
  ImGui.SameLine(ctx, win_w - 32)
  U.text3('?')
  tip(HELP)
end

-- What the window edits from the arrange view (see arrange.lua).
local arrange_ops = {
  select = function(h)
    st.sel = h.key
    r.SetEditCurPos2(0, h.t, false, false)
  end,
  move = function(key, t)
    local i = st.by_key[key]
    if i and math.abs(st.hits[i].t - t) > 1e-7 then
      core.edit_move(st.edits, st.hits[i], t)
      rebuild()
    end
  end,
  delete = function(h)
    core.edit_delete(st.edits, h)
    if st.sel == h.key then st.sel = nil end
    rebuild()
  end,
  add = function(t)
    st.sel = core.edit_add(st.edits, t)
    rebuild()
  end,
}

local FLAG_PATTERN = { nil, nil, '[qc]', 's' }

-- Arrange view: hit lines (editable with the mouse) while detecting/separating, flagged
-- slices while quantizing/smoothing, nothing otherwise.
local function update_arrange(t)
  local lines_mode = cfg.arrange_view == 1 and O.available and st.an and st.an.done and st.tab <= 2
  local flags_mode = cfg.arrange_view ~= 0 and O.available and st.tab >= 3
  if not lines_mode then AR.release() end
  if lines_mode then
    if t >= st.line_tracks_at then
      st.line_tracks, st.line_tracks_at = target_tracks(), t + 0.25
    end
    local hover, ghost
    if AR.available then
      arrange_ops.rs, arrange_ops.re = st.an.rs, st.an.re
      hover, ghost = AR.update(st.hits, st.line_tracks, arrange_ops)
    end
    local pad = cfg.pad_ms / 1000
    local key = ('%d|%s|%s|%s|%.4f'):format(st.hits_version, tostring(hover or st.sel),
      ghost and ('%.4f'):format(ghost) or '', st.line_tracks_at, pad)
    if key ~= st.lines_key then
      st.lines = O.hit_lines(st.hits, pad, hover or st.sel, ghost)
      st.lines_key = key
    end
    O.update(st.lines, st.line_tracks, key)
    st.lines_shown = true
  elseif flags_mode then
    local scan = project_scan()
    local pattern = FLAG_PATTERN[st.tab]
    local key = ('flags|%d|%d|%s'):format(scan_cache.state, st.tab, tostring(st.focus))
    if key ~= st.lines_key then
      local lines = {}
      for _, f in ipairs(scan.flagged) do
        if f.kinds:find(pattern) then
          local focused = st.focus == f.sid .. ':' .. f.idx
          lines[#lines + 1] = { t = f.t, w = focused and 3 or 2,
            color = focused and O.COLORS.active or (st.tab == 3 and O.COLORS.flag or O.COLORS.risk) }
        end
      end
      st.lines, st.lines_key = lines, key
    end
    O.update(st.lines, scan.tracks, key)
    st.lines_shown = true
  elseif st.lines_shown then
    O.clear()
    st.lines_shown, st.lines_key = false, nil
  end
end

local function tick()
  local t = now()
  if st.reading then
    repeat
      local ok, res = xpcall(A.step, debug.traceback, st.an)
      if not ok then
        A.log('analysis error: %s', tostring(res))
        set_msg('Analysis failed: ' .. tostring(res):match('^[^\n]*'), COL.err)
        st.reading = false
        break
      end
      if res then
        st.reading = false
        run_detection()
        set_msg(('Found %d hits. Tune detection, fix hits in the view, then go to Separate.'):format(#st.hits), COL.ok)
        break
      end
    until now() - t > 0.03
  end
  if st.detect_due and t >= st.detect_due then run_detection() end
  if st.markers_due and t >= st.markers_due and not st.mouse_down then
    st.markers_due = nil
    if cfg.arrange_view == 2 and st.an and st.an.done then
      E.write_markers(st.hits)
      st.markers_shown = true
    end
  end
  update_arrange(t)
  if st.cfg_due and t >= st.cfg_due then
    st.cfg_due = nil
    S.save(cfg)
  end
end

local function frame()
  U.push_theme()
  ImGui.SetNextWindowSize(ctx, 1080, 740, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, 'Reap Detective', true, ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoScrollWithMouse)
  if visible then
    local font = U.push_font(false)
    st.mouse_down = ImGui.IsMouseDown(ctx, ImGui.MouseButton_Left)
    st.view_info = nil
    draw_steps(ImGui.GetFrameHeightWithSpacing(ctx) + U.SP.xs)
    ImGui.Dummy(ctx, 0, U.SP.xs)
    draw_status()
    handle_view_keys()
    U.pop_font(font)
    ImGui.End(ctx)
  end
  U.pop_theme()
  tick()
  return open
end

local function cleanup()
  AR.release()
  if st.markers_shown then E.clear_markers() end
  if st.lines_shown then O.clear() end
  A.destroy(st.an)
  st.an = nil
end

local function loop()
  local ok, open = xpcall(frame, debug.traceback)
  if not ok then
    cleanup() -- never leave the arrange view's mouse captured
    A.log('error: %s', tostring(open))
    error(open, 0)
  end
  if open then r.defer(loop) end
end

r.atexit(function()
  S.save(cfg)
  cleanup()
end)

do
  local n = E.restore_legacy_colors()
  if n > 0 then
    set_msg(('Restored the original color of %d item(s) painted by an older version. ' ..
      'Flags now show in the Quantize and Smooth steps instead.'):format(n), COL.ok)
  end
end

r.defer(loop)
