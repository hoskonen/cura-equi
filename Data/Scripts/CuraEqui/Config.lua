-- Scripts/CuraEqui/Config.lua
CuraEqui = CuraEqui or {}

CuraEqui.Config = {
    UI = {
        hudElement = "HUD",
        fallbackToNotification = true,

    },
    Debug = {
        enabled = true,
        distanceTrace = true,
        distanceTraceStepM = 500.0,
        hud = { enabled = true, lane = "notification", id = "CuraEqui_DebugHUD", refresh = 10000 },
        hungerTrace = true, -- log a compact hunger line each tick
        hungerTraceEvery = 10000,
        mountTrace = true,
        feedTrace = true,
        buffTraceVerbose = false, -- false = log only when buff changes
        tickTrace = true,
    },

    Hunger = {
        tickSec              = 10,
        hungerStart          = 30,
        hungerMax            = 100,
        debuffAt             = 70,
        -- Rates
        ratePerMinIdle       = 0.3, -- horse idle (includes unmounted or mounted-but-standing)
        ratePerMinMounted    = 1.0, -- horse mounted & moving: time drift while ridden
        ratePerKmMounted     = 6.0, -- extra drain per ridden kilometer
        speedIdleMps         = 0.2, -- below this → idle
        -- Sated
        satedDrainMul        = 0.75,
        satedSecPerNutrition = 6,     -- x per nutrition
        satedCapSec          = 600,   -- 10 min max
        -- Grazing
        grazePerMinIdleUnmtd = -0.01, -- negative recovers while unmounted & idle
        grazeSatedMul        = 1.0,   -- sated multiplier applied to grazing
    },

    Diet = {
        strict               = "guid+token", -- "guid-only" | "guid+token" | "guid+token+keywords"
        allowKeywordFallback = false,        -- set false to require explicit map from DietData.lua
        keywordNutrition     = 10
    },

    HUD = {
        showWhenMounted   = true,
        nearRadiusM       = 20.0,
        refresh           = 5,
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
        },
        -- pretty names per tier (fallbacks provided in code if you skip this)
        hungerNames       = {
            ok       = "OK",
            minor    = "Mild",
            moderate = "Hungry",
            critical = "Starving",
            sated    = "Sated",
        },
    },
    Feeding = {
        style                  = "vanilla", -- "vanilla" (picker → instant feed), "experimental", "hybrid" (later)
        filtersMulti           = "food.vegetable.*|food.fruit.*|food.nut.*",
        overfeedPolicy         = "allow",   -- "allow" | "skip"  (what to do if a single item would overshoot need)
        removeItems            = true,      -- ← keep false until you verify removal works on your build
        -- Sated Mode (goal-based planning; picker path)
        needMode               = "sated",   -- "hunger" | "sated"
        needCapPerFeed         = 25,
        satedMinSec            = 300,
        satedMaxSec            = 900,
        satedSecPerPoint       = 6,
        satedAlsoReducesHunger = true,
        -- Toasts (dev-style, no localization)
        toastOnDone            = true,
        toastLane              = "notification", -- "notification" (right) | "tutorial" | "infotext"
        toastSec               = 2.0,

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
        openInventoryOnFeed    = true,  -- if true, pressing Feed opens inventory for you
        postCloseWindowSec     = 5.0,   -- scan window after close
        postCloseDelayMs       = 2000,  -- how long after the inventory closes before the scan starts at all
        landDelayMs            = 2000,  -- how long after detecting a valid item before the delete+consume actually happens
        -- Toasts
        toastOnStart           = "@curaequi_drop_food",
        toastOnEat             = "@curaequi_horse_munch",
        toastOnFull            = "@curaequi_horse_full",
        toastWindowEnded       = "@curaequi_feed_window_ended",
        -- Toast Settings
        toastSec               = 2.0,            -- duration in s for tutorial lane
        toastPrio              = 0,              -- priority for tutorial lane
        toastLane              = "notification", -- "infotext" | "tutorial" | "notification"
    },
    Audio = {
        enabled       = true,
        allowFallback = true,                     -- keep legacy fallback if ATL fails
        feedTrigger   = "a_o_horse_eating",       -- ATL trigger name (atl_name in XML)
        feedTrigger1  = "a_o_horse_eating_grass", -- ATL trigger name (atl_name in XML)
        feedTrigger3  = "a_o_horse_snort2",       -- ATL trigger name (atl_name in XML)
        feedTrigger4  = "a_o_horse_snort3",       -- ATL trigger name (atl_name in XML)
        pathHints     = { "horse" },              -- NEW: folders to try as prefixes
    },
    Buffs = {
        applyDelaySec = 1.2,
    }
}
