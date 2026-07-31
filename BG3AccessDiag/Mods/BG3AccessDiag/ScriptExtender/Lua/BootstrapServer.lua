local C = Ext.Require("Diag/Common.lua")
local Probes = Ext.Require("Diag/ServerProbes.lua")

C.log("bootstrap server loaded, extender v%s, game %s",
    tostring(Ext.Utils.Version()), tostring(Ext.Utils.GameVersion()))

Probes.init()

Ext.Events.SessionLoaded:Subscribe(function()
    C.log("session loaded, scheduling server probe set")
    Ext.Timer.WaitForRealtime(7000, function()
        pcall(function() Probes.runAll() end)
    end)
end)

-- Narration source check: do the Osiris events the design leans on actually fire?
local seen = {}
local function watch(name, arity)
    local ok = pcall(function()
        Ext.Osiris.RegisterListener(name, arity, "after", function(...)
            local args = { ... }
            seen[name] = (seen[name] or 0) + 1
            if seen[name] <= 3 then
                C.report("osiris_events", seen)
                C.dump("osiris_event_" .. name .. ".json", args)
            end
        end)
    end)
    if not ok then C.log("could not register listener for %s/%d", name, arity) end
end

watch("CombatStarted", 1)
watch("CombatEnded", 1)
watch("TurnStarted", 1)
watch("TurnEnded", 1)
watch("DialogStarted", 2)
watch("DialogEnded", 2)
watch("EnteredCombat", 2)
watch("LeveledUp", 1)
