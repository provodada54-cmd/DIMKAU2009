--[[
    GlobalChat Addon for LinoriaLib
    Firebase-based global chat window integrated into the UI library.
    Usage:
        local GlobalChat = loadstring(readfile('addons/GlobalChat.lua'))()
        GlobalChat:SetLibrary(Library)
        -- In your settings tab:
        GlobalChat:ApplyToTab(tab)
]]

local Players       = game:GetService('Players')
local HttpService   = game:GetService('HttpService')
local RunService    = game:GetService('RunService')
local TextService   = game:GetService('TextService')
local TweenService  = game:GetService('TweenService')

local GlobalChat = {}
GlobalChat.__index = GlobalChat

-- ─── Configuration ────────────────────────────────────────────────────────────
GlobalChat.FirebaseUrl       = 'https://apirobloxuser-default-rtdb.firebaseio.com'
GlobalChat.MessagesPath      = '/globalchat/messages'
GlobalChat.MaxMessages       = 50
GlobalChat.UpdateInterval    = 3     -- seconds between fetches
GlobalChat.BubbleDisplayTime = 10   -- seconds a 3D bubble stays visible
-- ──────────────────────────────────────────────────────────────────────────────

-- State
GlobalChat.Library     = nil
GlobalChat.ScreenGui   = nil
GlobalChat.ChatWindow = nil
GlobalChat.Enabled    = false

local request         = (syn and syn.request) or (http and http.request) or http_request or (Fluxus and Fluxus.request) or request
local thumbnailCache  = {}
local messageHistory  = {}
local displayedBubbles = {}
local lastFetchTime   = 0
local pollingStarted  = false

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function GetThumbnail(userId)
    if thumbnailCache[userId] then return thumbnailCache[userId] end
    local ok, result = pcall(function()
        return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
    end)
    local url = ok and result or 'rbxassetid://5107154082'
    thumbnailCache[userId] = url
    return url
end

-- ─── 3D Chat Bubble ───────────────────────────────────────────────────────────

local function Create3DBubble(player, message, timestamp)
    if not player.Character or not player.Character:FindFirstChild('Head') then return end
    local key         = player.UserId .. '_' .. timestamp
    if displayedBubbles[key] then return end
    local now         = os.time()
    local age         = now - timestamp
    if age >= GlobalChat.BubbleDisplayTime then return end
    displayedBubbles[key] = true

    local head = player.Character.Head
    local old  = head:FindFirstChild('GlobalChatBubble')
    if old then old:Destroy() end

    local Board = Instance.new('BillboardGui')
    Board.Name        = 'GlobalChatBubble'
    Board.Size        = UDim2.new(0, 220, 0, 60)
    Board.StudsOffset = Vector3.new(0, 2.5, 0)
    Board.AlwaysOnTop = true
    Board.Parent      = head

    local Bg = Instance.new('Frame')
    Bg.Size                    = UDim2.fromScale(1, 1)
    Bg.BackgroundColor3        = Color3.fromRGB(20, 20, 20)
    Bg.BackgroundTransparency  = 0.15
    Bg.BorderSizePixel         = 0
    Bg.Parent                  = Board
    Instance.new('UICorner', Bg).CornerRadius = UDim.new(0, 8)

    local Txt = Instance.new('TextLabel')
    Txt.Size             = UDim2.new(1, -10, 1, -10)
    Txt.Position         = UDim2.fromOffset(5, 5)
    Txt.BackgroundTransparency = 1
    Txt.Text             = message
    Txt.TextColor3       = Color3.new(1, 1, 1)
    Txt.TextSize         = 14
    Txt.Font             = Enum.Font.GothamBold
    Txt.TextWrapped      = true
    Txt.Parent           = Bg

    local remain = GlobalChat.BubbleDisplayTime - age
    task.delay(remain, function()
        if Board and Board.Parent then Board:Destroy() end
        displayedBubbles[key] = nil
    end)
end

-- ─── Message Row ─────────────────────────────────────────────────────────────

function GlobalChat:AddMessage(data)
    local key = tostring(data.timestamp) .. tostring(data.userId)
    if messageHistory[key] then return end
    messageHistory[key] = true

    local L  = self.Library
    local SF = self.ScrollFrame
    if not (L and SF) then return end

    local Row = L:Create('Frame', {
        BackgroundColor3 = L.MainColor,
        BorderColor3     = L.OutlineColor,
        BorderMode       = Enum.BorderMode.Inset,
        Size             = UDim2.new(1, 0, 0, 54),
        LayoutOrder      = data.timestamp,
        ZIndex           = 3,
        Parent           = SF,
    })
    L:AddToRegistry(Row, { BackgroundColor3 = 'MainColor', BorderColor3 = 'OutlineColor' })

    -- Avatar
    local Av = L:Create('ImageLabel', {
        BackgroundTransparency = 1,
        Position  = UDim2.fromOffset(4, 4),
        Size      = UDim2.fromOffset(46, 46),
        Image     = GetThumbnail(data.userId),
        ZIndex    = 4,
        Parent    = Row,
    })
    L:Create('UICorner', { CornerRadius = UDim.new(1, 0), Parent = Av })

    -- Name
    local Name = L:CreateLabel({
        Position         = UDim2.new(0, 54, 0, 5),
        Size             = UDim2.new(1, -58, 0, 18),
        Text             = data.displayName .. '  (@' .. data.username .. ')',
        TextSize         = 12,
        TextColor3       = L.AccentColor,
        TextXAlignment   = Enum.TextXAlignment.Left,
        ZIndex           = 4,
        Parent           = Row,
    })
    L:AddToRegistry(Name, { TextColor3 = 'AccentColor' })

    -- Message text
    L:CreateLabel({
        Position         = UDim2.new(0, 54, 0, 26),
        Size             = UDim2.new(1, -58, 0, 22),
        Text             = data.message,
        TextSize         = 13,
        TextXAlignment   = Enum.TextXAlignment.Left,
        TextWrapped      = true,
        ClipsDescendants = true,
        ZIndex           = 4,
        Parent           = Row,
    })

    -- Trim old rows
    local rows = {}
    for _, c in ipairs(SF:GetChildren()) do
        if c:IsA('Frame') then rows[#rows+1] = c end
    end
    if #rows > GlobalChat.MaxMessages then
        table.sort(rows, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
        rows[1]:Destroy()
    end
end

-- ─── Firebase ────────────────────────────────────────────────────────────────

function GlobalChat:SendMessage(message)
    if not request then return end
    local LP = Players.LocalPlayer
    local data = {
        userId      = LP.UserId,
        username    = LP.Name,
        displayName = LP.DisplayName,
        message     = message,
        timestamp   = os.time(),
        gameId      = game.PlaceId,
    }
    task.spawn(function()
        local ok = pcall(function()
            request({
                Url     = GlobalChat.FirebaseUrl .. GlobalChat.MessagesPath .. '.json',
                Method  = 'POST',
                Headers = { ['Content-Type'] = 'application/json' },
                Body    = HttpService:JSONEncode(data),
            })
        end)
        if ok then Create3DBubble(LP, message, data.timestamp) end
    end)
end

function GlobalChat:FetchAndUpdate()
    if not request then return end
    local ok, result = pcall(function()
        local resp = request({
            Url    = GlobalChat.FirebaseUrl .. GlobalChat.MessagesPath ..
                     '.json?orderBy="$key"&limitToLast=' .. GlobalChat.MaxMessages ..
                     '&nocache=' .. math.random(1, 999999),
            Method = 'GET',
        })
        if resp.Success and resp.Body and resp.Body ~= 'null' then
            return HttpService:JSONDecode(resp.Body)
        end
    end)
    if not (ok and result) then return end

    local sorted = {}
    for _, msg in pairs(result) do sorted[#sorted+1] = msg end
    table.sort(sorted, function(a, b) return a.timestamp < b.timestamp end)

    local now = os.time()
    for _, msg in ipairs(sorted) do
        self:AddMessage(msg)
        if now - msg.timestamp < GlobalChat.BubbleDisplayTime then
            local pl = Players:GetPlayerByUserId(msg.userId)
            if pl and pl.Character then
                Create3DBubble(pl, msg.message, msg.timestamp)
            end
        end
    end
end

-- ─── Chat Window ─────────────────────────────────────────────────────────────

function GlobalChat:CreateWindow()
    local L  = self.Library
    if not L then return end

    -- Create dedicated ScreenGui for Chat
    if not self.ScreenGui then
        local SG = Instance.new('ScreenGui')
        SG.Name = 'GlobalChatGui'
        SG.ZIndexBehavior = Enum.ZIndexBehavior.Global
        SG.DisplayOrder = 10 -- Higher than main GUI (0) and Overlay (-1)
        SG.ResetOnSpawn = false
        
        -- Protect it if possible
        if syn and syn.protect_gui then syn.protect_gui(SG) end
        SG.Parent = game:GetService('CoreGui')
        
        self.ScreenGui = SG
    end

    local SG = self.ScreenGui

    -- Outer
    local Outer = L:Create('Frame', {
        BackgroundColor3 = Color3.new(0, 0, 0),
        BorderSizePixel  = 0,
        Position         = UDim2.new(1, -370, 1, -300),
        Size             = UDim2.fromOffset(360, 290),
        ZIndex           = 1,
        Parent           = SG,
    })

    if L.IsMobile then
        Outer.Size = UDim2.fromOffset(350, 250)
        Outer.Position = UDim2.fromOffset(10, 10)
    end

    if L.RegisterAutoScaleTarget then
        L:RegisterAutoScaleTarget(SG)
    end

    L:MakeDraggable(Outer, 25)

    -- Inner chrome
    local Inner = L:Create('Frame', {
        BackgroundColor3 = L.MainColor,
        BorderColor3     = L.AccentColor,
        BorderMode       = Enum.BorderMode.Inset,
        Position         = UDim2.new(0, 1, 0, 1),
        Size             = UDim2.new(1, -2, 1, -2),
        ZIndex           = 1,
        Parent           = Outer,
    })
    L:AddToRegistry(Inner, { BackgroundColor3 = 'MainColor', BorderColor3 = 'AccentColor' })

    -- Title
    L:CreateLabel({
        Position       = UDim2.new(0, 7, 0, 0),
        Size           = UDim2.new(1, -14, 0, 25),
        Text           = 'Global Chat',
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex         = 2,
        Parent         = Inner,
    })

    -- Messages area
    local MsgOuter = L:Create('Frame', {
        BackgroundColor3 = L.BackgroundColor,
        BorderColor3     = L.OutlineColor,
        Position         = UDim2.new(0, 8, 0, 25),
        Size             = UDim2.new(1, -16, 1, -70),
        ZIndex           = 1,
        Parent           = Inner,
    })
    L:AddToRegistry(MsgOuter, { BackgroundColor3 = 'BackgroundColor', BorderColor3 = 'OutlineColor' })

    local MsgInner = L:Create('Frame', {
        BackgroundColor3 = L.BackgroundColor,
        BorderColor3     = Color3.new(0, 0, 0),
        BorderMode       = Enum.BorderMode.Inset,
        Size             = UDim2.new(1, 0, 1, 0),
        ZIndex           = 1,
        Parent           = MsgOuter,
    })
    L:AddToRegistry(MsgInner, { BackgroundColor3 = 'BackgroundColor' })

    local SF = L:Create('ScrollingFrame', {
        BackgroundTransparency = 1,
        BorderSizePixel        = 0,
        Size                   = UDim2.new(1, -4, 1, -4),
        Position               = UDim2.fromOffset(2, 2),
        ScrollBarThickness     = 4,
        ScrollBarImageColor3   = L.AccentColor,
        CanvasSize             = UDim2.new(0, 0, 0, 0),
        ZIndex                 = 2,
        Parent                 = MsgInner,
    })
    L:AddToRegistry(SF, { ScrollBarImageColor3 = 'AccentColor' })

    local Layout = L:Create('UIListLayout', {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding   = UDim.new(0, 3),
        Parent    = SF,
    })
    L:Create('UIPadding', {
        PaddingTop   = UDim.new(0, 3),
        PaddingLeft  = UDim.new(0, 3),
        PaddingRight = UDim.new(0, 3),
        Parent       = SF,
    })
    Layout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
        SF.CanvasSize     = UDim2.new(0, 0, 0, Layout.AbsoluteContentSize.Y + 10)
        SF.CanvasPosition = Vector2.new(0, SF.CanvasSize.Y.Offset)
    end)

    -- Input row
    local InputOuter = L:Create('Frame', {
        BackgroundColor3 = Color3.new(0, 0, 0),
        BorderSizePixel  = 0,
        Position         = UDim2.new(0, 8, 1, -44),
        Size             = UDim2.new(1, -16, 0, 32),
        ZIndex           = 2,
        Parent           = Inner,
    })

    local InputInner = L:Create('Frame', {
        BackgroundColor3 = L.MainColor,
        BorderColor3     = L.OutlineColor,
        BorderMode       = Enum.BorderMode.Inset,
        Size             = UDim2.new(1, 0, 1, 0),
        ZIndex           = 3,
        Parent           = InputOuter,
    })
    L:AddToRegistry(InputInner, { BackgroundColor3 = 'MainColor', BorderColor3 = 'OutlineColor' })

    local TB = L:Create('TextBox', {
        BackgroundTransparency = 1,
        Position               = UDim2.new(0, 4, 0, 0),
        Size                   = UDim2.new(1, -72, 1, 0),
        Font                   = L.Font,
        PlaceholderText        = 'Type a message...',
        PlaceholderColor3      = Color3.fromRGB(120, 120, 120),
        Text                   = '',
        TextColor3             = L.FontColor,
        TextSize               = 14,
        TextXAlignment         = Enum.TextXAlignment.Left,
        ClearTextOnFocus       = false,
        ZIndex                 = 4,
        Parent                 = InputInner,
    })
    L:AddToRegistry(TB, { TextColor3 = 'FontColor' })

    local SendOuter = L:Create('Frame', {
        BackgroundColor3 = Color3.new(0, 0, 0),
        BorderSizePixel  = 0,
        Position         = UDim2.new(1, -68, 0, 1),
        Size             = UDim2.new(0, 64, 1, -2),
        ZIndex           = 3,
        Parent           = InputInner,
    })

    local SendBtn = L:Create('TextButton', {
        BackgroundColor3 = L.AccentColor,
        BorderColor3     = L.AccentColorDark,
        BorderMode       = Enum.BorderMode.Inset,
        Size             = UDim2.new(1, 0, 1, 0),
        Font             = L.Font,
        Text             = 'Send',
        TextColor3       = Color3.new(1, 1, 1),
        TextSize         = 14,
        ZIndex           = 4,
        Parent           = SendOuter,
    })
    L:AddToRegistry(SendBtn, { BackgroundColor3 = 'AccentColor', BorderColor3 = 'AccentColorDark' })

    -- Save refs
    self.ChatWindow  = Outer
    self.ScrollFrame = SF
    self.TextBox     = TB
    self.SendButton  = SendBtn

    -- Send logic
    local function doSend()
        local msg = TB.Text:gsub('^%s*(.-)%s*$', '%1')
        if msg == '' or #msg > 200 then return end
        TB.Text = ''
        self:SendMessage(msg)
    end
    SendBtn.MouseButton1Down:Connect(doSend)
    SendBtn.TouchTap:Connect(doSend)
    TB.FocusLost:Connect(function(enter) if enter then doSend() end end)
end

-- ─── Polling ─────────────────────────────────────────────────────────────────

function GlobalChat:StartPolling()
    if pollingStarted then return end
    pollingStarted = true

    -- Message fetch loop
    task.spawn(function()
        while true do
            local now = tick()
            if now - lastFetchTime >= GlobalChat.UpdateInterval then
                self:FetchAndUpdate()
                lastFetchTime = now
            end
            task.wait(1)
        end
    end)

    -- Sync visibility with main GUI
    local L = self.Library
    task.spawn(function()
        while true do
            RunService.Heartbeat:Wait()
            if self.Enabled and self.ChatWindow then
                local shouldShow = L and L.MenuOpen or false
                if self.ChatWindow.Visible ~= shouldShow then
                    self.ChatWindow.Visible = shouldShow
                end
            end
        end
    end)

    -- Bubble cleanup
    task.spawn(function()
        while true do
            task.wait(30)
            local now = os.time()
            for k in pairs(displayedBubbles) do
                local ts = tonumber(k:match('_(%d+)$'))
                if ts and (now - ts) > 15 then displayedBubbles[k] = nil end
            end
        end
    end)

    -- New player → show their recent bubble
    Players.PlayerAdded:Connect(function(pl)
        pl.CharacterAdded:Connect(function()
            task.wait(1)
            local msgs = {}
            local ok, result = pcall(function()
                if not request then return end
                local resp = request({
                    Url    = GlobalChat.FirebaseUrl .. GlobalChat.MessagesPath ..
                             '.json?orderBy="$key"&limitToLast=5',
                    Method = 'GET',
                })
                if resp.Success and resp.Body and resp.Body ~= 'null' then
                    return HttpService:JSONDecode(resp.Body)
                end
            end)
            if ok and result then
                for _, m in pairs(result) do msgs[#msgs+1] = m end
                table.sort(msgs, function(a, b) return a.timestamp < b.timestamp end)
                local now = os.time()
                for i = #msgs, 1, -1 do
                    local m = msgs[i]
                    if m.userId == pl.UserId and (now - m.timestamp) < GlobalChat.BubbleDisplayTime then
                        Create3DBubble(pl, m.message, m.timestamp)
                        break
                    end
                end
            end
        end)
    end)
end

-- ─── Public API ──────────────────────────────────────────────────────────────

function GlobalChat:SetLibrary(lib)
    self.Library = lib
end

--- Add a toggle to an existing groupbox
function GlobalChat:CreateGroupBox(groupbox)
    groupbox:AddToggle('GlobalChat_Enabled', { Text = 'Enable Global Chat', Default = false })
        :OnChanged(function(Value)
            self.Enabled = Value
            if Value then
                if not self.ChatWindow then
                    self:CreateWindow()
                    self:FetchAndUpdate()
                    lastFetchTime = tick()
                end
                self:StartPolling()
                -- Show immediately if menu is currently open
                if self.Library and self.Library.MenuOpen then
                    self.ChatWindow.Visible = true
                end
            else
                if self.ChatWindow then
                    self.ChatWindow.Visible = false
                end
            end
        end)
end

--- Automatically creates a groupbox in the given tab
function GlobalChat:ApplyToTab(tab)
    assert(self.Library, 'GlobalChat: Must call SetLibrary(lib) first!')
    local groupbox = tab:AddLeftGroupbox('Global Chat')
    self:CreateGroupBox(groupbox)
end

return GlobalChat