-- Run from the repo root:  lua tests/run.lua
package.path = './?.lua;./Items Editing/?.lua;' .. package.path

local mock = require 'tests.mock_reaper'
reaper = mock.api

local core = require 'reapdetective.core'
local S = require 'reapdetective.settings'
local E = require 'reapdetective.edit'

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print('FAIL: ' .. msg) end
end
local function near(a, b, tol, msg)
  check(a ~= nil and b ~= nil and math.abs(a - b) <= tol,
    ('%s (got %s, want %s +- %g)'):format(msg, tostring(a), tostring(b), tol))
end

----------------------------------------------------------------------------------------
-- Synthetic drum audio
----------------------------------------------------------------------------------------

local SR, HOP_N = 48000, 48
local function synth(dur, hits, noise_db)
  local n = math.floor(dur * SR)
  local x = {}
  local noise = core.lin(noise_db or -70)
  local seed = 1
  for i = 1, n do
    seed = (seed * 1103515245 + 12345) % 2147483648
    x[i] = (seed / 2147483648 * 2 - 1) * noise
  end
  for _, h in ipairs(hits) do
    local i0 = math.floor(h.t * SR) + 1
    local amp = core.lin(h.db or 0)
    for i = i0, math.min(n, i0 + math.floor(h.len * SR)) do
      local tt = (i - i0) / SR
      local att = math.min(1, tt / 0.0008)
      x[i] = x[i] + amp * att * math.exp(-tt / h.decay) * math.sin(2 * math.pi * h.f * tt)
      if h.click then -- beater/stick click: short broadband burst
        seed = (seed * 1103515245 + 12345) % 2147483648
        x[i] = x[i] + amp * h.click * math.exp(-tt / 0.0015) * (seed / 2147483648 * 2 - 1)
      end
    end
  end
  return x, n
end

local function make_env(x, n)
  local d, dn = {}, 0
  dn = core.block_peaks_db(x, n, 1, HOP_N, d, dn)
  local peak = core.SILENCE_DB
  for i = 1, dn do if d[i] > peak then peak = d[i] end end
  local mip, sizes = core.build_mip(d, dn)
  return { db = d, hold = core.sliding_max(d, dn, 20), n = dn, hop = 0.001, t0 = 0, peak = peak,
           mip = mip, sizes = sizes }
end

local function refine(x, env, o)
  local j0 = math.max(1, o.j - 1)
  local i0 = (j0 - 1) * HOP_N
  local frames = (o.k + 2 - j0) * HOP_N
  local buf = {}
  for f = 1, frames do buf[f] = x[i0 + f] or 0 end
  return core.refine_onset(buf, frames, 1, SR, i0 / SR, core.lin(o.base + 1)) or o.t
end

----------------------------------------------------------------------------------------
-- core: detection
----------------------------------------------------------------------------------------

do
  -- kick-like: 55 Hz with a long decay (the classic false-retrigger case)
  local hits = {
    { t = 0.2003, f = 55, decay = 0.25, len = 0.6, db = -3, click = 0.5 },
    { t = 0.7111, f = 55, decay = 0.25, len = 0.6, db = -6, click = 0.5 },
    { t = 1.2507, f = 55, decay = 0.25, len = 0.6, db = -12, click = 0.5 }, -- softer hit over the ring
    { t = 1.5000, f = 55, decay = 0.25, len = 0.6, db = -45, click = 0.5 }, -- below threshold
  }
  local x, n = synth(2.2, hits)
  local env = make_env(x, n)
  local on = core.detect(env, { thr = -30, sens = 8, retrig = 0.03 })
  check(#on == 3, ('kick: 3 onsets expected, got %d'):format(#on))
  for i = 1, math.min(3, #on) do
    near(on[i].t, hits[i].t, 0.0015, 'kick onset (block) ' .. i)
    near(refine(x, env, on[i]), hits[i].t, 0.0002, 'kick onset (refined) ' .. i)
  end
end

do
  -- worst case: pure 55 Hz sine (no click) starting at zero phase over the previous ring.
  -- It only clears the ring after a millisecond or two; documents the limit.
  local hits = {
    { t = 0.2003, f = 55, decay = 0.25, len = 0.6, db = -3 },
    { t = 0.7111, f = 55, decay = 0.25, len = 0.6, db = -12 },
  }
  local x, n = synth(1.4, hits)
  local env = make_env(x, n)
  local on = core.detect(env, { thr = -30, sens = 8, retrig = 0.03 })
  check(#on == 2, 'pure sine kick: 2 onsets')
  near(on[2] and refine(x, env, on[2]), 0.7111, 0.002, 'pure sine kick over ring: within 2 ms')
end

do
  -- snare flam: grace note 18 ms before the main stroke, plus a fast 32nd pair
  local hits = {
    { t = 0.3000, f = 210, decay = 0.08, len = 0.3, db = -14 },
    { t = 0.3180, f = 210, decay = 0.08, len = 0.3, db = 0 },
    { t = 0.8000, f = 210, decay = 0.08, len = 0.3, db = -2 },
    { t = 0.8625, f = 210, decay = 0.08, len = 0.3, db = -2 },
  }
  local x, n = synth(1.4, hits)
  local env = make_env(x, n)
  local on = core.detect(env, { thr = -30, sens = 6, retrig = 0.03 })
  check(#on == 3, ('snare: flam merged by retrigger -> 3 onsets, got %d'):format(#on))
  near(on[1] and on[1].t, 0.3, 0.0015, 'flam split at grace note')
  local on2 = core.detect(env, { thr = -30, sens = 6, retrig = 0.005 })
  check(#on2 == 4, ('snare: short retrigger sees both flam strokes, got %d'):format(#on2))
end

----------------------------------------------------------------------------------------
-- core: merge, edits, plan, grid, smoothing
----------------------------------------------------------------------------------------

do
  local hits = core.merge({
    { t = 1.000, lvl = -10, tr = 1 }, { t = 1.008, lvl = -2, tr = 2 },   -- kick + snare 8 ms apart
    { t = 2.000, lvl = -1, tr = 2 }, { t = 2.050, lvl = -1, tr = 1 },
  }, 0.03, 'loudest')
  check(#hits == 3, 'merge: 3 hits')
  near(hits[1].t, 1.0, 1e-9, 'merge: split at first onset')
  near(hits[1].a, 1.008, 1e-9, 'merge: anchor at loudest onset')
  check(hits[1].n == 2, 'merge: two onsets in first hit')
end

do
  local auto = { { t = 1, a = 1, lvl = 0 }, { t = 2, a = 2, lvl = 0 }, { t = 3, a = 3.01, lvl = 0 } }
  local ed = core.new_edits()
  local h = core.apply_edits(auto, ed)
  core.edit_delete(ed, h[1])
  core.edit_move(ed, h[3], 3.1)
  core.edit_add(ed, 2.5)
  h = core.apply_edits(auto, ed)
  check(#h == 3, 'edits: count')
  near(h[1].t, 2, 1e-9, 'edits: deleted first')
  check(h[2].kind == 'added' and math.abs(h[2].t - 2.5) < 1e-9, 'edits: added hit')
  check(h[3].kind == 'moved' and math.abs(h[3].t - 3.1) < 1e-9 and math.abs(h[3].a - 3.11) < 1e-9, 'edits: moved hit keeps anchor offset')
  -- auto detection jitters by 0.5 ms: edits still apply
  auto[3].t = 3.0005
  h = core.apply_edits(auto, ed)
  check(#h == 3 and h[3].kind == 'moved', 'edits: tolerant matching')
  core.edit_move(ed, h[3], 3.2)
  check(#ed.moves == 1, 'edits: moving a moved hit updates the same entry')
  core.edit_delete(ed, h[2])
  check(#ed.adds == 0, 'edits: deleting an added hit removes it')
end

do
  local slices, dropped = core.split_plan({
    { t = 0.9, a = 0.9 }, { t = 1.0, a = 1.0 }, { t = 1.008, a = 1.008 }, { t = 2.0, a = 2.0 }, { t = 3.0, a = 3.0 },
  }, 0.005, 0.012, 0.95, 2.5)
  check(#slices == 2 and dropped == 1, ('plan: 2 slices, 1 dropped (got %d, %d)'):format(#slices, dropped))
  near(slices[1].s, 0.995, 1e-9, 'plan: split = t - pad')
  near(slices[1].next_s, 1.995, 1e-9, 'plan: next_s')
  near(slices[2].next_s, 2.5, 1e-9, 'plan: last slice ends at range end')
  check(core.slot_of(slices, 2.5, 0.5) == 0 and core.slot_of(slices, 2.5, 1.5) == 1 and core.slot_of(slices, 2.5, 2.6) == 3, 'plan: slot_of')
end

do
  near(core.grid_target(5.13, 4, 8, 0.25), 5.25, 1e-9, 'grid: nearest 1/16')
  near(core.grid_target(5.10, 4, 8, 0.25), 5.0, 1e-9, 'grid: rounds down')
  near(core.grid_target(7.9, 4, 7.5, 1.0), 7.5, 1e-9, 'grid: 7/8 bar snaps to next downbeat, not past it')
  near(core.grid_target(3.95, 4, 8, 0.25), 4.0, 1e-9, 'grid: before measure start')
end

do
  -- nothing moved: tail fills the trim gap, crossfade before B's start
  local p = core.smooth_pair({ start = 0, safe_end = 1.0 }, { nom_start = 1.0, stop = 2, head_safe = 0.5 }, 0.005, 'pre', true)
  near(p.a_end, 1.0, 1e-9, 'smooth: A ends at B start'); near(p.b_start, 0.995, 1e-9, 'smooth: B pre-extended')
  check(not p.flag, 'smooth: clean')
  -- B moved 20 ms later: A's tail may only reach its safe end; B's head covers the rest
  p = core.smooth_pair({ start = 0, safe_end = 1.0 }, { nom_start = 1.02, stop = 2, head_safe = 0.52 }, 0.005, 'pre', true)
  near(p.a_end, 1.0, 1e-9, 'smart: A stops at safe end'); near(p.b_start, 0.995, 1e-9, 'smart: B head fills')
  check(not p.flag, 'smart: clean')
  -- same without smart fill: A's tail runs into the next hit -> flagged
  p = core.smooth_pair({ start = 0, safe_end = 1.0 }, { nom_start = 1.02, stop = 2, head_safe = 0.52 }, 0.005, 'pre', false)
  near(p.a_end, 1.02, 1e-9, 'plain: A fills'); check(p.flag and p.reason == 'tail', 'plain: flagged tail')
  -- post fade
  p = core.smooth_pair({ start = 0, safe_end = 2 }, { nom_start = 1.0, stop = 2, head_safe = 0.5 }, 0.004, 'post', true)
  near(p.a_end, 1.004, 1e-9, 'post: A overlaps into B'); near(p.b_start, 1.0, 1e-9, 'post: B unchanged')
end

do
  local t = { sid = 'ab12', idx = 7, k = 'S', L = true, R = false, ns = 1.25, at = 1.255, ts = 2.5, hs = 0.75 }
  local d = core.tag_decode(core.tag_encode(t))
  check(d and d.sid == 'ab12' and d.idx == 7 and d.k == 'S' and d.L and not d.R and math.abs(d.at - 1.255) < 1e-9, 'tag round trip')
  check(core.tag_decode('garbage') == nil, 'tag: reject garbage')
end

----------------------------------------------------------------------------------------
-- edit: full workflow on a mock project
----------------------------------------------------------------------------------------

local function project_items()
  local out = {}
  for i = 0, reaper.CountMediaItems(0) - 1 do out[#out + 1] = reaper.GetMediaItem(0, i) end
  return out
end

-- every piece must still play the audio that was originally at (pos - shift)
local function shift_of(it)
  local tk = it.takes[1]
  return it.pos - tk.offs   -- original items had offs 0 at pos 0 (rate 1)
end

local function workflow(split_xfade)
  local label = ('[split xfade %g] '):format(split_xfade)
  mock.reset({ split_xfade = split_xfade })
  local kick, snare, oh = mock.add_track('Kick'), mock.add_track('Snare'), mock.add_track('OH')
  for _, tr in ipairs({ kick, snare, oh }) do mock.add_item(tr, 0, 6, { group = 1 }) end

  -- 120 BPM: 8th grid = 0.25 s. Hits slightly off the grid; the 2.29 hit is suspicious.
  local hits = {
    { t = 0.512, a = 0.512 }, { t = 0.998, a = 1.004 }, { t = 1.49, a = 1.49 },
    { t = 2.0, a = 2.0 }, { t = 2.29, a = 2.29 }, { t = 2.76, a = 2.76 },
  }
  local rs, re = 0.25, 3.25
  local pad, trim = 0.005, 0.010
  local slices = core.split_plan(hits, pad, trim + 0.002, rs, re)
  local st = E.separate({ kick, snare, oh }, slices, rs, re, trim)
  check(st.items == 3, label .. 'separate: 3 items')
  check(st.pieces == 3 * 8, label .. ('separate: 8 pieces per track (got %d)'):format(st.pieces))

  local by_slot = {}
  for _, it in ipairs(project_items()) do
    local tag = E.get_tag(it)
    check(tag ~= nil, label .. 'every piece tagged')
    near(shift_of(it), 0, 1e-9, label .. 'piece audio not moved by separate')
    by_slot[tag.idx] = by_slot[tag.idx] or {}
    table.insert(by_slot[tag.idx], it)
  end
  for i = 1, #slices do
    local g = by_slot[i]
    check(#g == 3, label .. 'slice on all 3 tracks')
    near(g[1].pos, slices[i].s, 1e-9, label .. 'slice starts at split ' .. i)
    near(g[1].pos + g[1].len, slices[i].next_s - trim, 1e-9, label .. 'slice tail trimmed ' .. i)
    check(g[1].group == g[2].group and g[2].group == g[3].group and g[1].group ~= 1, label .. 'slice grouped across tracks')
    check(g[1].fin == 0 and g[1].fout == 0, label .. 'split edges have no fades')
  end
  check(by_slot[0][1].group == 1, label .. 'head piece keeps original group')

  -- quantize to 1/8, flag > 1/64 (0.03125 s at 120 BPM)
  local cfg = S.load()
  cfg.grid, cfg.triplet, cfg.use_proj_grid, cfg.strength, cfg.exclude_ms = 2, false, false, 100, 0
  cfg.max_move, cfg.move_flagged = 4, false
  check(cfg.fade_shape == 1 and cfg.xfade_ms == 10 and cfg.max_move == 4, label .. 'defaults loaded')
  local q = E.quantize(cfg)
  check(q.slices == 6 and q.flagged == 1 and q.moved == 4 and q.kept == 2,
    label .. ('quantize: 6 slices, 4 moved, 2 kept (on grid + flagged), 1 flagged (got %d/%d/%d/%d)'):format(q.slices, q.moved, q.kept, q.flagged))
  for i, sl in ipairs(slices) do
    local it = by_slot[i][1]
    local anchor = E.tl(it, E.get_tag(it).at)
    local target = math.floor(sl.a / 0.25 + 0.5) * 0.25
    if math.abs(target - sl.a) > 0.03125 then
      near(anchor, sl.a, 1e-9, label .. 'flagged slice stays put')
      check(E.is_flagged(it), label .. 'flagged slice flagged')
      check(it.color == 0, label .. 'flagging leaves the item color alone')
    else
      near(anchor, target, 1e-9, label .. 'anchor on grid ' .. i)
      check(not E.is_flagged(it), label .. 'unflagged slice not flagged')
    end
    local s1, s3 = shift_of(by_slot[i][1]), shift_of(by_slot[i][3])
    near(s1, s3, 1e-12, label .. 'all tracks moved together ' .. i)
  end

  -- smooth twice: second run must not change anything
  cfg.xfade, cfg.xfade_ms, cfg.fade_mode, cfg.smart_fill = true, 5, 1, true
  local sm = E.smooth(cfg)
  check(sm.joins == 3 * 7, label .. ('smooth: 7 boundaries per track (got %d)'):format(sm.joins))
  local snap = {}
  for _, it in ipairs(project_items()) do snap[it] = { it.pos, it.len, it.takes[1].offs } end
  E.smooth(cfg)
  local same = true
  for _, it in ipairs(project_items()) do
    local s = snap[it]
    if math.abs(s[1] - it.pos) > 1e-9 or math.abs(s[2] - it.len) > 1e-9 or math.abs(s[3] - it.takes[1].offs) > 1e-9 then same = false end
  end
  check(same, label .. 'smooth is idempotent')

  -- every boundary: exactly xf of overlap, fades match, B's transient untouched,
  -- A's tail never plays into the next hit
  local list = {}
  for _, it in ipairs(project_items()) do if it.track == kick then list[#list + 1] = it end end
  table.sort(list, function(x, y) return x.pos < y.pos end)
  for i = 1, #list - 1 do
    local a, b = list[i], list[i + 1]
    local ta, tb = E.get_tag(a), E.get_tag(b)
    local a_end = a.pos + a.len
    near(a_end - b.pos, 0.005, 1e-9, label .. 'overlap = crossfade length ' .. i)
    near(a.fout, 0.005, 1e-12, label .. 'fade out set ' .. i)
    check(a.misc.C_FADEOUTSHAPE == 1 and b.misc.C_FADEINSHAPE == 1, label .. 'equal power shape ' .. i)
    near(b.fin, 0.005, 1e-12, label .. 'fade in set ' .. i)
    check(a_end <= E.tl(b, tb.ns) + 1e-9, label .. 'fade ends before slice start ' .. i)
    check(a_end <= E.tl(a, ta.ts) + 1e-9, label .. 'tail stays clean ' .. i)
    check(b.pos >= E.tl(b, tb.hs) - 1e-9, label .. 'head stays clean ' .. i)
  end

  -- scoped quantize: select one slice on one track, quantize to 1/16 with the whole group
  for _, it in ipairs(project_items()) do it.sel = false end
  by_slot[5][2].sel = true
  cfg.grid, cfg.move_flagged = 3, true
  local q2 = E.quantize(cfg)
  check(q2.slices == 1 and q2.scoped, label .. 'scoped quantize: only the selected slice')
  near(E.tl(by_slot[5][3], E.get_tag(by_slot[5][3]).at), 2.25, 1e-9, label .. 'scoped quantize moved OH with it')

  check(E.clear_flags() > 0, label .. 'clear flags')
  check(not E.is_flagged(by_slot[5][1]) and by_slot[5][1].color == 0, label .. 'flags cleared, color untouched')
end

workflow(0)
workflow(0.01) -- REAPER's "overlap and crossfade items when splitting" preference turned on

do
  mock.reset()
  E.write_markers({ { t = 1 }, { t = 2 } })
  check(#mock.state.markers == 2, 'markers written')
  mock.state.markers[#mock.state.markers + 1] = { pos = 5, name = 'Chorus', idx = 3 }
  E.write_markers({ { t = 1 } })
  check(#mock.state.markers == 2, 'markers rewritten, user marker kept')
  E.clear_markers()
  check(#mock.state.markers == 1 and mock.state.markers[1].name == 'Chorus', 'markers cleared')
end

do
  -- two hits 40 ms apart snap to the same 1/8 line -> both flagged, neither moved
  mock.reset()
  local tr = mock.add_track('Snare')
  mock.add_item(tr, 0, 4)
  local hits = { { t = 1.0, a = 1.0 }, { t = 1.49, a = 1.49 }, { t = 1.53, a = 1.53 }, { t = 2.02, a = 2.02 } }
  local slices = core.split_plan(hits, 0.005, 0.012, 0.5, 3)
  E.separate({ tr }, slices, 0.5, 3, 0.010)
  local cfg = S.load()
  cfg.grid, cfg.max_move, cfg.move_flagged, cfg.exclude_ms = 2, 1, false, 0
  local q = E.quantize(cfg)
  check(q.collisions == 2 and q.flagged == 2, ('collision: 2 slices flagged (got %d/%d)'):format(q.collisions, q.flagged))
end

do
  -- settings saved by v1 (no _version) get the new defaults for changed keys, keep the rest
  mock.reset()
  reaper.SetExtState(S.SECTION, 'settings', 'max_move=n4;xfade_ms=n5;thr_db=n-35.2', true)
  local c = S.load()
  check(c.max_move == 2 and c.xfade_ms == 10 and c.fade_shape == 1 and c.thr_db == -35.2, 'settings migration v1 -> v2')
  c.xfade_ms = 12
  S.save(c)
  local c2 = S.load()
  check(c2.xfade_ms == 12 and c2.max_move == 2, 'settings v2 round trip keeps user values')
end

do
  local K = require 'reapdetective.keys'
  local function p(d) local m, k, kind = K.parse(d); local ms = {}; for x in pairs(m) do ms[#ms + 1] = x end; table.sort(ms); return table.concat(ms, ','), k, kind end
  local function eq(d, mods, key, kind)
    local m, k, kd = p(d)
    check(m == mods and k == key and kd == kind, ('parse %q -> %s %s %s (got %s %s %s)'):format(d, mods, tostring(key), tostring(kind), m, tostring(k), tostring(kd)))
  end
  -- formats seen in REAPER 7.82 on macOS
  eq('Cmd+Z', 'cmd', 'Key_Z', 'key')
  eq('Cmd+Shift+Z', 'cmd,shift', 'Key_Z', 'key')
  eq('Cmd+Opt+Shift+R', 'alt,cmd,shift', 'Key_R', 'key')
  eq('Opt+Return', 'alt', 'Key_Enter', 'key')
  eq('Control+M', 'ctrl', 'Key_M', 'key')
  eq('Cmd+NumPad +', 'cmd', 'Key_KeypadAdd', 'key')
  eq('NumPad 4', '', 'Key_Keypad4', 'key')
  eq('Space', '', 'Key_Space', 'key')
  eq('Shift+Tab', 'shift', 'Key_Tab', 'key')
  eq('Shift+8', 'shift', 'Key_8', 'key')
  eq('Cmd+[', 'cmd', 'Key_LeftBracket', 'key')
  eq('F13', '', 'Key_F13', 'key')
  eq('+', '', '+', 'char')
  eq('>', '', '>', 'char')
  eq('Opt+Mousewheel', 'alt', nil, nil)
  eq('MultiRotate', '', nil, nil)

  local tmp = os.tmpname()
  local f = io.open(tmp, 'w')
  f:write('KEY 9 83 40026 0\t\t # Main : Cmd+S : OVERRIDE DEFAULT : File: Save project\n')
  f:write('KEY 1 77 1 102\t\t # glob hotkey : M : \n')
  f:write('KEY 9 83 1 102\t\t # glob hotkey : Cmd+S :\n')
  f:close()
  local g = K.read_globals(tmp)
  os.remove(tmp)
  check(g['M'] and g['Cmd+S'] and not g['Cmd+Z'], 'globals read from reaper-kb.ini')
end

do
  -- forwarding against a stub ImGui (macOS behaviors: Cmd reported as Ctrl)
  local K = require 'reapdetective.keys'
  local ImGui = setmetatable({ Mod_Ctrl = 1 << 12, Mod_Shift = 1 << 13, Mod_Alt = 1 << 14, Mod_Super = 1 << 15,
    ConfigVar_MacOSXBehaviors = 99 }, { __index = function(t, k)
      if k:match('^Key_') then local v = 1000 + #k * 37 + k:byte(-1); rawset(t, k, v); return v end
      error('no ImGui.' .. k) end })
  local down, mods, ran = {}, 0, {}
  ImGui.GetConfigVar = function() return 1 end
  ImGui.GetKeyMods = function() return mods end
  ImGui.IsKeyPressed = function(_, k) return down[k] or false end
  ImGui.GetInputQueueCharacter = function() return false end
  local shortcuts = { [40029] = { 'Cmd+Z' }, [40030] = { 'Cmd+Shift+Z' }, [40044] = { 'Space' },
                      [40026] = { 'Cmd+S' }, [24866] = { 'C' }, [1012] = { '+' } }
  local names = { [24866] = 'Main action section: Momentarily set override to Chains' }
  local ids = { 40029, 40030, 40044, 40026, 24866, 1012 }
  local saved = {}
  for _, k in ipairs({ 'GetOS', 'GetResourcePath', 'SectionFromUniqueID', 'kbd_enumerateActions',
    'CountActionShortcuts', 'GetActionShortcutDesc', 'Main_OnCommand' }) do saved[k] = reaper[k] end
  local tmpdir = os.tmpname(); os.remove(tmpdir); os.execute('mkdir -p ' .. tmpdir)
  local f = io.open(tmpdir .. '/reaper-kb.ini', 'w'); f:write('KEY 9 83 1 102\t\t # glob hotkey : Cmd+S :\n'); f:close()
  reaper.GetOS = function() return 'macOS-arm64' end
  reaper.GetResourcePath = function() return tmpdir end
  reaper.SectionFromUniqueID = function() return {} end
  reaper.kbd_enumerateActions = function(_, i) local id = ids[i + 1]; return id or 0, names[id] or 'x' end
  reaper.CountActionShortcuts = function(_, id) return #(shortcuts[id] or {}) end
  reaper.GetActionShortcutDesc = function(_, id, i) return true, shortcuts[id][i + 1] end
  reaper.Main_OnCommand = function(id) ran[#ran + 1] = id end
  local map = K.build(ImGui, {})
  local function press(key, m, consumed) down = { [ImGui[key]] = true }; mods = m; ran = {}; K.forward(ImGui, {}, map, consumed or {}); return ran[1] end
  check(press('Key_Z', ImGui.Mod_Ctrl) == 40029, 'Cmd+Z runs undo')
  check(press('Key_Z', ImGui.Mod_Ctrl | ImGui.Mod_Shift) == 40030, 'Cmd+Shift+Z runs redo')
  check(press('Key_Z', 0) == nil, 'plain Z does not run undo')
  check(press('Key_S', ImGui.Mod_Ctrl) == nil, 'global Cmd+S is left to REAPER')
  check(press('Key_C', 0) == nil, 'momentary actions are skipped')
  check(press('Key_Space', 0) == 40044, 'Space runs play/stop')
  check(press('Key_Space', 0, { [ImGui.Key_Space] = true }) == nil, 'keys the window used are not forwarded')
  check(map.chars[43] and map.chars[43].cmd == 1012, 'character shortcut (+) mapped')
  for k, v in pairs(saved) do reaper[k] = v end
  os.remove(tmpdir .. '/reaper-kb.ini'); os.remove(tmpdir)
end

do
  -- items painted by versions before 0.2 get their own color back, keeping the flag
  mock.reset()
  local tr = mock.add_track('Kick')
  local painted = reaper.ColorToNative(230, 50, 50) | 0x1000000
  local a = mock.add_item(tr, 0, 1, { color = painted })
  local b = mock.add_item(tr, 1, 1, { color = 0x1000000 | 123 })     -- user recolored it since
  a.ext[E.FLAG_KEY] = 'c|' .. (0x1000000 | 456)
  b.ext[E.FLAG_KEY] = 'q|' .. (0x1000000 | 789)
  check(E.restore_legacy_colors() == 1, 'legacy: one painted item restored')
  check(a.color == (0x1000000 | 456) and b.color == (0x1000000 | 123), 'legacy: only the still-painted item recolored')
  check(E.is_flagged(a) and E.is_flagged(b) and a.ext[E.FLAG_KEY] == 'c', 'legacy: flags kept in the new format')
  check(E.restore_legacy_colors() == 0, 'legacy: second run does nothing')
end

print(('%d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
