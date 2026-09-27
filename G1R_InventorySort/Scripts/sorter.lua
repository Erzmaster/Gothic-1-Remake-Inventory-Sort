local M = {}

local GROUP_RANKS = {
    melee = { twohand = 1, onehand = 2, unknown = 98, empty = 99 },
    ranged = { crossbow = 1, bow = 2, unknown = 98, empty = 99 },
    magic = { teleport = 1, rune = 2, scroll = 3, unknown = 98, empty = 99 },
    wearables = { armor = 1, amulet = 2, ring = 3, unknown = 98, empty = 99 },
    food = { bowl = 1, food = 2, herb = 3, drug = 4, unknown = 98, empty = 99 },
    potions = { healing = 1, mana = 2, mixed = 3, beverage = 4, unknown = 98, empty = 99 },
    materials = {
        alchemy_recipe = 1,
        inscription_recipe = 2,
        ore = 3,
        material = 4,
        trophy = 5,
        unknown = 98,
        empty = 99,
    },
    documents = { writing = 1, unknown = 98, empty = 99 },
    miscellaneous = { lockpick = 1, torch = 2, instrument = 3, junk = 4, unknown = 98, empty = 99 },
    artefacts = { quest = 1, key = 2, unknown = 98, empty = 99 },
}

local MAGIC_CATEGORY_RANKS = {
    fire = 1,
    ice = 2,
    energy = 3,
    wind = 4,
    summon = 5,
    status = 6,
    other = 7,
    transform = 8,
    unknown = 9,
}

-- Tooltip values verified in the user's current inventory. Exact gameplay-tag
-- keys make an unknown or newly added spell fall back safely instead of being
-- guessed from its localized display name.
local MAGIC_MAX_DAMAGE = {
    ["item.weapon.rune.fireball"] = 130,
    ["item.weapon.scroll.fireball"] = 130,
    ["item.weapon.scroll.firebolt"] = 35,
    ["item.weapon.scroll.firerain"] = 50,
    ["item.weapon.scroll.stormoffire"] = 250,
    ["item.weapon.scroll.iceblock"] = 60,
    ["item.weapon.scroll.icebolt"] = 20,
    ["item.weapon.scroll.icewave"] = 120,
    ["item.weapon.scroll.chainlightning"] = 20,
    ["item.weapon.scroll.balllightning"] = 150,
    ["item.weapon.scroll.pyrokinesis"] = 20,
    ["item.weapon.scroll.stormfist"] = 120,
    ["item.weapon.scroll.fistofwind"] = 20,
}

local MAGIC_STATUS_SPELLS = {
    charm = true,
    control = true,
    fear = true,
    sleep = true,
}

local MAGIC_OTHER_SPELLS = {
    heal = true,
    light = true,
    telekinesis = true,
    teleport = true,
}

local NAME_REPLACEMENTS = {
    ["Ä"] = "a", ["ä"] = "a",
    ["Ö"] = "o", ["ö"] = "o",
    ["Ü"] = "u", ["ü"] = "u",
    ["ẞ"] = "ss", ["ß"] = "ss",
    ["À"] = "a", ["Á"] = "a", ["Â"] = "a", ["Ã"] = "a", ["Å"] = "a",
    ["à"] = "a", ["á"] = "a", ["â"] = "a", ["ã"] = "a", ["å"] = "a",
    ["È"] = "e", ["É"] = "e", ["Ê"] = "e", ["Ë"] = "e",
    ["è"] = "e", ["é"] = "e", ["ê"] = "e", ["ë"] = "e",
    ["Ì"] = "i", ["Í"] = "i", ["Î"] = "i", ["Ï"] = "i",
    ["ì"] = "i", ["í"] = "i", ["î"] = "i", ["ï"] = "i",
    ["Ò"] = "o", ["Ó"] = "o", ["Ô"] = "o", ["Õ"] = "o",
    ["ò"] = "o", ["ó"] = "o", ["ô"] = "o", ["õ"] = "o",
    ["Ù"] = "u", ["Ú"] = "u", ["Û"] = "u",
    ["ù"] = "u", ["ú"] = "u", ["û"] = "u",
    ["Ç"] = "c", ["ç"] = "c", ["Ñ"] = "n", ["ñ"] = "n",
}

function M.normalize_name(value)
    local result = tostring(value or "")
    for character, replacement in pairs(NAME_REPLACEMENTS) do
        result = result:gsub(character, replacement)
    end
    return result:lower()
end

function M.inventory_kind_from_filter_tag(filter_tag)
    local normalized = tostring(filter_tag or ""):lower()
    local tokens = {}
    for token in normalized:gmatch("[a-z0-9]+") do
        tokens[token] = true
    end

    local matches = {}
    local function add_if(condition, kind)
        if condition then matches[#matches + 1] = kind end
    end

    add_if(tokens.melee or tokens.meleeweapon or tokens.meleeweapons, "melee")
    add_if(tokens.ranged or tokens.rangedweapon or tokens.rangedweapons, "ranged")
    add_if(tokens.magic, "magic")
    add_if(tokens.wereables or tokens.wearables, "wearables")
    add_if(tokens.food, "food")
    add_if(tokens.potion or tokens.potions, "potions")
    add_if(tokens.material or tokens.materials, "materials")
    add_if(tokens.document or tokens.documents, "documents")
    add_if(tokens.misc or tokens.miscellaneous, "miscellaneous")
    add_if(tokens.artefact or tokens.artefacts or tokens.artifact or tokens.artifacts, "artefacts")

    if #matches ~= 1 then return nil end
    return matches[1]
end

local function potion_metadata(class_name)
    local class = tostring(class_name or ""):lower()
    local magnitude_by_suffix = {
        ["health_01"] = 50,
        ["health_02"] = 70,
        ["health_03"] = 100,
        ["health_quick"] = 30,
        ["mana_01"] = 30,
        ["mana_02"] = 50,
        ["mana_03"] = 70,
    }

    if class:find("seaforestbrew", 1, true) then
        return "mixed", 80, 40
    end
    if class:find("potion_health", 1, true) then
        for suffix, magnitude in pairs(magnitude_by_suffix) do
            if suffix:find("health", 1, true) and class:find(suffix, 1, true) then
                return "healing", magnitude, nil
            end
        end
        return "healing", nil, nil
    end
    if class:find("potion_mana", 1, true) then
        for suffix, magnitude in pairs(magnitude_by_suffix) do
            if suffix:find("mana", 1, true) and class:find(suffix, 1, true) then
                return "mana", magnitude, nil
            end
        end
        return "mana", nil, nil
    end
    if class:find("potion_booze", 1, true) then return "beverage", 60, nil end
    if class:find("potion_strongbeer", 1, true) then return "beverage", 40, nil end
    if class:find("potion_wine", 1, true) then return "beverage", 50, nil end
    if class:find("potion_beer", 1, true) then return "beverage", 20, nil end
    if class:find("potion_water", 1, true) then return "beverage", 0, nil end
    return "unknown", nil, nil
end

function M.classify_group(inventory_kind, item_type, class_name)
    local tag = tostring(item_type or ""):lower()

    if inventory_kind == "melee" then
        if tag:match("%.twohand$") and tag:find("item.weapon.", 1, true) == 1 then return "twohand" end
        if tag:match("%.onehand$") and tag:find("item.weapon.", 1, true) == 1
            and not tag:find(".torch.", 1, true) then return "onehand" end
    elseif inventory_kind == "ranged" then
        if tag == "item.weapon.crossbow" then return "crossbow" end
        if tag == "item.weapon.bow" then return "bow" end
    elseif inventory_kind == "magic" then
        if tag == "item.weapon.rune.teleport" then return "teleport" end
        if tag:find("item.weapon.rune.", 1, true) == 1 then return "rune" end
        if tag:find("item.weapon.scroll.", 1, true) == 1 then return "scroll" end
    elseif inventory_kind == "wearables" then
        if tag == "item.armor" then return "armor" end
        if tag == "item.amulet" then return "amulet" end
        if tag == "item.ring" then return "ring" end
    elseif inventory_kind == "food" then
        if tag == "item.food.bowl" then return "bowl" end
        if tag == "item.food" then return "food" end
        if tag == "item.herb" then return "herb" end
        if tag == "item.drug" then return "drug" end
    elseif inventory_kind == "potions" then
        return potion_metadata(class_name)
    elseif inventory_kind == "materials" then
        if tag == "item.recipe.alchemy" then return "alchemy_recipe" end
        if tag == "item.recipe.inscription" then return "inscription_recipe" end
        if tag == "item.ore" then return "ore" end
        if tag == "item.material" then return "material" end
        if tag == "item.trophy" then return "trophy" end
    elseif inventory_kind == "documents" then
        if tag == "item.writing" then return "writing" end
    elseif inventory_kind == "miscellaneous" then
        if tag == "item.lockpick" then return "lockpick" end
        if tag == "item.weapon.torch.onehand" then return "torch" end
        if tag == "item.instrument" then return "instrument" end
        if tag == "item.junk" then return "junk" end
    elseif inventory_kind == "artefacts" then
        if tag == "item.quest" then return "quest" end
        if tag == "item.key" then return "key" end
    end
    return "unknown"
end

function M.potion_metadata(class_name)
    return potion_metadata(class_name)
end

function M.magic_max_damage(item_type)
    return MAGIC_MAX_DAMAGE[tostring(item_type or ""):lower()]
end

local function magic_spell_id(item_type)
    local tag = tostring(item_type or ""):lower()
    return tag:match("^item%.weapon%.rune%.(.+)$")
        or tag:match("^item%.weapon%.scroll%.(.+)$")
end

function M.classify_magic_category(spell_category, item_type)
    local category = tostring(spell_category or ""):lower()
    local tag = tostring(item_type or ""):lower()
    local spell_id = magic_spell_id(tag)

    if category:find("fire", 1, true) then return "fire" end
    if category:find("ice", 1, true) then return "ice" end
    if category:find("energy", 1, true) or category:find("lightning", 1, true) then return "energy" end
    if category:find("wind", 1, true) then return "wind" end

    if MAGIC_MAX_DAMAGE[tag] ~= nil then
        if tag:find("fire", 1, true) or tag:find("pyrokinesis", 1, true) then return "fire" end
        if tag:find("ice", 1, true) then return "ice" end
        if tag:find("lightning", 1, true) then return "energy" end
        if tag:find("wind", 1, true) or tag:find("stormfist", 1, true) then return "wind" end
    end

    if spell_id ~= nil and spell_id:find("summon.", 1, true) == 1 then return "summon" end
    if MAGIC_STATUS_SPELLS[spell_id] then return "status" end
    if MAGIC_OTHER_SPELLS[spell_id] then return "other" end
    if category:find("transform", 1, true)
        or (spell_id ~= nil and spell_id:find("transform.", 1, true) == 1) then
        return "transform"
    end
    return "unknown"
end

local function optional_descending(left, right)
    if left == right then return nil end
    if left == nil then return false end
    if right == nil then return true end
    return left > right
end

local function entry_less(inventory_kind, ranks, left, right)
    local left_rank = ranks[left.group] or ranks.unknown
    local right_rank = ranks[right.group] or ranks.unknown
    if left_rank ~= right_rank then return left_rank < right_rank end

    if inventory_kind == "melee" or inventory_kind == "ranged" then
        local result = optional_descending(left.damage, right.damage)
        if result ~= nil then return result end
    elseif inventory_kind == "magic" then
        local left_category_rank = MAGIC_CATEGORY_RANKS[left.magic_category]
            or MAGIC_CATEGORY_RANKS.unknown
        local right_category_rank = MAGIC_CATEGORY_RANKS[right.magic_category]
            or MAGIC_CATEGORY_RANKS.unknown
        if left_category_rank ~= right_category_rank then
            return left_category_rank < right_category_rank
        end
        local circle_result = optional_descending(left.magic_circle, right.magic_circle)
        if circle_result ~= nil then return circle_result end
        local damage_result = optional_descending(left.damage, right.damage)
        if damage_result ~= nil then return damage_result end
    elseif inventory_kind == "potions" then
        local primary_result = optional_descending(left.magnitude, right.magnitude)
        if primary_result ~= nil then return primary_result end
        local secondary_result = optional_descending(left.secondary_magnitude, right.secondary_magnitude)
        if secondary_result ~= nil then return secondary_result end
    end

    if left.name_key ~= right.name_key then return left.name_key < right.name_key end
    return left.original_index < right.original_index
end

function M.sort(entries, inventory_kind)
    local ranks = GROUP_RANKS[inventory_kind]
    if ranks == nil then
        return false, nil, nil, "unsupported inventory kind: " .. tostring(inventory_kind)
    end

    local equipped = {}
    local regular = {}
    for _, entry in ipairs(entries) do
        if entry.equipped == true then
            equipped[#equipped + 1] = entry
        else
            regular[#regular + 1] = entry
        end
    end

    table.sort(regular, function(left, right)
        return entry_less(inventory_kind, ranks, left, right)
    end)

    local merged = {}
    for _, entry in ipairs(equipped) do merged[#merged + 1] = entry end
    for _, entry in ipairs(regular) do merged[#merged + 1] = entry end
    return true, merged, regular, nil
end

return M
