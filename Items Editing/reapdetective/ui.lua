-- @noindex
-- Reap Detective: theme + small widgets for the ReaImGui window.
--
-- Design rules (Refactoring UI): one primary action per step, hierarchy through
-- color/weight before size, three text colors, spacing from a fixed scale
-- (4 8 12 16 24 32), labels left of their controls, more space around groups than within.

local U = {}

local ImGui, ctx
local fonts = {}

-- Palette (0xRRGGBBAA). Greys lean blue so the dark UI doesn't feel muddy.
U.C = {
  bg = 0x15181DFF, surface = 0x1C2027FF, frame = 0x242932FF, frame_hi = 0x2C323CFF,
  frame_act = 0x353C48FF, border = 0x2A2F38FF,
  text = 0xE4E7ECFF, text2 = 0xA7ADB8FF, text3 = 0x7E8592FF,
  accent = 0x3D8BF2FF, accent_hi = 0x5A9DF5FF, accent_lo = 0x2F76D6FF, accent_bg = 0x3D8BF233,
  ok = 0x7DD38AFF, warn = 0xF2B04AFF, err = 0xF26B6BFF,
  -- hit view
  view_bg = 0x111317FF, lane_alt = 0x15181DFF, ruler = 0x191C22FF, head = 0x1A1D23FF, head_alt = 0x1D2027FF,
  wave = 0x4F92DCD9, wave_off = 0x3A404AFF, thr = 0xF26B6B66,
  bar = 0xFFFFFF2E, beat = 0xFFFFFF14, sub = 0xFFFFFF08,
  hit = 0xFFC400B3, hit_moved = 0x6EE07AB3, hit_added = 0x40D0FFB3, hit_sel = 0xFFFFFFFF,
  pad = 0xFFC4002E, anchor = 0xFF8A1AFF, edit_cur = 0xD8D8D880, play_cur = 0x50FF50D0,
  out_range = 0x0000009A, pill = 0x0E1014D9,
}
local C = U.C

U.SP = { xs = 4, sm = 8, md = 12, lg = 16, xl = 24 }
U.LABEL_W = 112
U.CONTROL_W = 230

-- Constant lookup that tolerates names missing from older ReaImGui versions.
local function K(name)
  local ok, v = pcall(function() return ImGui[name] end)
  return ok and v or nil
end
U.K = K

function U.init(imgui, context)
  ImGui, ctx = imgui, context
  local ok = pcall(function()
    fonts.regular = ImGui.CreateFont('sans-serif', 14)
    fonts.bold = ImGui.CreateFont('sans-serif', 14, ImGui.FontFlags_Bold)
    ImGui.Attach(ctx, fonts.regular)
    ImGui.Attach(ctx, fonts.bold)
  end)
  if not ok then fonts = {} end
end

----------------------------------------------------------------------------------------
-- Theme
----------------------------------------------------------------------------------------

local VARS = {
  { 'StyleVar_WindowPadding', 16, 12 }, { 'StyleVar_FramePadding', 8, 5 },
  { 'StyleVar_ItemSpacing', 8, 8 }, { 'StyleVar_ItemInnerSpacing', 6, 6 },
  { 'StyleVar_CellPadding', 8, 5 }, { 'StyleVar_FrameRounding', 5 }, { 'StyleVar_GrabRounding', 4 },
  { 'StyleVar_GrabMinSize', 12 }, { 'StyleVar_ChildRounding', 8 }, { 'StyleVar_PopupRounding', 6 },
  { 'StyleVar_TabRounding', 6 }, { 'StyleVar_WindowRounding', 8 }, { 'StyleVar_ScrollbarSize', 10 },
  { 'StyleVar_ScrollbarRounding', 8 }, { 'StyleVar_FrameBorderSize', 0 }, { 'StyleVar_ChildBorderSize', 0 },
  { 'StyleVar_TabBarBorderSize', 0 },
}

local COLORS = {
  { 'Col_WindowBg', C.bg }, { 'Col_ChildBg', C.surface }, { 'Col_PopupBg', 0x1F232AFA },
  { 'Col_Border', C.border }, { 'Col_FrameBg', C.frame }, { 'Col_FrameBgHovered', C.frame_hi },
  { 'Col_FrameBgActive', C.frame_act }, { 'Col_Button', C.frame_hi }, { 'Col_ButtonHovered', C.frame_act },
  { 'Col_ButtonActive', 0x3E4654FF }, { 'Col_Header', C.frame_hi }, { 'Col_HeaderHovered', C.frame_act },
  { 'Col_HeaderActive', C.accent_bg }, { 'Col_SliderGrab', C.accent }, { 'Col_SliderGrabActive', C.accent_hi },
  { 'Col_CheckMark', C.accent_hi }, { 'Col_Tab', 0x00000000 }, { 'Col_TabHovered', C.frame_hi },
  { { 'Col_TabSelected', 'Col_TabActive' }, C.frame }, { 'Col_TabSelectedOverline', C.accent },
  { { 'Col_TabDimmed', 'Col_TabUnfocused' }, 0x00000000 },
  { { 'Col_TabDimmedSelected', 'Col_TabUnfocusedActive' }, C.frame }, { 'Col_TabDimmedSelectedOverline', C.accent },
  { 'Col_Text', C.text }, { 'Col_TextDisabled', C.text3 },
  { 'Col_Separator', C.border }, { 'Col_TableHeaderBg', 0x00000000 }, { 'Col_TableRowBg', 0x00000000 },
  { 'Col_TableRowBgAlt', 0xFFFFFF05 }, { 'Col_TableBorderLight', C.border }, { 'Col_TableBorderStrong', C.border },
  { 'Col_ScrollbarBg', 0x00000000 }, { 'Col_ScrollbarGrab', C.frame_hi }, { 'Col_ScrollbarGrabHovered', C.frame_act },
  { 'Col_ScrollbarGrabActive', C.accent }, { 'Col_TitleBg', C.bg }, { 'Col_TitleBgActive', C.bg },
  { 'Col_TitleBgCollapsed', C.bg }, { 'Col_ResizeGrip', 0x00000000 }, { 'Col_PlotHistogram', C.accent },
}

local pushed_vars, pushed_cols = 0, 0

function U.push_theme()
  pushed_vars, pushed_cols = 0, 0
  for _, v in ipairs(VARS) do
    local id = K(v[1])
    if id then ImGui.PushStyleVar(ctx, id, v[2], v[3]); pushed_vars = pushed_vars + 1 end
  end
  for _, c in ipairs(COLORS) do
    local id
    if type(c[1]) == 'table' then
      for _, name in ipairs(c[1]) do id = id or K(name) end
    else
      id = K(c[1])
    end
    if id then ImGui.PushStyleColor(ctx, id, c[2]); pushed_cols = pushed_cols + 1 end
  end
end

function U.pop_theme()
  ImGui.PopStyleColor(ctx, pushed_cols)
  ImGui.PopStyleVar(ctx, pushed_vars)
end

function U.push_font(bold)
  local f = bold and fonts.bold or fonts.regular
  if f then ImGui.PushFont(ctx, f); return true end
  return false
end

function U.pop_font(pushed) if pushed then ImGui.PopFont(ctx) end end

-- Run fn with the bold font (falls back to the regular font).
function U.bold(fn)
  local p = U.push_font(true)
  fn()
  U.pop_font(p)
end

----------------------------------------------------------------------------------------
-- Text
----------------------------------------------------------------------------------------

function U.text(s, col) ImGui.TextColored(ctx, col or C.text, s) end
function U.text2(s) ImGui.TextColored(ctx, C.text2, s) end
function U.text3(s) ImGui.TextColored(ctx, C.text3, s) end

-- Wrapped tertiary paragraph (help copy).
function U.hint(s)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
  ImGui.TextWrapped(ctx, s)
  ImGui.PopStyleColor(ctx)
end

function U.tip(s) if s then ImGui.SetItemTooltip(ctx, s) end end

-- Small uppercase group title with extra space above it (more space around than within).
function U.section(title, first)
  if not first then ImGui.Dummy(ctx, 0, U.SP.xs) end
  U.bold(function() ImGui.TextColored(ctx, C.text3, title:upper()) end)
end

-- Shorten s with an ellipsis so it fits in max_w pixels.
function U.truncate(s, max_w)
  if ImGui.CalcTextSize(ctx, s) <= max_w then return s end
  local lo, hi = 0, #s
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if ImGui.CalcTextSize(ctx, s:sub(1, mid) .. '…') <= max_w then lo = mid else hi = mid - 1 end
  end
  return s:sub(1, lo) .. '…'
end

----------------------------------------------------------------------------------------
-- Flow layout: groups sit side by side and wrap to the next line when out of room
----------------------------------------------------------------------------------------

local flow_first = true

function U.flow_begin() flow_first = true end

-- Call before drawing a group that is `width` pixels wide.
function U.flow(width)
  if flow_first then flow_first = false; return end
  ImGui.SameLine(ctx, 0, U.SP.lg)
  if ImGui.GetContentRegionAvail(ctx) < width then ImGui.NewLine(ctx) end
end

-- Inline "Label [control]" group in a flow; sizes the next control.
function U.inline(label, width, help)
  U.flow(ImGui.CalcTextSize(ctx, label) + 6 + width)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.TextColored(ctx, C.text2, label)
  U.tip(help)
  ImGui.SameLine(ctx, 0, 6)
  ImGui.SetNextItemWidth(ctx, width)
end

----------------------------------------------------------------------------------------
-- Rows: label on the left, control in a fixed column
----------------------------------------------------------------------------------------

function U.label(label, help)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.TextColored(ctx, C.text2, label)
  U.tip(help)
  ImGui.SameLine(ctx, U.LABEL_W)
end

-- Start a row and size the next control. width < 0 fills the remaining space.
function U.row(label, help, width)
  U.label(label, help)
  ImGui.SetNextItemWidth(ctx, width or U.CONTROL_W)
end

-- Indent to the control column without a label (for checkboxes that belong to a group).
function U.row_blank()
  ImGui.Dummy(ctx, 0, 0)
  ImGui.SameLine(ctx, U.LABEL_W)
end

----------------------------------------------------------------------------------------
-- Buttons: one primary per screen, secondary for the rest, tertiary for minor actions
----------------------------------------------------------------------------------------

function U.primary(label, w, h)
  h = h or ImGui.GetFrameHeight(ctx)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, C.accent)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, C.accent_hi)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, C.accent_lo)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFFFFFFF)
  local p = U.push_font(true)
  local pressed = ImGui.Button(ctx, label, w or 0, h)
  U.pop_font(p)
  ImGui.PopStyleColor(ctx, 4)
  return pressed
end

function U.secondary(label, w, h)
  return ImGui.Button(ctx, label, w or 0, h or 0)
end

function U.tertiary(label)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x00000000)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, C.frame)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, C.frame_hi)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent_hi)
  local pressed = ImGui.Button(ctx, label)
  ImGui.PopStyleColor(ctx, 4)
  return pressed
end

-- Segmented control: returns the clicked index (1-based) or nil.
function U.segmented(options, current)
  local clicked
  for i, label in ipairs(options) do
    if i > 1 then ImGui.SameLine(ctx, 0, 2) end
    local on = i == current
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, on and C.accent_bg or C.frame)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, on and C.accent_bg or C.frame_hi)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, on and C.accent_hi or C.text2)
    if ImGui.Button(ctx, label) then clicked = i end
    ImGui.PopStyleColor(ctx, 3)
  end
  return clicked
end

----------------------------------------------------------------------------------------
-- Callouts and decorations
----------------------------------------------------------------------------------------

-- Inline notice with a colored bar on the left. Returns true if its button was pressed.
function U.callout(col, s, button)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.Indent(ctx, 10)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, col)
  ImGui.TextWrapped(ctx, s)
  ImGui.PopStyleColor(ctx)
  local pressed = false
  if button then pressed = U.tertiary(button) end
  ImGui.Unindent(ctx, 10)
  local _, y2 = ImGui.GetItemRectMax(ctx)
  ImGui.DrawList_AddRectFilled(dl, x, y + 1, x + 3, y2, col, 1.5)
  return pressed
end

function U.dot(dl, x, y, col, radius)
  ImGui.DrawList_AddCircleFilled(dl, x, y, radius or 4, col)
end

-- Rounded label background drawn behind text at (x, y).
function U.pill(dl, x, y, s, fg, bg)
  local w, h = ImGui.CalcTextSize(ctx, s)
  ImGui.DrawList_AddRectFilled(dl, x - 6, y - 2, x + w + 6, y + h + 2, bg or C.pill, 4)
  ImGui.DrawList_AddText(dl, x, y, fg or C.text, s)
  return w + 12
end

return U
