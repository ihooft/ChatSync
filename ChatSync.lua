local addonName = ...
local addon = CreateFrame("Frame")
local prefix = "|cff33ff99ChatSync:|r "

local function Print(message)
    print(prefix .. message)
end

local function Frame(index)
    return _G["ChatFrame" .. index]
end

local function MaxWindows()
    -- Retail moved this value from NUM_CHAT_WINDOWS in 11.2.7.
    if Constants and Constants.ChatFrameConstants and Constants.ChatFrameConstants.MaxChatWindows then
        return Constants.ChatFrameConstants.MaxChatWindows
    end
    return NUM_CHAT_WINDOWS or 10
end

local function BuiltinWindows()
    -- Only General and Combat Log are guaranteed to be active on every toon.
    return math.min(2, MaxWindows())
end

local function CopyValues(...)
    local values = {}
    for i = 1, select("#", ...) do
        values[i] = select(i, ...)
    end
    return values
end

local function ChannelNames(index)
    local raw = CopyValues(GetChatWindowChannels(index))
    local names = {}
    for i = 1, #raw, 2 do
        if type(raw[i]) == "string" then
            names[#names + 1] = raw[i]
        end
    end
    return names
end

local function IsActive(index)
    local frame = Frame(index)
    if not frame or frame.isTemporary then return false end
    if index <= BuiltinWindows() then return true end
    local _, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(index)
    -- A tab in the dock can be hidden while another tab is selected.
    return shown == true or shown == 1 or frame.isDocked == true
        or (type(docked) == "number" and docked > 0)
end

local function Capture(index)
    if not IsActive(index) then return nil end
    local frame = Frame(index)
    local name, fontSize = GetChatWindowInfo(index)
    local file, size, flags = frame:GetFont()
    return {
        name = name,
        fontSize = fontSize,
        font = { file = file, size = size, flags = flags },
        messages = CopyValues(GetChatWindowMessages(index)),
        channels = ChannelNames(index),
    }
end

local function DefaultProfile()
    return ChatSyncDB.profiles and ChatSyncDB.profiles.Default
end

local function Save()
    local profile = { version = 4, windows = {} }
    local count = 0
    for index = 1, MaxWindows() do
        local window = Capture(index)
        if window then
            profile.windows[index] = window
            count = count + 1
        end
    end
    ChatSyncDB.profiles.Default = profile
    Print("Saved " .. count .. " chat window(s) to the Default profile.")
end

local function SetOf(values)
    local set = {}
    for _, value in ipairs(values or {}) do set[value] = true end
    return set
end

local function ApplyMessages(index, desired)
    desired = desired or {}
    local current = CopyValues(GetChatWindowMessages(index))
    local wanted = SetOf(desired)
    local present = SetOf(current)
    local frame = Frame(index)
    for _, group in ipairs(current) do
        if not wanted[group] then
            if frame.RemoveMessageGroup then
                frame:RemoveMessageGroup(group)
            else
                RemoveChatWindowMessages(index, group)
            end
        end
    end
    for _, group in ipairs(desired) do
        if not present[group] then
            if frame.AddMessageGroup then
                frame:AddMessageGroup(group)
            else
                AddChatWindowMessages(index, group)
            end
        end
    end
end

local function DesiredChannels(window, profileVersion)
    local result = {}
    local values = window.channels or {}
    -- Version 1 stored alternating names and numeric IDs.
    if profileVersion == 1 then
        for i = 1, #values, 2 do
            if type(values[i]) == "string" then result[#result + 1] = values[i] end
        end
    else
        for _, value in ipairs(values) do
            if type(value) == "string" then result[#result + 1] = value end
        end
    end
    return result
end

local function ApplyChannels(index, desired)
    local frame = Frame(index)
    local current = ChannelNames(index)
    local wanted = SetOf(desired)
    local present = SetOf(current)
    for _, name in ipairs(current) do
        if not wanted[name] then
            if frame.RemoveChannel then
                frame:RemoveChannel(name)
            elseif ChatFrame_RemoveChannel then
                ChatFrame_RemoveChannel(frame, name)
            else
                RemoveChatWindowChannel(index, name)
            end
        end
    end
    for _, name in ipairs(desired) do
        if not present[name] then
            if frame.AddChannel then
                frame:AddChannel(name)
            elseif ChatFrame_AddChannel then
                ChatFrame_AddChannel(frame, name)
            else
                AddChatWindowChannel(index, name)
            end
        end
    end
end

local function ApplyWindow(index, window, version)
    local frame = Frame(index)
    if type(window.name) == "string" and window.name ~= "" then
        if FCF_SetWindowName then
            FCF_SetWindowName(frame, window.name)
        else
            SetChatWindowName(index, window.name)
        end
    end
    if window.font and window.font.file and window.font.size then
        frame:SetFont(window.font.file, window.font.size, window.font.flags or "")
        if SetChatWindowSize then SetChatWindowSize(index, window.font.size) end
    elseif window.fontSize and SetChatWindowSize then
        SetChatWindowSize(index, window.fontSize)
    end
    ApplyMessages(index, window.messages)
    ApplyChannels(index, DesiredChannels(window, version))
end

local function Apply()
    local profile = DefaultProfile()
    if type(profile) ~= "table" or type(profile.windows) ~= "table" then
        Print("No Default profile saved. Use /chatsync save on your source character.")
        return
    end

    local windows = profile.windows
    if profile.version == 2 or profile.version == 3 then
        Print("Resave the Default profile on the source character: previous builds could count an inactive window as saved.")
        return
    end
    local max = MaxWindows()
    local reserved = BuiltinWindows()
    local desired, current = {}, {}
    local applied, removed, created = 0, 0, 0
    for index = reserved + 1, max do
        if windows[index] then desired[#desired + 1] = windows[index] end
        if IsActive(index) then current[#current + 1] = index end
    end

    -- Blizzard picks the next available frame ID. Pair user windows by order,
    -- so a reserved or skipped ID does not prevent creation.
    while #current < #desired do
        if not FCF_OpenNewWindow then break end
        local window = desired[#current + 1]
        local frame, index = FCF_OpenNewWindow(window.name, true)
        if not frame then break end
        index = index or frame:GetID()
        if not index or index > max or not IsActive(index) then break end
        local known = false
        for _, existing in ipairs(current) do
            if existing == index then known = true; break end
        end
        if known then break end
        current[#current + 1] = index
        created = created + 1
    end

    for index = 1, reserved do
        if windows[index] and IsActive(index) then
            ApplyWindow(index, windows[index], profile.version)
            applied = applied + 1
        end
    end

    for position, window in ipairs(desired) do
        local index = current[position]
        if index then
            ApplyWindow(index, window, profile.version)
            applied = applied + 1
        end
    end

    for position = #current, #desired + 1, -1 do
        local index = current[position]
        local frame = Frame(index)
        if index > 3 and frame and FCF_Close then
            FCF_Close(frame)
            removed = removed + 1
        end
    end

    Print("Applied " .. applied .. " window(s); created " .. created .. "; removed " .. removed .. ".")
    if #current < #desired then
        Print("Could not create " .. (#desired - #current) .. " window(s). Check that the default chat UI has a free slot.")
    end
end

local function Status()
    local count = 0
    local profile = DefaultProfile()
    local slots = {}
    if profile and profile.windows then
        for index in pairs(profile.windows) do
            count = count + 1
            slots[#slots + 1] = index
        end
        table.sort(slots)
    end
    Print("v0.3.0; Default profile: " .. count .. " window(s); slots: " .. (#slots > 0 and table.concat(slots, ", ") or "none") .. "; apply on login: " .. (ChatSyncDB.autoApply and "on" or "off"))
    if profile and (profile.version == 2 or profile.version == 3) then
        Print("Resave on the source character: this profile may include unused slots.")
    end
end

local optionsPanel
local optionsCategory
local refreshOptions

local function CreateOptions()
    optionsPanel = CreateFrame("Frame", "ChatSyncOptionsPanel", UIParent)
    optionsPanel.name = "ChatSync"

    local title = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 20, -20)
    title:SetText("ChatSync")

    local description = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    description:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    description:SetWidth(560)
    description:SetJustifyH("LEFT")
    description:SetText("Save a chat layout to the account-wide Default profile, then apply it on other characters.")

    local profileTitle = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    profileTitle:SetPoint("TOPLEFT", description, "BOTTOMLEFT", 0, -24)
    profileTitle:SetText("Default profile")

    local profileStatus = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    profileStatus:SetPoint("TOPLEFT", profileTitle, "BOTTOMLEFT", 0, -8)
    profileStatus:SetWidth(540)
    profileStatus:SetJustifyH("LEFT")

    local saveButton = CreateFrame("Button", nil, optionsPanel, "UIPanelButtonTemplate")
    saveButton:SetSize(205, 26)
    saveButton:SetPoint("TOPLEFT", profileStatus, "BOTTOMLEFT", 0, -16)
    saveButton:SetText("Save Current as Default")
    saveButton:SetScript("OnClick", function()
        Save()
        refreshOptions()
    end)

    local applyButton = CreateFrame("Button", nil, optionsPanel, "UIPanelButtonTemplate")
    applyButton:SetSize(160, 26)
    applyButton:SetPoint("LEFT", saveButton, "RIGHT", 12, 0)
    applyButton:SetText("Apply Default")
    applyButton:SetScript("OnClick", function()
        Apply()
        refreshOptions()
    end)

    local checkbox = CreateFrame("CheckButton", nil, optionsPanel, "UICheckButtonTemplate")
    checkbox:SetPoint("TOPLEFT", saveButton, "BOTTOMLEFT", -4, -24)
    checkbox:SetSize(28, 28)
    local checkboxLabel = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    checkboxLabel:SetPoint("LEFT", checkbox, "RIGHT", 3, 0)
    checkboxLabel:SetText("Automatically apply Default when a character loads")
    checkbox:SetScript("OnClick", function(self)
        ChatSyncDB.autoApply = self:GetChecked() and true or false
        Print("Apply on login " .. (ChatSyncDB.autoApply and "enabled." or "disabled."))
    end)

    local note = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", checkbox, "BOTTOMLEFT", 4, -12)
    note:SetWidth(550)
    note:SetJustifyH("LEFT")
    note:SetText("Saving replaces the Default profile. Applying changes this character's chat windows. Auto apply is an account-wide setting.")

    refreshOptions = function()
        local profile = DefaultProfile()
        local count = 0
        if profile and profile.windows then
            for _ in pairs(profile.windows) do count = count + 1 end
        end
        profileStatus:SetText(count > 0 and (count .. " chat window(s) saved") or "No layout saved yet")
        applyButton:SetEnabled(count > 0)
        checkbox:SetChecked(ChatSyncDB.autoApply == true)
    end
    optionsPanel:SetScript("OnShow", refreshOptions)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        optionsCategory = Settings.RegisterCanvasLayoutCategory(optionsPanel, "ChatSync")
        Settings.RegisterAddOnCategory(optionsCategory)
    else
        InterfaceOptions_AddCategory(optionsPanel)
    end
end

local function OpenOptions()
    if optionsCategory and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(optionsCategory:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(optionsPanel)
    end
end

local function Inspect()
    for index = 1, MaxWindows() do
        local frame = Frame(index)
        if frame then
            local name, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(index)
            if IsActive(index) or (type(name) == "string" and name ~= "") then
                Print("slot " .. index .. ": " .. tostring(name) .. ", shown=" .. tostring(shown)
                    .. ", docked=" .. tostring(docked) .. ", frameDocked=" .. tostring(frame.isDocked)
                    .. ", active=" .. tostring(IsActive(index)))
            end
        end
    end
end

SLASH_CHATSYNC1 = "/chatsync"
SLASH_CHATSYNC2 = "/csync"
SlashCmdList.CHATSYNC = function(message)
    local command = strtrim(message or ""):lower()
    if command == "save" then Save()
    elseif command == "apply" then Apply()
    elseif command == "auto" then
        ChatSyncDB.autoApply = not ChatSyncDB.autoApply
        Print("Apply on login " .. (ChatSyncDB.autoApply and "enabled." or "disabled."))
    elseif command == "status" then Status()
    elseif command == "inspect" then Inspect()
    elseif command == "options" or command == "" then OpenOptions()
    else Print("Commands: /chatsync options, save, apply, auto, status, inspect") end
end

addon:RegisterEvent("ADDON_LOADED")
addon:RegisterEvent("PLAYER_LOGIN")
addon:SetScript("OnEvent", function(_, event, loadedName)
    if event == "ADDON_LOADED" and loadedName == addonName then
        if type(ChatSyncDB) ~= "table" then ChatSyncDB = {} end
        if type(ChatSyncDB.profiles) ~= "table" then ChatSyncDB.profiles = {} end
        if not ChatSyncDB.profiles.Default and type(ChatSyncDB.profile) == "table" then
            ChatSyncDB.profiles.Default = ChatSyncDB.profile
        end
        ChatSyncDB.profile = nil
        if ChatSyncDB.autoApply == nil then ChatSyncDB.autoApply = false end
        CreateOptions()
    elseif event == "PLAYER_LOGIN" and ChatSyncDB and ChatSyncDB.autoApply and DefaultProfile() then
        C_Timer.After(2, Apply)
    end
end)
