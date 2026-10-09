-- Minimal in-memory stand-in for the parts of the REAPER API that edit.lua/settings.lua use.
-- Tempo is a constant 120 BPM in 4/4 (1 QN = 0.5 s, 1 bar = 4 QN).

local M = {}

local function new_state()
  return { tracks = {}, items = {}, markers = {}, ext = {}, cursor = 0, toggles = { [1156] = 1 },
           split_xfade = 0 }
end

M.state = new_state()

function M.reset(opts)
  M.state = new_state()
  if opts and opts.split_xfade then M.state.split_xfade = opts.split_xfade end
end

function M.add_track(name)
  local tr = { name = name, items = {}, freemode = 0 }
  M.state.tracks[#M.state.tracks + 1] = tr
  tr.number = #M.state.tracks
  return tr
end

local function sort_track(tr)
  table.sort(tr.items, function(a, b) return a.pos < b.pos end)
end

local function rebuild_project_list()
  local list = {}
  for _, tr in ipairs(M.state.tracks) do
    sort_track(tr)
    for _, it in ipairs(tr.items) do list[#list + 1] = it end
  end
  M.state.items = list
end

function M.add_item(tr, pos, len, opts)
  opts = opts or {}
  local it = {
    track = tr, pos = pos, len = len, sel = false, group = opts.group or 0, color = opts.color or 0,
    fin = opts.fin or 0, fout = opts.fout or 0, fin_auto = 0, fout_auto = 0, mix = -1, loop = 0,
    ext = {}, takes = {}, cur = 1,
  }
  it.takes[1] = { item = it, offs = opts.offs or 0, rate = opts.rate or 1, src_len = opts.src_len or 1000,
                  midi = opts.midi or false }
  tr.items[#tr.items + 1] = it
  rebuild_project_list()
  return it
end

local item_fields = {
  D_POSITION = 'pos', D_LENGTH = 'len', I_GROUPID = 'group', I_CUSTOMCOLOR = 'color',
  D_FADEINLEN = 'fin', D_FADEOUTLEN = 'fout', D_FADEINLEN_AUTO = 'fin_auto', D_FADEOUTLEN_AUTO = 'fout_auto',
  I_MIXFLAG = 'mix', B_LOOPSRC = 'loop',
}

local R = {}

function R.GetMediaItemInfo_Value(it, k)
  if k == 'C_LANEPLAYS' then return 1 end
  local f = item_fields[k]
  if f then return it[f] end
  return it.misc and it.misc[k] or 0
end

function R.SetMediaItemInfo_Value(it, k, v)
  local f = item_fields[k]
  if f then
    it[f] = v
    if f == 'pos' then rebuild_project_list() end
  else
    it.misc = it.misc or {}
    it.misc[k] = v
  end
  return true
end

function R.GetSetMediaItemInfo_String(it, k, v, set)
  if set then it.ext[k] = v; return true, v end
  local val = it.ext[k]
  if val == nil then return false, '' end
  return true, val
end

function R.GetActiveTake(it) return it.takes[it.cur] end
function R.CountTakes(it) return #it.takes end
function R.GetTake(it, i) return it.takes[i + 1] end
function R.TakeIsMIDI(tk) return tk.midi end
function R.GetTakeNumStretchMarkers() return 0 end
function R.GetMediaItemTake_Source(tk) return tk end
function R.GetMediaSourceLength(src) return src.src_len, false end

function R.GetMediaItemTakeInfo_Value(tk, k)
  if k == 'D_STARTOFFS' then return tk.offs end
  if k == 'D_PLAYRATE' then return tk.rate end
  return 0
end

function R.SetMediaItemTakeInfo_Value(tk, k, v)
  if k == 'D_STARTOFFS' then tk.offs = v end
  if k == 'D_PLAYRATE' then tk.rate = v end
  return true
end

function R.GetMediaItem_Track(it) return it.track end
function R.IsMediaItemSelected(it) return it.sel end
function R.SetMediaItemSelected(it, s) it.sel = s end
function R.CountMediaItems() return #M.state.items end
function R.GetMediaItem(_, i) return M.state.items[i + 1] end
function R.CountTrackMediaItems(tr) return #tr.items end
function R.GetTrackMediaItem(tr, i) sort_track(tr); return tr.items[i + 1] end
function R.GetMediaTrackInfo_Value(tr, k)
  if k == 'I_FREEMODE' then return tr.freemode end
  if k == 'IP_TRACKNUMBER' then return tr.number end
  return 0
end

-- Behaves like REAPER, including the optional "overlap and crossfade items when splitting".
function R.SplitMediaItem(it, t)
  if t <= it.pos or t >= it.pos + it.len then return nil end
  local ov = M.state.split_xfade
  local tr = it.track
  local right = {
    track = tr, pos = t - ov / 2, len = it.pos + it.len - (t - ov / 2), sel = it.sel, group = it.group,
    color = it.color, fin = ov, fout = it.fout, fin_auto = 0, fout_auto = 0, mix = it.mix, loop = it.loop,
    ext = {}, takes = {}, cur = it.cur,
  }
  for k, v in pairs(it.ext) do right.ext[k] = v end
  for i, tk in ipairs(it.takes) do
    right.takes[i] = { item = right, offs = tk.offs + (right.pos - it.pos) * tk.rate, rate = tk.rate,
                       src_len = tk.src_len, midi = tk.midi }
  end
  it.len = t + ov / 2 - it.pos
  it.fout = ov
  tr.items[#tr.items + 1] = right
  rebuild_project_list()
  return right
end

function R.ColorToNative(r_, g, b) return r_ | (g << 8) | (b << 16) end
function R.Undo_BeginBlock2() end
function R.Undo_EndBlock2() end
function R.PreventUIRefresh() end
function R.UpdateArrange() end
function R.UpdateTimeline() end
function R.time_precise() return os.clock() end
function R.GetCursorPosition() return M.state.cursor end
function R.SetEditCurPos2(_, t) M.state.cursor = t end
function R.Main_OnCommand(id)
  if id == 40289 then for _, it in ipairs(M.state.items) do it.sel = false end end
end
function R.GetToggleCommandState(id) return M.state.toggles[id] or 0 end

-- 120 BPM, 4/4
function R.TimeMap2_timeToQN(_, t) return t * 2 end
function R.TimeMap2_QNToTime(_, qn) return qn / 2 end
function R.TimeMap_QNToMeasures(_, qn)
  local m = math.floor(qn / 4)
  return m, m * 4, m * 4 + 4
end
function R.GetSetProjectGrid() return 0, 0.0625 end

function R.GetExtState(sec, key) return (M.state.ext[sec] or {})[key] or '' end
function R.SetExtState(sec, key, v) M.state.ext[sec] = M.state.ext[sec] or {}; M.state.ext[sec][key] = v end

function R.EnumProjectMarkers3(_, i)
  local m = M.state.markers[i + 1]
  if not m then return 0 end
  return 1, false, m.pos, 0, m.name, m.idx, m.color
end
function R.DeleteProjectMarker(_, idx)
  for i, m in ipairs(M.state.markers) do
    if m.idx == idx then table.remove(M.state.markers, i); return true end
  end
  return false
end
function R.AddProjectMarker2(_, _, pos, _, name, idx, color)
  M.state.markers[#M.state.markers + 1] = { pos = pos, name = name, idx = idx, color = color }
  return idx
end

M.api = R
return M
