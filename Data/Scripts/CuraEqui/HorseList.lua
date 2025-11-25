-- Cura Equi – HorseList.lua
-- Master list of all known horse Storm names from horses.xml.
-- Used to determine which horses can ever be treated as “player-owned”.
System.LogAlways("[CuraEqui][HorseList] HorseList.lua loaded")
CuraEqui = CuraEqui or {}
CuraEqui.HorseList = CuraEqui.HorseList or {}

local HL = CuraEqui.HorseList

----------------------------------------------------------
-- 1. Horses that CAN BE OWNED (stable sale pools)
--    These are the ONLY horses allowed to become the
--    persistent Cura Equi “main horse”.
----------------------------------------------------------
HL.Ownable = {

    -- Unique player horse
    tsem_sedivka = true,

    tsem_horseForSale_1 = true,
    tsem_horseForSale_2 = true,
    tsem_horseForSale_3 = true,

    kgru_horseForSale_1 = true,
    kgru_horseForSale_2 = true,
    kgru_horseForSale_3 = true,
    kgru_horseForSale_4 = true,
    kgru_horseForSale_5 = true,
    kgru_horseForSale_6 = true,

    kmal_horseForSale_1 = true,
    kmal_horseForSale_2 = true,
    kmal_horseForSale_3 = true,
    kmal_horseForSale_4 = true,
    kmal_horseForSale_5 = true,
    kmal_horseForSale_6 = true,

    kkut_horseForSale_1 = true,
    kkut_horseForSale_2 = true,
    kkut_horseForSale_3 = true,
    kkut_horseForSale_4 = true,
}

----------------------------------------------------------
-- 2. Horses that should NEVER be treated as player-owned
--    These are quest horses, cinematic horses, noble
--    horses, work horses, world horses, etc.
----------------------------------------------------------
HL.NeverOwned = {

    -- Story / unique horses
    tneb_bibiana = true,
    ttro_horseCaponTrosecko = true,
    ttro_bergovHorse = true,
    kzik_gringolet = true,
    katvuSleh_horse = true,
    rodinnaChlouba_racingHorse = true,

    -- Village / work / misc world horses
    nebakovPruzkum_herynk = true,
    knab_horse_1 = true,

    tvez_horse_1 = true,
    tvez_horse_2 = true,
    tvez_horse_3 = true,
    tvez_horse_4 = true,

    tneb_horse_16 = true,
}

----------------------------------------------------------
-- 3. Public helpers
----------------------------------------------------------

-- Check if Storm name is in the ownable list
function HL.IsOwnable(name)
    if not name then return false end
    name = tostring(name)
    return HL.Ownable[name] == true
end

-- Check if Storm name is explicitly forbidden
function HL.IsNeverOwned(name)
    if not name then return false end
    name = tostring(name)
    return HL.NeverOwned[name] == true
end

return CuraEqui.HorseList
