-- @noindex
-- Quantize separated slices using the settings from the Reap Detective window.
local path = debug.getinfo(1, 'S').source:match('^@?(.*[/\\])') or ''
package.path = path .. '?.lua;' .. package.path
local S = require 'reapdetective.settings'
local E = require 'reapdetective.edit'
local s = E.quantize(S.load())
if s.slices == 0 then reaper.MB('No separated slices found. Use Separate in Reap Detective first.', 'Reap Detective', 0) end
