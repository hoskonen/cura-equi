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
        allow            = { -- future: template/tag keys
            -- ["itm_apple"]= {nutrition=25, bond=2},
            -- ["itm_carrot"]= {nutrition=20, bond=1},
        },
        denyKeywords     = { "sword", "mace", "axe", "arrow", "meat_raw", "spoiled", "quest" },
        allowKeywords    = { "ui_nm_", "apple", "bread", "carrot" },
        keywordNutrition = 10
    },

    HUD = {
        showWhenMounted = true,
        nearRadiusM     = 20.0,
        tiers           = {
            { name = "sated",  uidd = "1a638e4c-e931-415d-b3bd-c8402ed836ea" },
            { name = "minor",  uidd = "3329d630-3aa6-4d65-b7bb-8257fdecb66c" },
            { name = "moderate", uidd = "11a47968-997f-41a4-a9f7-ad5a99b1d737" },
            { name = "critical", uidd = "5b57061a-3425-460e-9848-a26afbd060a4" },
        }
    },
    FeedScan = {
        radius                 = 3.0,
        windowSec              = 8.0,
        tickMs                 = 250,
        groundProbe            = true,
        groundOffsetDown       = 1.2,   -- meters below mouth to sample
        autoArmOnActionVisible = false, -- keep OFF for now
        autoArmWindowSec       = 3.0,   -- short window if auto-armed
        armCooldownSec         = 10.0,  -- don’t re-arm too often
        armOnInventoryClose    = true,  -- start scan after inv closes
        armTimeoutSec          = 25.0,  -- give up if no close within this time
        postCloseWindowSec     = 10.0,  -- scan window after close
        postCloseDelayMs       = 2000,  -- how long after the inventory closes before the scan starts at all
        landDelayMs            = 1000,  -- how long after detecting a valid item before the delete+consume actually happens
        munchSfx               = "a_o_horse_eating",
        -- Toasts
        toastOnStart           = "@curaequi_drop_food",
        toastOnEat             = "@curaequi_horse_munch",
        -- Toast Settings
        toastMs                = 1800,       -- duration in ms for tutorial lane
        toastPrio              = 0,          -- priority for tutorial lane
        toastLane              = "infotext", -- "tutorial" (tiny) or "notification"
    }
}
