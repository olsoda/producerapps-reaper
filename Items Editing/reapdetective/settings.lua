-- @noindex
-- Reap Detective: settings with defaults, persisted in REAPER's global ExtState.

local S = {}

S.SECTION = 'ReapDetective'

S.GRIDS = {
  { label = '1/4',  qn = 1 },
  { label = '1/8',  qn = 1 / 2 },
  { label = '1/16', qn = 1 / 4 },
  { label = '1/32', qn = 1 / 8 },
  { label = '1/64', qn = 1 / 16 },
}

S.MAX_MOVES = {
  { label = 'Off (never flag)', qn = nil },
  { label = '1/32',  qn = 1 / 8 },
  { label = '1/48',  qn = 1 / 12 },
  { label = '1/64',  qn = 1 / 16 },
  { label = '1/96',  qn = 1 / 24 },
  { label = '1/128', qn = 1 / 32 },
}

-- REAPER's crossfade shapes, in C_FADEINSHAPE/C_FADEOUTSHAPE index order (0-based).
S.FADE_SHAPE_LABELS = 'Linear (equal gain)\0Slight convex (equal power)\0Slight concave\0' ..
  'Sharp convex\0Sharp concave\0Slight S-curve\0Sharp S-curve\0'

S.FADE_MODES = { 'pre', 'center', 'post' }
S.FADE_MODE_LABELS = 'Before slice start (protects transient)\0Centered on slice start\0After slice start (inside pad)\0'

S.defaults = {
  -- detection
  thr_db       = -30,    -- dB below each key track's peak
  sens_db      = 8,      -- minimum rise (dB) within 5 ms
  retrig_ms    = 30,     -- flam / retrigger window, within and across key tracks
  anchor       = 2,      -- onset that gets quantized: 0 first, 1 loudest, 2 highest-priority track
  arrange_view = 1,      -- show hits in the arrange view: 0 off, 1 lines (js_ReaScriptAPI), 2 markers
  window_view  = false,  -- also show the waveform/hit view inside the script window
  -- separation
  pad_ms       = 5,      -- split this far before the transient
  trim_ms      = 10,     -- shorten each slice's tail so slices can move without overlapping
  -- quantize
  grid         = 3,      -- index into GRIDS (1/16)
  triplet      = false,
  use_proj_grid = false,
  strength     = 100,    -- percent
  exclude_ms   = 0,      -- hits already this close to the grid are left alone
  max_move     = 2,      -- index into MAX_MOVES (1/32)
  move_flagged = false,  -- move flagged slices anyway (they are listed either way)
  -- smoothing
  xfade        = true,   -- false = fill gaps only (butt splices)
  xfade_ms     = 10,
  fade_mode    = 1,      -- index into FADE_MODES
  fade_shape   = 1,      -- REAPER shape index (0-based): 1 = slight convex, equal power
  smart_fill   = true,   -- avoid double hits by filling from the next slice's head when needed
}

local function encode(v)
  if type(v) == 'boolean' then return v and 'b1' or 'b0' end
  return 'n' .. tostring(v)
end

local function decode(s)
  local tag, rest = s:sub(1, 1), s:sub(2)
  if tag == 'b' then return rest == '1' end
  if tag == 'n' then return tonumber(rest) end
end

-- Bump VERSION when defaults change; keys listed for a version are reset to the new
-- default once for settings saved by an older version.
S.VERSION = 3
S.RESET_ON_UPGRADE = { [2] = { 'max_move', 'xfade_ms', 'fade_shape' }, [3] = { 'anchor' } }

function S.load()
  local cfg = {}
  for k, v in pairs(S.defaults) do cfg[k] = v end
  local raw = reaper.GetExtState(S.SECTION, 'settings')
  local saved_ver = tonumber(raw:match('_version=n(%d+)')) or (raw ~= '' and 1 or S.VERSION)
  for k, v in raw:gmatch('([%w_]+)=([^;]*)') do
    local val = decode(v)
    if val ~= nil and S.defaults[k] ~= nil and type(val) == type(S.defaults[k]) then cfg[k] = val end
  end
  for ver = saved_ver + 1, S.VERSION do
    for _, k in ipairs(S.RESET_ON_UPGRADE[ver] or {}) do cfg[k] = S.defaults[k] end
  end
  return cfg
end

function S.save(cfg)
  local parts = {}
  for k in pairs(S.defaults) do parts[#parts + 1] = k .. '=' .. encode(cfg[k]) end
  parts[#parts + 1] = '_version=' .. encode(S.VERSION)
  table.sort(parts)
  reaper.SetExtState(S.SECTION, 'settings', table.concat(parts, ';'), true)
end

-- Grid size in QN for quantizing.
function S.grid_qn(cfg)
  if cfg.use_proj_grid then
    local _, div = reaper.GetSetProjectGrid(0, false)
    if div and div > 0 then return div * 4 end -- project grid is in whole notes
  end
  local qn = S.GRIDS[cfg.grid].qn
  if cfg.triplet then qn = qn * 2 / 3 end
  return qn
end

return S
