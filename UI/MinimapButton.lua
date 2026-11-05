local _, ns = ...
local L = ns.L
local UI = ns.UI

-- A button on the edge of the minimap. Its look and geometry follow LibDBIcon, so
-- that it sits naturally among other addons' buttons, without embedding the library.
local ICON = "Interface\\Icons\\INV_Misc_Coin_01"
local TEXTURE_BORDER = 136430 -- Interface\Minimap\MiniMap-TrackingBorder
local TEXTURE_BACKGROUND = 136467 -- Interface\Minimap\UI-Minimap-Background
local TEXTURE_HIGHLIGHT = 136477 -- Interface\Minimap\UI-Minimap-ZoomButton-Highlight
local DEFAULT_ANGLE = 225
local EDGE_OFFSET = 5

local button = nil
local dragging = false

local function GetSettings()
    local ui = ns.db.ui
    ui.minimap = ui.minimap or { angle = DEFAULT_ANGLE, hidden = false }
    return ui.minimap
end

local function PlaceAt(angle)
    local radians = math.rad(angle)
    local radiusX = Minimap:GetWidth() / 2 + EDGE_OFFSET
    local radiusY = Minimap:GetHeight() / 2 + EDGE_OFFSET
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(radians) * radiusX, math.sin(radians) * radiusY)
end

-- The cursor comes in screen pixels and the minimap's center in its own scale.
local function FollowCursor()
    local centerX, centerY = Minimap:GetCenter()
    local cursorX, cursorY = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    local angle = math.deg(math.atan2(cursorY / scale - centerY, cursorX / scale - centerX)) % 360
    GetSettings().angle = angle
    PlaceAt(angle)
end

local function ShowTooltip(self)
    if dragging then
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Trading Book")
    GameTooltip:AddLine(L["Left-click: open or close"], 1, 1, 1)
    GameTooltip:AddLine(L["Drag: move"], 1, 1, 1)
    GameTooltip:AddLine(L["/tradingbook minimap: hide this icon"], 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

local function CreateButton()
    button = CreateFrame("Button", "TradingBookMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFixedFrameStrata(true)
    button:SetFrameLevel(8)
    button:SetFixedFrameLevel(true)
    button:RegisterForClicks("LeftButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture(TEXTURE_HIGHLIGHT)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(50, 50)
    border:SetTexture(TEXTURE_BORDER)
    border:SetPoint("TOPLEFT", button, "TOPLEFT")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(24, 24)
    background:SetTexture(TEXTURE_BACKGROUND)
    background:SetPoint("CENTER", button, "CENTER")

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetTexture(ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- Trims the border drawn into item icons.
    icon:SetPoint("CENTER", button, "CENTER")

    button:SetScript("OnClick", function()
        UI.Toggle()
    end)
    button:SetScript("OnEnter", ShowTooltip)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    button:SetScript("OnDragStart", function(self)
        dragging = true
        GameTooltip:Hide()
        self:LockHighlight()
        self:SetScript("OnUpdate", FollowCursor)
    end)
    button:SetScript("OnDragStop", function(self)
        dragging = false
        self:UnlockHighlight()
        self:SetScript("OnUpdate", nil)
    end)
end

function UI.ToggleMinimapButton()
    local settings = GetSettings()
    settings.hidden = not settings.hidden
    button:SetShown(not settings.hidden)
    if settings.hidden then
        ns.Print(L["Minimap icon hidden. Type /tradingbook minimap to bring it back."])
    end
end

ns.OnEvent("PLAYER_LOGIN", function()
    local settings = GetSettings()
    CreateButton()
    PlaceAt(settings.angle)
    button:SetShown(not settings.hidden)
end)
