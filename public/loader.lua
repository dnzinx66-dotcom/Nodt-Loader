-- NODT Loader — Key System com cache local
-- Cliente cola esse script no Delta.

local API_AUTH   = "https://nodt-jz6jdzp7.manus.space"   -- Manus (valida key)
local API_SCRIPT = "https://nodt-loader.vercel.app"       -- Vercel (serve script ofuscado)
local KEY_FILE   = "NODT/saved_key.txt"

local function getHwid()
    local ok, id = pcall(function()
        return game:GetService("RbxAnalyticsService"):GetClientId()
    end)
    if ok and typeof(id) == "string" and #id > 10 then return "rbx_" .. id end
    if type(gethwid) == "function" then
        local ok2, hwid = pcall(gethwid)
        if ok2 and hwid then return "ext_" .. hwid end
    end
    return "uid_" .. tostring(game:GetService("Players").LocalPlayer.UserId)
end

local function readKey()
    if type(readfile) ~= "function" or type(isfile) ~= "function" then return nil end
    if not isfile(KEY_FILE) then return nil end
    local ok, data = pcall(readfile, KEY_FILE)
    if ok and type(data) == "string" and data ~= "" then return data end
    return nil
end

local function saveKey(key)
    if type(writefile) ~= "function" then return end
    if type(isfolder) == "function" and type(makefolder) == "function" then
        if not isfolder("NODT") then makefolder("NODT") end
    end
    pcall(writefile, KEY_FILE, key)
end

local function httpRequest(opts)
    local req = nil
    if type(syn) == "table" and type(syn.request) == "function" then req = syn.request
    elseif type(http) == "table" and type(http.request) == "function" then req = http.request
    elseif type(request) == "function" then req = request
    elseif type(http_request) == "function" then req = http_request
    end
    if not req then return nil, "sem HTTP" end
    local ok, res = pcall(req, opts)
    if not ok then return nil, tostring(res) end
    return res
end

local function jsonEncode(tbl)
    local ok, http = pcall(function() return game:GetService("HttpService") end)
    if not ok then return nil end
    local ok2, s = pcall(function() return http:JSONEncode(tbl) end)
    return ok2 and s or nil
end

local function jsonDecode(s)
    local ok, http = pcall(function() return game:GetService("HttpService") end)
    if not ok then return nil end
    local ok2, t = pcall(function() return http:JSONDecode(s) end)
    return ok2 and t or nil
end

local function validateKey(key, hwid)
    local body = jsonEncode({ key = key, hwid = hwid })
    if not body then return false, "JSON falhou" end
    local res, err = httpRequest({
        Url = API_AUTH .. "/api/nodt/verify",
        Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = body,
    })
    if not res or not res.Body then return false, err or "sem resposta" end
    local data = jsonDecode(res.Body)
    if not data then return false, "JSON inválido" end
    if data.valid ~= true then return false, (data.error or "key inválida") end
    return true
end

local function downloadScript()
    local res, err = httpRequest({
        Url = API_SCRIPT .. "/api/script",
        Method = "GET",
    })
    if not res or not res.Body then return nil, err or "sem resposta" end
    if res.StatusCode ~= 200 then return nil, "HTTP " .. tostring(res.StatusCode) end
    if #res.Body < 100 then return nil, "resposta curta" end
    return res.Body
end

local function promptKey()
    local gui = Instance.new("ScreenGui")
    gui.Name = "NODT_Loader"
    gui.ResetOnSpawn = false
    if type(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then gui.Parent = hui else gui.Parent = game:GetService("CoreGui") end
    else
        gui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
    end

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromOffset(320, 190)
    frame.Position = UDim2.new(0.5, -160, 0.5, -95)
    frame.BackgroundColor3 = Color3.fromRGB(14, 14, 16)
    frame.BorderSizePixel = 0
    frame.Parent = gui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 12)
    local stroke = Instance.new("UIStroke", frame)
    stroke.Color = Color3.fromRGB(205, 208, 215)
    stroke.Thickness = 1.5

    local title = Instance.new("TextLabel", frame)
    title.Size = UDim2.new(1, -32, 0, 28)
    title.Position = UDim2.fromOffset(16, 12)
    title.BackgroundTransparency = 1
    title.Text = "NODT HUB — KEY"
    title.TextColor3 = Color3.new(1, 1, 1)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 16
    title.TextXAlignment = Enum.TextXAlignment.Left

    local box = Instance.new("TextBox", frame)
    box.Size = UDim2.new(1, -32, 0, 38)
    box.Position = UDim2.fromOffset(16, 48)
    box.BackgroundColor3 = Color3.fromRGB(6, 6, 7)
    box.BorderSizePixel = 0
    box.Text = ""
    box.PlaceholderText = "Cole sua key aqui"
    box.PlaceholderColor3 = Color3.fromRGB(98, 100, 106)
    box.TextColor3 = Color3.new(1, 1, 1)
    box.Font = Enum.Font.GothamMedium
    box.TextSize = 13
    box.TextXAlignment = Enum.TextXAlignment.Left
    box.ClearTextOnFocus = false
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 8)
    Instance.new("UIPadding", box).PaddingLeft = UDim.new(0, 12)

    local err = Instance.new("TextLabel", frame)
    err.Size = UDim2.new(1, -32, 0, 16)
    err.Position = UDim2.fromOffset(16, 92)
    err.BackgroundTransparency = 1
    err.Text = ""
    err.TextColor3 = Color3.fromRGB(240, 98, 98)
    err.Font = Enum.Font.Gotham
    err.TextSize = 11
    err.TextXAlignment = Enum.TextXAlignment.Left

    local btn = Instance.new("TextButton", frame)
    btn.Size = UDim2.new(1, -32, 0, 38)
    btn.Position = UDim2.fromOffset(16, 120)
    btn.BackgroundColor3 = Color3.fromRGB(205, 208, 215)
    btn.BorderSizePixel = 0
    btn.Text = "ATIVAR"
    btn.TextColor3 = Color3.fromRGB(16, 16, 18)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 13
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)

    local submitted = Instance.new("BindableEvent")
    btn.MouseButton1Click:Connect(function()
        if btn.Text ~= "ATIVAR" then return end
        btn.Text = "VALIDANDO..."
        err.Text = ""
        submitted:Fire(box.Text)
    end)
    box.FocusLost:Connect(function(enter)
        if enter and btn.Text == "ATIVAR" then
            btn.Text = "VALIDANDO..."
            err.Text = ""
            submitted:Fire(box.Text)
        end
    end)

    return {
        WaitForKey = function() return submitted.Event:Wait() end,
        SetError = function(msg) err.Text = msg; btn.Text = "ATIVAR" end,
        Destroy = function() gui:Destroy() end,
    }
end

task.spawn(function()
    local hwid = getHwid()

    -- 1) tem key salva? valida de novo (o server checa HWID)
    local savedKey = readKey()
    if savedKey then
        local ok, err = validateKey(savedKey, hwid)
        if ok then
            local script = downloadScript()
            if script then return loadstring(script)() end
        end
        -- key salva não vale mais (HWID mudou? server caiu?)
        -- não apaga, só cai pro prompt
    end

    -- 2) pede a key
    local ui = promptKey()
    while true do
        local key = ui:WaitForKey()
        if not key or #key < 8 then
            ui:SetError("Key muito curta")
        else
            local ok, err = validateKey(key, hwid)
            if ok then
                saveKey(key)
                local script, dlErr = downloadScript()
                if script then
                    ui:Destroy()
                    return loadstring(script)()
                else
                    ui:SetError("Falha ao baixar script: " .. tostring(dlErr))
                end
            else
                ui:SetError("Key inválida: " .. tostring(err))
            end
        end
    end
end)
