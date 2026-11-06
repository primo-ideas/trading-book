local addonName, ns = ...
local L = ns.L
local UI = ns.UI

-- Trading Book's page in the game's options, under AddOns. Its settings read and write
-- the same saved values as the slash commands, so that both always agree.

-- The window's scale, in percent like the game's UI scale. The largest still fits the
-- window on a screen.
local SCALE_MIN, SCALE_MAX, SCALE_STEP = 50, 120, 5

local category = nil
local settings = {}

local function ScalePercent(scale)
    local percent = math.floor(scale * 100 / SCALE_STEP + 0.5) * SCALE_STEP
    return math.max(SCALE_MIN, math.min(SCALE_MAX, percent))
end

local function FormatPercent(value)
    return ("%d%%"):format(math.floor(value + 0.5))
end

-- defaultValue: a value, or a function that returns it.
local function AddSetting(key, name, valueType, defaultValue, getValue, setValue)
    local setting = Settings.RegisterProxySetting(category, addonName .. "_" .. key, valueType, name,
        defaultValue, getValue, setValue)
    table.insert(settings, setting)
    return setting
end

local function GameScalePercent()
    return ScalePercent(UI.GetGameScale())
end

local function RegisterSettings()
    category = Settings.RegisterVerticalLayoutCategory("Trading Book")

    local minimap = AddSetting("MinimapIcon", L["Minimap icon"], Settings.VarType.Boolean, true,
        UI.IsMinimapButtonShown, UI.SetMinimapButtonShown)
    Settings.CreateCheckbox(category, minimap, L["Shows Trading Book's icon on the edge of the minimap."])

    local tooltip = AddSetting("ItemTooltip", L["Item tooltips"], Settings.VarType.Boolean, true,
        UI.IsItemTooltipShown, UI.SetItemTooltipShown)
    Settings.CreateCheckbox(category, tooltip,
        L["Adds what the account holds of an item and what it sold for to the item's tooltip."])

    local scan = AddSetting("AutoScan", L["Scan the auction house"], Settings.VarType.Boolean, true,
        ns.Market.IsAutoScanEnabled, ns.Market.SetAutoScanEnabled)
    Settings.CreateCheckbox(category, scan,
        L["Scans it when it opens, at most every 15 minutes as the game allows, unless Auctionator already has prices. /tradingbook scan starts a scan by hand."])

    local mailSummary = AddSetting("MailSummary", L["Mail summary"], Settings.VarType.Boolean, true,
        ns.Mail.IsSummaryEnabled, ns.Mail.SetSummaryEnabled)
    Settings.CreateCheckbox(category, mailSummary,
        L["When you leave the mailbox, sums up in the chat the sales, purchases and expiries collected."])

    -- A scale of its own starts from the game's, so that turning it on changes nothing yet.
    local ownScale = AddSetting("OwnScale", L["Custom window scale"], Settings.VarType.Boolean, false,
        function()
            return UI.GetWindowScale() ~= nil
        end,
        function(value)
            UI.SetWindowScale(value and GameScalePercent() / 100 or nil)
        end)
    local ownScaleControl = Settings.CreateCheckbox(category, ownScale,
        L["Replaces the game's UI scale for the window: it keeps its size when the game's scale changes."])

    -- While the window follows the game, the slider shows the game's scale and changes
    -- nothing: restoring the defaults, which sets it too, must not give the window a
    -- scale of its own again.
    local scale = AddSetting("Scale", L["Window scale"], Settings.VarType.Number, GameScalePercent,
        function()
            return ScalePercent(UI.GetWindowScale() or UI.GetGameScale())
        end,
        function(value)
            if UI.GetWindowScale() then
                UI.SetWindowScale(value / 100)
            end
        end)
    local options = Settings.CreateSliderOptions(SCALE_MIN, SCALE_MAX, SCALE_STEP)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, FormatPercent)
    local scaleControl = Settings.CreateSlider(category, scale, options,
        L["The window's size, in percent like the game's UI scale."])
    scaleControl:SetParentInitializer(ownScaleControl, function()
        return ownScale:GetValue()
    end)

    Settings.RegisterAddOnCategory(category)
end

-- Shows a change made elsewhere, such as by a slash command, if the page is open.
function UI.RefreshSettings()
    for _, setting in ipairs(settings) do
        setting:NotifyUpdate()
    end
end

function UI.OpenSettings()
    Settings.OpenToCategory(category:GetID())
end

ns.OnEvent("ADDON_LOADED", function(name)
    if name == addonName then
        RegisterSettings()
    end
end)
