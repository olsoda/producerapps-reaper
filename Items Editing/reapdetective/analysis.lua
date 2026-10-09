-- @noindex
-- Reap Detective: reads key tracks through audio accessors and turns them into hits.

local core = require 'reapdetective.core'

local A = {}

A.HOP_S = 0.001            -- envelope resolution: 1 ms blocks
A.ENV_SR = 24000           -- envelope pass (detection only needs block peaks)
A.ENV_HOP_N = 24           -- A.ENV_SR * A.HOP_S
A.SR = 48000               -- sample-accurate onset refinement
A.HOP_N = 48               -- A.SR * A.HOP_S
A.CHUNK_BLOCKS = 1024      -- ~1 s of audio per read

-- Optional debug log (set A.log_path to enable).
A.log_path = nil
A.LOG_MAX = 1024 * 1024 -- start over when the log grows past ~1 MB

function A.log(fmt, ...)
  if not A.log_path then return end
  local f = io.open(A.log_path, 'a')
  if not f then return end
  if (f:seek('end') or 0) > A.LOG_MAX then
    f:close()
    f = io.open(A.log_path, 'w')
    if not f then return end
  end
  f:write(os.date('%H:%M:%S '), (select('#', ...) > 0) and fmt:format(...) or fmt, '\n')
  f:close()
end

-- Create an analysis object. tracks: list of MediaTrack. rs/re: range in seconds.
function A.new(tracks, rs, re)
  local an = { rs = rs, re = re, tracks = {}, done = false, progress = 0 }
  for i, tr in ipairs(tracks) do
    local _, name = reaper.GetTrackName(tr)
    local nch = math.min(2, math.max(1, math.floor(reaper.GetMediaTrackInfo_Value(tr, 'I_NCHAN'))))
    an.tracks[i] = {
      track = tr, guid = reaper.GetTrackGUID(tr), name = name, nch = nch,
      enabled = true, offset = 0, refine_cache = {}, count = 0,
    }
  end
  return an
end

function A.destroy(an)
  if not an then return end
  for _, kt in ipairs(an.tracks) do
    if kt.acc then reaper.DestroyAudioAccessor(kt.acc); kt.acc = nil end
  end
end

-- Reading is incremental and driven from the defer loop: in REAPER, GetAudioAccessorSamples
-- returns nil (and reads nothing) when called from inside a Lua coroutine.
function A.begin_read(an)
  an.total_blocks = math.max(1, math.floor((an.re - an.rs) / A.HOP_S))
  an.buf = reaper.new_array(A.ENV_HOP_N * A.CHUNK_BLOCKS * 2)
  an.ti = 1
  A.log('read: %d track(s), range %.3f - %.3f s, %d blocks', #an.tracks, an.rs, an.re, an.total_blocks)
end

local function finish_track(an, kt)
  local d, n = kt.d, kt.n
  local peak = core.SILENCE_DB
  for i = 1, n do if d[i] > peak then peak = d[i] end end
  local hold = core.sliding_max(d, n, math.floor(core.HOLD_S / A.HOP_S + 0.5))
  local mip, sizes = core.build_mip(d, n)
  kt.env = { db = d, hold = hold, n = n, hop = A.HOP_S, t0 = an.rs, peak = peak, mip = mip, sizes = sizes }
  kt.d, kt.n = nil, nil
  A.log('  "%s": peak %.1f dBFS, reads ok=%d silent=%d failed=%d', kt.name, peak,
    kt.reads.ok, kt.reads.silent, kt.reads.failed)
end

-- Read one chunk (~1 s) of the current track. Returns true when every track is done.
function A.step(an)
  if an.done then return true end
  local kt = an.tracks[an.ti]
  if not kt.acc then
    kt.acc = reaper.CreateTrackAudioAccessor(kt.track)
    kt.d, kt.n = {}, 0
    kt.reads = { ok = 0, silent = 0, failed = 0 }
  end
  local total = an.total_blocks
  local blocks = math.min(A.CHUNK_BLOCKS, total - kt.n)
  local frames = blocks * A.ENV_HOP_N
  local buf = an.buf
  buf.clear()
  local rv = reaper.GetAudioAccessorSamples(kt.acc, A.ENV_SR, kt.nch, an.rs + kt.n * A.HOP_S, frames, buf)
  if rv == 1 then
    kt.reads.ok = kt.reads.ok + 1
    kt.n = core.block_peaks_db(buf.table(1, frames * kt.nch), frames, kt.nch, A.ENV_HOP_N, kt.d, kt.n)
  else
    if rv == 0 then kt.reads.silent = kt.reads.silent + 1 else kt.reads.failed = kt.reads.failed + 1 end
    for _ = 1, blocks do kt.n = kt.n + 1; kt.d[kt.n] = core.SILENCE_DB end
  end
  an.progress = ((an.ti - 1) + kt.n / total) / #an.tracks
  if kt.n >= total then
    finish_track(an, kt)
    an.ti = an.ti + 1
    if an.ti > #an.tracks then
      an.done, an.progress, an.buf = true, 1, nil
    end
  end
  return an.done
end

-- Sample-accurate onset time for a block-level onset, cached per detection block.
local refine_buf, refine_buf_size = nil, 0
local function refine(kt, o)
  local c = kt.refine_cache[o.k]
  if c then return c end
  local env = kt.env
  local j0 = math.max(1, o.j - 1)
  local ts = env.t0 + (j0 - 1) * env.hop
  local frames = (o.k + 2 - j0) * A.HOP_N
  if refine_buf_size < frames * 2 then
    refine_buf_size = math.max(frames * 2, 4096)
    refine_buf = reaper.new_array(refine_buf_size)
  end
  refine_buf.clear()
  local t = nil
  if kt.acc and reaper.GetAudioAccessorSamples(kt.acc, A.SR, kt.nch, ts, frames, refine_buf) == 1 then
    t = core.refine_onset(refine_buf.table(1, frames * kt.nch), frames, kt.nch, A.SR, ts,
      core.lin(o.base + 1.0))
  end
  t = t or o.t
  kt.refine_cache[o.k] = t
  return t
end

-- Run detection on every enabled key track and merge into hits.
-- p = { thr, sens, retrig, anchor }
function A.detect(an, p)
  local onsets = {}
  for ti, kt in ipairs(an.tracks) do
    kt.count = 0
    if kt.enabled and kt.env then
      local found = core.detect(kt.env, { thr = p.thr + kt.offset, sens = p.sens, retrig = p.retrig })
      kt.count = #found
      for _, o in ipairs(found) do
        onsets[#onsets + 1] = { t = refine(kt, o), lvl = o.lvl, tr = ti }
      end
    end
  end
  local hits = core.merge(onsets, p.retrig, p.anchor == 1 and 'loudest' or 'first')
  local counts = {}
  for _, kt in ipairs(an.tracks) do
    counts[#counts + 1] = ('%s=%d%s'):format(kt.name, kt.count, kt.enabled and '' or '(off)')
  end
  A.log('detect thr=%.1f sens=%.1f retrig=%.0fms: %s -> %d hits', p.thr, p.sens, p.retrig * 1000,
    table.concat(counts, ', '), #hits)
  return hits
end

return A
