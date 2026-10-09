-- @noindex
-- Reap Detective: pure logic (no reaper.* calls) so it can be unit tested outside REAPER.
--
-- Terminology
--   onset   : a transient found on one key track
--   hit     : one or more onsets merged by the retrigger window (a flam, or kick+snare
--             played slightly apart, becomes one hit)
--   t       : earliest onset time of a hit; the slice is split at t - pad
--   a       : anchor time of a hit; this is what gets quantized to the grid
--   slice   : the piece of audio from one split point to the next

local M = {}

local floor, max, min, abs, log = math.floor, math.max, math.min, math.abs, math.log

M.SILENCE_DB = -240

function M.db(x)
  if x <= 1e-12 then return M.SILENCE_DB end
  return 20 * log(x, 10)
end

function M.lin(d) return 10 ^ (d / 20) end

----------------------------------------------------------------------------------------
-- Envelope
----------------------------------------------------------------------------------------

-- Reduce an interleaved sample chunk to per-block peak levels in dB.
-- buf: Lua table of interleaved samples (frames * nch values)
-- Appends to out (starting at index out_n + 1) and returns the new out_n.
function M.block_peaks_db(buf, frames, nch, hop_n, out, out_n)
  local blocks = floor(frames / hop_n)
  local stride = hop_n * nch
  for b = 0, blocks - 1 do
    local m = 0
    local base = b * stride
    for i = base + 1, base + stride do
      local v = buf[i]
      if v < 0 then v = -v end
      if v > m then m = v end
    end
    out_n = out_n + 1
    out[out_n] = M.db(m)
  end
  return out_n
end

-- Sliding maximum over the last w values (inclusive), O(n).
function M.sliding_max(d, n, w)
  local out, dq, head, tail = {}, {}, 1, 0
  for k = 1, n do
    local v = d[k]
    while tail >= head and d[dq[tail]] <= v do tail = tail - 1 end
    tail = tail + 1; dq[tail] = k
    if dq[head] <= k - w then head = head + 1 end
    out[k] = d[dq[head]]
  end
  return out
end

-- Max-pyramid for fast waveform drawing. mip[1] = d, mip[L][i] = max of 2^(L-1) blocks.
function M.build_mip(d, n)
  local mip, sizes = { d }, { n }
  local L = 1
  while sizes[L] > 1 do
    local src, sn, dst = mip[L], sizes[L], {}
    local dn = 0
    for i = 1, sn, 2 do
      dn = dn + 1
      local a, b = src[i], src[i + 1]
      dst[dn] = (b and b > a) and b or a
    end
    L = L + 1
    mip[L], sizes[L] = dst, dn
  end
  return mip, sizes
end

----------------------------------------------------------------------------------------
-- Detection
----------------------------------------------------------------------------------------

M.HOLD_S = 0.020   -- held-peak window; must span at least half a period of the lowest drum
M.RISE_S = 0.005   -- attacks must rise by `sens` dB within this window
M.LEVEL_S = 0.010  -- window after detection used to measure a hit's level

-- Detect onsets on one track envelope.
-- env: { db = {...}, hold = {...}, n = blocks, hop = seconds, t0 = time of block 1, peak = dB }
-- p:   { thr = dB relative to track peak (<= 0), sens = rise in dB, retrig = seconds }
-- Returns list of { k = detection block, j = first block of the attack,
--                   base = level the attack rose from (dB), lvl = hit level re track peak,
--                   t = block-accurate onset time }
function M.detect(env, p)
  local D, Hd, n, hop = env.db, env.hold, env.n, env.hop
  local out = {}
  if not n or n < 2 or env.peak <= -120 then return out end
  local R = max(1, floor(M.RISE_S / hop + 0.5))
  local lvlN = max(1, floor(M.LEVEL_S / hop + 0.5))
  local retrigN = max(1, floor(p.retrig / hop + 0.5))
  local thr = env.peak + p.thr
  local sens = p.sens
  local last = -1e9
  for k = R + 1, n do
    local dk = D[k]
    if k - last >= retrigN then
      local base = Hd[k - R]
      if dk - base >= sens then
        local lv = dk
        for q = k + 1, min(n, k + lvlN) do if D[q] > lv then lv = D[q] end end
        if lv >= thr then
          local j = k
          for q = k - R + 1, k do
            if D[q] > base + 1.0 then j = q; break end
          end
          out[#out + 1] = {
            k = k, j = j, base = base, lvl = lv - env.peak,
            t = env.t0 + (j - 1) * hop,
          }
          last = k
        end
      end
    end
  end
  return out
end

-- Sample-accurate onset: first sample whose magnitude exceeds thr_lin.
-- buf: interleaved samples starting at time ts. Returns time or nil.
function M.refine_onset(buf, frames, nch, sr, ts, thr_lin)
  for f = 0, frames - 1 do
    local base = f * nch
    for c = 1, nch do
      local v = buf[base + c]
      if v > thr_lin or -v > thr_lin then return ts + f / sr end
    end
  end
  return nil
end

----------------------------------------------------------------------------------------
-- Merging (retrigger / flam window across tracks)
----------------------------------------------------------------------------------------

-- onsets: list of { t, lvl, tr }. win: seconds. anchor: 'first' | 'loudest'
-- A hit absorbs every onset that starts within `win` of the hit's first onset.
function M.merge(onsets, win, anchor)
  table.sort(onsets, function(x, y) return x.t < y.t end)
  local hits, cur = {}, nil
  for i = 1, #onsets do
    local o = onsets[i]
    if cur and o.t - cur.t < win then
      cur.n = cur.n + 1
      cur.tracks[o.tr] = true
      if o.lvl > cur.lvl then cur.lvl, cur.loud_t = o.lvl, o.t end
    else
      cur = { t = o.t, loud_t = o.t, lvl = o.lvl, n = 1, tracks = { [o.tr] = true }, tr = o.tr }
      hits[#hits + 1] = cur
    end
  end
  for i = 1, #hits do
    local h = hits[i]
    h.a = (anchor == 'loudest') and h.loud_t or h.t
  end
  return hits
end

----------------------------------------------------------------------------------------
-- Manual edits layered over automatic detection
----------------------------------------------------------------------------------------

M.EDIT_TOL = 0.002 -- an edit applies to the auto hit within 2 ms of where it was made

function M.new_edits() return { adds = {}, dels = {}, moves = {}, next_id = 1 } end

local function find_near(list, t, field, tol)
  for i = 1, #list do
    local v = field and list[i][field] or list[i]
    if abs(v - t) <= tol then return i end
  end
end

-- Returns a sorted list of hits. Each hit gets:
--   key  : stable identity for selection ('a:<orig t>' or 'm:<id>')
--   kind : 'auto' | 'moved' | 'added'
--   orig : original auto t (auto/moved only)
function M.apply_edits(auto_hits, edits, tol)
  tol = tol or M.EDIT_TOL
  local out = {}
  for i = 1, #auto_hits do
    local h = auto_hits[i]
    if not find_near(edits.dels, h.t, nil, tol) then
      local mi = find_near(edits.moves, h.t, 'from', tol)
      local o = { t = h.t, a = h.a, lvl = h.lvl, tr = h.tr, n = h.n, orig = h.t,
                  key = ('a:%.6f'):format(h.t), kind = 'auto' }
      if mi then
        local m = edits.moves[mi]
        local d = m.to - h.t
        o.t, o.a, o.kind, o.key = m.to, h.a + d, 'moved', ('a:%.6f'):format(m.from)
      end
      out[#out + 1] = o
    end
  end
  for i = 1, #edits.adds do
    local ad = edits.adds[i]
    out[#out + 1] = { t = ad.t, a = ad.t, lvl = 0, n = 1, key = 'm:' .. ad.id, kind = 'added', id = ad.id }
  end
  table.sort(out, function(x, y) return x.t < y.t end)
  return out
end

function M.edit_add(edits, t)
  local id = edits.next_id
  edits.next_id = id + 1
  edits.adds[#edits.adds + 1] = { id = id, t = t }
  return 'm:' .. id
end

function M.edit_move(edits, hit, new_t)
  if hit.kind == 'added' then
    for i = 1, #edits.adds do
      if edits.adds[i].id == hit.id then edits.adds[i].t = new_t end
    end
    return
  end
  local mi = find_near(edits.moves, hit.orig, 'from', M.EDIT_TOL)
  if mi then
    edits.moves[mi].to = new_t
  else
    edits.moves[#edits.moves + 1] = { from = hit.orig, to = new_t }
  end
end

function M.edit_delete(edits, hit)
  if hit.kind == 'added' then
    for i = #edits.adds, 1, -1 do
      if edits.adds[i].id == hit.id then table.remove(edits.adds, i) end
    end
    return
  end
  local mi = find_near(edits.moves, hit.orig, 'from', M.EDIT_TOL)
  if mi then table.remove(edits.moves, mi) end
  edits.dels[#edits.dels + 1] = hit.orig
end

function M.edit_count(edits)
  return #edits.adds + #edits.dels + #edits.moves
end

----------------------------------------------------------------------------------------
-- Separation plan
----------------------------------------------------------------------------------------

-- Turn hits into slices. Each slice starts at s = t - pad (clamped into the range).
-- Hits closer than min_len to the previous split are dropped (reported in `dropped`).
-- Returns slices = { { s, t, a, prev_t, next_s }, ... }, dropped
function M.split_plan(hits, pad, min_len, rs, re)
  local slices, dropped = {}, 0
  for i = 1, #hits do
    local h = hits[i]
    if h.t >= rs and h.t < re then
      local s = max(rs, h.t - pad)
      local last = slices[#slices]
      if s > re - min_len then
        dropped = dropped + 1
      elseif last and s - last.s < min_len then
        dropped = dropped + 1
      else
        slices[#slices + 1] = { s = s, t = h.t, a = h.a }
      end
    end
  end
  for i = 1, #slices do
    local sl = slices[i]
    sl.next_s = slices[i + 1] and slices[i + 1].s or re
    sl.prev_t = slices[i - 1] and slices[i - 1].t or max(rs, sl.t - 0.1)
  end
  return slices, dropped
end

-- Which slot a time falls in: 0 = before the first split, i = slice i, #slices+1 = at/after re.
function M.slot_of(slices, re, t, eps)
  eps = eps or 1e-7
  if t >= re - eps then return #slices + 1 end
  local lo, hi, ans = 1, #slices, 0
  while lo <= hi do
    local mid = (lo + hi) // 2
    if slices[mid].s <= t + eps then ans = mid; lo = mid + 1 else hi = mid - 1 end
  end
  return ans
end

----------------------------------------------------------------------------------------
-- Quantize math
----------------------------------------------------------------------------------------

-- Nearest grid line to qn, with the grid restarting at each measure (odd meters work).
-- ms/me = measure start/end in QN, div = grid size in QN.
function M.grid_target(qn, ms, me, div)
  local q1 = ms + floor((qn - ms) / div + 1e-9) * div
  local q2 = q1 + div
  if me and q2 > me + 1e-9 then q2 = me end
  if qn - q1 <= q2 - qn then return q1 end
  return q2
end

----------------------------------------------------------------------------------------
-- Smoothing (fill gaps + crossfade) plan for one boundary
----------------------------------------------------------------------------------------

-- A = earlier slice, B = later slice on the same track, all times on the timeline:
--   A.start, A.safe_end   (A's tail may extend up to here without reaching the next hit)
--   B.nom_start, B.stop, B.head_safe  (B's head may extend back to here)
-- xf: crossfade length, mode: 'pre' | 'center' | 'post', smart: avoid double hits.
-- Returns { a_end, b_start, fade, flag, reason } or nil when the pair can't be joined.
function M.smooth_pair(A, B, xf, mode, smart, min_len)
  min_len = min_len or 0.001
  local left, right
  if mode == 'post' then left, right = 0, xf
  elseif mode == 'center' then left, right = xf / 2, xf / 2
  else left, right = xf, 0 end

  local boundary = B.nom_start
  if smart and A.safe_end and A.safe_end - right < boundary then
    boundary = A.safe_end - right
    if B.head_safe and boundary - left < B.head_safe then
      -- neither side can cover the gap cleanly; keep B's head safe, let A's tail run long
      boundary = min(B.nom_start, B.head_safe + left)
    end
  end

  local a_end, b_start = boundary + right, boundary - left
  if a_end - A.start < min_len or B.stop - b_start < min_len then return nil end

  local flag, reason = false, nil
  if A.safe_end and a_end > A.safe_end + 1e-4 then
    flag, reason = true, 'tail'
  elseif B.head_safe and b_start < B.head_safe - 1e-4 then
    flag, reason = true, 'head'
  end
  return { a_end = a_end, b_start = b_start, fade = left + right, flag = flag, reason = reason }
end

----------------------------------------------------------------------------------------
-- Item tag (stored in P_EXT on every piece produced by Separate)
----------------------------------------------------------------------------------------
-- Source-time fields are in the active take's source seconds, so they survive moves and
-- trims: timeline = pos + (src - startoffs) / playrate.
--   sid  session id      idx  slot index (0 = before first slice, n+1 = after range)
--   k    'S' slice / 'F' fixed      L/R  left/right edge was created by a split
--   ns   nominal start   at   anchor   ts  tail-safe end   hs  head-safe start

local TAG_FMT = 'v1;%s;%d;%s;%d;%d;%.9f;%.9f;%.9f;%.9f'

function M.tag_encode(t)
  return TAG_FMT:format(t.sid, t.idx, t.k, t.L and 1 or 0, t.R and 1 or 0,
    t.ns, t.at or 0, t.ts, t.hs)
end

function M.tag_decode(s)
  if not s or s == '' then return nil end
  local sid, idx, k, L, R, ns, at, ts, hs =
    s:match('^v1;([^;]+);(-?%d+);(%a);(%d);(%d);([^;]+);([^;]+);([^;]+);([^;]+)$')
  if not sid then return nil end
  return { sid = sid, idx = tonumber(idx), k = k, L = L == '1', R = R == '1',
           ns = tonumber(ns), at = tonumber(at), ts = tonumber(ts), hs = tonumber(hs) }
end

return M
