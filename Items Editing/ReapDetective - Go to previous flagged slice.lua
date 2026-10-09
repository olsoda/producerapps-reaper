-- @noindex
-- Select the previous slice colored for review and move the edit cursor to its hit.
local path = debug.getinfo(1, 'S').source:match('^@?(.*[/\\])') or ''
package.path = path .. '?.lua;' .. package.path
local S = require 'reapdetective.settings'
local E = require 'reapdetective.edit'
E.goto_flagged(-1)
reaper.defer(function() end) -- selection change only: no undo point
