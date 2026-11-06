local _, ns = ...
local L = ns.L
local UI = ns.UI

-- The history as CSV, selected in a box, to copy into a spreadsheet: the game gives
-- no other way to hand text over.
local WIDTH, HEIGHT = 720, 460
-- Where ButtonFrameTemplate places its Inset once the button bar is hidden.
local INSET_LEFT, INSET_RIGHT = 4, 6
-- The scroll bar of ScrollFrameTemplate sits outside the frame, on its right.
local SCROLLBAR_ROOM = 24
-- Beside the portrait, like the main window's toolbar.
local HINT_LEFT, HINT_TOP = 66, -38
local ICON = "Interface\\Icons\\INV_Misc_Note_01"

local frame, editBox = nil, nil
local csv = ""

local function Create()
    frame = CreateFrame("Frame", "TradingBookExportFrame", UIParent, "ButtonFrameTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER", UIParent, "CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:SetTitle("Trading Book: " .. L["History as CSV"])
    frame:SetPortraitToAsset(ICON)
    ButtonFrameTemplate_HideButtonBar(frame)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    table.insert(UISpecialFrames, "TradingBookExportFrame")

    local hint = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", frame, "TOPLEFT", HINT_LEFT, HINT_TOP)
    hint:SetPoint("RIGHT", frame, "RIGHT", -UI.PADDING, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText(L["The text is selected: copy it, then paste it into a spreadsheet."])

    local scroll = CreateFrame("ScrollFrame", nil, frame.Inset, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", frame.Inset, "TOPLEFT", UI.PADDING, -UI.PADDING)
    scroll:SetPoint("BOTTOMRIGHT", frame.Inset, "BOTTOMRIGHT", -(UI.PADDING + SCROLLBAR_ROOM), UI.PADDING)

    editBox = CreateFrame("EditBox", nil, scroll)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(0)
    editBox:SetFontObject("GameFontHighlightSmall")
    editBox:SetWidth(WIDTH - INSET_LEFT - INSET_RIGHT - 2 * UI.PADDING - SCROLLBAR_ROOM)
    editBox:SetScript("OnEscapePressed", function()
        frame:Hide()
    end)
    -- Read only: typing puts the text back, selected again.
    editBox:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            self:SetText(csv)
            self:HighlightText()
        end
    end)
    scroll:SetScrollChild(editBox)
end

function UI.ShowExport()
    if not frame then
        Create()
    end
    csv = ns.Ledger.ToCSV()
    editBox:SetText(csv)
    frame:Show()
    editBox:SetFocus()
    editBox:HighlightText()
end
