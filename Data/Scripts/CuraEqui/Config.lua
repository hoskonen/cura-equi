-- Scripts/CuraEqui/Config.lua
CuraEqui = CuraEqui or {}

CuraEqui.Config = {
    Debug = {
        enabled = true,
        distanceTrace = true,
        distanceTraceStepM = 100.0,
        hud = { enabled = true, refresh = 1200, lane = "notification", id = "CuraEqui_DebugHUD" }
    },

    Hunger = {
        hungerMax            = 100,
        hungerStart          = 30,
        tickSec              = 10,
        ratePerMin           = 1.0,  -- hunger per minute
        ratePerKm            = 15.0, -- hunger per kilometer
        debuffAt             = 70,
        satedSecPerNutrition = 6,    -- x per nutrition
        satedCapSec          = 600,  -- 10 min max
    },

    Diet = {
        strict               = "guid+token", -- "guid-only" | "guid+token" | "guid+token+keywords"
        allowKeywordFallback = false,        -- set false to require explicit map from DietData.lua
        allowKeywords        = { "ui_nm_", "apple", "bread", "carrot" },
        denyKeywords         = { "sword", "mace", "axe", "arrow", "meat_raw", "spoiled", "quest" },
        keywordNutrition     = 10
    },

    HUD = {
        showWhenMounted   = true,
        nearRadiusM       = 20.0,
        playerStatusTiers = {
            { name = "sated",    uidd = "1a638e4c-e931-415d-b3bd-c8402ed836ea" },
            { name = "minor",    uidd = "3329d630-3aa6-4d65-b7bb-8257fdecb66c" },
            { name = "moderate", uidd = "11a47968-997f-41a4-a9f7-ad5a99b1d737" },
            { name = "critical", uidd = "5b57061a-3425-460e-9848-a26afbd060a4" },
            { name = "ok",       uidd = "f3d4b5e2-7f8a-4d6b-9a31-8b0d1c9a7c52" },
        },
        horseDebuffTiers  = {
            { name = "sated",    uidd = "7d3c2a91-8c6b-4f3f-9a6e-2b1d3e94a6b0" },
            { name = "minor",    uidd = "c4b7f9d2-1e35-4a07-8b3a-1b6e9b2a0c18" },
            { name = "moderate", uidd = "e1a5c0f7-2d4c-41f9-8d45-7a9f0c3e1b72" },
            { name = "critical", uidd = "9f2e6b84-3a10-4719-b6d9-5d0c8f2a4c63" },
        },
        thresholds        = {
            minor = 50,
            moderate = 70,
            critical = 90
        }
    },
    FeedScan = {
        radius                 = 2.0,
        windowSec              = 5.0,
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
