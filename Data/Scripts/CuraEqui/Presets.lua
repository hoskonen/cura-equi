CuraEqui = CuraEqui or {}

local function merge_into(dst, src, overwrite)
    if type(dst) ~= "table" or type(src) ~= "table" then return end
    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = dst[k] or {}
            merge_into(dst[k], v, overwrite)
        else
            if overwrite or dst[k] == nil then
                dst[k] = v
            end
        end
    end
end

function CuraEqui.ApplyPreset(preset, cause)
    local C = CuraEqui.Config or {}
    local P = C.Presets or {}

    local name = tostring(preset or ""):lower()
    if name == "" or name == "current" then
        name = (C.Hunger and C.Hunger.preset) or "moderate"
    end

    -- allow "fill" behavior as a mode, not a preset
    local overwrite = true
    if name == "fill" then
        overwrite = false
        name = (C.Hunger and C.Hunger.preset) or "moderate"
    end

    -- validate preset exists; fallback to moderate
    if not (P.Hunger and P.Hunger[name]) then
        name = "moderate"
    end

    C.Hunger = C.Hunger or {}
    C.Hunger.preset = name

    if P.Hunger and P.Hunger[name] then
        merge_into(C.Hunger, P.Hunger[name], overwrite)
    end
    if P.Feeding and P.Feeding[name] then
        C.Feeding = C.Feeding or {}
        merge_into(C.Feeding, P.Feeding[name], overwrite)
    end

    return name
end
