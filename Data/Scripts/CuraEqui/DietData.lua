-- Scripts/CuraEqui/DietData.lua
-- Source: horse_food_items.xml → normalized into GUID+token table
-- Nutrition here is *our* scoring (independent of the game’s NutritionBenefit).
-- Tweak freely.

CuraEqui = CuraEqui or {}
CuraEqui.DietData = {
    byGuid = { -- [template GUID] -> { token, nutrition }
        ["02d9c556-6c40-4e5e-abab-48b2acc7287a"] = { token = "appledried", nutrition = 12 },
        ["06787e37-2822-4180-9dda-6aa1a2d15707"] = { token = "apple_half_eaten", nutrition = 10 },
        ["1c2da556-488b-4a86-b22a-c42acb299938"] = { token = "watermelon", nutrition = 10 },
        ["220fd40a-3990-4a34-b6de-eb4a6451539b"] = { token = "sauerkraut", nutrition = 4 },
        ["2264f217-590e-4c0f-a4c6-f50c6532b9f6"] = { token = "apple", nutrition = 12 },
        ["2485a0f4-22b5-40d1-9025-b57345f08ce2"] = { token = "peaches", nutrition = 10 },
        ["2606aceb-9a94-4342-aa26-f6e6548a0be7"] = { token = "winesprout", nutrition = 0 },
        ["27795e53-68b1-4d05-9b02-ae1815c8095b"] = { token = "roastedpeas", nutrition = 8 },
        ["295c54f8-76a3-42fa-8fe1-8f1ecb63576b"] = { token = "applecooked", nutrition = 16 },
        ["2ac0499c-a18f-425f-ab8c-bc81eaa0142a"] = { token = "plums", nutrition = 10 },
        ["2eeb7bf7-f0ac-4c46-9468-97c2f76cb254"] = { token = "pear", nutrition = 12 },
        ["3bebc0b5-dcf8-4449-b37a-a5a362995826"] = { token = "leek", nutrition = 6 },
        ["4088cfbd-c7cc-46ba-9e68-8db8815932e3"] = { token = "onioncooked", nutrition = 14 },
        ["4a6fa310-067a-404d-9813-bd1761d1c70d"] = { token = "onion", nutrition = 8 },
        ["55537a99-41ba-4497-925c-a543ced248e3"] = { token = "beetcooked", nutrition = 14 },
        ["5585da96-12c9-478d-a1a2-d5f206d9fe72"] = { token = "cabbagecooked", nutrition = 20 },
        ["5dceabb5-aef0-4bf5-b401-acbc30a44e21"] = { token = "garlic", nutrition = 8 },
        ["5f02ef0d-0551-44b1-902c-c96a8650d01d"] = { token = "garliccooked", nutrition = 12 },
        ["7899825d-ed6f-4f00-b698-649ba652cf6d"] = { token = "beet", nutrition = 10 },
        ["8d6964b1-b645-4aa1-adcc-db22646f3722"] = { token = "cabbage", nutrition = 16 },
        ["907a2cd5-2730-424e-bf11-ef1f2db8f7e1"] = { token = "horseradish", nutrition = 12 },
        ["9173874c-7494-42ee-8965-a0d12d673945"] = { token = "walnuts", nutrition = 18 },
        ["9373471a-28cd-4719-a343-4669dd501a0a"] = { token = "parsnip", nutrition = 10 },
        ["9dd42af6-e0e0-42e8-81e8-fff02f8d1579"] = { token = "poi_sauerkraut", nutrition = 0 },
        ["b7ee311c-736b-4f7c-987b-8431ce3b5600"] = { token = "carrot", nutrition = 12 },
        ["bc26419a-f9d5-40d1-902c-c96a8650d01d"] = { token = "carrotcooked", nutrition = 16 },
        ["c191701b-3ad1-43ff-b4d1-4e56c9d95dda"] = { token = "pieceofwatermelon", nutrition = 8 },
        ["d2ffc509-509f-4db0-81b6-ad5311231e10"] = { token = "apple_story", nutrition = 8 },
        ["e19d0a82-e5cc-49b2-b0a2-14b004cb4717"] = { token = "horseradishcooked", nutrition = 16 },
        ["ea84be32-b3fc-4dfa-8dab-7169bd9e441d"] = { token = "turnip", nutrition = 10 },
        ["f0c9f56f-cd0f-4973-bfb5-3cea3e756bcc"] = { token = "pearcooked", nutrition = 16 },
        ["f2ee05db-430c-4505-8b39-ce658fb4bb74"] = { token = "peardried", nutrition = 12 },
    },
    byToken = {} -- filled just below
}

-- Build byToken: "apple" → best entry (& nutrition)
for guid, e in pairs(CuraEqui.DietData.byGuid) do
    CuraEqui.DietData.byToken[e.token] = { guid = guid, nutrition = e.nutrition }
end
