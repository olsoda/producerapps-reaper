-- @noindex
-- Fill gaps and crossfade separated slices (selected slices, or all) using the window's settings.
local path = debug.getinfo(1, 'S').source:match('^@?(.*[/\\])') or ''
package.path = path .. '?.lua;' .. package.path
local S = require 'reapdetective.settings'
local E = require 'reapdetective.edit'
local s = E.smooth(S.load())
if s.joins + s.skipped == 0 then reaper.MB('No separated slices found to smooth.', 'Reap Detective', 0) end
