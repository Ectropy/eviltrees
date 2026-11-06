--[[
    core/devlog.lua
    ---------------
    Optional developer logging. Off by default so the console stays quiet for
    players (the submission guidelines ask for this). Turn it on while
    developing by setting devlog.enabled = true in main.lua.
]]

local devlog = {}

devlog.enabled = false

-- Same arguments as the built-in log(), but only prints when enabled.
function devlog.print(...)
    if devlog.enabled then
        log(...)
    end
end

return devlog
