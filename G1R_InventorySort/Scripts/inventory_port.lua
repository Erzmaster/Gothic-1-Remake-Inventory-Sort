local sorter = require("sorter")

local M = {}

local GET_INVENTORY_BASE_PATH = "/Script/G1R.InventoryMain:GetInventoryBase"
local GET_DEFINITION_PATH = "/Script/G1R.InventoryBase:GetBaseConfigByPos"
local GET_ITEM_TYPE_PATH = "/Script/G1R.ItemDefinition:GetItemType"
local GET_ITEM_WEARABLE_EQUIPPED_PATH = "/Script/G1R.InventoryBase:GetItemWearableEquipped"
local GET_DAMAGE_TYPES_PATH = "/Script/G1R.WeaponDefinition:GetDamageTypes"
local GET_DAMAGE_PATH = "/Script/G1R.WeaponDefinition:GetDamage"
local GET_SPELL_CONFIG_PATH = "/Script/G1R.SpellContainer:GetSpellConfigFromContainer"
local GET_SPELL_CATEGORY_PATH = "/Script/G1R.SpellConfig:GetSpellCategoryTag"
local GET_SELECTED_FILTER_TAG_PATH = "/Script/G1R.AlkFilterWidget:GetSelectedFilterTag"
local SET_LIST_ITEMS_PATH = "/Script/G1R.DiscreteItemViewWidget:SetListItemsBP"
local GET_NUM_ITEMS_PATH = "/Script/G1R.DiscreteItemViewWidget:GetNumItems"
local GET_ITEM_AT_PATH = "/Script/G1R.DiscreteItemViewWidget:GetItemAt"
local GET_INDEX_FOR_ITEM_PATH = "/Script/G1R.DiscreteItemViewWidget:GetIndexForItem"
local ITEMS_NUM_PATH = "/Script/G1R.InventoryBase:ItemsNum"
local IS_ITEM_VALID_PATH = "/Script/G1R.InventoryBase:IsItemValidByPos"
local GET_ITEM_ID_PATH = "/Script/G1R.InventoryBase:GetItemIdByPos"
local GET_ITEM_NAME_PATH = "/Script/G1R.InventoryBase:GetItemNameByPos"
local GET_ITEM_AMOUNT_PATH = "/Script/G1R.InventoryBase:GetItemAmountByPos"

local WEAPON_MELEE_CLASS_PATH = "/Script/G1R.WeaponMeleeDefinition"
local WEAPON_RANGED_CLASS_PATH = "/Script/G1R.WeaponRangedDefinition"
local WEAPON_ARCHERY_CLASS_PATH = "/Script/G1R.WeaponArcheryDefinition"

local functions = {}
local classes = {}
local definition_cache = {}
local warned_missing_damage = {}
local warned_metadata = {}
local logged_skip_reasons = {}
local logged_damage_accessor_error = false
local scratch_owner = nil
local scratch_original = nil
local scratch_probe = nil

local function log(message)
    print("[G1R_InventorySort] " .. tostring(message) .. "\n")
end

local function unwrap(value)
    if value == nil then
        return nil
    end

    local ok, unwrapped = pcall(function()
        return value:get()
    end)
    if ok then
        return unwrapped
    end
    return value
end

local function is_valid(object)
    if object == nil then
        return false
    end

    local ok, result = pcall(function()
        return object:IsValid()
    end)
    return ok and result == true
end

local function full_class_name(object)
    local ok, result = pcall(function()
        return object:GetClass():GetFullName()
    end)
    if not ok or result == nil then
        return "<unknown class>"
    end
    return tostring(result)
end

local function full_object_name(object)
    local ok, result = pcall(function()
        return object:GetFullName()
    end)
    if not ok or result == nil then
        error("could not read the full name of a UI list object")
    end
    return tostring(result)
end

local function resolve_function(path)
    if functions[path] ~= nil then
        return functions[path]
    end

    local resolved = StaticFindObject(path)
    if resolved == nil or not is_valid(resolved) then
        error("could not resolve UFunction " .. path)
    end
    functions[path] = resolved
    return resolved
end

local function resolve_class(path)
    if classes[path] ~= nil then
        return classes[path]
    end

    local resolved = StaticFindObject(path)
    if resolved == nil or not is_valid(resolved) then
        error("could not resolve UClass " .. path)
    end
    classes[path] = resolved
    return resolved
end

local function safe_property(object, property_name)
    if object == nil then
        return nil
    end
    local ok, result = pcall(function()
        return unwrap(object[property_name])
    end)
    if ok then
        return result
    end
    return nil
end

local function safe_call(path, context, ...)
    local arguments = { ... }
    local ok, result = pcall(function()
        local fn = resolve_function(path)
        return unwrap(fn(context, table.unpack(arguments)))
    end)
    if ok then
        return result
    end
    if not warned_metadata[path] then
        warned_metadata[path] = true
        log("optional metadata unavailable from " .. path .. ": " .. tostring(result))
    end
    return nil
end

local function object_is_a(object, class_path)
    local class = resolve_class(class_path)
    local ok, result = pcall(function()
        return object:IsA(class)
    end)
    if not ok then
        error("could not verify " .. full_class_name(object) .. " against " .. class_path
            .. ": " .. tostring(result))
    end
    return result == true
end

local function text_to_string(value)
    if value == nil then
        return ""
    end

    local ok, converted = pcall(function()
        return value:ToString()
    end)
    if ok and converted ~= nil then
        return tostring(converted)
    end
    return tostring(value)
end

local function numeric_value(value)
    value = unwrap(value)
    if type(value) == "number" then
        return value
    end
    return tonumber(value)
end

local function gameplay_tag_to_string(value)
    local tag = unwrap(value)
    if tag == nil then
        return ""
    end

    local ok, result = pcall(function()
        if tag.TagName ~= nil then
            return tag.TagName:ToString()
        end
        return tostring(tag)
    end)
    if ok and result ~= nil then
        return tostring(result)
    end
    return ""
end

local function get_selected_inventory_kind(panel)
    local generic_filter = panel.GenericFilter
    if not is_valid(generic_filter) then
        return nil, "<filter widget unavailable>"
    end

    local get_selected_filter_tag = resolve_function(GET_SELECTED_FILTER_TAG_PATH)
    local filter_tag = gameplay_tag_to_string(get_selected_filter_tag(generic_filter))
    local inventory_kind = sorter.inventory_kind_from_filter_tag(filter_tag)
    return inventory_kind, filter_tag ~= "" and filter_tag or "<empty filter tag>"
end

local function damage_from_functions(definition)
    local get_damage_types = resolve_function(GET_DAMAGE_TYPES_PATH)
    local get_damage = resolve_function(GET_DAMAGE_PATH)
    local damage_types = unwrap(get_damage_types(definition))
    if damage_types == nil then
        return nil
    end

    local total = 0
    local component_count = 0

    local function add_damage_component(element)
        local damage_type = unwrap(element)
        if damage_type ~= nil then
            local component = numeric_value(get_damage(definition, damage_type))
            if component ~= nil then
                total = total + component
                component_count = component_count + 1
            end
        end
    end

    -- UFunction TArray return values are converted to ordinary 1-based Lua
    -- tables by some UE4SS builds. Direct UObject properties, on the other
    -- hand, may still be exposed as TArray userdata. Support both forms.
    if type(damage_types) == "table" then
        for _, element in ipairs(damage_types) do
            add_damage_component(element)
        end
    else
        damage_types:ForEach(function(_, element)
            add_damage_component(element)
        end)
    end

    if component_count > 0 then
        return total
    end
    return nil
end

local function get_total_base_damage(definition)
    -- Do not read WeaponDefinition.m_DamageBase directly. On this game's
    -- UE4SS build, reflecting/iterating that TMap can produce a native access
    -- violation that Lua's pcall cannot contain. These UFunctions are the
    -- game's supported accessor path and are called only for definitions
    -- verified against the native melee/ranged weapon classes.
    local ok, damage = pcall(damage_from_functions, definition)
    if ok then
        return damage
    end

    if not logged_damage_accessor_error then
        logged_damage_accessor_error = true
        log("damage accessor error for " .. full_class_name(definition) .. ": " .. tostring(damage))
    end
    return nil
end

local function get_inventory_base(panel)
    local get_inventory_base = resolve_function(GET_INVENTORY_BASE_PATH)
    local inventory_base = unwrap(get_inventory_base(panel))
    if not is_valid(inventory_base) then
        error("GetInventoryBase returned no valid inventory")
    end
    return inventory_base
end

local function get_definition(inventory_base, position)
    local get_definition_by_position = resolve_function(GET_DEFINITION_PATH)
    local definition = unwrap(get_definition_by_position(inventory_base, position))
    if not is_valid(definition) then
        return nil
    end
    return definition
end

local function metadata_for_definition(definition)
    local class_name = full_class_name(definition)
    if definition_cache[class_name] ~= nil then
        return definition_cache[class_name]
    end

    local metadata = {
        class_name = class_name,
        item_type = gameplay_tag_to_string(safe_call(GET_ITEM_TYPE_PATH, definition)),
        damage = nil,
        damage_loaded = false,
        spell_category = nil,
        magic_loaded = false,
    }
    definition_cache[class_name] = metadata
    return metadata
end

local function load_damage(metadata, definition)
    if not metadata.damage_loaded then
        metadata.damage = get_total_base_damage(definition)
        metadata.damage_loaded = true
    end

    if metadata.damage == nil and not warned_missing_damage[metadata.class_name] then
        warned_missing_damage[metadata.class_name] = true
        log("could not read base damage for " .. metadata.class_name
            .. "; the item will retain its type and use alphabetical fallback")
    end
    return metadata.damage
end

local function load_magic(metadata, definition)
    if not metadata.magic_loaded then
        local spell_config = safe_call(GET_SPELL_CONFIG_PATH, definition)
        if is_valid(spell_config) then
            metadata.spell_category = gameplay_tag_to_string(
                safe_call(GET_SPELL_CATEGORY_PATH, spell_config))
        end
        local circle = numeric_value(safe_property(definition, "RequiredMagicCircleLevel"))
        if circle ~= nil and circle > 0 then
            metadata.magic_circle = circle
        end
        metadata.magic_loaded = true
    end
    return metadata.spell_category, metadata.magic_circle
end

local function get_list_items(panel)
    local tile_view_items = panel.TileView_Items
    if not is_valid(tile_view_items) then
        error("TileView_Items is not valid")
    end

    local tile_view_grid = tile_view_items.TileView_Grid
    if not is_valid(tile_view_grid) then
        error("TileView_Grid is not valid")
    end

    local list_items = tile_view_grid.ListItems
    if list_items == nil then
        error("TileView_Grid.ListItems is unavailable")
    end
    return list_items, tile_view_grid, tile_view_items
end

local function snapshot_entries(list_items)
    local entries = {}
    list_items:ForEach(function(_, element)
        local slot = unwrap(element)
        if not is_valid(slot) then
            error("inventory list contains an invalid slot object")
        end

        local original_index = #entries + 1
        local name = text_to_string(slot.m_Name)
        local is_empty = unwrap(slot.m_IsEmpty) == true
        local position = numeric_value(slot.m_Pos)
        if not is_empty and position == nil then
            error("inventory slot has no numeric m_Pos: " .. name)
        end

        entries[#entries + 1] = {
            object = slot,
            object_key = full_object_name(slot),
            name = name,
            amount = numeric_value(slot.m_Amount),
            name_key = sorter.normalize_name(name),
            position = position,
            is_empty = is_empty,
            group = is_empty and "empty" or "unknown",
            equipped = false,
            damage = nil,
            magic_category = "unknown",
            magic_circle = nil,
            magnitude = nil,
            secondary_magnitude = nil,
            class_name = is_empty and "<empty>" or "<unresolved>",
            item_type = "",
            original_index = original_index,
        }
    end)
    return entries
end


local function prepare_entries(panel, entries, selected_kind, provider)
    local inventory_base = provider == nil and get_inventory_base(panel) or nil
    for _, entry in ipairs(entries) do
        if not entry.is_empty then
            local definition
            if provider ~= nil then
                definition = provider.definition_at(entry.position)
            else
                definition = get_definition(inventory_base, entry.position)
            end
            if definition == nil then
                entry.group = "unknown"
                local warning_key = "definition:" .. tostring(entry.position)
                if not warned_metadata[warning_key] then
                    warned_metadata[warning_key] = true
                    log("definition unavailable for " .. entry.name
                        .. "; preserving it in the Unknown category")
                end
            else
                local metadata = metadata_for_definition(definition)
                entry.definition = definition
                entry.metadata = metadata
                entry.class_name = metadata.class_name
                entry.item_type = metadata.item_type
                entry.group = sorter.classify_group(
                    selected_kind, metadata.item_type, metadata.class_name)
                if provider ~= nil then
                    entry.equipped = provider.equipped_at(entry.position) == true
                else
                    entry.equipped = safe_call(
                        GET_ITEM_WEARABLE_EQUIPPED_PATH, inventory_base, entry.position) == true
                end

                if selected_kind == "melee" and entry.group ~= "unknown" then
                    if object_is_a(definition, WEAPON_MELEE_CLASS_PATH) then
                        entry.damage = load_damage(metadata, definition)
                    else
                        entry.group = "unknown"
                    end
                elseif selected_kind == "ranged" and entry.group ~= "unknown" then
                    if object_is_a(definition, WEAPON_RANGED_CLASS_PATH)
                        or object_is_a(definition, WEAPON_ARCHERY_CLASS_PATH) then
                        entry.damage = load_damage(metadata, definition)
                    else
                        entry.group = "unknown"
                    end
                elseif selected_kind == "magic" then
                    if entry.group ~= "unknown" then
                        local spell_category, magic_circle = load_magic(metadata, definition)
                        entry.magic_category = sorter.classify_magic_category(
                            spell_category, metadata.item_type)
                        entry.magic_circle = magic_circle
                        entry.damage = sorter.magic_max_damage(metadata.item_type)
                    else
                        entry.magic_category = "unknown"
                    end
                elseif selected_kind == "potions" then
                    local group, magnitude, secondary_magnitude =
                        sorter.potion_metadata(metadata.class_name)
                    entry.group = group
                    entry.magnitude = magnitude
                    entry.secondary_magnitude = secondary_magnitude
                end
            end
        end
    end
    return true, nil
end

local function log_skip_once(reason, config)
    if not config.log_skipped_lists or logged_skip_reasons[reason] then
        return
    end
    logged_skip_reasons[reason] = true
    log("refresh ignored safely: " .. reason)
end

local function snapshot_list_objects(list_items)
    local objects = {}
    local keys = {}
    list_items:ForEach(function(_, element)
        local object = unwrap(element)
        if not is_valid(object) then
            error("inventory list contains an invalid slot object")
        end
        objects[#objects + 1] = object
        keys[#keys + 1] = full_object_name(object)
    end)
    return objects, keys
end

local function same_order(left, right)
    if #left ~= #right then
        return false
    end
    for index = 1, #left do
        if left[index] ~= right[index] then
            return false
        end
    end
    return true
end

local function same_identity_multiset(left, right)
    if #left ~= #right then
        return false
    end
    local counts = {}
    for _, key in ipairs(left) do
        counts[key] = (counts[key] or 0) + 1
    end
    for _, key in ipairs(right) do
        local count = counts[key]
        if count == nil or count == 0 then
            return false
        end
        counts[key] = count - 1
    end
    for _, count in pairs(counts) do
        if count ~= 0 then
            return false
        end
    end
    return true
end

local function verify_list_order(list_items, expected_keys)
    local _, live_keys = snapshot_list_objects(list_items)
    if not same_order(live_keys, expected_keys) then
        error("inventory UI list verification failed")
    end
end

local function verify_list_view_state(item_view, list_view, expected_objects, expected_keys)
    -- Gothic's DiscreteItemViewWidget owns additional hover/current-index
    -- state on top of the inner UMG TileView. Its public accessors must agree
    -- with the inner property snapshot before we accept the new order;
    -- otherwise InputReceivedUse can act on a stale outer index.
    local get_num_items = resolve_function(GET_NUM_ITEMS_PATH)
    local get_item_at = resolve_function(GET_ITEM_AT_PATH)
    local get_index_for_item = resolve_function(GET_INDEX_FOR_ITEM_PATH)

    local live_list_items = list_view.ListItems
    if live_list_items == nil then
        error("TileView_Grid.ListItems became unavailable after reordering")
    end
    verify_list_order(live_list_items, expected_keys)

    local live_count = numeric_value(get_num_items(item_view))
    if live_count ~= #expected_objects then
        error("inventory UI list count verification failed")
    end

    for index, expected_object in ipairs(expected_objects) do
        local list_index = index - 1
        local live_object = unwrap(get_item_at(item_view, list_index))
        if not is_valid(live_object)
            or full_object_name(live_object) ~= expected_keys[index] then
            error("inventory UI object verification failed at index " .. tostring(list_index))
        end

        local resolved_index = numeric_value(get_index_for_item(item_view, expected_object))
        if resolved_index ~= list_index then
            error("inventory UI index verification failed for " .. expected_keys[index])
        end
    end
end

local function filtered_array(inventory_base, expected_count)
    local array = inventory_base.FilteredInventory
    if array == nil then
        error("InventoryBase.FilteredInventory is unavailable")
    end
    local array_count = numeric_value(array:GetArrayNum())
    if array_count ~= expected_count then
        error("filtered inventory count does not match the UI list")
    end
    return array
end

local function array_data_address(array)
    local address = numeric_value(array:GetArrayDataAddress())
    if address == nil or address == 0 then
        error("filtered inventory has no usable array data address")
    end
    return address
end

local function filtered_lua_index(index, expected_count)
    local position = numeric_value(index)
    if position == nil or position % 1 ~= 0 or position < 1
        or position > expected_count then
        error("filtered inventory exposed an invalid element index")
    end
    return position
end

local function filtered_entries(array, expected_count)
    local values = {}
    local fingerprints = {}
    local callback_count = 0
    local bad_index = false
    array:ForEach(function(index, element)
        callback_count = callback_count + 1
        if numeric_value(index) ~= callback_count then bad_index = true end
        local item = unwrap(element)
        if item == nil then
            error("filtered inventory contains an unreadable virtual item")
        end
        local id = numeric_value(item.m_Id)
        if id == nil then
            error("filtered inventory item has no numeric ID")
        end
        local inventory_type = numeric_value(item.m_InventoryType)
        if inventory_type == nil then
            error("filtered inventory item has no numeric inventory type")
        end
        local slot_data = item.m_SlotData
        local item_count = slot_data ~= nil and numeric_value(slot_data.m_ItemCount) or nil
        local definition = slot_data ~= nil and unwrap(slot_data.m_ItemDefinition) or nil
        local definition_name = is_valid(definition) and full_object_name(definition) or "<none>"
        local payload = item.m_Payload
        local stage_level = payload ~= nil and numeric_value(payload.m_StageLevel) or nil
        if stage_level == nil then
            error("filtered inventory item has no readable payload stage")
        end
        values[callback_count] = item
        fingerprints[callback_count] = table.concat({
            tostring(id), tostring(inventory_type), tostring(item_count),
            definition_name, tostring(stage_level),
        }, "|")
    end)
    if callback_count ~= expected_count or #values ~= expected_count
        or #fingerprints ~= expected_count
        or numeric_value(array:GetArrayNum()) ~= expected_count then
        error("filtered inventory enumeration was incomplete")
    end
    if bad_index then
        error("filtered inventory exposed an invalid element index")
    end
    return values, fingerprints
end

local function read_model_state(inventory_base, expected_count)
    local items_num = numeric_value(resolve_function(ITEMS_NUM_PATH)(inventory_base))
    if items_num ~= expected_count then
        error("InventoryBase.ItemsNum does not match the UI list")
    end
    local is_item_valid = resolve_function(IS_ITEM_VALID_PATH)
    local get_item_id = resolve_function(GET_ITEM_ID_PATH)
    local get_item_name = resolve_function(GET_ITEM_NAME_PATH)
    local get_item_amount = resolve_function(GET_ITEM_AMOUNT_PATH)
    local array = filtered_array(inventory_base, expected_count)
    local _, fingerprints = filtered_entries(array, expected_count)
    local state = {}

    for position = 0, expected_count - 1 do
        if unwrap(is_item_valid(inventory_base, position)) ~= true then
            error("filtered inventory contains an invalid item position")
        end
        local id = numeric_value(get_item_id(inventory_base, position))
        local name = text_to_string(unwrap(get_item_name(inventory_base, position)))
        local amount = numeric_value(get_item_amount(inventory_base, position))
        if id == nil or amount == nil or name == "" then
            error("filtered inventory item metadata is incomplete")
        end
        -- m_Id is item metadata, not a unique slot key. Two valid filtered
        -- entries may share it. The one-to-one mapping is established by the
        -- distinct m_Pos values checked in verify_ui_model_alignment below.
        local id_prefix = tostring(id) .. "|"
        if fingerprints[position + 1]:sub(1, #id_prefix) ~= id_prefix then
            error("filtered inventory array disagrees with GetItemIdByPos")
        end
        state[position + 1] = {
            id = id,
            name = name,
            amount = amount,
            fingerprint = fingerprints[position + 1],
        }
    end
    return state
end

local function verify_ui_model_alignment(original_entries, model_state)
    local seen_positions = {}
    for _, entry in ipairs(original_entries) do
        local position = entry.position
        if entry.is_empty or position == nil or position < 0
            or position >= #model_state or position % 1 ~= 0 or seen_positions[position] then
            error("UI slots are not a one-to-one view of the filtered inventory")
        end
        seen_positions[position] = true
        local model_item = model_state[position + 1]
        if entry.name ~= model_item.name or entry.amount ~= model_item.amount then
            error("UI slot and filtered inventory disagree at position " .. tostring(position))
        end
    end
end

local function get_scratch_inventories(panel, inventory_base)
    local owner_address = numeric_value(inventory_base:GetAddress())
    if owner_address == nil then
        error("could not identify the inventory base")
    end
    if scratch_owner ~= owner_address or not is_valid(scratch_original)
        or not is_valid(scratch_probe) then
        local class = inventory_base:GetClass()
        if not is_valid(class) then error("inventory base class is unavailable") end
        scratch_original = StaticConstructObject(class, panel, 0)
        scratch_probe = StaticConstructObject(class, panel, 0)
        if not is_valid(scratch_original) or not is_valid(scratch_probe) then
            error("could not construct temporary filtered-inventory copies")
        end
        scratch_owner = owner_address
    end
    return scratch_original, scratch_probe
end

local function copy_filtered_array(destination, source, count)
    destination.FilteredInventory = source.FilteredInventory
    local source_array = filtered_array(source, count)
    local destination_array = filtered_array(destination, count)
    if array_data_address(source_array) == array_data_address(destination_array) then
        error("filtered-inventory copy shares its element storage")
    end
    local _, source_fingerprints = filtered_entries(source_array, count)
    local _, destination_fingerprints = filtered_entries(destination_array, count)
    if not same_order(source_fingerprints, destination_fingerprints) then
        error("filtered-inventory copy changed item identities")
    end
    return destination_array
end

local function write_filtered_array(destination_array, source_array, source_indices, expected_count)
    local source_values = filtered_entries(source_array, expected_count)
    -- Validate the destination's callback indices without changing it first.
    filtered_entries(destination_array, expected_count)
    local next_index = 0
    destination_array:ForEach(function(index, element)
        local destination_index = filtered_lua_index(index, expected_count)
        next_index = next_index + 1
        if destination_index ~= next_index then
            error("filtered inventory callback indices changed during write")
        end
        local source_index = source_indices[destination_index]
        if source_index == nil or source_values[source_index] == nil then
            error("filtered-inventory permutation is incomplete")
        end
        element:set(source_values[source_index])
    end)
    if next_index ~= expected_count then
        error("filtered inventory write was incomplete")
    end
end

local function verify_model_order(inventory_base, expected_state)
    local live_state = read_model_state(inventory_base, #expected_state)
    for index, expected in ipairs(expected_state) do
        local actual = live_state[index]
        if actual.id ~= expected.id or actual.name ~= expected.name
            or actual.amount ~= expected.amount or actual.fingerprint ~= expected.fingerprint then
            error("filtered inventory verification failed at index " .. tostring(index - 1))
        end
    end
end

local function write_entries(panel, list_items, list_view, item_view, original_entries, sorted_entries)
    -- Resolve every required public DiscreteItemViewWidget function before
    -- changing anything. A game update that removes one of them therefore
    -- leaves the UI list untouched.
    local set_list_items = resolve_function(SET_LIST_ITEMS_PATH)
    resolve_function(GET_NUM_ITEMS_PATH)
    resolve_function(GET_ITEM_AT_PATH)
    resolve_function(GET_INDEX_FOR_ITEM_PATH)

    local original_objects, original_keys = snapshot_list_objects(list_items)
    if #original_entries ~= #original_objects then
        error("inventory list changed while sorting; refusing to write it")
    end

    local snapshot_keys = {}
    for index, entry in ipairs(original_entries) do
        if not is_valid(entry.object) then
            error("inventory slot became invalid while sorting; refusing to write it")
        end
        snapshot_keys[index] = entry.object_key
    end
    if not same_order(original_keys, snapshot_keys) then
        error("inventory list contents changed while sorting; refusing to write it")
    end

    local target_objects = {}
    local target_keys = {}
    for index, entry in ipairs(sorted_entries) do
        target_objects[index] = entry.object
        target_keys[index] = entry.object_key
    end
    if not same_identity_multiset(original_keys, target_keys) then
        error("refusing to write: sorted UI list changed item count or identity")
    end
    local inventory_base = get_inventory_base(panel)
    local original_state = read_model_state(inventory_base, #original_entries)
    verify_ui_model_alignment(original_entries, original_state)

    local source_indices = {}
    local sorted_state = {}
    local model_changed = false
    for index, entry in ipairs(sorted_entries) do
        local source_index = entry.position + 1
        source_indices[index] = source_index
        sorted_state[index] = original_state[source_index]
        if source_index ~= index then model_changed = true end
    end
    local ui_changed = not same_order(original_keys, target_keys)
    if not ui_changed and not model_changed then
        return false
    end
    local identity_indices = {}
    for index = 1, #original_entries do identity_indices[index] = index end

    -- The temporary UInventoryBase instances own independent copies of the
    -- filtered virtual-item view. Test the permutation on a copy before
    -- touching the live filtered view or any UI slot.
    local original_copy, probe_copy = get_scratch_inventories(panel, inventory_base)
    local original_copy_array = copy_filtered_array(original_copy, inventory_base, #original_entries)
    local probe_array = copy_filtered_array(probe_copy, original_copy, #original_entries)
    write_filtered_array(probe_array, original_copy_array, source_indices, #original_entries)
    local _, probe_fingerprints = filtered_entries(probe_array, #original_entries)
    for index, expected in ipairs(sorted_state) do
        if probe_fingerprints[index] ~= expected.fingerprint then
            error("temporary filtered-inventory reorder failed verification")
        end
    end
    local _, original_copy_fingerprints = filtered_entries(original_copy_array, #original_entries)
    for index, expected in ipairs(original_state) do
        if original_copy_fingerprints[index] ~= expected.fingerprint then
            error("temporary reorder changed its source copy")
        end
    end
    verify_model_order(inventory_base, original_state)

    local write_ok, write_error = pcall(function()
        write_filtered_array(filtered_array(inventory_base, #original_entries),
            original_copy_array, source_indices, #original_entries)
        verify_model_order(inventory_base, sorted_state)
        for index, entry in ipairs(sorted_entries) do
            entry.object.m_Pos = index - 1
        end
        if ui_changed then
            set_list_items(item_view, target_objects, true)
        end
        verify_list_view_state(item_view, list_view, target_objects, target_keys)
        for index, entry in ipairs(sorted_entries) do
            if numeric_value(entry.object.m_Pos) ~= index - 1 then
                error("UI slot position verification failed")
            end
        end
    end)
    if write_ok then
        return true
    end

    -- Restore through the same high-level game UI API if either the setter or
    -- any post-write check fails. There is deliberately no fallback that
    -- mutates the internal ListItems TArray or bypasses the wrapper state.
    local rollback_ok, rollback_error = pcall(function()
        write_filtered_array(filtered_array(inventory_base, #original_entries),
            original_copy_array, identity_indices, #original_entries)
        for _, entry in ipairs(original_entries) do
            entry.object.m_Pos = entry.position
        end
        if ui_changed then
            set_list_items(item_view, original_objects, true)
        end
        verify_model_order(inventory_base, original_state)
        verify_list_view_state(item_view, list_view, original_objects, original_keys)
    end)
    if rollback_ok then
        error("inventory UI reorder failed and was rolled back: " .. tostring(write_error))
    end
    error("inventory UI reorder failed and rollback also failed: " .. tostring(write_error)
        .. "; rollback error: " .. tostring(rollback_error))
end

local function log_sort(entries, inventory_kind, config)
    if not config.log_successful_sorts then
        return
    end

    local preview = {}
    local preview_count = math.min(config.log_preview_count or 0, #entries)
    local equipped_count = 0
    for _, entry in ipairs(entries) do
        if entry.equipped then equipped_count = equipped_count + 1 end
    end
    for index = 1, preview_count do
        local entry = entries[index]
        preview[#preview + 1] = string.format(
            "%s [%s%s]",
            entry.name,
            entry.group,
            entry.equipped and ", equipped" or ""
        )
    end

    local suffix = ""
    if #preview > 0 then
        suffix = "; first: " .. table.concat(preview, ", ")
    end
    log(string.format(
        "synchronized %d %s filtered/UI entries; preserved %d equipped entries first%s",
        #entries,
        inventory_kind,
        equipped_count,
        suffix
    ))
end

function M.sort_panel(panel, config)
    if not is_valid(panel) then
        return false
    end

    -- The selected UI tab is the authority. In particular, do not use
    -- InventoryMain.ActivatedFilter: during initial construction it reports
    -- Melee even though the selected tab is All and the list is still mixed.
    local selected_kind, selected_filter_tag = get_selected_inventory_kind(panel)
    if selected_kind == nil then
        log_skip_once("selected tab is unsupported or intentionally unchanged: "
            .. selected_filter_tag, config)
        return false
    end

    local list_items, list_view, item_view = get_list_items(panel)
    local entries = snapshot_entries(list_items)
    if #entries < 2 then
        return false
    end

    local prepared, skip_reason = prepare_entries(panel, entries, selected_kind)
    if not prepared then
        log_skip_once(skip_reason, config)
        return false
    end

    local sorted, merged_entries, _, reason = sorter.sort(entries, selected_kind)
    if not sorted then
        error(reason)
    end
    local changed = write_entries(panel, list_items, list_view, item_view, entries, merged_entries)
    if changed then
        log_sort(merged_entries, selected_kind, config)
    end
    return changed
end

M.log = log
M.unwrap = unwrap
M.is_valid = is_valid
M.full_class_name = full_class_name
M.prepare_entries = prepare_entries

return M
