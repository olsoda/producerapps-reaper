-- @noindex
-- Reap Detective: editing operations on REAPER items (separate, quantize, smooth, flags).
--
-- Everything is done through the item/take API, so REAPER's mouse-editing preferences
-- (auto-crossfade, trim content behind items, crossfade-on-split) never get in the way.
-- Each operation is a single undo point.

local core = require 'reapdetective.core'
local S = require 'reapdetective.settings'

local E = {}

E.TAG_KEY = 'P_EXT:ReapDetective'
E.FLAG_KEY = 'P_EXT:ReapDetective_flag'
E.MARKER_NAME = 'RD'
E.MARKER_BASE = 10000
-- review flags: q = quantize move too far, c = collides with a neighbor, s = smoothing double-hit risk
-- (FLAG_COLORS are only used to undo the item painting done by versions before 0.2)
E.FLAG_COLORS = { q = { 230, 50, 50 }, s = { 245, 150, 30 } }
E.FLAG_REASONS = { q = 'Moves too far', c = 'Same grid line as a neighbor', s = 'Double hit risk' }
E.EPS = 1e-6

local r = reaper

----------------------------------------------------------------------------------------
-- Item helpers
----------------------------------------------------------------------------------------

function E.get_tag(item)
  local ok, s = r.GetSetMediaItemInfo_String(item, E.TAG_KEY, '', false)
  if ok then return core.tag_decode(s) end
end

local function set_tag(item, tag)
  r.GetSetMediaItemInfo_String(item, E.TAG_KEY, core.tag_encode(tag), true)
end

local function item_bounds(item)
  local pos = r.GetMediaItemInfo_Value(item, 'D_POSITION')
  return pos, pos + r.GetMediaItemInfo_Value(item, 'D_LENGTH')
end

-- Timeline time of a source time (active take) on this item.
function E.tl(item, src)
  local take = r.GetActiveTake(item)
  local pos = r.GetMediaItemInfo_Value(item, 'D_POSITION')
  local offs = r.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
  local rate = r.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
  return pos + (src - offs) / rate
end

-- Timeline range the active take's source can cover (nil = unlimited, e.g. looped).
local function source_limits(item)
  if r.GetMediaItemInfo_Value(item, 'B_LOOPSRC') == 1 then return nil, nil end
  local take = r.GetActiveTake(item)
  local len, is_qn = r.GetMediaSourceLength(r.GetMediaItemTake_Source(take))
  if is_qn or not len or len <= 0 then return nil, nil end
  return E.tl(item, 0), E.tl(item, len)
end

-- Move an item's edges to [start, stop] on the timeline without moving its audio.
function E.set_bounds(item, start, stop)
  local pos = r.GetMediaItemInfo_Value(item, 'D_POSITION')
  local d = start - pos
  if d ~= 0 then
    for i = 0, r.CountTakes(item) - 1 do
      local tk = r.GetTake(item, i)
      if tk then
        local rate = r.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
        local offs = r.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS')
        r.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', offs + d * rate)
      end
    end
    r.SetMediaItemInfo_Value(item, 'D_POSITION', start)
  end
  r.SetMediaItemInfo_Value(item, 'D_LENGTH', stop - start)
end

-- shape: REAPER fade shape index (0 = linear/equal gain, 1 = slight convex/equal power, ...).
-- Uses the classic C_FADE*SHAPE/D_FADE*DIR parameters (REAPER 7.82 maps them as in 7.80).
local function set_fade(item, which, len, shape)
  r.SetMediaItemInfo_Value(item, 'D_FADE' .. which .. 'LEN', len)
  r.SetMediaItemInfo_Value(item, 'D_FADE' .. which .. 'LEN_AUTO', 0)
  if shape then
    r.SetMediaItemInfo_Value(item, 'C_FADE' .. which .. 'SHAPE', shape)
    r.SetMediaItemInfo_Value(item, 'D_FADE' .. which .. 'DIR', 0)
  end
end

local function next_group_id()
  local mx = 0
  for i = 0, r.CountMediaItems(0) - 1 do
    local g = r.GetMediaItemInfo_Value(r.GetMediaItem(0, i), 'I_GROUPID')
    if g > mx then mx = g end
  end
  return math.floor(mx) + 1
end

local function plays(track, item)
  if r.GetMediaTrackInfo_Value(track, 'I_FREEMODE') ~= 2 then return true end -- not fixed lanes
  return r.GetMediaItemInfo_Value(item, 'C_LANEPLAYS') ~= 0
end

----------------------------------------------------------------------------------------
-- Review flags: kept in the item's P_EXT only, so item colors stay the user's.
-- (Versions before 0.2 also painted flagged items and stored "kinds|original color".)
----------------------------------------------------------------------------------------

local function read_flag(item)
  local ok, s = r.GetSetMediaItemInfo_String(item, E.FLAG_KEY, '', false)
  if not ok or s == '' then return nil end
  local kinds = s:match('^(%a*)')
  if not kinds or kinds == '' then return nil end
  return kinds
end

local function write_flag(item, kinds)
  r.GetSetMediaItemInfo_String(item, E.FLAG_KEY, kinds or '', true)
end

function E.flag(item, kind)
  local kinds = read_flag(item) or ''
  if not kinds:find(kind, 1, true) then kinds = kinds .. kind end
  write_flag(item, kinds)
end

function E.unflag(item, kind)
  local kinds = read_flag(item)
  if not kinds then return end
  if kind then kinds = kinds:gsub(kind, '') else kinds = '' end
  write_flag(item, kinds)
end

function E.is_flagged(item) return read_flag(item) ~= nil end

function E.clear_flags()
  r.Undo_BeginBlock2(0)
  local n = 0
  for i = 0, r.CountMediaItems(0) - 1 do
    local it = r.GetMediaItem(0, i)
    if read_flag(it) then E.unflag(it); n = n + 1 end
  end
  r.Undo_EndBlock2(0, 'Reap Detective: clear review flags', -1)
  return n
end

-- Projects flagged by older versions have painted items: put the original color back
-- (only where the item still shows the review color) and keep the flag itself.
function E.restore_legacy_colors()
  local painted = {}
  for _, c in pairs(E.FLAG_COLORS) do painted[r.ColorToNative(c[1], c[2], c[3]) | 0x1000000] = true end
  local todo = {}
  for i = 0, r.CountMediaItems(0) - 1 do
    local it = r.GetMediaItem(0, i)
    local ok, s = r.GetSetMediaItemInfo_String(it, E.FLAG_KEY, '', false)
    if ok and s ~= '' then
      local kinds, col = s:match('^(%a*)|(-?%d+)$')
      if kinds then todo[#todo + 1] = { it, kinds, tonumber(col) } end
    end
  end
  if #todo == 0 then return 0 end
  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(1)
  local n = 0
  for _, t in ipairs(todo) do
    if painted[math.floor(r.GetMediaItemInfo_Value(t[1], 'I_CUSTOMCOLOR'))] then
      r.SetMediaItemInfo_Value(t[1], 'I_CUSTOMCOLOR', t[3])
      n = n + 1
    end
    write_flag(t[1], t[2])
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock2(0, 'Reap Detective: remove review colors', -1)
  return n
end

----------------------------------------------------------------------------------------
-- Separate
----------------------------------------------------------------------------------------

local function separate_item(item, take, slices, rs, re, trim, sid, gid0, stats)
  local pos0, end0 = item_bounds(item)
  local offs0 = r.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
  local rate = r.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
  local function src(t) return offs0 + (t - pos0) * rate end
  local n = #slices

  local cuts = {}
  for i = 1, n do
    local s = slices[i].s
    if s > pos0 + E.EPS and s < end0 - E.EPS then cuts[#cuts + 1] = { t = s, slot = i } end
  end
  if re > pos0 + E.EPS and re < end0 - E.EPS then cuts[#cuts + 1] = { t = re, slot = n + 1 } end

  local pieces = { { item = item, start = pos0, slot = core.slot_of(slices, re, pos0), L = false, R = false } }
  local cur = item
  for _, c in ipairs(cuts) do
    local right = r.SplitMediaItem(cur, c.t)
    if right then
      pieces[#pieces].stop, pieces[#pieces].R = c.t, true
      pieces[#pieces + 1] = { item = right, start = c.t, slot = c.slot, L = true, R = false }
      cur = right
    end
  end
  pieces[#pieces].stop = end0

  for _, p in ipairs(pieces) do
    local it, slot = p.item, p.slot
    local sl = slices[slot]
    local stop = p.stop
    if p.R then stop = math.max(p.start + 0.001, p.stop - trim) end
    E.set_bounds(it, p.start, stop)
    if p.L then set_fade(it, 'IN', 0) end
    if p.R then set_fade(it, 'OUT', 0) end

    local hs
    if p.L then
      local this_t = sl and sl.t or re
      local prev_t = sl and sl.prev_t or (slices[n] and slices[n].t or rs)
      hs = src(prev_t + (this_t - prev_t) / 2)
    else
      hs = src(p.start)
    end
    local is_slice = slot >= 1 and slot <= n
    set_tag(it, {
      sid = sid, idx = slot, k = is_slice and 'S' or 'F', L = p.L, R = p.R,
      ns = src(p.start), at = is_slice and src(sl.a) or 0, ts = src(p.stop), hs = hs,
    })
    if is_slice then r.SetMediaItemInfo_Value(it, 'I_GROUPID', gid0 + slot) end
  end
  stats.pieces = stats.pieces + #pieces
  stats.items = stats.items + 1
end

-- Split every playing audio item on `tracks` that overlaps [rs, re) at the slice starts
-- (and at re), trim each slice's tail by `trim`, tag all pieces and group each slice
-- across tracks.
function E.separate(tracks, slices, rs, re, trim)
  local stats = { items = 0, pieces = 0, skipped = 0, stretch = 0 }
  if #slices == 0 then return stats end
  local sid = ('%x'):format(math.floor(r.time_precise() * 1000) % 0xFFFFFFF)
  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(1)
  local gid0 = next_group_id() - 1
  for _, tr in ipairs(tracks) do
    local list = {}
    for i = 0, r.CountTrackMediaItems(tr) - 1 do
      local it = r.GetTrackMediaItem(tr, i)
      local s, e = item_bounds(it)
      if s < re and e > rs then list[#list + 1] = it end
    end
    for _, it in ipairs(list) do
      local take = r.GetActiveTake(it)
      if not take or r.TakeIsMIDI(take) or not plays(tr, it) then
        stats.skipped = stats.skipped + 1
      else
        if r.GetTakeNumStretchMarkers(take) > 0 then stats.stretch = stats.stretch + 1 end
        separate_item(it, take, slices, rs, re, trim, sid, gid0, stats)
      end
    end
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock2(0, 'Reap Detective: separate', -1)
  stats.sid = sid
  return stats
end

----------------------------------------------------------------------------------------
-- Collect tagged items
----------------------------------------------------------------------------------------

-- Returns all tagged items and the scope: the set of slice keys touched by the current
-- item selection (nil = no tagged item selected = everything).
function E.collect()
  local all, scope = {}, nil
  for i = 0, r.CountMediaItems(0) - 1 do
    local it = r.GetMediaItem(0, i)
    local tag = E.get_tag(it)
    if tag and r.GetActiveTake(it) then
      local e = { item = it, tag = tag, track = r.GetMediaItem_Track(it), key = tag.sid .. ':' .. tag.idx }
      all[#all + 1] = e
      if r.IsMediaItemSelected(it) then
        scope = scope or {}
        scope[e.key] = true
      end
    end
  end
  return all, scope
end

----------------------------------------------------------------------------------------
-- Quantize
----------------------------------------------------------------------------------------

function E.quantize(cfg)
  local all, scope = E.collect()
  local groups, order = {}, {}
  for _, e in ipairs(all) do
    if e.tag.k == 'S' and (not scope or scope[e.key]) then
      local g = groups[e.key]
      if not g then
        g = { items = {}, ref = e }
        groups[e.key] = g
        order[#order + 1] = g
      end
      g.items[#g.items + 1] = e
    end
  end

  local div = S.grid_qn(cfg)
  local max_qn = S.MAX_MOVES[cfg.max_move] and S.MAX_MOVES[cfg.max_move].qn
  local strength = cfg.strength / 100
  local excl = cfg.exclude_ms / 1000
  local stats = { slices = #order, moved = 0, flagged = 0, collisions = 0, kept = 0, scoped = scope ~= nil }

  for _, g in ipairs(order) do
    g.at = E.tl(g.ref.item, g.ref.tag.at)
    g.qn = r.TimeMap2_timeToQN(0, g.at)
    local _, ms, me = r.TimeMap_QNToMeasures(0, g.qn)
    g.tq = core.grid_target(g.qn, ms, me, div)
  end
  -- two neighboring slices landing on the same grid line: probably a double detection
  table.sort(order, function(x, y) return x.at < y.at end)
  for i = 2, #order do
    local p, g = order[i - 1], order[i]
    if p.ref.tag.sid == g.ref.tag.sid and math.abs(p.tq - g.tq) < 1e-9 then
      p.collide, g.collide = true, true
    end
  end

  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(1)
  for _, g in ipairs(order) do
    for _, e in ipairs(g.items) do E.unflag(e.item, 'q'); E.unflag(e.item, 'c') end
    local at, qn, tq = g.at, g.qn, g.tq
    local target = r.TimeMap2_QNToTime(0, tq)
    local flagged = g.collide or (max_qn ~= nil and math.abs(tq - qn) > max_qn + 1e-9)
    if g.collide then stats.collisions = stats.collisions + 1 end
    if flagged then
      stats.flagged = stats.flagged + 1
      for _, e in ipairs(g.items) do E.flag(e.item, g.collide and 'c' or 'q') end
    end
    if math.abs(target - at) <= excl or (flagged and not cfg.move_flagged) then
      stats.kept = stats.kept + 1
    else
      local delta = (target - at) * strength
      for _, e in ipairs(g.items) do
        local pos = r.GetMediaItemInfo_Value(e.item, 'D_POSITION')
        r.SetMediaItemInfo_Value(e.item, 'D_POSITION', pos + delta)
      end
      stats.moved = stats.moved + 1
    end
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock2(0, 'Reap Detective: quantize slices', -1)
  return stats
end

----------------------------------------------------------------------------------------
-- Smooth: fill gaps + crossfade
----------------------------------------------------------------------------------------

function E.smooth(cfg)
  local all, scope = E.collect()
  local by_track, tracks = {}, {}
  for _, e in ipairs(all) do
    e.nom = E.tl(e.item, e.tag.ns)
    local l = by_track[e.track]
    if not l then
      l = {}
      by_track[e.track] = l
      tracks[#tracks + 1] = e.track
    end
    l[#l + 1] = e
  end

  local xf = cfg.xfade and cfg.xfade_ms / 1000 or 0
  local mode = S.FADE_MODES[cfg.fade_mode] or 'pre'
  local shape = math.floor(cfg.fade_shape)
  local stats = { joins = 0, flagged = 0, skipped = 0, scoped = scope ~= nil }

  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(1)
  for _, tr in ipairs(tracks) do
    local list = by_track[tr]
    table.sort(list, function(x, y) return x.nom < y.nom end)
    for _, e in ipairs(list) do
      if not scope or scope[e.key] then E.unflag(e.item, 's') end
    end
    for i = 1, #list - 1 do
      local a, b = list[i], list[i + 1]
      if a.tag.sid == b.tag.sid and b.tag.idx == a.tag.idx + 1 and a.tag.R and b.tag.L
        and (not scope or scope[a.key] or scope[b.key]) then
        local a_start = r.GetMediaItemInfo_Value(a.item, 'D_POSITION')
        local _, b_stop = item_bounds(b.item)
        local A = { start = a_start, safe_end = E.tl(a.item, a.tag.ts) }
        local B = { nom_start = b.nom, stop = b_stop, head_safe = E.tl(b.item, b.tag.hs) }
        local _, a_src_end = source_limits(a.item)
        local b_src_start = source_limits(b.item)
        if a_src_end and a_src_end < A.safe_end then A.safe_end = a_src_end end
        if b_src_start and b_src_start > B.head_safe then B.head_safe = b_src_start end

        local plan = core.smooth_pair(A, B, xf, mode, cfg.smart_fill)
        if plan then
          E.set_bounds(a.item, a_start, plan.a_end)
          E.set_bounds(b.item, plan.b_start, b_stop)
          set_fade(a.item, 'OUT', plan.fade, shape)
          set_fade(b.item, 'IN', plan.fade, shape)
          r.SetMediaItemInfo_Value(a.item, 'I_MIXFLAG', 1)
          r.SetMediaItemInfo_Value(b.item, 'I_MIXFLAG', 1)
          stats.joins = stats.joins + 1
          if plan.flag then
            stats.flagged = stats.flagged + 1
            E.flag(a.item, 's')
            E.flag(b.item, 's')
          end
        else
          stats.skipped = stats.skipped + 1
        end
      end
    end
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock2(0, 'Reap Detective: fill gaps and crossfade', -1)
  return stats
end

----------------------------------------------------------------------------------------
-- Review navigation
----------------------------------------------------------------------------------------

-- Jump to the next (dir = 1) or previous (dir = -1) flagged item relative to the edit
-- cursor, select every item of that slice and move the edit cursor/view there.
-- Select every item of one slice (all tracks) and move the edit cursor/view to time t.
function E.focus_slice(sid, idx, t)
  r.PreventUIRefresh(1)
  r.Main_OnCommand(40289, 0) -- Item: Unselect all items
  for i = 0, r.CountMediaItems(0) - 1 do
    local it = r.GetMediaItem(0, i)
    local tag = E.get_tag(it)
    if tag and tag.sid == sid and tag.idx == idx then r.SetMediaItemSelected(it, true) end
  end
  r.SetEditCurPos2(0, t, true, false)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
end

-- One pass over the project: how many separated pieces exist, and every flagged slice
-- ({ sid, idx, t, kinds, tracks }) sorted by time.
function E.scan()
  local tagged, by_key, flagged, flag_tracks = 0, {}, {}, {}
  for i = 0, r.CountMediaItems(0) - 1 do
    local it = r.GetMediaItem(0, i)
    local tag = E.get_tag(it)
    if tag then
      tagged = tagged + 1
      local kinds = read_flag(it)
      if kinds and r.GetActiveTake(it) then
        local key = tag.sid .. ':' .. tag.idx
        local f = by_key[key]
        if not f then
          f = { sid = tag.sid, idx = tag.idx, kinds = '', tracks = 0,
                t = tag.k == 'S' and E.tl(it, tag.at) or r.GetMediaItemInfo_Value(it, 'D_POSITION') }
          by_key[key] = f
          flagged[#flagged + 1] = f
        end
        f.tracks = f.tracks + 1
        flag_tracks[r.GetMediaItem_Track(it)] = true
        for k in kinds:gmatch('%a') do
          if not f.kinds:find(k, 1, true) then f.kinds = f.kinds .. k end
        end
      end
    end
  end
  table.sort(flagged, function(a, b) return a.t < b.t end)
  local tracks = {}
  for tr in pairs(flag_tracks) do tracks[#tracks + 1] = tr end
  return { tagged = tagged, flagged = flagged, tracks = tracks }
end

function E.reasons(kinds)
  local t = {}
  for k in kinds:gmatch('%a') do t[#t + 1] = E.FLAG_REASONS[k] end
  return table.concat(t, ', ')
end

-- Jump to the next (dir = 1) or previous (dir = -1) flagged slice relative to the edit cursor.
-- `kinds` limits which flags count (pattern, default any).
function E.goto_flagged(dir, kinds)
  local cur = r.GetCursorPosition()
  local best
  for _, f in ipairs(E.scan().flagged) do
    if not kinds or f.kinds:find(kinds) then
      if (dir > 0 and f.t > cur + 0.001) or (dir < 0 and f.t < cur - 0.001) then
        if not best or (dir > 0 and f.t < best.t) or (dir < 0 and f.t > best.t) then best = f end
      end
    end
  end
  if not best then return nil end
  E.focus_slice(best.sid, best.idx, best.t)
  return best
end

----------------------------------------------------------------------------------------
-- Hit markers in the arrange view (display only)
----------------------------------------------------------------------------------------

function E.clear_markers()
  local del, i = {}, 0
  while true do
    local rv, isrgn, _, _, name, idx = r.EnumProjectMarkers3(0, i)
    if rv == 0 then break end
    if not isrgn and name == E.MARKER_NAME then del[#del + 1] = idx end
    i = i + 1
  end
  for _, idx in ipairs(del) do r.DeleteProjectMarker(0, idx, false) end
  return #del
end

function E.write_markers(hits)
  r.PreventUIRefresh(1)
  E.clear_markers()
  local col = r.ColorToNative(255, 190, 0) | 0x1000000
  for i, h in ipairs(hits) do
    r.AddProjectMarker2(0, false, h.t, 0, E.MARKER_NAME, E.MARKER_BASE + i, col)
  end
  r.PreventUIRefresh(-1)
  r.UpdateTimeline()
end

----------------------------------------------------------------------------------------
-- Environment checks
----------------------------------------------------------------------------------------

function E.grouping_enabled() return r.GetToggleCommandState(1156) == 1 end
function E.enable_grouping() if not E.grouping_enabled() then r.Main_OnCommand(1156, 0) end end
function E.ripple_on() return r.GetToggleCommandState(40310) == 1 or r.GetToggleCommandState(40311) == 1 end

return E
