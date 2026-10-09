-- @noindex
-- Clear every review flag set by quantize or smoothing (and undo the item colors older versions painted).
local path = debug.getinfo(1, 'S').source:match('^@?(.*[/\\])') or ''
package.path = path .. '?.lua;' .. package.path
local S = require 'reapdetective.settings'
local E = require 'reapdetective.edit'
E.restore_legacy_colors()
E.clear_flags()
