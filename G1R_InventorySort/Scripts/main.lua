local config = require("config")
local inventory_port = require("inventory_port")
local trade_ui_port = require("trade_ui_port")

local INVENTORY_MAIN_CLASS = "/Script/G1R.InventoryMain"
local INVENTORY_WIDGET_CLASS = "/Game/UI/ManagementUI/Inventory/W_Inventory_Main.W_Inventory_Main_C"
local REFRESH_FUNCTION = INVENTORY_WIDGET_CLASS .. ":RefreshInventoryBP"
local VERSION = "2.5.0"

local hook_registered = false
local sorting_in_progress = false

local function class_path(object)
    local full_name = inventory_port.full_class_name(object)
    return full_name:gsub("^%S+%s+", "")
end

local function on_inventory_refreshed(context, fallback_panel)
    if sorting_in_progress then
        return
    end

    local panel = inventory_port.unwrap(context)
    if not inventory_port.is_valid(panel) then
        panel = fallback_panel
    end
    if not inventory_port.is_valid(panel) then
        return
    end

    local operation = "sort"
    sorting_in_progress = true
    local ok, error_message = xpcall(function()
        if trade_ui_port.is_trade_panel(panel) then
            operation = "trade UI sort"
            trade_ui_port.sort_panel(panel, config)
        else
            inventory_port.sort_panel(panel, config)
        end
    end, debug.traceback)
    sorting_in_progress = false

    if not ok then
        inventory_port.log(operation .. " failed: " .. tostring(error_message))
    end
end

NotifyOnNewObject(INVENTORY_MAIN_CLASS, function(panel)
    if hook_registered or not inventory_port.is_valid(panel) then
        return hook_registered
    end
    if class_path(panel) ~= INVENTORY_WIDGET_CLASS then
        return false
    end

    local ok, error_message = pcall(function()
        RegisterHook(REFRESH_FUNCTION, function(context)
            on_inventory_refreshed(context, panel)
        end)
    end)

    if not ok then
        inventory_port.log("could not register the inventory refresh hook: " .. tostring(error_message))
        return false
    end

    hook_registered = true
    inventory_port.log("v" .. VERSION .. " loaded; guarded inventory UI sorting is active")
    return true
end)
