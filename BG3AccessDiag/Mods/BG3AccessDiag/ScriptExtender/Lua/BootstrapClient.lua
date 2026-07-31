local C = Ext.Require("Diag/Common.lua")
local Probes = Ext.Require("Diag/ClientProbes.lua")

C.log("bootstrap client loaded, extender v%s, game %s",
    tostring(Ext.Utils.Version()), tostring(Ext.Utils.GameVersion()))

Probes.init()
Probes.E10_env()

-- Menu-level probes: everything that does not need a loaded session.
local firedMenu = false
Ext.Events.GameStateChanged:Subscribe(function()
    local state = tostring(Ext.Utils.GetGameState())
    C.log("client game state -> %s", state)
    if not firedMenu and state:find("Menu") then
        firedMenu = true
        Ext.Timer.WaitForRealtime(4000, function()
            C.log("running menu probe set")
            pcall(function() Probes.E10_env() end)
            pcall(function() Probes.E11_input() end)
            pcall(function() Probes.E4_E3_E5_tree("mainmenu") end)
            pcall(function() Probes.E6_bridge(20) end)
        end)
    end
end)

-- Session-level probes: needs a loaded save.
Ext.Events.SessionLoaded:Subscribe(function()
    C.log("session loaded, scheduling full client probe set")
    Ext.Timer.WaitForRealtime(6000, function()
        pcall(function() Probes.runAll("ingame") end)
    end)
end)
