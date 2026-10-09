# Reap Detective

A Beat Detective–style multitrack drum editor for REAPER, written as a Lua ReaScript with a
ReaImGui window.

```
1 Detect  ->  2 Separate  ->  3 Quantize  ->  (nudge by hand)  ->  4 Smooth
```

1. **Detect.** Analyze the *key* tracks (kick, snare, toms) over the time selection. Tune
   Threshold, Sensitivity and Retrigger and watch the hit lines update live on your tracks in
   the arrange view. Drag, add and delete hits right there with the mouse.
2. **Separate.** Split the key tracks *plus any other selected tracks* (overheads, rooms, snare
   bottom) at every hit. Each split sits a *trigger pad* before the transient, and each slice's
   tail is trimmed so slices can move without overlapping. All tracks' pieces of a slice are
   item-grouped, so a hand nudge moves the whole kit together.
3. **Quantize.** Snap each slice's hit to the grid. Slices that would move further than a
   limit, or that would land on the same grid line as a neighbor, stay put and are flagged for
   review. They're listed in the window and marked with red lines in the arrange view. Item
   colors are never changed.
4. **Smooth.** You run this yourself, after you're happy with the placement. It fills the gaps
   and crossfades every boundary. By default the fade sits completely **before** the next
   slice's start, so no transient is ever faded.

## Requirements

- REAPER 7.82 or newer.
- **ReaImGui**: the window.
- **js_ReaScriptAPI**: hit lines on the arrange view and mouse editing there. Without it, hits
  only show as project markers.

Both extensions are in the ReaTeam Extensions repository, which ReaPack includes by default.
Install Reap Detective from the [ProducerApps repository](../README.md#install).

Besides **Script: ReapDetective.lua** (the window), these actions are installed for keyboard
shortcuts. They use the settings last set in the window, so they work with it closed:

- `ReapDetective - Quantize slices`
- `ReapDetective - Smooth (fill gaps and crossfade)`
- `ReapDetective - Go to next flagged slice` / `…previous…`
- `ReapDetective - Clear review flags`

## Workflow

1. Select the key tracks (or items on them) and make a time selection over the section. Run
   **Reap Detective**, check the "Analyze will use:" line, and press **Analyze**. Key tracks
   are the selected tracks plus the tracks of any selected items. With no time selection, the
   range is the span of the selected items.
2. In **1 Detect**:
   - **Threshold**: in dB below each key track's loudest peak.
   - **Sensitivity**: how sharply the level must jump within 5 ms. Raise it to drop bleed and
     ghost notes.
   - **Retrigger**: the flam window. Onsets closer than this become one hit, whether they're
     on one track (a snare flam) or across key tracks (kick and snare played a few ms apart).
     The split always goes before the first onset.
   - **Anchor**: which onset of a merged hit Quantize puts on the grid.
     - *Track priority* (default): the onset from the highest-priority key track. If the
       drummer flams kick and snare, the snare lands on the grid. Within that track, the
       loudest onset wins, so a snare flam's main stroke counts rather than its grace note.
       The **Priority** button next to it shows the top track and opens a list to reorder the
       key tracks. The default is snare, then kick, then toms, then the rest (guessed from
       the track names). Your order is saved with the project.
     - *Loudest onset*: the loudest onset, from any track.
     - *First onset*: the earliest one.

     Set the anchor before Separate: each slice keeps the anchor it was separated with. In
     the waveform view, hovering a merged hit shows which track it's anchored on.
   - **Per-track offsets**: compensate for a tom that picks up lots of bleed.
3. Fix the hits in the **arrange view**. With **In arrange** set to *Lines* (the default), every
   hit is an amber line across exactly the tracks Separate will cut, while the Detect or
   Separate step is open. When you zoom in far enough, a dim line marks each split point (the
   trigger pad before the hit).

   | Action | Input |
   |---|---|
   | Move a hit | Drag its line |
   | Delete a hit | Option-click its line (Alt on Windows) |
   | Add a hit | Option-click anywhere else on those tracks. A grey line previews where it lands |

   The script only takes the mouse while you're on a hit line or holding Option over those
   tracks. Everywhere else, and in every other step, REAPER behaves normally.

   **Waveforms here** (Detect toolbar) also shows each key track's waveform and threshold in
   the script window, with the same editing plus keys there:

   | Action | Input |
   |---|---|
   | Add / move / delete | Double-click / drag / Alt-click or right-click |
   | Nudge the selected hit | ←/→ (1 ms; Shift 5 ms; Alt 0.1 ms) |
   | Step through hits | Tab / Shift-Tab |
   | Zoom / scroll / fit | Wheel / Shift-wheel / F |

   While the window has focus, REAPER's own shortcuts keep working: ⌘Z, ⌘⇧Z, Space, your
   custom bindings, and so on. The exceptions are Tab, F, and ←/→/Del when a hit is selected.

   *In arrange → Markers* shows hits as `RD` project markers instead, for display only.
4. **2 Separate**: also select the overheads, rooms, etc. Either select the tracks or their
   items. Check the track list on the right, then press Separate. It's one undo point.
5. **3 Quantize**: set Grid (default 1/16), Strength, Exclude within, and Flag if move >
   (default 1/32). Hits snap to the *nearest* grid line, so on a 1/16 grid nothing ever moves
   more than 1/32. At that setting, only collisions get flagged; pick 1/48 or 1/64 to also catch
   hits that are suspiciously far off. It works on the slices of the selected items, or on every
   slice if no separated item is selected.
6. Review the flagged slices: click one in the list, or use Previous/Next. That selects the
   whole slice across tracks and moves the view to it. Nudge it in the arrange view (the
   slices are grouped). Red lines mark the flagged slices on the tracks while the Quantize
   step is open.
7. **4 Smooth**: choose the crossfade length (default 10 ms), shape (REAPER's seven shapes;
   default slight convex/equal power), and position (default: entirely before the slice
   start). Press Smooth. You can run it again after more nudging; it recomputes from each
   slice's original edges, so repeated runs don't drift.

## Design notes

**Addon, native actions, or a script?** A Lua ReaScript with a ReaImGui window. REAPER's own
pieces each cover part of this (Dynamic Split, item quantize, auto-crossfade), but they can't
be chained to:
- merge flams across several key tracks,
- let you hand-edit hits before splitting,
- flag suspicious quantize moves, or
- control which side of the transient the fade lands on.

A C++ extension would only add speed. The analysis is already fast enough in Lua (it reads a
1 ms envelope at 24 kHz, then refines each onset to the sample).

**Do we need to switch crossfade modes mid-chain?** No. Every edit goes through the item/take
API and sets positions, offsets and fades explicitly. REAPER's mouse-editing preferences (auto
crossfade, trim content behind items, overlap on split) don't affect API edits, so nothing gets
toggled. Separate even corrects for "overlap and crossfade items when splitting" if you have it
on. The only REAPER options that matter are for your hand nudges between Quantize and Smooth:
- **Item grouping on.** The Separate tab warns if it's off and has a button to turn it on.
- **Ripple editing off.**

## How smoothing avoids double hits

After quantizing, slice B may have moved later than the end of slice A. Filling that gap from
A's tail would eventually play the *original* B transient, which sits later in A's audio. That's
the classic doubled-flam artifact.

With **Avoid double hits** on, A's tail only extends as far as the original split point. Any
remaining gap is filled from B's own pre-attack audio, extended backwards no further than
halfway to the previous hit. If neither side can cover a gap cleanly, the boundary is
flagged for review: it's listed in the Smooth step and marked with an orange line in the
arrange view.

Each piece remembers where it came from (in the item's `P_EXT` data), which is what lets
Smooth and Quantize re-run safely.

## Files

```
Items Editing/ReapDetective.lua             the window (and the ReaPack package header)
Items Editing/reapdetective/core.lua        pure logic: detection, flam merging, grid math, smoothing plan
Items Editing/reapdetective/analysis.lua    audio accessors -> envelopes -> hits
Items Editing/reapdetective/edit.lua        separate / quantize / smooth / review flags / markers
Items Editing/reapdetective/settings.lua    defaults + persistence (ExtState)
Items Editing/reapdetective/keys.lua        passes REAPER shortcuts through while the window has focus
Items Editing/reapdetective/overlay.lua     lines on the arrange view (js_ReaScriptAPI composites)
Items Editing/reapdetective/arrange.lua     mouse editing of hits in the arrange view
Items Editing/reapdetective/ui.lua          theme and widgets for the window
tests/run.lua                               unit + workflow tests against a mock REAPER
tests/gui_smoke.lua                         drives the whole window headless, frame by frame
```

Each analysis and arrange-view edit is logged to `Data/ReapDetective/debug.log` in REAPER's
resource folder (Options → Show REAPER resource path).

## Known gaps

- Items with stretch markers are separated, but the window warns you to check them. The
  source-time math assumes no stretch markers.
- There's no swing quantize yet, and no per-key-track high-pass/low-pass filter for detection
  (useful for kick mics with lots of snare bleed).
- With several takes in an item, the active take defines the edit positions.
