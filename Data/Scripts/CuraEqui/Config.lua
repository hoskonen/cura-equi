-- Scripts/CuraEqui/Config.lua
CuraEqui = CuraEqui or {}

CuraEqui.Config = {
    UI = {
        hudElement = "HUD",
        fallbackToNotification = true,
        feed = {
            lane = "infotext", -- "infotext" | "tutorial" | "notification"
            sec  = 2.0,        -- default duration for center messages (seconds)
            prio = 0,          -- priority for the lane
            msg  = {
                onEat        = "@curaequi_horse_eats_happily",
                onFull       = "@curaequi_horse_full",
                onRefusal    = "@curaequi_horse_refuse",
                onLeftovers  = "@curaequi_feed_leftovers",
                onSatedBlock = "@curaequi_horse_not_hungry_yet",
            },
        }
    },
    Debug = {
        enabled = false,
        distanceTrace = false,
        distanceTraceStepM = 500.0,
        hud = { enabled = true, lane = "notification", id = "CuraEqui_DebugHUD", refresh = 10000 },
        hungerTrace = false, -- log a compact hunger line each tick
        hungerTraceEvery = 10000,
        mountTrace = false,
        feedTrace = false,
        feedTraceVerbose = false,
        feedUI = false,           -- right corner ui notifications
        persistTrace = false,     -- log saving
        tickTrace = false,
        buffTraceVerbose = false, -- false = log only when buff changes
        buffTraceTick = false,
        skipTrace = false,
        skipTraceVerbose = false,
        ownershipTrace = false,
        horseIdentityTrace = false,
        staminaSnapshot = false, -- capture a reference staminaMax (debug only)
        horseDerived = true,
        showHorseStatsTutorial = false
    },
    Hunger = {
        preset                   = "moderate", -- "hardcore" | "moderate" | "laidback" "moderate" | "laidback"
        tickSec                  = 10,
        hungerStart              = 50,
        hungerMax                = 100,
        debuffAt                 = 70,
        -- Rates
        ratePerMinIdle           = 0.015, -- horse idle (includes mounted-but-standing)
        ratePerMinMounted        = 0.35,  -- horse mounted & moving: time drift while ridden
        ratePerKmMounted         = 0.5,   -- extra drain per ridden kilometer
        speedIdleMps             = 0.2,   -- below this → idle
        -- Sated
        satedDrainMul            = 0.75,
        satedSecPerNutrition     = 12, -- x per nutrition
        satedCapSec              = 2000,
        -- Sated feeding policy: “block whenever sated is active, set satedBlockIfRemainingSec = 1 or if you want a softer rule (“block only if ≥ 10 min left”), set 600.
        satedHardBlock           = true,                      -- if true, block feeding while plenty of sated time remains
        satedBlockIfRemainingSec = 1,                         -- threshold in seconds; 0 disables blocking (used only if satedHardBlock=true)-- 10 min max
        -- Grazing
        grazePerMinIdleUnmtd     = -0.12,                     -- negative recovers while unmounted & idle
        grazeSatedMul            = 1.0,                       -- sated multiplier applied to grazing
        grazingPerSession        = 10,                        -- set 0 or nil to disable (max hunger points recovered per idle-unmounted session)
        grazeRamp                = { start = 10, full = 35 }, -- % hunger: 0% effect at 10, 100% effect at 35+
        -- Grazing - Night
        night                    = {
            disableGrazing   = true,
            timeDrainMul     = 1.0, -- 1.0 keeps same time drain at night (raise if you want nights a bit harsher)
            maxDeltaPerNight = 35,  -- absolute cap on hunger gained from sunset→sunrise

        },
        waitCatchup              = { enabled = true, maxCatchupSec = 0 }, -- catch up
        EnableFallbackCatchUp    = false,
        -- Gift Sated to a newly detected horse (acquisition or mid-session swap)
        newHorseSatedSec         = 1200, -- 20 min; set 0 to disable

    },
    Presets = {
        Hunger = {
            hardcore = {
                ratePerMinIdle       = 0.35,
                ratePerMinMounted    = 0.7,
                ratePerKmMounted     = 1.0,
                grazePerMinIdleUnmtd = -0.08,
                night                = { disableGrazing = true, timeDrainMul = 1.2, maxDeltaPerNight = 40 },
            },
            moderate = {
                ratePerMinIdle       = 0.025,
                ratePerMinMounted    = 0.10,
                ratePerKmMounted     = 0.15,
                grazePerMinIdleUnmtd = -0.015,
                night                = { disableGrazing = true, timeDrainMul = 0.75, maxDeltaPerNight = 35 },
            },
            laidback = {
                ratePerMinIdle       = 0.01,
                ratePerMinMounted    = 0.05,
                ratePerKmMounted     = 0.10,
                grazePerMinIdleUnmtd = -0.04,
                night                = { disableGrazing = false, timeDrainMul = 0.5, maxDeltaPerNight = 12 },
            },
        },
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
            { name = "minor",    uidd = "3329d630-3aa6-4d65-b7bb-8257fdecb66c" },
            { name = "moderate", uidd = "11a47968-997f-41a4-a9f7-ad5a99b1d737" },
            { name = "critical", uidd = "5b57061a-3425-460e-9848-a26afbd060a4" },
            { name = "ok",       uidd = "f3d4b5e2-7f8a-4d6b-9a31-8b0d1c9a7c52" },
        },
        horseDebuffTiers  = {
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
        filtersMulti           = "food.vegetable.*|food.fruit.*|food.nut.*",
        overfeedPolicy         = "allow", -- "allow" | "skip"  (what to do if a single item would overshoot need)
        removeItems            = true,    -- ← keep false until you verify removal works on your build
        -- Sated Mode (goal-based planning; picker path)
        needMode               = "sated", -- "hunger" | "sated"
        needCapPerFeed         = 35,
        satedMinSec            = 0,
        satedMaxSec            = 2000,
        satedSecPerPoint       = 10,
        satedSecPerPointHorse  = 20,
        satedAlsoReducesHunger = true,
        -- Toasts (dev-style, no localization)
        toastOnDone            = true,
        toastLane              = "notification", -- "notification" (right) | "tutorial" | "infotext"
        toastSec               = 4.0,
        allowAnyHorse          = false
    },
    Drinking = {
        sources = {
            { class = "WaterTubeActionTrigger" },                                           -- laundry/wash tubes
            { class = "SmartObjectHolder",     nameMatch = "Water/waterResource" },         -- wash areas
            { class = "TriggerArea",           nameMatch = "Water/waterResource" },
            { class = "SmartObjectHolder",     nameMatch = "animalcare/horseParkingSpot" }, -- stone/wood troughs
        }
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

-- DELETE THIS LATER WHEN OLD VARIABLES HAVE BEEN REMOVED
do
    local C = CuraEqui.Config or {}
    if C.FeedScan then
        CuraEqui.Config.UI       = CuraEqui.Config.UI or {}
        CuraEqui.Config.UI.feed  = CuraEqui.Config.UI.feed or {}
        local UF                 = CuraEqui.Config.UI.feed
        UF.lane                  = UF.lane or C.FeedScan.toastLane
        UF.sec                   = UF.sec or C.FeedScan.toastSec
        UF.prio                  = UF.prio or C.FeedScan.toastPrio
        UF.msg                   = UF.msg or {}
        UF.msg.onFull            = UF.msg.onFull or C.FeedScan.toastOnFull
        -- We intentionally do NOT migrate onStart/onEat/windowEnded (scanner-only)
        CuraEqui.Config.FeedScan = nil
    end
end

if CuraEqui and CuraEqui.ApplyPreset then
    CuraEqui.ApplyPreset("overwrite") -- or "fill" if you prefer config wins
end
