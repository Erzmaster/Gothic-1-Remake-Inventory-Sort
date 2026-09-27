-- Merchant payloads use stable source indices. Keep the trading model and
-- each slot's m_Pos unchanged while reordering only the visible slots.
local inventory_port = require("inventory_port")
local sorter = require("sorter")

local M = {}
local FILTER_PATH = "/Script/G1R.AlkFilterWidget:GetSelectedFilterTag"
local SET_LIST_PATH = "/Script/G1R.DiscreteItemViewWidget:SetListItemsBP"
local COUNT_PATH = "/Script/G1R.DiscreteItemViewWidget:GetNumItems"
local ITEM_PATH = "/Script/G1R.DiscreteItemViewWidget:GetItemAt"
local INDEX_PATH = "/Script/G1R.DiscreteItemViewWidget:GetIndexForItem"
local functions = {}

local function unwrap(value) return inventory_port.unwrap(value) end
local function valid(value) return inventory_port.is_valid(unwrap(value)) end
local function number(value)
    value = unwrap(value)
    return type(value) == "number" and value or tonumber(value)
end
local function text(value)
    value = unwrap(value)
    if value == nil then return "" end
    local ok, converted = pcall(function() return value:ToString() end)
    return ok and converted ~= nil and tostring(converted) or tostring(value)
end
local function name_of(object)
    if not valid(object) then error("merchant object is invalid") end
    return tostring(object:GetFullName())
end
local function direction_of(panel)
    if not valid(panel) then return nil end
    local ok, name = pcall(function() return panel:GetFullName() end)
    if not ok or name == nil then return nil end
    name = tostring(name)
    if name:find("W_TradingInventory_Buy", 1, true) then return "buy" end
    if name:find("W_TradingInventory_Sell", 1, true) then return "sell" end
    return nil
end
local function fn(path)
    if functions[path] == nil then
        local result = StaticFindObject(path)
        if not valid(result) then error("could not resolve " .. path) end
        functions[path] = result
    end
    return functions[path]
end
local function count_of(array)
    if array == nil then error("merchant filtered array is unavailable") end
    local count = number(array:GetArrayNum())
    if count == nil or count < 0 or count % 1 ~= 0 then
        error("merchant filtered array count is invalid")
    end
    return count
end

local function model_snapshot(panel, expected_count)
    local base = unwrap(panel.InventoryBaseTrading)
    if not valid(base) then error("merchant trading base is invalid") end
    local array = base.FilteredInventoryTrading
    if count_of(array) ~= expected_count then error("merchant UI/model counts differ") end
    local state = {}
    array:ForEach(function(index, element)
        if number(index) ~= #state + 1 then error("merchant array index changed") end
        local item = unwrap(element)
        local definition = item and unwrap(item.m_ItemDef) or nil
        local entry = {
            definition = definition,
            name = item and text(item.m_ItemName) or "",
            amount = item and number(item.m_ItemAmount) or nil,
            price = item and number(item.m_ItemPrice) or nil,
            id = item and number(item.m_ItemId) or nil,
            slot_id = item and number(item.m_SlotId) or nil,
        }
        if not valid(definition) or entry.name == "" or entry.amount == nil
            or entry.price == nil or entry.id == nil or entry.slot_id == nil then
            error("merchant model item is incomplete")
        end
        entry.key = table.concat({name_of(definition), entry.name,
            tostring(entry.amount), tostring(entry.price), tostring(entry.id),
            tostring(entry.slot_id)}, "|")
        state[#state + 1] = entry
    end)
    if #state ~= expected_count or count_of(array) ~= expected_count then
        error("merchant model enumeration changed")
    end
    return state
end

local function ui_snapshot(panel)
    local view = unwrap(panel.TileView_Items)
    if not valid(view) then error("merchant item view is invalid") end
    local grid = unwrap(view.TileView_Grid)
    if not valid(grid) or grid.ListItems == nil then
        error("merchant UI list is unavailable")
    end
    local entries = {}
    grid.ListItems:ForEach(function(_, element)
        local slot = unwrap(element)
        if not valid(slot) then error("merchant UI slot is invalid") end
        local item_name = text(slot.m_Name)
        entries[#entries + 1] = {
            object = slot,
            object_key = name_of(slot),
            name = item_name,
            name_key = sorter.normalize_name(item_name),
            amount = number(slot.m_Amount),
            value = number(slot.m_Value),
            position = number(slot.m_Pos),
            is_empty = unwrap(slot.m_IsEmpty) == true,
            equipped = false,
            group = "unknown",
            magic_category = "unknown",
            original_index = #entries + 1,
        }
    end)
    return entries, view
end

local function validate_mapping(entries, model)
    if #entries ~= #model then error("merchant UI/model counts differ") end
    local positions, objects = {}, {}
    for _, entry in ipairs(entries) do
        local pos = entry.position
        if entry.is_empty or pos == nil or pos % 1 ~= 0 or pos < 0
            or pos >= #model or positions[pos] or objects[entry.object_key] then
            error("merchant UI positions or slots are not one-to-one")
        end
        positions[pos], objects[entry.object_key] = true, true
        local item = model[pos + 1]
        if entry.name ~= item.name or entry.amount ~= item.amount
            or entry.value ~= item.price then
            error("merchant UI/model item mismatch at position " .. tostring(pos))
        end
    end
end

local function same_order(left, right)
    if #left ~= #right then return false end
    for index = 1, #left do
        if left[index] ~= right[index] then return false end
    end
    return true
end

local function verify_model(panel, original)
    local current = model_snapshot(panel, #original)
    for index, item in ipairs(original) do
        if item.key ~= current[index].key then
            error("merchant model changed at position " .. tostring(index - 1))
        end
    end
end

local function verify_view(view, objects, keys)
    local grid = unwrap(view.TileView_Grid)
    if not valid(grid) or grid.ListItems == nil then
        error("merchant UI list disappeared")
    end
    local actual = {}
    grid.ListItems:ForEach(function(_, element)
        actual[#actual + 1] = name_of(unwrap(element))
    end)
    if not same_order(actual, keys) or number(fn(COUNT_PATH)(view)) ~= #objects then
        error("merchant UI order or count verification failed")
    end
    local item_at, index_for = fn(ITEM_PATH), fn(INDEX_PATH)
    for index, object in ipairs(objects) do
        local live = unwrap(item_at(view, index - 1))
        if not valid(live) or name_of(live) ~= keys[index]
            or number(index_for(view, object)) ~= index - 1 then
            error("merchant UI index verification failed")
        end
    end
end

function M.is_trade_panel(panel)
    return direction_of(panel) ~= nil
end

function M.sort_panel(panel, config)
    local direction = direction_of(panel)
    if direction == nil then return false end
    local filter = unwrap(panel.GenericFilter)
    if not valid(filter) then return false end
    local tag = unwrap(fn(FILTER_PATH)(filter))
    if tag == nil then return false end
    local kind = sorter.inventory_kind_from_filter_tag(text(tag.TagName))
    if kind == nil then return false end -- Both All tabs stay untouched.

    local entries, view = ui_snapshot(panel)
    if #entries < 2 then return false end
    local model = model_snapshot(panel, #entries)
    validate_mapping(entries, model)
    inventory_port.prepare_entries(panel, entries, kind, {
        definition_at = function(pos) return model[pos + 1].definition end,
        equipped_at = function() return false end,
    })
    local sorted, ordered, _, reason = sorter.sort(entries, kind)
    if not sorted then error(reason) end

    local old_objects, old_keys, new_objects, new_keys = {}, {}, {}, {}
    for index, entry in ipairs(entries) do
        old_objects[index], old_keys[index] = entry.object, entry.object_key
    end
    for index, entry in ipairs(ordered) do
        new_objects[index], new_keys[index] = entry.object, entry.object_key
    end
    if same_order(old_keys, new_keys) then return false end
    fn(COUNT_PATH); fn(ITEM_PATH); fn(INDEX_PATH)
    local set_list = fn(SET_LIST_PATH)
    local ok, failure = pcall(function()
        set_list(view, new_objects, true)
        verify_view(view, new_objects, new_keys)
        verify_model(panel, model)
        for _, entry in ipairs(entries) do
            if number(entry.object.m_Pos) ~= entry.position then
                error("merchant slot source position changed")
            end
        end
    end)
    if not ok then
        local restored, restore_error = pcall(function()
            set_list(view, old_objects, true)
            verify_view(view, old_objects, old_keys)
            verify_model(panel, model)
        end)
        if restored then error("merchant UI reorder failed and was rolled back: " .. tostring(failure)) end
        error("merchant UI reorder and rollback failed: " .. tostring(failure)
            .. "; rollback error: " .. tostring(restore_error))
    end
    if config.log_successful_sorts then
        local preview = {}
        for index = 1, math.min(config.log_preview_count or 0, #ordered) do
            preview[#preview + 1] = ordered[index].name .. " [" .. ordered[index].group .. "]"
        end
        inventory_port.log(string.format("reordered %d %s %s merchant UI slots; model/positions untouched; first: %s",
            #ordered, direction, kind, table.concat(preview, ", ")))
    end
    return true
end

return M
