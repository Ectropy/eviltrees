--[[
    core/safe.lua
    -------------
    Two small helpers for calling code that might throw an error.

    The plugin API is new and some calls can fail (e.g. reading an interface
    that isn't loaded yet). Lua's pcall ("protected call") runs a function and
    catches any error, like try/catch in JS.
]]

local safe = {}

-- Runs fn and returns its result, or nil if it threw an error.
-- JS equivalent: try { return fn() } catch { return undefined }
function safe.try(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

-- Wraps an event handler so that an error is logged instead of being lost.
-- "..." means "whatever arguments the event passes", forwarded unchanged.
function safe.handler(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            log("[error] in " .. name .. ": " .. tostring(err))
        end
    end
end

return safe
