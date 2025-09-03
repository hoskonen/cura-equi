-- Scripts/CuraEqui/Config.lua
CuraEqui = CuraEqui or {}

CuraEqui.Config = {
    Debug = {
        enabled            = true,  -- master debug (logging)
        distanceTrace      = true,  -- off by default; flip on when needed
        distanceTraceStepM = 100.0, -- meters per log milestone
    },

    Hunger = {
        hungerMax   = 100,
        hungerStart = 30,
        tickSec     = 10,
        ratePerMin  = 1.0,  -- hunger per minute
        ratePerKm   = 15.0, -- hunger per kilometer
        debuffAt    = 70,
    },

    Diet = {
        allow = { -- future: template/tag keys
            -- ["itm_apple"]= {nutrition=25, bond=2},
            -- ["itm_carrot"]= {nutrition=20, bond=1},
        },
        denyKeywords = { "sword", "mace", "axe", "arrow", "meat_raw", "spoiled", "quest" },
    },

    HUD = {
        showWhenMounted = true,
        nearRadiusM     = 20.0,
        tiers           = {
            -- optional future: hud effect ids per tier
            -- {name="OK",        effect="ce_horse_sated"},
            -- {name="Peckish",   effect="ce_horse_hungry1"},
            -- {name="Hungry",    effect="ce_horse_hungry2"},
            -- {name="Starving",  effect="ce_horse_starving"},
        }
    }
}
