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

function CuraEqui.ApplyPreset(mode)
    local C = CuraEqui.Config or {}
    local P = C.Presets or {}
    local name = (C.Hunger and C.Hunger.preset) or "moderate"
    local overwrite = (mode ~= "fill") -- "overwrite" (default) vs "fill"

    -- Apply Hunger preset
    if P.Hunger and P.Hunger[name] then
        merge_into(C.Hunger, P.Hunger[name], overwrite)
    end
    -- Apply Feeding preset (if provided)
    if P.Feeding and P.Feeding[name] then
        merge_into(C.Feeding, P.Feeding[name], overwrite)
    end
end

if System and System.AddCCommand then
    System.AddCCommand("curaequi_preset", function(_, p)
        if p and CuraEqui.Config and CuraEqui.Config.Hunger then
            CuraEqui.Config.Hunger.preset = p
            CuraEqui.ApplyPreset("overwrite")
            System.LogAlways("[CuraEqui] Applied preset: " .. tostring(p))
        end
    end, "Apply a CuraEqui hunger/feeding preset")
end
