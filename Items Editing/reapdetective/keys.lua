-- @noindex
-- Reap Detective: keep REAPER's keyboard shortcuts working while the window has focus.
--
-- ReaImGui passes global-scope shortcuts through to REAPER, but normal-scope ones (Cmd+Z,
-- Space, ...) are swallowed by the focused window. This reads the Main section's shortcuts
-- (including the user's own bindings) and runs the matching action when its key chord is
-- pressed in our window. Global-scope shortcuts are skipped since REAPER already gets them.

local K = {}

-- REAPER key names -> ImGui key constant names
local NAMED = {
  ['Space'] = 'Key_Space', ['Return'] = 'Key_Enter', ['Enter'] = 'Key_Enter',
  ['Esc'] = 'Key_Escape', ['Escape'] = 'Key_Escape', ['Tab'] = 'Key_Tab',
  ['Backspace'] = 'Key_Backspace', ['Delete'] = 'Key_Delete', ['Del'] = 'Key_Delete',
  ['Insert'] = 'Key_Insert', ['Ins'] = 'Key_Insert', ['Home'] = 'Key_Home', ['End'] = 'Key_End',
  ['Page Up'] = 'Key_PageUp', ['PageUp'] = 'Key_PageUp', ['Pg Up'] = 'Key_PageUp',
  ['Page Down'] = 'Key_PageDown', ['PageDown'] = 'Key_PageDown', ['Pg Down'] = 'Key_PageDown',
  ['Left'] = 'Key_LeftArrow', ['Right'] = 'Key_RightArrow', ['Up'] = 'Key_UpArrow', ['Down'] = 'Key_DownArrow',
  ['NumPad +'] = 'Key_KeypadAdd', ['NumPad -'] = 'Key_KeypadSubtract', ['NumPad *'] = 'Key_KeypadMultiply',
  ['NumPad /'] = 'Key_KeypadDivide', ['NumPad .'] = 'Key_KeypadDecimal', ['NumPad Enter'] = 'Key_KeypadEnter',
  ['NumPad ='] = 'Key_KeypadEqual',
  ['-'] = 'Key_Minus', ['='] = 'Key_Equal', ['['] = 'Key_LeftBracket', [']'] = 'Key_RightBracket',
  [';'] = 'Key_Semicolon', ["'"] = 'Key_Apostrophe', [','] = 'Key_Comma', ['.'] = 'Key_Period',
  ['/'] = 'Key_Slash', ['\\'] = 'Key_Backslash', ['`'] = 'Key_GraveAccent',
}

-- REAPER modifier names (macOS and Windows/Linux spellings) -> logical modifier
local MODS = {
  Cmd = 'cmd', Opt = 'alt', Alt = 'alt', Shift = 'shift', Control = 'ctrl', Ctrl = 'ctrl', Win = 'super',
}

-- Split a REAPER shortcut description into modifiers and key name.
-- Returns mods (set of logical modifiers), key name, kind ('key' | 'char' | nil if unusable).
function K.parse(desc)
  local mods, rest = {}, desc
  local changed = true
  while changed do
    changed = false
    local name, tail = rest:match('^(%a+)%+(.+)$')
    if name and MODS[name] then
      mods[MODS[name]] = true
      rest, changed = tail, true
    end
  end
  if NAMED[rest] then return mods, NAMED[rest], 'key' end
  if rest:match('^%u$') or rest:match('^%d$') then return mods, 'Key_' .. rest, 'key' end
  local fn = rest:match('^F(%d%d?)$')
  if fn and tonumber(fn) >= 1 and tonumber(fn) <= 24 then return mods, 'Key_F' .. fn, 'key' end
  if rest:match('^NumPad (%d)$') then return mods, 'Key_Keypad' .. rest:match('(%d)$'), 'key' end
  -- a typed character such as '+' or '>' (shifted keys bound by character)
  if #rest == 1 and rest:match('%p') and not mods.cmd and not mods.alt and not mods.ctrl then
    return mods, rest, 'char'
  end
  return mods, nil, nil -- mouse wheel, MIDI, etc.
end

-- Shortcut descriptions REAPER treats as global ("glob hotkey" entries in reaper-kb.ini).
function K.read_globals(path)
  local globals = {}
  local f = io.open(path, 'r')
  if not f then return globals end
  for line in f:lines() do
    local desc = line:match('^KEY%s+%d+%s+%d+%s+%S+%s+102%s.-#%s*glob hotkey%s*:%s*(.-)%s*:')
    if desc and desc ~= '' then globals[desc] = true end
  end
  f:close()
  return globals
end

-- Build the forwarding table. ImGui is the ReaImGui module, ctx a context.
function K.build(ImGui, ctx)
  local r = reaper
  local mac = r.GetOS():find('OSX') or r.GetOS():find('mac')
  local swap = mac and ImGui.GetConfigVar(ctx, ImGui.ConfigVar_MacOSXBehaviors) ~= 0
  -- with ImGui's macOS behaviors the Cmd key is reported as Ctrl and Control as Super
  local MODBIT = {
    shift = ImGui.Mod_Shift, alt = ImGui.Mod_Alt,
    cmd = swap and ImGui.Mod_Ctrl or ImGui.Mod_Super,
    ctrl = (mac and swap) and ImGui.Mod_Super or ImGui.Mod_Ctrl,
    super = ImGui.Mod_Super,
  }
  local globals = K.read_globals(r.GetResourcePath() .. '/reaper-kb.ini')
  local sec = r.SectionFromUniqueID(0)
  local keys, chars = {}, {}
  local idx = 0
  while true do
    local cmd, name = r.kbd_enumerateActions(sec, idx)
    if not cmd or cmd == 0 then break end
    idx = idx + 1
    local n = r.CountActionShortcuts(sec, cmd)
    if n > 0 and not (name or ''):find('Momentarily') then
      for i = 0, n - 1 do
        local _, desc = r.GetActionShortcutDesc(sec, cmd, i)
        if desc and not globals[desc] then
          local mods, key, kind = K.parse(desc)
          local ok, code = pcall(function() return key and ImGui[key] end)
          if kind == 'key' and ok and code then
            local bits = 0
            for m in pairs(mods) do bits = bits | MODBIT[m] end
            keys[#keys + 1] = { key = code, mods = bits, cmd = cmd, desc = desc }
          elseif kind == 'char' then
            chars[utf8.codepoint(key)] = { cmd = cmd, desc = desc }
          end
        end
      end
    end
  end
  return { keys = keys, chars = chars }
end

-- Run REAPER actions for shortcuts pressed this frame. `consumed` is a set of ImGui keys the
-- window already used itself. Returns the description of the shortcut it ran, if any.
function K.forward(ImGui, ctx, map, consumed)
  local mods = ImGui.GetKeyMods(ctx)
  for _, e in ipairs(map.keys) do
    if e.mods == mods and not consumed[e.key] and ImGui.IsKeyPressed(ctx, e.key, false) then
      reaper.Main_OnCommand(e.cmd, 0)
      return e.desc
    end
  end
  local i = 0
  while true do
    local ok, c = ImGui.GetInputQueueCharacter(ctx, i)
    if not ok then break end
    local e = map.chars[c]
    if e then
      reaper.Main_OnCommand(e.cmd, 0)
      return e.desc
    end
    i = i + 1
  end
end

return K
