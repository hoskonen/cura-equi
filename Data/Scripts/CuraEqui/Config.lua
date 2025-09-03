---Config for Cura Equi.
CuraEqui.Config = {
    Hunger = {
        hungerMax   = 100,
        hungerStart = 30,
        tickSec     = 10,
        ratePerMin  = 1.0,
        ratePerKm   = 15.0,
        debuffAt    = 70,
    },
    Diet = {
        -- Good foods map (template/tag → nutrition, bond, flags)
        -- you’ll switch to exact template IDs when you have them
        -- ["itm_apple"] = { nutrition=25, bond=2, flags={"sweet"} },
    },
    Deny = {
        keywords = { "sword", "mace", "axe", "arrow", "meat_raw", "spoiled", "quest" },
    },
}
