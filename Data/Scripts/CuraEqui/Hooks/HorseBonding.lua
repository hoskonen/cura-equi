-- Scripts/CuraEqui/Hooks/HorseBonding.lua
local function install()
    local H = _G.Horse
    if not (H and type(H.OnBonding) == "function") then return false end
    if H.__ce_bond_minwrapped then return true end

    local base = H.OnBonding
    function H:OnBonding(user, slot)
        -- call vanilla first to preserve behavior
        local ok, ret = pcall(base, self, user, slot)
        if not ok then
            System.LogAlways("[CuraEqui][Bonding] vanilla error: " .. tostring(ret))
        end
        System.LogAlways("[CuraEqui][Bonding] OnBonding fired for horse id=" .. tostring(self.id))
        return ret
    end

    H.__ce_bond_minwrapped = true
    System.LogAlways("[CuraEqui][Bonding] Hooked Horse:OnBonding (minimal)")
    return true
end

-- try now; if Horse.lua isn’t ready yet, retry
local function ensure()
    if not install() then Script.SetTimer(200, ensure) end
end
ensure()

-- self-heal: re-assert every 5s in case another reload overwrites it
Script.SetTimerForFunction(5000, "CuraEqui_Bonding_Rehook")
function CuraEqui_Bonding_Rehook()
    if not (_G.Horse and _G.Horse.__ce_bond_minwrapped) then install() end
    Script.SetTimerForFunction(5000, "CuraEqui_Bonding_Rehook")
end
