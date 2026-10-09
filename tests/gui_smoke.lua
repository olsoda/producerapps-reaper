-- Headless smoke test: runs ReapDetective.lua frame by frame against a stub ImGui and the
-- mock REAPER project, clicking through Analyze -> edit hits -> Separate -> Quantize -> Smooth.
-- Catches runtime errors in the GUI code paths (not ImGui rendering itself).
-- Run from the repo root:  lua tests/gui_smoke.lua
package.path = './?.lua;./Items Editing/?.lua;' .. package.path

local mock = require 'tests.mock_reaper'
local R = mock.api
reaper = R

----------------------------------------------------------------------------------------
-- Extra REAPER stubs needed by the window script
----------------------------------------------------------------------------------------

local SR = 48000
local signals = {}
local deferred, exit_fn = nil, nil

local function make_signal(hits, dur)
  local x, n = {}, math.floor(dur * SR)
  for i = 1, n do x[i] = 0 end
  for _, h in ipairs(hits) do
    local i0 = math.floor(h.t * SR) + 1
    for i = i0, math.min(n, i0 + math.floor(0.25 * SR)) do
      local tt = (i - i0) / SR
      x[i] = x[i] + h.amp * math.min(1, tt / 0.0005) * math.exp(-tt / 0.05) * math.sin(2 * math.pi * h.f * tt + 0.3)
    end
  end
  return x
end

local clock = 0
function R.time_precise() return clock end -- advanced 40 ms per frame by run()
function R.ImGui_GetBuiltinPath() return '.' end
function R.defer(fn) deferred = fn end
function R.atexit(fn) exit_fn = fn end
function R.MB() return 1 end
function R.ValidatePtr2() return true end
function R.GetPlayState() return 0 end
function R.GetPlayPosition() return 0 end
function R.format_timestr_pos(t) return ('%d.1.00'):format(math.floor(t * 2 / 4) + 1) end
function R.GetTrackName(tr) return true, tr.name end
function R.GetTrackGUID(tr) return '{' .. tr.name .. '}' end
local base_track_info = R.GetMediaTrackInfo_Value
function R.GetMediaTrackInfo_Value(tr, k)
  if k == 'I_NCHAN' then return 2 end
  if k == 'I_TCPH' or k == 'I_WNDH' then return 80 end
  if k == 'I_TCPY' then return (tr.number - 1) * 80 end
  if k == 'B_TCPPIN' then return 0 end
  return base_track_info(tr, k)
end
function R.CountSelectedTracks() local n = 0; for _, t in ipairs(mock.state.tracks) do if t.sel then n = n + 1 end end; return n end
function R.GetSelectedTrack(_, i)
  local n = -1
  for _, t in ipairs(mock.state.tracks) do if t.sel then n = n + 1; if n == i then return t end end end
end
function R.CountSelectedMediaItems() return 0 end
function R.GetSet_LoopTimeRange2() return mock.state.ts or 0, mock.state.te or 0 end
-- js_ReaScriptAPI stand-ins: track what is composited onto the arrange view
local composites, arrange_hwnd = {}, { name = 'arrange' }
function R.GetMainHwnd() return { name = 'main' } end
function R.JS_Window_FindChildByID(_, id) return id == 1000 and arrange_hwnd or nil end
function R.JS_LICE_CreateBitmap() return {} end
function R.JS_LICE_Clear(bm, color) bm.color = color end
function R.JS_LICE_DestroyBitmap(bm) composites[bm] = nil end
function R.JS_Composite(hwnd, x, y, w, h, bm) assert(hwnd == arrange_hwnd); composites[bm] = { x = x, y = y, w = w, h = h }; return 1 end
function R.JS_Composite_Unlink(_, bm) composites[bm] = nil end
function R.JS_Window_GetClientSize() return true, 2000, 800 end
function R.JS_Window_InvalidateRect() end
function R.GetSet_ArrangeView2() return 0, 10 end
function R.GetHZoomLevel() return 200 end
function R.CountTracks() return #mock.state.tracks end
function R.GetTrack(_, i) return mock.state.tracks[i + 1] end
local GHOST = 0xFF8C8C8C -- the "add here" preview line follows the mouse while Option is held
local function count_lines()
  local n = 0
  for bm in pairs(composites) do if bm.color ~= GHOST then n = n + 1 end end
  return n
end
local function line_xs()
  local xs = {}
  for bm, c in pairs(composites) do if bm.color ~= GHOST then xs[#xs + 1] = c.x end end
  table.sort(xs)
  return xs
end

-- arrange-view mouse: screen == client coordinates here
local mouse = { x = 0, y = 0, lmb = false, alt = false, over = true }
local intercepting, messages, msg_clock = false, {}, 0
local other_hwnd = { name = 'other' }
function R.GetMousePosition() return mouse.x, mouse.y end
function R.JS_Window_ScreenToClient(_, x, y) return x, y end
function R.JS_Window_FromPoint() return mouse.over and arrange_hwnd or other_hwnd end
function R.JS_Window_AddressFromHandle(h) return h == arrange_hwnd and 1000 or 1 end
function R.JS_Mouse_GetState(flags) return ((mouse.lmb and 1 or 0) | (mouse.alt and 16 or 0)) & flags end
function R.JS_Mouse_LoadCursor(n) return { n = n } end
function R.JS_Mouse_SetCursor() end
function R.JS_WindowMessage_InterceptList() intercepting = true; return 1 end
function R.JS_WindowMessage_Release() intercepting = false end
function R.JS_WindowMessage_Peek(_, m)
  if not intercepting then return false end
  local e = messages[m] or { time = 0, x = 0 }
  return true, false, e.time, 0, 0, e.x, 0
end
local function mouse_down_at(x)   -- the OS delivers a button-down to the arrange window
  mouse.x, mouse.lmb = x, true
  if intercepting then msg_clock = msg_clock + 1; messages.WM_LBUTTONDOWN = { time = msg_clock, x = x } end
end

function R.GetAppVersion() return '7.82/mock' end
local proj_ext = {}
function R.GetProjExtState(_, sec, key) local v = proj_ext[sec .. '/' .. key]; return v and 1 or 0, v or '' end
function R.SetProjExtState(_, sec, key, v) proj_ext[sec .. '/' .. key] = v; return 1 end
local state_count = 0
function R.GetProjectStateChangeCount() state_count = state_count + 1; return state_count end
function R.GetOS() return 'macOS-arm64' end
function R.GetResourcePath() return '/nonexistent' end
function R.RecursiveCreateDirectory() return 0 end
function R.SectionFromUniqueID() return {} end
local shortcut_ids = { 40029, 40044 }
local shortcut_desc = { [40029] = 'Cmd+Z', [40044] = 'Space' }
function R.kbd_enumerateActions(_, i) return shortcut_ids[i + 1] or 0, 'action' end
function R.CountActionShortcuts(_, id) return shortcut_desc[id] and 1 or 0 end
function R.GetActionShortcutDesc(_, id) return true, shortcut_desc[id] end
local ran_actions = {}
local base_main = R.Main_OnCommand
function R.Main_OnCommand(id, flag) ran_actions[#ran_actions + 1] = id; return base_main(id, flag) end
function R.CreateTrackAudioAccessor(tr) return { track = tr } end
function R.GetAudioAccessorStartTime() return 0 end
function R.GetAudioAccessorEndTime() return 4.5 end
function R.DestroyAudioAccessor(acc) acc.dead = true end
function R.GetAudioAccessorSamples(acc, sr, nch, t, frames, buf)
  if coroutine.isyieldable() then return nil end -- like REAPER: no reads from inside a coroutine
  assert(not acc.dead, 'accessor used after destroy')
  local x = signals[acc.track] or {}
  for f = 0, frames - 1 do
    local v = x[math.floor((t + f / sr) * SR + 0.5) + 1] or 0
    for c = 1, nch do buf[f * nch + c] = v end
  end
  return 1
end
function R.new_array(size)
  local a = {}
  for i = 1, size do a[i] = 0 end
  a.clear = function() for i = 1, size do a[i] = 0 end end
  a.table = function(off, n)
    local t = {}
    for i = 1, n do t[i] = a[off + i - 1] end
    return t
  end
  return a
end

----------------------------------------------------------------------------------------
-- Stub ImGui
----------------------------------------------------------------------------------------

local frame = {}       -- per-frame scripted input
active_tab = 'Detect'  -- which tab the stub reports as open (global: used by the stub table)
local log = {}         -- text output of the current frame
local const_id = 0
local ImGui = {}

local function rv_false(_, _, v) return false, v end
local fns = {
  CreateContext = function() return {} end,
  Begin = function() return true, not frame.close end,
  BeginTabBar = function() return true end,
  BeginPopup = function(_, id) return frame.popup == id end,
  BeginTabItem = function(_, label) return label:find(frame.tab or active_tab, 1, true) ~= nil end,
  BeginChild = function() return true end, BeginTable = function() return true end,
  Button = function(_, label) return frame.press == label end,
  SmallButton = function(_, label) return frame.press == label end,
  RadioButton = function() return false end,
  Checkbox = function(_, label, v) if frame.toggle == label then return true, not v end return false, v end,
  SliderDouble = rv_false, Combo = rv_false,
  GetCursorScreenPos = function() return 0, 100 end,
  GetWindowWidth = function() return 1080 end,
  GetFrameHeight = function() return 24 end,
  CalcTextSize = function(_, text) return #text * 7, 14 end,
  GetCursorPosX = function() return 0 end,
  GetTextLineHeight = function() return 14 end,
  GetFrameHeightWithSpacing = function() return 30 end,
  GetItemRectMax = function() return 100, 120 end,
  GetContentRegionAvail = function() return 1000, 400 end,
  GetTextLineHeightWithSpacing = function() return 17 end,
  GetMousePos = function() return frame.mx or 500, 250 end,
  GetMouseWheel = function() return frame.wheel or 0, 0 end,
  GetMouseDelta = function() return 0, 0 end,
  GetKeyMods = function() return frame.mods or 0 end,
  GetConfigVar = function() return 1 end,
  GetInputQueueCharacter = function() return false end,
  IsItemHovered = function() return true end,
  IsItemActive = function() return frame.down or false end,
  IsItemClicked = function(_, b) return (b or 0) == 0 and frame.click or false end,
  IsMouseDoubleClicked = function() return frame.dbl or false end,
  IsMouseDown = function() return frame.down or false end,
  IsMouseDragging = function() return frame.dragging or false end,
  IsWindowFocused = function() return true end,
  IsAnyItemActive = function() return false end,
  IsKeyPressed = function(_, key) return frame.key == key end,
  GetWindowDrawList = function() return {} end,
  Text = function(_, s) log[#log + 1] = s end,
  TextColored = function(_, _, s) log[#log + 1] = s end,
  TextWrapped = function(_, s) log[#log + 1] = s end,
  BulletText = function(_, s) log[#log + 1] = s end,
}
setmetatable(ImGui, { __index = function(t, k)
  if fns[k] then return fns[k] end
  if k:find('_') and k:sub(1, 1):match('%u') and not k:find('^DrawList_') then
    const_id = const_id + 1
    rawset(t, k, const_id)
    return const_id
  end
  return function() end
end })

package.preload['imgui'] = function() return function() return ImGui end end

----------------------------------------------------------------------------------------
-- Project: kick + snare key tracks, OH, 120 BPM (8th = 0.25 s)
----------------------------------------------------------------------------------------

local kick, snare, oh = mock.add_track('Kick'), mock.add_track('Snare'), mock.add_track('OH')
for _, tr in ipairs({ kick, snare, oh }) do mock.add_item(tr, 0, 4.5) end
local kick_hits, snare_hits, oh_hits = {}, {}, {}
for b = 0, 7 do
  local t = 0.5 + b * 0.5 + ((b % 3) - 1) * 0.006       -- slightly loose timing
  if b % 2 == 0 then kick_hits[#kick_hits + 1] = { t = t, f = 60, amp = 0.8 }
  else
    snare_hits[#snare_hits + 1] = { t = t - 0.015, f = 200, amp = 0.15 } -- flam grace note
    snare_hits[#snare_hits + 1] = { t = t, f = 200, amp = 0.7 }
  end
  oh_hits[#oh_hits + 1] = { t = t + 0.003, f = 900, amp = 0.3 }
end
signals[kick], signals[snare], signals[oh] = make_signal(kick_hits, 4.5), make_signal(snare_hits, 4.5), make_signal(oh_hits, 4.5)
kick.sel, snare.sel = true, true
mock.state.ts, mock.state.te = 0.25, 4.4

----------------------------------------------------------------------------------------
-- Drive frames
----------------------------------------------------------------------------------------

local function run(input)
  frame, log = input or {}, {}
  assert(deferred, 'script did not defer')
  local fn = deferred
  deferred = nil
  clock = clock + 0.04
  fn()
end
local function logged(pat)
  for _, s in ipairs(log) do if s:find(pat) then return s end end
end

R.SetExtState('ReapDetective', 'settings', 'window_view=b1;_version=n2', true)
dofile('Items Editing/ReapDetective.lua')
require('reapdetective.analysis').log_path = nil -- don't write debug.log from tests
run()
run({ press = 'Analyze' })
local guard = 0
repeat run(); guard = guard + 1 until logged('^Found %d+ hits') or guard > 500
local found = logged('^Found (%d+) hits')
assert(found, 'analysis did not finish')
local nhits = tonumber(found:match('^Found (%d+) hits'))
print('analysis found ' .. nhits .. ' hits')
assert(nhits == 8, 'expected 8 hits (4 kicks + 4 flammed snares), got ' .. nhits)

for _ = 1, 10 do run() end
assert(count_lines() == 8, 'expected 8 hit lines on the arrange view, got ' .. count_lines())
for bm, c in pairs(composites) do assert(c.y == 0 and c.h == 160 and bm.color, 'line should span the 2 key tracks') end

-- double-click an empty spot to add a hit, select it with Tab, nudge, delete
run({ dbl = true, click = true, mx = 990 })
run()
assert(count_lines() == 9, 'double-click did not add a hit (expected 9 lines)')
run({ key = ImGui.Key_Tab })
run({ key = ImGui.Key_RightArrow })
run({ key = ImGui.Key_Delete })
run()
assert(count_lines() == 8, 'delete did not remove the selected hit')

-- grab a hit and drag it (x of the first hit: view starts at 0.25 s, 1000 px for 4.15 s)
local x_first = (0.494 - 0.25) / 4.15 * 1000
run({ click = true, down = true, mx = x_first })
run({ down = true, dragging = true, mx = x_first + 2 })
run({ mx = x_first + 2 })
run({ wheel = 1, mx = 300 })
run({ key = ImGui.Key_F })

-- track priority popup: Snare first by default; move Kick up
run({ popup = 'priority' })
assert(logged('TRACK PRIORITY'), 'priority popup not drawn')
assert(logged('Snare'), 'priority popup should list the key tracks')

-- edit hits in the arrange view (waveform view off): 200 px/s, view starts at 0 s
run({ toggle = 'Waveforms here' })
for _ = 1, 8 do run() end
local xs = line_xs()
local x0 = xs[1]
assert(#xs == 8, 'expected 8 hit lines before arrange editing, got ' .. #xs)
mouse.x, mouse.y, mouse.over = x0 + 1, 50, true
run()
assert(intercepting, 'hovering a hit line should capture clicks')
mouse.x = x0 + 60                               -- away from any line, no Option
run()
assert(not intercepting, 'clicks must go back to REAPER away from the lines')
mouse.x = x0 + 1
run()
mouse_down_at(x0 + 1)
run()                                           -- click seen: drag starts
mouse.x = x0 + 21                               -- drag 20 px = 100 ms later
run(); run()
mouse.lmb = false
run(); run()
xs = line_xs()
assert(xs[1] ~= x0 and math.abs(xs[1] - (x0 + 20)) <= 1, ('drag should move the first line by 20 px (%s -> %s)'):format(x0, xs[1]))
-- Option-click on empty space adds a hit, Option-click on a line deletes it
mouse.alt, mouse.x = true, 650
run()
assert(intercepting, 'Option over the cut tracks should capture clicks')
local ghost_seen = false
for bm, c in pairs(composites) do if bm.color == GHOST and c.x == 650 then ghost_seen = true end end
assert(ghost_seen, 'Option over empty space should preview the new hit')
mouse_down_at(650)
run(); mouse.lmb = false; run(); run()
assert(count_lines() == 9, 'Option-click should add a hit, got ' .. count_lines())
mouse.x = 651
run()
mouse_down_at(651)
run(); mouse.lmb = false; run(); run()
assert(count_lines() == 8, 'Option-click on a line should delete it, got ' .. count_lines())
mouse.alt, mouse.x = false, 1500
run(); run()
assert(not intercepting, 'capture released')
-- never start capturing while REAPER owns a drag that passes over a line
mouse.lmb, mouse.x = true, xs[2] or 300
run()
assert(not intercepting, 'must not capture while the button is already down')
mouse.lmb = false
run()

-- separate key tracks + OH
oh.sel = true
local results = {}
local function press(label, pat)
  run({ press = label })
  run()
  local line = logged(pat)
  assert(line, label .. ' failed: ' .. tostring(log[#log]))
  results[#results + 1] = line
end
active_tab = 'Separate'
for _ = 1, 8 do run() end
for _, c in pairs(composites) do assert(c.h == 240, 'lines should cover key tracks + selected OH') end
press('Separate 3 tracks', '^Separated 3 item')
active_tab = 'Quantize'
press('Quantize slices', '^Quantized')
assert(count_lines() == 0, 'lines should be hidden on the Quantize tab')
active_tab = 'Smooth'
press('Smooth', '^Smoothed')
active_tab = 'Detect'
for _, line in ipairs(results) do print(line) end
local tagged = 0
for _, it in ipairs(mock.state.items) do if it.ext['P_EXT:ReapDetective'] then tagged = tagged + 1 end end
assert(tagged == #mock.state.items and tagged > 3, 'items not separated/tagged')
-- flag one slice so the review list has a row to show and jump to
local EM = require 'reapdetective.edit'
for _, it in ipairs(mock.state.items) do
  local tag = EM.get_tag(it)
  if tag and tag.k == 'S' and tag.idx == 3 then EM.flag(it, 'c') end
end
mock.state.cursor = 0
for _ = 1, 15 do run({ tab = 'Quantize' }) end
assert(logged('Same grid line as a neighbor'), 'flagged slice not listed')
local red = 0
for bm in pairs(composites) do if bm.color == 0xFFE64545 then red = red + 1 end end
assert(red >= 1, 'flagged slice should be marked in the arrange view')
for _, it in ipairs(mock.state.items) do assert(it.color == 0, 'flags must not recolor items') end
run({ press = 'Next', tab = 'Quantize' })
assert(mock.state.cursor > 0, 'Next did not jump to the flagged slice')
local selected = 0
for _, it in ipairs(mock.state.items) do if it.sel then selected = selected + 1 end end
assert(selected == 3, 'jump should select the slice on all 3 tracks, got ' .. selected)
run({ press = 'Clear flags', tab = 'Quantize' })
run({ press = 'Re-analyze' })
for _ = 1, 50 do run() end

-- shortcuts pass through to REAPER while the window is focused
ran_actions = {}
run({ key = ImGui.Key_Z, mods = ImGui.Mod_Ctrl })
assert(ran_actions[1] == 40029, 'Cmd+Z was not passed to REAPER')
ran_actions = {}
run({ key = ImGui.Key_Z })
assert(#ran_actions == 0, 'plain Z should not run undo')

-- leaving Detect/Separate releases the arrange view
run()
assert(intercepting, 'mouse is resting on a hit line in Detect')
run({ tab = 'Quantize' })
assert(not intercepting, 'capture should be released outside Detect/Separate')

-- close
run({ close = true })
assert(deferred == nil, 'script kept running after close')
exit_fn()
assert(count_lines() == 0, 'arrange lines not cleaned up on exit')
print('gui smoke test OK')
