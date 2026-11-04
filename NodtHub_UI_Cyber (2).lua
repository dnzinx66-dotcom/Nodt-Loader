local State = {}
-- ============================================================
-- NODT HUB KEY CLIENT (v1)
-- ============================================================
_G.__NODT_AUTH_PASSED = false

do
    local API_URL = "https://nodtkey-mr2kymqx.manus.space/api"
    local TOKEN_FILE = "NODT/token.json"

    State.SessionToken = nil
    State.KeyExpiresAt = 0

    local function getHwid()
        pcall(function()
            local cid = game:GetService("RbxAnalyticsService"):GetClientId()
            if typeof(cid) == "string" and #cid > 10 then _G.__NODT_HWID = "rbx_" .. cid end
        end)
        if _G.__NODT_HWID then return _G.__NODT_HWID end

        pcall(function()
            if typeof(gethwid) == "function" then
                local h = gethwid()
                if typeof(h) == "string" and #h > 5 then _G.__NODT_HWID = "ext_" .. h end
            end
        end)
        if _G.__NODT_HWID then return _G.__NODT_HWID end

        pcall(function()
            if typeof(getserial) == "function" then
                local h = getserial()
                if typeof(h) == "string" and #h > 5 then _G.__NODT_HWID = "ser_" .. h end
            end
        end)
        if _G.__NODT_HWID then return _G.__NODT_HWID end

        pcall(function()
            local lp = game:GetService("Players").LocalPlayer
            if lp then _G.__NODT_HWID = "uid_" .. tostring(lp.UserId) end
        end)
        return _G.__NODT_HWID or "unknown_hwid"
    end

    local function jsonEncode(tbl)
        local ok, http = pcall(function() return game:GetService("HttpService") end)
        if not ok then return nil end
        local ok2, encoded = pcall(function() return http:JSONEncode(tbl) end)
        return ok2 and encoded or nil
    end

    local function jsonDecode(str)
        local ok, http = pcall(function() return game:GetService("HttpService") end)
        if not ok then return nil end
        local ok2, decoded = pcall(function() return http:JSONDecode(str) end)
        return ok2 and decoded or nil
    end

    local function getRequest()
        if typeof(syn) == "table" and typeof(syn.request) == "function" then return syn.request end
        if typeof(http) == "table" and typeof(http.request) == "function" then return http.request end
        if typeof(request) == "function" then return request end
        if typeof(http_request) == "function" then return http_request end
        return nil
    end

    local function apiRequest(method, endpoint, body)
        local req = getRequest()
        if not req then return nil, "Executor sem request HTTP" end

        local payload = body and jsonEncode(body) or nil
        local headers = { ["Content-Type"] = "application/json" }
        if State.SessionToken then
            headers["Authorization"] = "Bearer " .. State.SessionToken
        end

        local ok, response = pcall(req, {
            Url = API_URL .. endpoint,
            Method = method,
            Headers = headers,
            Body = payload
        })

        if not ok or not response or not response.Body then return nil, "Network error" end
        local decoded = jsonDecode(response.Body)
        if not decoded then return nil, "Invalid JSON from server" end
        return decoded, response.StatusCode
    end

    -- Pega a função do executor (getgenv / getfenv / _G), pois nem todo executor expõe tudo em _G
    local function pick(name)
        local f
        pcall(function() f = getgenv()[name] end)
        if type(f) ~= "function" then pcall(function() f = getfenv()[name] end) end
        if type(f) ~= "function" then f = rawget(_G, name) end
        return type(f) == "function" and f or nil
    end

    local function saveToken(token, expiresAt)
        local exp = tonumber(expiresAt)
        if not exp then exp = os.time() + 86400 end
        if exp > 100000000000 then exp = math.floor(exp / 1000) end

        local data = jsonEncode({ token = token, expires_at = exp })
        if not data then return false end

        local writeFn = rawget(_G, "writefile") or writefile
        local mkdirFn = rawget(_G, "makefolder") or makefolder
        local isFolderFn = rawget(_G, "isfolder") or isfolder

        if not writeFn then return false end

        local ok = pcall(function()
            if mkdirFn and isFolderFn and not isFolderFn("NODT") then
                pcall(mkdirFn, "NODT")
            end
            writeFn("NODT/token.json", data)
        end)
        return ok
    end

    local function loadToken()
        local readFn = rawget(_G, "readfile") or readfile
        if not readFn then return nil end

        local ok, raw = pcall(readFn, "NODT/token.json")
        if not ok or type(raw) ~= "string" or raw == "" then return nil end

        local data = jsonDecode(raw)
        if type(data) ~= "table" or type(data.token) ~= "string" or not data.expires_at then
            return nil
        end

        local exp = tonumber(data.expires_at)
        if not exp then return nil end
        if exp > 100000000000 then exp = math.floor(exp / 1000) end

        if exp > os.time() + 60 then
            return data.token, exp
        end
        return nil
    end

    local function promptKey()
        local gui = Instance.new("ScreenGui")
        gui.Name = "NodtHubKeyInput"
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 99999
        gui.IgnoreGuiInset = true
        pcall(function()
            gui.Parent = game:GetService("CoreGui")
        end)
        if not gui.Parent then
            gui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
        end

        local TweenService = game:GetService("TweenService")
        local submitted = Instance.new("BindableEvent")
        local busy = false

        -- ============ Visual "Ember Grid" (cyberpunk, igual ao da janela principal) ============
        -- Base ink verde-azulada, brasa (vermelho-laranja) -> ambar nos destaques, menta como sinal de "sistema ativo".
        local C_EMBER = Color3.fromRGB(255, 76, 46)
        local C_AMBER = Color3.fromRGB(255, 176, 32)
        local C_MINT = Color3.fromRGB(46, 255, 196)
        local C_INK = Color3.fromRGB(7, 10, 13)
        local C_LINE = Color3.fromRGB(44, 60, 70)
        local C_TEXT = Color3.fromRGB(238, 246, 244)
        local C_SUB = Color3.fromRGB(156, 176, 178)
        local C_FAINT = Color3.fromRGB(100, 122, 128)
        local C_ERR = Color3.fromRGB(255, 98, 84)
        local WHITE = Color3.new(1, 1, 1)
        local BRAND_SEQ = ColorSequence.new(C_EMBER, C_AMBER)
        local BTN_SEQ = ColorSequence.new(Color3.fromRGB(255, 66, 48), Color3.fromRGB(255, 124, 38))
        local PW, PH = 292, 184 -- caixa compacta

        local function addGradient(parent, rotation, colors, alphas)
            local g = Instance.new("UIGradient")
            g.Rotation = rotation or 0
            g.Color = colors or ColorSequence.new(WHITE)
            if alphas then
                g.Transparency = alphas
            end
            g.Parent = parent
            return g
        end

        local function addCorner(parent, radius)
            local c = Instance.new("UICorner")
            c.CornerRadius = radius
            c.Parent = parent
            return c
        end

        local function addStroke(parent, color, thickness, transparency)
            local s = Instance.new("UIStroke")
            s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
            s.Color = color
            s.Thickness = thickness
            s.Transparency = transparency
            s.Parent = parent
            return s
        end

        local function newFrame(props, parent)
            local f = Instance.new("Frame")
            f.BorderSizePixel = 0
            for k, v in pairs(props) do
                f[k] = v
            end
            f.Parent = parent
            return f
        end

        local function newText(props, parent)
            local t = Instance.new("TextLabel")
            t.BackgroundTransparency = 1
            t.BorderSizePixel = 0
            for k, v in pairs(props) do
                t[k] = v
            end
            t.Parent = parent
            return t
        end

        -- Listras duras alternando duas cores (efeito "hazard"). n = quantidade de listras de cada cor.
        local function hardStripes(a, b, n)
            local kp = {}
            local total = n * 2
            for i = 0, total - 1 do
                local c = (i % 2 == 0) and a or b
                kp[#kp + 1] = ColorSequenceKeypoint.new(i == 0 and 0 or (i / total + 0.001), c)
                kp[#kp + 1] = ColorSequenceKeypoint.new(i == total - 1 and 1 or ((i + 1) / total), c)
            end
            return ColorSequence.new(kp)
        end

        -- Halo de brasa bem curto atras da caixa (pulsa devagar). Sem escurecer a tela do jogo.
        local halo = Instance.new("ImageLabel")
        halo.Name = "Halo"
        halo.AnchorPoint = Vector2.new(0.5, 0.5)
        halo.Position = UDim2.new(0.5, 0, 0.5, 4)
        halo.Size = UDim2.fromOffset(PW + 36, PH + 36)
        halo.BackgroundTransparency = 1
        halo.Image = "rbxassetid://1316045217"
        halo.ImageColor3 = C_EMBER
        halo.ImageTransparency = 0.8
        halo.ScaleType = Enum.ScaleType.Slice
        halo.SliceCenter = Rect.new(10, 10, 118, 118)
        halo.Parent = gui
        TweenService:Create(halo, TweenInfo.new(2.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
            ImageTransparency = 0.9,
        }):Play()

        local frame = Instance.new("Frame")
        frame.Name = "LoginPanel"
        frame.AnchorPoint = Vector2.new(0.5, 0.5)
        frame.Position = UDim2.new(0.5, 0, 0.5, 0)
        frame.Size = UDim2.fromOffset(PW, PH)
        frame.BackgroundColor3 = WHITE
        frame.BorderSizePixel = 0
        frame.ClipsDescendants = true
        frame.Parent = gui

        addCorner(frame, UDim.new(0, 6))
        addGradient(frame, 115, ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(18, 27, 33)),
            ColorSequenceKeypoint.new(0.55, Color3.fromRGB(10, 15, 19)),
            ColorSequenceKeypoint.new(1, C_INK),
        }))
        local frameStroke = addStroke(frame, C_LINE, 1.2, 0.05)

        -- Entrada: a caixa "encaixa" no lugar.
        local popScale = Instance.new("UIScale")
        popScale.Scale = 0.92
        popScale.Parent = frame
        TweenService:Create(popScale, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

        -- Brilho suave de brasa no topo.
        local topGlow = newFrame({
            Name = "TopGlow",
            Size = UDim2.new(1, 0, 0, 70),
            BackgroundColor3 = C_EMBER,
            BackgroundTransparency = 0.88,
        }, frame)
        addGradient(topGlow, 90, nil, NumberSequence.new(0, 1))

        -- Linha de varredura (scanner) que desce devagar pela caixa.
        local scan = newFrame({
            Name = "Scan",
            Position = UDim2.new(0, 0, 0, 0),
            Size = UDim2.new(1, 0, 0, 1),
            BackgroundColor3 = C_MINT,
            BackgroundTransparency = 0.86,
        }, frame)
        TweenService:Create(scan, TweenInfo.new(3.8, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1), {
            Position = UDim2.new(0, 0, 1, -1),
        }):Play()

        -- Etiqueta "hazard" (listras brasa/ink) no canto superior esquerdo.
        local hazard = newFrame({
            Name = "Hazard",
            Position = UDim2.fromOffset(0, 0),
            Size = UDim2.fromOffset(78, 5),
            BackgroundColor3 = WHITE,
        }, frame)
        addGradient(hazard, 35, hardStripes(C_EMBER, C_INK, 4))

        -- Colchetes de mira nos cantos (pulsam de leve).
        local function bracket(ax, ay)
            local ox = ax == 0 and 5 or -5
            local oy = ay == 0 and 5 or -5
            for _, size in ipairs({ UDim2.fromOffset(9, 2), UDim2.fromOffset(2, 9) }) do
                local piece = newFrame({
                    AnchorPoint = Vector2.new(ax, ay),
                    Position = UDim2.new(ax, ox, ay, oy),
                    Size = size,
                    BackgroundColor3 = C_EMBER,
                    ZIndex = 5,
                }, frame)
                TweenService:Create(piece, TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
                    BackgroundTransparency = 0.6,
                }):Play()
            end
        end
        bracket(0, 1)
        bracket(1, 1)
        bracket(1, 0)

        -- Emblema: dois losangos girando em sentidos opostos com um nucleo menta (desenhado em codigo).
        local chip = newFrame({
            Name = "Emblem",
            Position = UDim2.fromOffset(14, 14),
            Size = UDim2.fromOffset(36, 36),
            BackgroundTransparency = 1,
        }, frame)
        local outerDiamond = newFrame({
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(25, 25),
            Rotation = 45,
            BackgroundTransparency = 1,
        }, chip)
        addCorner(outerDiamond, UDim.new(0, 3))
        addStroke(outerDiamond, C_AMBER, 1.2, 0.5)
        TweenService:Create(outerDiamond, TweenInfo.new(11, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1), {
            Rotation = -315,
        }):Play()
        local innerDiamond = newFrame({
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(17, 17),
            Rotation = 45,
            BackgroundColor3 = C_INK,
        }, chip)
        addCorner(innerDiamond, UDim.new(0, 3))
        addStroke(innerDiamond, C_EMBER, 1.8, 0)
        TweenService:Create(innerDiamond, TweenInfo.new(8, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1), {
            Rotation = 405,
        }):Play()
        local coreDot = newFrame({
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(6, 6),
            BackgroundColor3 = C_MINT,
            ZIndex = 3,
        }, chip)
        addCorner(coreDot, UDim.new(0, 1))
        TweenService:Create(coreDot, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
            BackgroundTransparency = 0.6,
        }):Play()

        local title = newText({
            Name = "Title",
            Position = UDim2.fromOffset(58, 14),
            Size = UDim2.new(1, -150, 0, 20),
            Font = Enum.Font.GothamBlack,
            Text = "NODT HUB",
            TextColor3 = WHITE,
            TextSize = 17,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, frame)
        addGradient(title, 0, ColorSequence.new(WHITE, Color3.fromRGB(255, 198, 160)))

        local subtitle = newText({
            Name = "Subtitle",
            Position = UDim2.fromOffset(58, 34),
            Size = UDim2.new(1, -70, 0, 14),
            Font = Enum.Font.Code,
            Text = "HWID vinculado na 1ª ativação",
            TextColor3 = C_SUB,
            TextSize = 10,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, frame)

        -- Selo de status no canto (quadradinho menta piscando).
        newText({
            Name = "Status",
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, -34, 0, 16),
            Size = UDim2.fromOffset(60, 12),
            Font = Enum.Font.Code,
            Text = "SECURE",
            TextColor3 = C_MINT,
            TextSize = 9,
            TextXAlignment = Enum.TextXAlignment.Right,
        }, frame)
        local statusDot = newFrame({
            Name = "StatusDot",
            Position = UDim2.new(1, -26, 0, 19),
            Size = UDim2.fromOffset(6, 6),
            BackgroundColor3 = C_MINT,
        }, frame)
        TweenService:Create(statusDot, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
            BackgroundTransparency = 0.7,
        }):Play()

        -- Divisor com fade.
        local divider = newFrame({
            Name = "Divider",
            Position = UDim2.fromOffset(16, 58),
            Size = UDim2.new(1, -32, 0, 1),
            BackgroundColor3 = WHITE,
        }, frame)
        addGradient(divider, 0, BRAND_SEQ, NumberSequence.new(0.1, 1))

        local field = Instance.new("Frame")
        field.Name = "KeyField"
        field.Position = UDim2.fromOffset(16, 70)
        field.Size = UDim2.new(1, -32, 0, 34)
        field.BackgroundColor3 = Color3.fromRGB(8, 12, 15)
        field.BorderSizePixel = 0
        field.Parent = frame
        addCorner(field, UDim.new(0, 4))
        local fieldStroke = addStroke(field, C_LINE, 1.2, 0.1)

        local glyph = newText({
            Name = "Prompt",
            Position = UDim2.fromOffset(0, 0),
            Size = UDim2.fromOffset(24, 34),
            Font = Enum.Font.Code,
            Text = ">",
            TextColor3 = C_EMBER,
            TextSize = 15,
        }, field)

        local box = Instance.new("TextBox")
        box.Name = "KeyInput"
        box.BackgroundTransparency = 1
        box.Position = UDim2.new(0, 24, 0, 0)
        box.Size = UDim2.new(1, -34, 1, 0)
        box.ClearTextOnFocus = false
        box.Text = ""
        box.PlaceholderText = "Digite sua key aqui..."
        box.PlaceholderColor3 = C_FAINT
        box.TextColor3 = C_TEXT
        box.Font = Enum.Font.Code
        box.TextSize = 13
        box.TextXAlignment = Enum.TextXAlignment.Left
        box.Parent = field

        -- Foco: o contorno acende em brasa e o ">" vira menta.
        box.Focused:Connect(function()
            TweenService:Create(fieldStroke, TweenInfo.new(0.2, Enum.EasingStyle.Quad), { Color = C_EMBER, Transparency = 0 }):Play()
            TweenService:Create(glyph, TweenInfo.new(0.2, Enum.EasingStyle.Quad), { TextColor3 = C_MINT }):Play()
        end)
        box.FocusLost:Connect(function()
            TweenService:Create(fieldStroke, TweenInfo.new(0.2, Enum.EasingStyle.Quad), { Color = C_LINE, Transparency = 0.1 }):Play()
            TweenService:Create(glyph, TweenInfo.new(0.2, Enum.EasingStyle.Quad), { TextColor3 = C_EMBER }):Play()
        end)

        local errorLabel = Instance.new("TextLabel")
        errorLabel.Name = "AuthError"
        errorLabel.BackgroundTransparency = 1
        errorLabel.Position = UDim2.fromOffset(16, 107)
        errorLabel.Size = UDim2.new(1, -32, 0, 16)
        errorLabel.Font = Enum.Font.Code
        errorLabel.Text = ""
        errorLabel.TextColor3 = C_ERR
        errorLabel.TextSize = 10
        errorLabel.TextXAlignment = Enum.TextXAlignment.Left
        errorLabel.TextWrapped = true
        errorLabel.Visible = false
        errorLabel.Parent = frame

        local btn = Instance.new("TextButton")
        btn.Name = "AuthenticateButton"
        btn.Position = UDim2.fromOffset(16, 128)
        btn.Size = UDim2.new(1, -32, 0, 34)
        btn.BackgroundColor3 = WHITE
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = "AUTENTICAR"
        btn.TextColor3 = WHITE
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 12
        btn.Parent = frame

        addCorner(btn, UDim.new(0, 4))
        local btnGradient = addGradient(btn, 0, BTN_SEQ)
        local btnStroke = addStroke(btn, WHITE, 1, 0.8)
        local btnScale = Instance.new("UIScale")
        btnScale.Parent = btn

        newText({
            Name = "Footer",
            Position = UDim2.fromOffset(16, 167),
            Size = UDim2.new(1, -32, 0, 12),
            Font = Enum.Font.Code,
            Text = "NODT//KEY-CLIENT v1",
            TextColor3 = C_FAINT,
            TextSize = 9,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, frame)

        local busyTween = nil
        local function startBusy()
            if busyTween then
                busyTween:Cancel()
            end
            btnGradient.Offset = Vector2.new(-0.45, 0)
            busyTween = TweenService:Create(btnGradient, TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
                Offset = Vector2.new(0.45, 0),
            })
            busyTween:Play()
        end
        local function stopBusy()
            if busyTween then
                busyTween:Cancel()
                busyTween = nil
            end
            btnGradient.Offset = Vector2.new(0, 0)
        end

        -- Erro: a caixa treme de leve e a mensagem aparece suavemente.
        local function playErrorFx()
            errorLabel.TextTransparency = 1
            TweenService:Create(errorLabel, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { TextTransparency = 0 }):Play()
            task.spawn(function()
                local base = frame.Position
                for _, dx in ipairs({ 10, -9, 7, -5, 3, 0 }) do
                    if not frame.Parent then
                        return
                    end
                    TweenService:Create(frame, TweenInfo.new(0.05, Enum.EasingStyle.Quad), { Position = base + UDim2.fromOffset(dx, 0) }):Play()
                    task.wait(0.05)
                end
            end)
        end

        local function submitKey()
            if busy then return end
            local value = box.Text
            if not value or #value == 0 then
                errorLabel.Text = "Digite sua key."
                errorLabel.Visible = true
                playErrorFx()
                return
            end
            busy = true
            errorLabel.Visible = false
            btn.Text = "VALIDANDO..."
            btn.BackgroundTransparency = 0.2
            startBusy()
            submitted:Fire(value)
        end

        btn.MouseEnter:Connect(function()
            if busy then return end
            TweenService:Create(btnScale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.03 }):Play()
            TweenService:Create(btnStroke, TweenInfo.new(0.16), { Transparency = 0.3 }):Play()
        end)

        btn.MouseLeave:Connect(function()
            TweenService:Create(btnScale, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
            if busy then return end
            TweenService:Create(btnStroke, TweenInfo.new(0.16), { Transparency = 0.8 }):Play()
        end)

        btn.MouseButton1Down:Connect(function()
            TweenService:Create(btnScale, TweenInfo.new(0.1, Enum.EasingStyle.Quad), { Scale = 0.97 }):Play()
        end)
        btn.MouseButton1Up:Connect(function()
            TweenService:Create(btnScale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.03 }):Play()
        end)

        btn.MouseButton1Click:Connect(submitKey)
        box.FocusLost:Connect(function(enterPressed)
            if enterPressed then
                submitKey()
            end
        end)

        local prompt = {}

        function prompt:WaitForKey()
            return submitted.Event:Wait()
        end

        function prompt:SetError(message)
            if not gui.Parent then return end
            busy = false
            errorLabel.Text = tostring(message)
            errorLabel.Visible = true
            btn.Text = "AUTENTICAR"
            btn.BackgroundTransparency = 0
            stopBusy()
            playErrorFx()
            box:CaptureFocus()
        end

        function prompt:Destroy()
            submitted:Destroy()
            gui:Destroy()
        end

        box:CaptureFocus()
        return prompt
    end

    local function validateAndRenew(token)
        local resp, status = apiRequest("POST", "/renew", { token = token })
        if status == 200 and resp and resp.ok then
            saveToken(resp.token, resp.expires_at)
            State.SessionToken = resp.token
            State.KeyExpiresAt = resp.expires_at
            return true
        end
        return false
    end


    local renewStarted = false
    local function startRenewLoop()
        if renewStarted then return end
        renewStarted = true
        task.spawn(function()
            while true do
                task.wait(3600)
                local exp = tonumber(State.KeyExpiresAt)
                if exp and exp > 100000000000 then exp = math.floor(exp / 1000) end
                if State.SessionToken and (not exp or exp - os.time() < 3600) then
                    pcall(validateAndRenew, State.SessionToken)
                end
            end
        end)
    end

    local function checkAuth()
        -- 1) Cache: se existe NODT/token.json com token válido, pula a tela de login
        local okLoad, cachedToken, cachedExp = pcall(loadToken)
        if okLoad and cachedToken and cachedExp then
            State.SessionToken = cachedToken
            State.KeyExpiresAt = cachedExp
            startRenewLoop()
            _G.__NODT_AUTH_PASSED = true
            return true
        end

        -- 2) Sem cache válido: mostra a tela de login
        warn("[NodtHub] Autenticação necessária.")
        warn("[NodtHub] Digite sua key na janela e clique em Autenticar.")

        local prompt = promptKey()
        while true do
            local key = prompt:WaitForKey()
            if not key or #key < 5 then
                prompt:SetError("Key inválida. Verifique e tente novamente.")
            else
                warn("[NodtHub] Validando key...")
                local hwid = getHwid()
                local resp, status = apiRequest("POST", "/validate", { key = key, hwid = hwid })

                if status == 200 and resp and resp.ok then
                    State.SessionToken = resp.token
                    State.KeyExpiresAt = resp.expires_at

                    -- Salva token + data de expiração em NODT/token.json
                    if saveToken(resp.token, resp.expires_at) then
                        warn("[NodtHub] Key válida! Token salvo com sucesso.")
                    else
                        warn("[NodtHub] Key válida, mas não foi possível salvar o cache.")
                    end

                    prompt:Destroy()
                    startRenewLoop()
                    _G.__NODT_AUTH_PASSED = true
                    return true
                else
                    local motivo = resp and resp.error or status or "Erro desconhecido"
                    local erro = string.lower(tostring(motivo))
                    local mensagem
                    if erro == "hwid_divergente" or erro == "hwid_mismatch" then
                        mensagem = "Key inválida, HWID diferente"
                    else
                        mensagem = tostring(motivo)
                    end
                    warn("[NodtHub] Falha na validação: " .. mensagem)
                    prompt:SetError(mensagem)
                end
            end
        end
    end

    -- Antes era `pcall(checkAuth)`, que engolia qualquer erro em silêncio
    local okAuth, errAuth = pcall(checkAuth)
    if not okAuth then
        warn("[NodtHub] Erro no checkAuth: " .. tostring(errAuth))
    end
end

if not _G.__NODT_AUTH_PASSED then
    return
end
-- ============================================================


local function getKnitRoot()
    local ReplicatedStorage = game:GetService("ReplicatedStorage")

    local ok, knit = pcall(function()
        return require(ReplicatedStorage.Packages.Knit)
    end)
    if ok and type(knit) == "table" and type(knit.GetController) == "function" then
        return knit
    end

    local okIndex, index = pcall(function()
        return ReplicatedStorage.Packages._Index
    end)
    if okIndex and index then
        for _, package in ipairs(index:GetChildren()) do
            if package.Name:match("^sleitnick_knit@") then
                local module = package:FindFirstChild("knit")
                if module and module:IsA("ModuleScript") then
                    local loaded, result = pcall(require, module)
                    if loaded and type(result) == "table" and type(result.GetController) == "function" then
                        return result
                    end
                end
            end
        end
    end

    warn("[NodtHub] Knit root nao encontrado")
    return nil
end

local function bootstrapCompatibility()
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local fenv = (pcall(getfenv, 1) and getfenv(1)) or _G
    local missing = {}

    local function grab(name)
        for _, source in ipairs({ fenv, genv, _G }) do
            local found, value = pcall(function()
                return source[name]
            end)
            if found and type(value) == "function" then
                return value
            end
        end
        return nil
    end

    local function grabTable(name)
        local found, value = pcall(function()
            return fenv[name] or genv[name]
        end)
        if found and type(value) == "table" then
            return value
        end
        return nil
    end

    local function publish(name, value)
        if not value then
            table.insert(missing, name)
            return
        end
        pcall(function()
            genv[name] = value
        end)
        pcall(function()
            fenv[name] = value
        end)
    end

    local connectionsOf = grab("getconnections") or grab("get_signal_cons")
    publish("getconnections", connectionsOf)
    local writeable = grab("make_writeable")
    local readonly = grab("make_readonly")
    local debugMeta = debug and debug.getmetatable

    publish("getrawmetatable", grab("getrawmetatable") or grab("get_raw_metatable") or debugMeta)

    publish("setreadonly", grab("setreadonly") or grab("set_readonly") or (writeable and readonly and function(target, state)
        if state then
            readonly(target)
        else
            writeable(target)
        end
    end))

    publish("getnamecallmethod", grab("getnamecallmethod") or grab("get_namecall_method"))

    local setIdentity = grab("setthreadidentity") or grab("set_thread_identity")
    local readIdentity = grab("getthreadidentity") or grab("get_thread_identity")

    if setIdentity then
        publish("setthreadidentity", setIdentity)
    end
    if readIdentity then
        publish("getthreadidentity", readIdentity)
    end

    local native = grab("firesignal") or grab("fire_signal")
    local viaConnections = connectionsOf and function(signal, ...)
        for _, connection in ipairs(connectionsOf(signal)) do
            pcall(connection.Fire, connection, ...)
        end
    end

    if native and viaConnections then
        local probe = Instance.new("BindableEvent")
        local landed = false
        probe.Event:Connect(function()
            landed = true
        end)
        pcall(native, probe.Event, true)
        task.wait(0.1)
        probe:Destroy()
        if not landed then
            native = nil
        end
    end

    local fire = native or viaConnections
    publish("firesignal", fire and function(signal, ...)
        if not setIdentity then
            return fire(signal, ...)
        end
        local restore = readIdentity and readIdentity()
        pcall(setIdentity, 2)
        pcall(fire, signal, ...)
        if restore then
            pcall(setIdentity, restore)
        end
    end)

    publish("loadstring", grab("loadstring") or grab("load"))

    local send = grab("request") or grab("http_request")
    if not send then
        local syntax = grabTable("syn") or grabTable("http") or grabTable("fluxus")
        send = syntax and syntax.request
    end

    publish("httpGet", function(url)
        local reached, body = pcall(function()
            return game:HttpGet(url)
        end)
        if reached and type(body) == "string" and #body > 0 then
            return body
        end
        if send then
            local sent, response = pcall(send, { Url = url, Method = "GET" })
            if sent and type(response) == "table" and type(response.Body) == "string" then
                return response.Body
            end
        end
        error("NODT: no working HTTP method for " .. tostring(url), 0)
    end)

    local hidden = grab("gethui") or grab("get_hidden_gui")
    local guard = grab("protect_gui")
    if not guard then
        local syntax = grabTable("syn")
        guard = syntax and syntax.protect_gui
    end
    publish("hidegui", function(gui)
        if guard then pcall(guard, gui) end
        if hidden then
            local reached, container = pcall(hidden)
            if reached and typeof(container) == "Instance" then
                gui.Parent = container
                return
            end
        end
        local pulled, core = pcall(game.GetService, game, "CoreGui")
        if pulled and core then
            local placed = pcall(function() gui.Parent = core end)
            if placed then return end
        end
        warn("[NODTHUB] hidegui: caiu no PlayerGui, UI visivel")
        gui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
    end)

end

bootstrapCompatibility()

local hookNamecall

do
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local prior = rawget(genv, "NODT_SESSION") or genv.NODT_SESSION
    local carried = type(prior) == "table" and prior.vault or nil
    if type(prior) == "table" and type(prior.unload) == "function" then
        pcall(prior.unload)
    end
    local session = {}
    session.vault = carried

    -- Central __namecall registry: one real hook on the metatable, any number of
    -- named handlers stacked on top of it. Newest handler runs first (same order
    -- the old per-feature hooks had), unload walks the stack LIFO.
    local hub = { stack = {}, byId = {}, installed = false, dead = false }
    local dispatch

    dispatch = function(level, self, method, ...)
        while level > 0 do
            local entry = hub.stack[level]
            if entry and entry.alive then
                -- Fix 1: handler protegido. 'passed' marca se o handler ja delegou para a
                -- chain; se o erro veio de dentro da chain (jogo/outro handler) ele e
                -- relancado como antes, sem reexecutar a chamada.
                local passed = false
                local function below(...)
                    passed = true
                    return entry.below(...)
                end
                local packed = table.pack(pcall(entry.callback, below, self, method, ...))
                if packed[1] then
                    return table.unpack(packed, 2, packed.n)
                end
                if passed then
                    error(packed[2], 0)
                end
                -- Se o handler falhar, continua a chain para nao quebrar o jogo.
                -- (o handler pode ter feito namecalls antes de falhar: restaura o metodo atual)
                if type(setnamecallmethod) == "function" then
                    pcall(setnamecallmethod, method)
                end
                return entry.below(self, method, ...)
            end
            level = level - 1
        end
        return hub.original(self, ...)
    end

    local function central(self, ...)
        return dispatch(#hub.stack, self, getnamecallmethod(), ...)
    end

    local function writeNamecall(meta, value)
        pcall(setreadonly, meta, false)
        local written = pcall(function()
            meta.__namecall = value
        end)
        pcall(setreadonly, meta, true)
        return written
    end

    -- callback(callNext, self, method, ...): call callNext(self, method, ...) to continue the chain.
    -- Registering the same id again only swaps the callback, it never stacks a second hook.
    -- Returns a release function (or nil when the executor can't hook).
    hookNamecall = function(id, callback, onUnload)
        if hub.dead then return nil end
        if type(id) ~= "string" or type(callback) ~= "function" then return nil end

        local current = hub.byId[id]
        if current and current.alive then
            current.callback = callback
            current.onUnload = onUnload or current.onUnload
            return current.release
        end

        if not (getrawmetatable and setreadonly and getnamecallmethod) then return nil end

        if not hub.installed then
            local meta = getrawmetatable(game)
            if not meta then return nil end
            local live = meta.__namecall
            if live ~= central then
                hub.original = live
                if not writeNamecall(meta, central) then
                    warn("[NODTHUB] hookNamecall falhou: setreadonly bloqueado pelo executor")
                    return nil
                end
            end
            hub.mt = meta
            hub.installed = true
        end

        local entry = {
            id = id,
            callback = callback,
            onUnload = onUnload,
            alive = true,
            index = #hub.stack + 1,
        }
        entry.below = function(self, method, ...)
            return dispatch(entry.index - 1, self, method, ...)
        end
        entry.release = function()
            if not entry.alive then return end
            entry.alive = false
            if hub.byId[id] == entry then
                hub.byId[id] = nil
            end
            if type(entry.onUnload) == "function" then
                pcall(entry.onUnload)
            end
            while #hub.stack > 0 and not hub.stack[#hub.stack].alive do
                hub.stack[#hub.stack] = nil
            end
        end

        hub.stack[entry.index] = entry
        hub.byId[id] = entry
        return entry.release
    end

    -- LIFO teardown: last handler installed is the first one released, then the
    -- original metamethod goes back. If another script wrapped us in the meantime
    -- we leave the central hook in place as a pure pass-through instead of cutting
    -- their wrapper out of the chain.
    session.unhook = function()
        hub.dead = true
        for level = #hub.stack, 1, -1 do
            local entry = hub.stack[level]
            hub.stack[level] = nil
            if entry then
                entry.alive = false
                hub.byId[entry.id] = nil
                if type(entry.onUnload) == "function" then
                    pcall(entry.onUnload)
                end
            end
        end
        if hub.installed and hub.mt and rawget(hub.mt, "__namecall") == central then
            writeNamecall(hub.mt, hub.original)
        end
        hub.installed = false
    end
    session.unload = function()
        if session.unloaded then return end
        session.unloaded = true
        if session.vault and session.vault.inventory then
            pcall(function()
                local Knit = getKnitRoot()
                if not Knit then return end
                local inventory = Knit.GetController("InventoryController")
                if inventory and inventory.Inventory then
                    inventory.Inventory:set(session.vault.inventory)
                end
            end)
        end
        if session.vault and session.vault.title then
            pcall(function()
                game:GetService("Players").LocalPlayer:SetAttribute("User_Title", session.vault.title)
            end)
        end
        if session.vault and session.vault.equipped then
            pcall(function()
                local Knit = getKnitRoot()
                if not Knit then return end
                local inventory = Knit.GetController("InventoryController")
                if inventory and inventory.Equipped then
                    inventory.Equipped:set(session.vault.equipped)
                end
            end)
        end
        if session.ui and session.ui.Unload then
            pcall(function()
                session.ui:Unload()
            end)
        end
        for _, link in ipairs(session.links or {}) do
            pcall(function()
                link:Disconnect()
            end)
        end
        pcall(function()
            local tagged = {}
            for _, name in ipairs(session.tags or {}) do
                tagged[name] = true
            end
            if not next(tagged) then return end
            local holders = {}
            if type(gethui) == "function" then
                local reached, container = pcall(gethui)
                if reached and container then table.insert(holders, container) end
            end
            table.insert(holders, game:GetService("CoreGui"))
            if workspace.CurrentCamera then
                table.insert(holders, workspace.CurrentCamera)
            end
            local players = game:GetService("Players")
            if players.LocalPlayer then
                local pg = players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
                if pg then table.insert(holders, pg) end
            end
            for _, holder in ipairs(holders) do
                for _, child in ipairs(holder:GetChildren()) do
                    if tagged[child.Name] then
                        child:Destroy()
                    end
                end
            end
            for _, model in ipairs(workspace:GetChildren()) do
                if model:IsA("Model") and model.Name:match("^CLIENT_BALL_%d+$") then
                    for _, child in ipairs(model:GetChildren()) do
                        if tagged[child.Name] then
                            child:Destroy()
                        end
                    end
                end
            end
            for _, other in ipairs(players:GetPlayers()) do
                if other.Character then
                    for _, child in ipairs(other.Character:GetChildren()) do
                        if tagged[child.Name] then
                            child:Destroy()
                        end
                    end
                end
            end
        end)
        pcall(session.unhook)
    end
    session.links = {}
    session.tags = {}
    genv.NODT_SESSION = session
end

local Library = (function()
    local Players = game:GetService("Players")
    local UserInputService = game:GetService("UserInputService")
    local TweenService = game:GetService("TweenService")
    local GuiService = game:GetService("GuiService")
    local HttpService = game:GetService("HttpService")
    local LocalPlayer = Players.LocalPlayer

    local RunService = game:GetService("RunService")

    -- Tema "Ember Grid" (cyberpunk): base ink verde-azulada quase preta, destaque brasa (vermelho-laranja) -> ambar,
    -- menta como sinal de "sistema ativo". Listras "hazard", colchetes de mira e cantos retos no lugar do degrade suave.
    -- As chaves antigas (Wine*, Glow...) foram mantidas porque o codigo fora da Library (botao flutuante, etc.) ainda le essas chaves.
    local Theme = {
        Accent = Color3.fromRGB(255, 76, 46),
        Accent2 = Color3.fromRGB(255, 176, 32),
        Accent3 = Color3.fromRGB(46, 255, 196),
        AccentSoft = Color3.fromRGB(68, 28, 20),
        Wine = Color3.fromRGB(126, 40, 26),
        WineHi = Color3.fromRGB(214, 70, 40),
        WineDeep = Color3.fromRGB(38, 16, 12),
        Glow = Color3.fromRGB(255, 198, 160),
        Shell = Color3.fromRGB(7, 10, 13),
        ShellTop = Color3.fromRGB(16, 24, 30),
        Panel = Color3.fromRGB(13, 18, 22),
        PanelLow = Color3.fromRGB(9, 13, 16),
        Raised = Color3.fromRGB(25, 35, 42),
        Sunken = Color3.fromRGB(8, 12, 15),
        Line = Color3.fromRGB(44, 60, 70),
        LineSoft = Color3.fromRGB(22, 31, 38),
        Text = Color3.fromRGB(238, 246, 244),
        SubText = Color3.fromRGB(156, 176, 178),
        Faint = Color3.fromRGB(100, 122, 128),
        OnAccent = Color3.fromRGB(255, 255, 255),
    }

    -- Medidas: janela compacta, cabecalho (marca + controles) e faixa de abas horizontal no topo.
    local WIN_W, WIN_H = 700, 480
    local HEAD_H = 46
    local TABS_H = 0
    local SIDEBAR_W = 150
    -- Roda do mouse com inercia (so em dispositivos sem toque). Mude para false para voltar ao scroll nativo.
    local SMOOTH_WHEEL = true

    local PILL = UDim.new(1, 0)
    local EASE = TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
    -- Fontes: Gotham para texto, Code para numeros e teclas (da o tom "instrumento" ao painel).
    local UI_FONT = Enum.Font.GothamMedium
    local MONO = Enum.Font.Code

    -- Icones das abas e dos grupos (nome do icone -> simbolo).
    local ICONS = {
        user = "👤", eye = "👁\u{FE0F}", settings = "⚙\u{FE0F}", ["gamepad-2"] = "🎮", crosshair = "🎯",
        box = "📦", gauge = "⏱\u{FE0F}", move = "🏃", server = "🖥\u{FE0F}", database = "💾",
        ["sliders-horizontal"] = "🎚\u{FE0F}", target = "🎯", sparkles = "✨", shield = "🛡\u{FE0F}",
        ["id-card"] = "🆔", tag = "🏷\u{FE0F}", circle = "⚪", shirt = "👕", ["refresh-cw"] = "🔄",
        zap = "⚡", ["shopping-bag"] = "🛍\u{FE0F}", gift = "🎁", wrench = "🔧",
    }

    local Lib = {
        Options = {},
        Toggles = {},
        Theme = Theme,
        CornerRadius = 6,
        ForceCheckbox = false,
        ShowToggleFrameInKeybinds = true,
        NotifySide = "Right",
        Unloaded = false,
        ToggleKeybind = nil,
        DefaultToggleKey = "RightShift",
    }

    Lib.WinSize = Vector2.new(WIN_W, WIN_H)

    local conns = {}
    local panels = {}
    local pickers = {}
    local pages = {}
    local configFolder = "NODT"

    local function new(class, props, parent)
        local inst = Instance.new(class)
        for key, value in pairs(props) do
            inst[key] = value
        end
        if parent then
            inst.Parent = parent
        end
        return inst
    end

    local function round(inst, radius, tracked)
        local corner = new("UICorner", { CornerRadius = radius }, inst)
        if tracked then
            table.insert(panels, corner)
        end
        return corner
    end

    local function outline(inst, color, thickness, transparency)
        return new("UIStroke", {
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
            LineJoinMode = Enum.LineJoinMode.Round,
            Color = color or Theme.Line,
            Thickness = thickness or 1,
            Transparency = transparency or 0,
        }, inst)
    end

    local function pad(inst, left, right, top, bottom)
        return new("UIPadding", {
            PaddingLeft = UDim.new(0, left or 0),
            PaddingRight = UDim.new(0, right or 0),
            PaddingTop = UDim.new(0, top or 0),
            PaddingBottom = UDim.new(0, bottom or 0),
        }, inst)
    end

    local function stack(inst, gap, dir)
        return new("UIListLayout", {
            FillDirection = dir or Enum.FillDirection.Vertical,
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, gap or 0),
        }, inst)
    end

    local function shade(inst, rotation, colors, alphas)
        return new("UIGradient", {
            Rotation = rotation or 90,
            Color = colors or ColorSequence.new(Color3.new(1, 1, 1)),
            Transparency = alphas or NumberSequence.new(0),
        }, inst)
    end

    local function glide(inst, props, speed)
        local anim = TweenService:Create(inst, speed and TweenInfo.new(speed, Enum.EasingStyle.Quart, Enum.EasingDirection.Out) or EASE, props)
        anim:Play()
        return anim
    end

    -- Animacao com controle total de duracao, estilo, direcao e atraso.
    local function ease(inst, props, seconds, style, direction, delay)
        local anim = TweenService:Create(inst, TweenInfo.new(seconds or 0.3, style or Enum.EasingStyle.Quint, direction or Enum.EasingDirection.Out, 0, false, delay or 0), props)
        anim:Play()
        return anim
    end

    -- Gradientes de marca: brasa -> ambar (barras, preenchimentos) e a versao com menta (contornos e linhas de destaque).
    local BRAND = ColorSequence.new(Theme.Accent, Theme.Accent2)
    local BRAND3 = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Theme.Accent),
        ColorSequenceKeypoint.new(0.55, Theme.Accent2),
        ColorSequenceKeypoint.new(1, Theme.Accent3),
    })
    local BRAND_LOOP = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Theme.Accent),
        ColorSequenceKeypoint.new(0.34, Theme.Accent2),
        ColorSequenceKeypoint.new(0.67, Theme.Accent3),
        ColorSequenceKeypoint.new(1, Theme.Accent),
    })

    -- Icones de linha desenhados em codigo (estilo Lepo): combinam com cada categoria.
    local ICON_SHAPES = {
        crosshair = { {"o",12,12,14}, {"l",12,2,12,7}, {"l",12,17,12,22}, {"l",2,12,7,12}, {"l",17,12,22,12}, {"d",12,12,3} },
        user = { {"o",12,8,8}, {"r",5,15,14,8,7} },
        eye = { {"r",2,6,20,12,6}, {"o",12,12,6}, {"d",12,12,2.5} },
        settings = { {"o",12,12,8}, {"l",12,1.5,12,5}, {"l",12,19,12,22.5}, {"l",1.5,12,5,12}, {"l",19,12,22.5,12}, {"l",4.6,4.6,7,7}, {"l",17,17,19.4,19.4}, {"l",19.4,4.6,17,7}, {"l",7,17,4.6,19.4} },
        ["gamepad-2"] = { {"r",2,7,20,11,5}, {"l",7,10,7,15}, {"l",4.5,12.5,9.5,12.5}, {"d",16,11.5,2.5}, {"d",18.8,14,2.5} },
        ["sliders-horizontal"] = { {"l",3,6,21,6}, {"l",3,12,21,12}, {"l",3,18,21,18}, {"d",8,6,5}, {"d",16,12,5}, {"d",10,18,5} },
        box = { {"r",4,4,16,16,3}, {"l",4,10,20,10}, {"l",12,4,12,10} },
        gauge = { {"o",12,12,18}, {"l",12,12,17,7.5}, {"d",12,12,3.5} },
        move = { {"l",3,12,20,12}, {"l",14,6,20,12}, {"l",14,18,20,12} },
        server = { {"r",3,3,18,7,2}, {"r",3,14,18,7,2}, {"d",7,6.5,2}, {"d",7,17.5,2} },
        database = { {"r",4,3,16,5.5,3}, {"r",4,9.5,16,5.5,3}, {"r",4,16,16,5.5,3} },
        target = { {"o",12,12,18}, {"o",12,12,10}, {"d",12,12,3.5} },
        sparkles = { {"l",10,3,10,17}, {"l",3,10,17,10}, {"l",19,14,19,22}, {"l",15,18,23,18} },
        shield = { {"r",5,3,14,17,7}, {"l",12,8,12,15} },
        ["id-card"] = { {"r",2,5,20,14,3}, {"o",8,11,5}, {"l",14,10,19,10}, {"l",14,14,19,14}, {"l",5.5,16,10.5,16} },
        tag = { {"r",3,8,18,10,3}, {"d",7.5,13,3} },
        circle = { {"o",12,12,18}, {"l",12,3,12,21}, {"l",4.2,7.5,19.8,16.5} },
        shirt = { {"r",7,6,10,14,2}, {"l",7,6,2,10}, {"l",17,6,22,10}, {"o",12,6,4} },
        ["refresh-cw"] = { {"o",12,12,16}, {"l",19,3,19,9}, {"l",13,9,19,9} },
        zap = { {"l",14,2,5,13}, {"l",5,13,12,13}, {"l",12,13,10,22}, {"l",10,22,19,10}, {"l",19,10,12,10}, {"l",12,10,14,2} },
        ["shopping-bag"] = { {"r",4,8,16,13,3}, {"r",8,3,8,9,4} },
        gift = { {"r",3,10,18,11,2}, {"r",2,6,20,4,1.5}, {"l",12,6,12,21}, {"o",9.5,3.5,4}, {"o",14.5,3.5,4} },
        wrench = { {"l",5,19,15,9,3}, {"o",17,7,8} },
    }

    -- Desenha o icone dentro de "parent" (centralizado) com o tamanho "size". Retorna objeto com :tint(cor).
    local function drawIcon(parent, name, size, color, thick)
        local shape = ICON_SHAPES[name or ""]
        if not shape then
            return nil
        end
        local k = size / 24
        local th = thick or math.max(1.2, 2 * k)
        local box = new("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(size, size),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
        }, parent)
        local parts = {}
        local function part(inst, stroke)
            table.insert(parts, { Inst = inst, Stroke = stroke })
        end
        for _, sh in ipairs(shape) do
            local kind = sh[1]
            if kind == "o" or kind == "d" then
                local d = sh[4] * k
                local f = new("Frame", {
                    AnchorPoint = Vector2.new(0.5, 0.5),
                    Position = UDim2.fromOffset(sh[2] * k, sh[3] * k),
                    Size = UDim2.fromOffset(d, d),
                    BackgroundColor3 = color,
                    BackgroundTransparency = kind == "o" and 1 or 0,
                    BorderSizePixel = 0,
                }, box)
                round(f, PILL)
                if kind == "o" then
                    part(outline(f, color, th, 0), true)
                else
                    part(f, false)
                end
            elseif kind == "r" then
                local f = new("Frame", {
                    Position = UDim2.fromOffset(sh[2] * k, sh[3] * k),
                    Size = UDim2.fromOffset(sh[4] * k, sh[5] * k),
                    BackgroundTransparency = 1,
                    BorderSizePixel = 0,
                }, box)
                round(f, UDim.new(0, (sh[6] or 0) * k))
                part(outline(f, color, th, 0), true)
            elseif kind == "l" then
                local x1, y1, x2, y2 = sh[2] * k, sh[3] * k, sh[4] * k, sh[5] * k
                local dx, dy = x2 - x1, y2 - y1
                local len = math.sqrt(dx * dx + dy * dy)
                local f = new("Frame", {
                    AnchorPoint = Vector2.new(0.5, 0.5),
                    Position = UDim2.fromOffset((x1 + x2) / 2, (y1 + y2) / 2),
                    Size = UDim2.fromOffset(len, (sh[6] and sh[6] * k) or th),
                    Rotation = math.deg(math.atan2(dy, dx)),
                    BackgroundColor3 = color,
                    BorderSizePixel = 0,
                }, box)
                round(f, PILL)
                part(f, false)
            end
        end
        local obj = { Frame = box }
        function obj.tint(to, seconds)
            local info = TweenInfo.new(seconds or 0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
            for _, p in ipairs(parts) do
                TweenService:Create(p.Inst, info, p.Stroke and { Color = to } or { BackgroundColor3 = to }):Play()
            end
        end
        return obj
    end

    -- Marca "twin": duas esferas sobrepostas (uma cheia, uma so contorno), desenhada 100% em codigo.
    local function makeLogo(parent, size, pulse)
        local holder = new("Frame", {
            Name = "NDTLogo",
            Size = UDim2.fromOffset(size, size),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
        }, parent)
        local d = math.floor(size * 0.68)
        local solid = new("Frame", {
            Position = UDim2.fromOffset(0, size - d),
            Size = UDim2.fromOffset(d, d),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
        }, holder)
        round(solid, PILL)
        shade(solid, 45, BRAND)
        local ringBall = new("Frame", {
            Position = UDim2.fromOffset(size - d, 0),
            Size = UDim2.fromOffset(d, d),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ZIndex = 2,
        }, holder)
        round(ringBall, PILL)
        outline(ringBall, Theme.Text, math.max(1.25, size * 0.07), 0)

        if pulse then
            local breathe = new("UIScale", { Scale = 1 }, holder)
            TweenService:Create(breathe, TweenInfo.new(2.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
                Scale = 1.045,
            }):Play()
        end
        return holder
    end

    Lib.MakeLogo = function(_, parent, size, pulse)
        return makeLogo(parent, size, pulse)
    end

    local function bind(signal, fn)
        local link = signal:Connect(fn)
        table.insert(conns, link)
        return link
    end

    local function tag()
        return string.char(math.random(97, 122), math.random(97, 122), math.random(97, 122), math.random(97, 122)) .. tostring(math.random(100000, 999999))
    end

    local Root = new("ScreenGui", {
        Name = tag(),
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        AutoLocalize = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 9999,
    })

    do
        local placed = false
        if type(hidegui) == "function" then
            placed = pcall(hidegui, Root)
        end
        if not placed or not Root.Parent then
            Root.Parent = LocalPlayer:WaitForChild("PlayerGui")
        end
        pcall(function()
            UserInputService.MouseIconEnabled = true
        end)
    end

    local TipCard = new("Frame", {
        BackgroundColor3 = Theme.Sunken,
        BorderSizePixel = 0,
        AutomaticSize = Enum.AutomaticSize.XY,
        Size = UDim2.fromOffset(0, 0),
        BackgroundTransparency = 0.02,
        Visible = false,
        ZIndex = 190,
    }, Root)
    round(TipCard, UDim.new(0, 8))
    outline(TipCard, Theme.Line, 1, 0.2)
    pad(TipCard, 12, 12, 8, 8)

    local TipText = new("TextLabel", {
        BackgroundTransparency = 1,
        AutomaticSize = Enum.AutomaticSize.XY,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "",
        ZIndex = 191,
    }, TipCard)

    local NotifyHolder = new("Frame", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -18, 0, 18),
        Size = UDim2.fromOffset(300, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        ZIndex = 180,
    }, Root)
    stack(NotifyHolder, 10)

    local KeybindFrame = new("Frame", {
        Position = UDim2.fromOffset(24, 120),
        Size = UDim2.fromOffset(200, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Theme.Panel,
        BackgroundTransparency = 0.02,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 60,
    }, Root)
    round(KeybindFrame, UDim.new(0, Lib.CornerRadius), true)
    outline(KeybindFrame, Theme.Line, 1, 0.3)
    pad(KeybindFrame, 16, 16, 12, 16)
    stack(KeybindFrame, 8)

    new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 16),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = Theme.Accent,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "Keybinds",
        LayoutOrder = 0,
        ZIndex = 61,
    }, KeybindFrame)

    local KeybindList = new("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = 1,
        ZIndex = 61,
    }, KeybindFrame)
    stack(KeybindList, 4)

    Lib.KeybindFrame = KeybindFrame
    Lib.Root = Root

    local function pointer()
        return UserInputService:GetMouseLocation() + Vector2.new(0, GuiService:GetGuiInset().Y)
    end

    local function attachTip(frame, text)
        if not text or text == "" then
            return
        end
        bind(frame.MouseEnter, function()
            TipText.Text = text
            local at = pointer()
            TipCard.Position = UDim2.fromOffset(at.X + 16, at.Y + 18)
            TipCard.Visible = true
        end)
        bind(frame.MouseMoved, function()
            if TipCard.Visible then
                local at = pointer()
                TipCard.Position = UDim2.fromOffset(at.X + 16, at.Y + 18)
            end
        end)
        bind(frame.MouseLeave, function()
            TipCard.Visible = false
        end)
    end

    function Lib:Notify(payload, seconds)
        local text = payload
        if type(payload) == "table" then
            text = payload.Description or payload.Title or payload.Text or ""
            seconds = seconds or payload.Time
        end

        local card = new("Frame", {
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundColor3 = Theme.Panel,
            BorderSizePixel = 0,
            BackgroundTransparency = 1,
            ZIndex = 181,
        }, NotifyHolder)
        round(card, UDim.new(0, 12))
        local edge = outline(card, Theme.Accent, 1, 1)
        pad(card, 20, 16, 12, 12)

        -- Barra vertical dourada na lateral esquerda do card.
        local bar = new("Frame", {
            AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.new(0, -14, 0.5, 0),
            Size = UDim2.new(0, 3, 1, 4),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
            BackgroundTransparency = 1,
            ZIndex = 182,
        }, card)
        round(bar, PILL)
        shade(bar, 90, BRAND)

        local body = new("TextLabel", {
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamMedium,
            TextSize = 13,
            TextColor3 = Theme.Text,
            TextTransparency = 1,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextWrapped = true,
            Text = tostring(text),
            ZIndex = 182,
        }, card)

        glide(card, { BackgroundTransparency = 0.04 })
        glide(edge, { Transparency = 0.5 })
        glide(bar, { BackgroundTransparency = 0 })
        glide(body, { TextTransparency = 0 })

        task.delay(seconds or 4, function()
            if not card.Parent then
                return
            end
            glide(card, { BackgroundTransparency = 1 })
            glide(edge, { Transparency = 1 })
            glide(bar, { BackgroundTransparency = 1 })
            glide(body, { TextTransparency = 1 })
            task.wait(0.24)
            card:Destroy()
        end)
    end

    function Lib:SetNotifySide(side)
        Lib.NotifySide = side
        if side == "Left" then
            NotifyHolder.AnchorPoint = Vector2.new(0, 0)
            NotifyHolder.Position = UDim2.new(0, 18, 0, 18)
        else
            NotifyHolder.AnchorPoint = Vector2.new(1, 0)
            NotifyHolder.Position = UDim2.new(1, -18, 0, 18)
        end
    end

    local function refreshKeybindList()
        for _, child in ipairs(KeybindList:GetChildren()) do
            if child:IsA("Frame") then
                child:Destroy()
            end
        end
        local order = 0
        for _, picker in ipairs(pickers) do
            if not picker.NoUI and picker.Value and picker.Value ~= "" then
                order = order + 1
                local row = new("Frame", {
                    Size = UDim2.new(1, 0, 0, 20),
                    BackgroundTransparency = 1,
                    LayoutOrder = order,
                    ZIndex = 62,
                }, KeybindList)
                new("TextLabel", {
                    Size = UDim2.new(1, -54, 1, 0),
                    BackgroundTransparency = 1,
                    Font = Enum.Font.GothamMedium,
                    TextSize = 12,
                    TextColor3 = Theme.SubText,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = picker.Label,
                    ZIndex = 62,
                }, row)
                local chip = new("Frame", {
                    AnchorPoint = Vector2.new(1, 0.5),
                    Position = UDim2.new(1, 0, 0.5, 0),
                    Size = UDim2.fromOffset(52, 18),
                    BackgroundColor3 = Theme.Sunken,
                    BorderSizePixel = 0,
                    ZIndex = 62,
                }, row)
                round(chip, UDim.new(0, 7))
                outline(chip, Theme.Line, 1)
                new("TextLabel", {
                    Size = UDim2.fromScale(1, 1),
                    BackgroundTransparency = 1,
                    Font = Enum.Font.GothamBold,
                    TextSize = 10,
                    TextColor3 = Theme.Accent,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = picker.Value,
                    ZIndex = 63,
                }, chip)
            end
        end
    end

    local function dragify(handle, target)
        local holding, origin, base, goal, follower = false, nil, nil, nil, nil

        -- Segue o alvo com suavizacao exponencial (independente do FPS),
        -- em vez de teleportar a janela a cada evento do mouse.
        local function follow()
            if follower then
                return
            end
            follower = RunService.RenderStepped:Connect(function(dt)
                if Lib.Unloaded or not target.Parent or not goal then
                    follower:Disconnect()
                    follower = nil
                    return
                end
                local cur = target.Position
                local dx = goal.X.Offset - cur.X.Offset
                local dy = goal.Y.Offset - cur.Y.Offset
                if math.abs(dx) + math.abs(dy) <= 1.5 then
                    target.Position = goal
                    if not holding then
                        follower:Disconnect()
                        follower = nil
                    end
                    return
                end
                local alpha = 1 - math.exp(-dt * 26)
                target.Position = UDim2.new(
                    goal.X.Scale, math.round(cur.X.Offset + dx * alpha),
                    goal.Y.Scale, math.round(cur.Y.Offset + dy * alpha)
                )
            end)
        end

        bind(handle.InputBegan, function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                holding = true
                origin = input.Position
                base = target.Position
                goal = base
            end
        end)
        bind(handle.InputEnded, function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                holding = false
            end
        end)
        bind(UserInputService.InputChanged, function(input)
            if not holding then
                return
            end
            if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
                local shift = input.Position - origin
                goal = UDim2.new(base.X.Scale, base.X.Offset + shift.X, base.Y.Scale, base.Y.Offset + shift.Y)
                follow()
            end
        end)
    end

    dragify(KeybindFrame, KeybindFrame)

    -- Scroll suave dos paineis.
    -- Toque (Android/Delta): o ScrollingFrame ja tem inercia e "elastico" nativos (ElasticBehavior).
    -- Mouse (dispositivo sem toque): a roda anima o CanvasPosition com Heartbeat, ligado so enquanto se move.
    local hoverList = nil
    local function smoothScroll(scroll, isShown)
        scroll.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
        if UserInputService.TouchEnabled or not SMOOTH_WHEEL then
            return
        end
        scroll.ScrollingEnabled = false

        local target, loop = 0, nil
        local function halt()
            if loop then
                loop:Disconnect()
                loop = nil
            end
        end

        bind(UserInputService.InputChanged, function(input)
            if input.UserInputType ~= Enum.UserInputType.MouseWheel or hoverList or Lib.Unloaded then
                return
            end
            if not isShown() then
                return
            end
            local px, py = input.Position.X, input.Position.Y
            if px == 0 and py == 0 then
                local at = UserInputService:GetMouseLocation()
                px, py = at.X, at.Y
            end
            local pos, size = scroll.AbsolutePosition, scroll.AbsoluteSize
            if px < pos.X or px > pos.X + size.X or py < pos.Y or py > pos.Y + size.Y then
                return
            end
            local limit = math.max(0, scroll.AbsoluteCanvasSize.Y - scroll.AbsoluteWindowSize.Y)
            if limit <= 0 then
                return
            end
            local from = loop and target or scroll.CanvasPosition.Y
            target = math.clamp(from - input.Position.Z * 88, 0, limit)
            if loop then
                return
            end
            loop = RunService.Heartbeat:Connect(function(dt)
                if Lib.Unloaded or not scroll.Parent then
                    halt()
                    return
                end
                local cur = scroll.CanvasPosition.Y
                local diff = target - cur
                if math.abs(diff) < 0.5 then
                    scroll.CanvasPosition = Vector2.new(0, target)
                    halt()
                    return
                end
                scroll.CanvasPosition = Vector2.new(0, cur + diff * (1 - math.exp(-16 * math.min(dt, 0.05))))
            end)
        end)
    end

    local function makeGroup(holder)
        local Group = { Holder = holder, Order = 0 }

        local function slot(height, auto)
            Group.Order = Group.Order + 1
            local frame = new("Frame", {
                Size = UDim2.new(1, 0, 0, height or 0),
                BackgroundTransparency = 1,
                LayoutOrder = Group.Order,
            }, holder)
            if auto then
                frame.AutomaticSize = Enum.AutomaticSize.Y
            end
            return frame
        end

        local function caption(parent, text)
            return new("TextLabel", {
                Size = UDim2.new(1, 0, 0, 14),
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextColor3 = Theme.SubText,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Text = text,
                LayoutOrder = 0,
            }, parent)
        end

        function Group:AddToggle(index, opts)
            opts = opts or {}
            local row = slot(46)
            if opts.Hidden then
                row.Visible = false
            end

            -- Realce de hover: estende 8px para fora da linha (o texto continua alinhado com os outros itens).
            local hoverBg = new("Frame", {
                Position = UDim2.fromOffset(-8, 0),
                Size = UDim2.new(1, 16, 1, 0),
                BackgroundColor3 = Theme.Raised,
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
            }, row)
            round(hoverBg, UDim.new(0, 8))

            -- Marca fina de destaque na margem: cresce quando o toggle liga.
            local tick = new("Frame", {
                AnchorPoint = Vector2.new(0, 0.5),
                Position = UDim2.new(0, -8, 0.5, 0),
                Size = UDim2.fromOffset(2, 0),
                BackgroundColor3 = Color3.new(1, 1, 1),
                BorderSizePixel = 0,
            }, row)
            round(tick, PILL)
            shade(tick, 90, BRAND)

            local label = new("TextLabel", {
                Position = UDim2.fromOffset(0, 2),
                Size = UDim2.new(1, -52, 0, 18),
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamBold,
                TextSize = 13,
                TextColor3 = Theme.Text,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Text = opts.Text or index,
            }, row)
            if opts.Description or opts.Desc then
                new("TextLabel", {
                    Position = UDim2.fromOffset(0, 21),
                    Size = UDim2.new(1, -52, 0, 17),
                    BackgroundTransparency = 1,
                    Font = Enum.Font.Gotham,
                    TextSize = 10,
                    TextColor3 = Theme.Faint,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = opts.Description or opts.Desc,
                }, row)
            end

            local box = Lib.ForceCheckbox
            local track = new("Frame", {
                AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1, 0, 0, 13),
                Size = box and UDim2.fromOffset(16, 16) or UDim2.fromOffset(34, 18),
                BackgroundColor3 = Theme.Raised,
                BorderSizePixel = 0,
            }, row)
            round(track, box and UDim.new(0, 4) or PILL)
            local edge = outline(track, Theme.Line, 1, 0.5)

            -- Preenchimento em gradiente (brasa -> ambar) que aparece suavemente quando o toggle liga.
            local fillOn = new("Frame", {
                Size = UDim2.fromScale(1, 1),
                BackgroundColor3 = Color3.new(1, 1, 1),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
            }, track)
            round(fillOn, box and UDim.new(0, 4) or PILL)
            shade(fillOn, 0, BRAND)

            local knob = new("Frame", {
                Position = box and UDim2.fromOffset(4, 4) or UDim2.fromOffset(3, 3),
                Size = box and UDim2.fromOffset(8, 8) or UDim2.fromOffset(12, 12),
                BackgroundColor3 = Theme.SubText,
                BorderSizePixel = 0,
            }, track)
            round(knob, box and UDim.new(0, 2) or PILL)

            local hit = new("TextButton", {
                Position = UDim2.fromOffset(-8, 0),
                Size = UDim2.new(1, 16, 1, 0),
                BackgroundTransparency = 1,
                Text = "",
                AutoButtonColor = false,
            }, row)
            attachTip(hit, opts.Tooltip)
            bind(hit.MouseEnter, function()
                glide(hoverBg, { BackgroundTransparency = 0.5 })
            end)
            bind(hit.MouseLeave, function()
                glide(hoverBg, { BackgroundTransparency = 1 })
            end)

            local Toggle = { Value = false, Type = "Toggle", Index = index, Callbacks = {} }

            local function paint()
                if Toggle.Value then
                    glide(track, { BackgroundColor3 = Theme.Accent })
                    glide(fillOn, { BackgroundTransparency = 0 })
                    glide(edge, { Transparency = 1 })
                    glide(knob, { BackgroundColor3 = Theme.OnAccent })
                    glide(label, { TextColor3 = Theme.Text })
                    ease(tick, { Size = UDim2.fromOffset(2, 14) }, 0.24, Enum.EasingStyle.Quint)
                    if not box then
                        ease(knob, { Position = UDim2.fromOffset(19, 3) }, 0.34, Enum.EasingStyle.Back)
                    end
                else
                    glide(track, { BackgroundColor3 = Theme.Raised })
                    glide(fillOn, { BackgroundTransparency = 1 })
                    glide(edge, { Transparency = 0.5 })
                    glide(knob, { BackgroundColor3 = Theme.SubText })
                    glide(label, { TextColor3 = Theme.SubText })
                    ease(tick, { Size = UDim2.fromOffset(2, 0) }, 0.18, Enum.EasingStyle.Quint)
                    if not box then
                        ease(knob, { Position = UDim2.fromOffset(3, 3) }, 0.2, Enum.EasingStyle.Quint)
                    end
                end
            end

            function Toggle:SetValue(value, silent)
                Toggle.Value = value and true or false
                paint()
                if silent then
                    return
                end
                if opts.Callback then
                    task.spawn(opts.Callback, Toggle.Value)
                end
                for _, fn in ipairs(Toggle.Callbacks) do
                    task.spawn(fn, Toggle.Value)
                end
            end

            function Toggle:OnChanged(fn)
                table.insert(Toggle.Callbacks, fn)
                task.spawn(fn, Toggle.Value)
                return Toggle
            end

            bind(hit.MouseButton1Click, function()
                Toggle:SetValue(not Toggle.Value)
            end)

            Toggle:SetValue(opts.Default and true or false, true)
            if opts.Default then
                if opts.Callback then
                    task.spawn(opts.Callback, true)
                end
            end

            Lib.Toggles[index] = Toggle
            return Toggle
        end

        function Group:AddSlider(index, opts)
            opts = opts or {}
            local wrap = slot(62)
            attachTip(wrap, opts.Tooltip)

            local label = new("TextLabel", {
                Size = UDim2.new(1, -64, 0, 18),
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamBold,
                TextSize = 13,
                TextColor3 = Theme.Text,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Text = opts.Text or index,
            }, wrap)

            if opts.Description or opts.Desc then
                new("TextLabel", {
                    Position = UDim2.fromOffset(0, 18),
                    Size = UDim2.new(1, 0, 0, 15),
                    BackgroundTransparency = 1,
                    Font = Enum.Font.Gotham,
                    TextSize = 10,
                    TextColor3 = Theme.Faint,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = opts.Description or opts.Desc,
                }, wrap)
            end

            -- Valor numerico em fonte mono, sem caixa, alinhado a direita.
            local readout = new("TextLabel", {
                AnchorPoint = Vector2.new(1, 0),
                Position = UDim2.new(1, 0, 0, 0),
                Size = UDim2.fromOffset(0, 18),
                AutomaticSize = Enum.AutomaticSize.X,
                BackgroundTransparency = 1,
                Font = MONO,
                TextSize = 12,
                TextColor3 = Theme.Accent,
                Text = "0",
            }, wrap)

            -- "track" e a area de toque (20px de altura); a barra fina visivel fica dentro dela.
            local track = new("Frame", {
                Position = UDim2.new(0, 0, 0, 39),
                Size = UDim2.new(1, 0, 0, 20),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
            }, wrap)

            local rail = new("Frame", {
                AnchorPoint = Vector2.new(0, 0.5),
                Position = UDim2.new(0, 0, 0.5, 0),
                Size = UDim2.new(1, 0, 0, 4),
                BackgroundColor3 = Theme.Raised,
                BorderSizePixel = 0,
            }, track)
            round(rail, PILL)

            local fill = new("Frame", {
                Size = UDim2.new(0, 0, 1, 0),
                BackgroundColor3 = Color3.new(1, 1, 1),
                BorderSizePixel = 0,
            }, rail)
            round(fill, PILL)
            shade(fill, 0, BRAND)

            local knob = new("Frame", {
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.new(0, 0, 0.5, 0),
                Size = UDim2.fromOffset(10, 10),
                BackgroundColor3 = Theme.Text,
                BorderSizePixel = 0,
                ZIndex = 3,
            }, track)
            round(knob, PILL)
            outline(knob, Theme.Accent, 2)

            local minimum = opts.Min or 0
            local maximum = opts.Max or 100
            local digits = opts.Rounding or 0
            local step = 10 ^ digits

            local Slider = { Value = opts.Default or minimum, Type = "Slider", Index = index, Min = minimum, Max = maximum, Callbacks = {} }

            local function paint()
                local span = maximum - minimum
                local ratio = span > 0 and math.clamp((Slider.Value - minimum) / span, 0, 1) or 0
                ease(fill, { Size = UDim2.new(ratio, 0, 1, 0) }, 0.14, Enum.EasingStyle.Quart)
                ease(knob, { Position = UDim2.new(ratio, 0, 0.5, 0) }, 0.14, Enum.EasingStyle.Quart)
                readout.Text = tostring(Slider.Value) .. (opts.Suffix or "")
            end

            function Slider:SetValue(value, silent)
                value = tonumber(value) or minimum
                value = math.clamp(value, minimum, maximum)
                value = math.floor(value * step + 0.5) / step
                Slider.Value = value
                paint()
                if silent then
                    return
                end
                if opts.Callback then
                    task.spawn(opts.Callback, value)
                end
                for _, fn in ipairs(Slider.Callbacks) do
                    task.spawn(fn, value)
                end
            end

            function Slider:OnChanged(fn)
                table.insert(Slider.Callbacks, fn)
                task.spawn(fn, Slider.Value)
                return Slider
            end

            local sliding = false

            local function seek(x)
                local width = track.AbsoluteSize.X
                if width <= 0 then
                    return
                end
                local ratio = math.clamp((x - track.AbsolutePosition.X) / width, 0, 1)
                Slider:SetValue(minimum + (maximum - minimum) * ratio)
            end

            bind(track.InputBegan, function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                    sliding = true
                    glide(knob, { Size = UDim2.fromOffset(14, 14) })
                    seek(input.Position.X)
                end
            end)
            bind(UserInputService.InputEnded, function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                    if sliding then
                        sliding = false
                        glide(knob, { Size = UDim2.fromOffset(10, 10) })
                    end
                end
            end)
            bind(UserInputService.InputChanged, function(input)
                if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                    seek(input.Position.X)
                end
            end)

            Slider:SetValue(opts.Default or minimum, true)
            if opts.Default ~= nil and opts.Callback then
                task.spawn(opts.Callback, Slider.Value)
            end

            Lib.Options[index] = Slider
            return Slider
        end

        function Group:AddDropdown(index, opts)
            opts = opts or {}
            local wrap = slot(0, true)
            stack(wrap, 6)
            attachTip(wrap, opts.Tooltip)

            caption(wrap, opts.Text or index)

            local button = new("TextButton", {
                Size = UDim2.new(1, 0, 0, 34),
                BackgroundColor3 = Theme.Raised,
                BorderSizePixel = 0,
                Font = UI_FONT,
                TextSize = 13,
                TextColor3 = Theme.Text,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Text = "",
                AutoButtonColor = false,
                LayoutOrder = 1,
            }, wrap)
            round(button, UDim.new(0, 8))
            local edge = outline(button, Theme.Line, 1, 0.5)
            pad(button, 12, 32, 0, 0)
            bind(button.MouseEnter, function()
                glide(button, { BackgroundColor3 = Theme.Line })
            end)
            bind(button.MouseLeave, function()
                glide(button, { BackgroundColor3 = Theme.Raised })
            end)

            -- Seta fina (o padding direito do botao desloca a origem, por isso o +20).
            local arrow = new("TextLabel", {
                AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1, 20, 0.5, 0),
                Size = UDim2.fromOffset(12, 12),
                BackgroundTransparency = 1,
                Font = Enum.Font.Gotham,
                TextSize = 14,
                TextColor3 = Theme.SubText,
                Text = ">",
                Rotation = 90,
            }, button)

            local panel = new("Frame", {
                Size = UDim2.new(1, 0, 0, 0),
                BackgroundColor3 = Theme.Raised,
                BorderSizePixel = 0,
                Visible = false,
                LayoutOrder = 2,
                ClipsDescendants = true,
            }, wrap)
            round(panel, UDim.new(0, 8))
            outline(panel, Theme.Line, 1, 0.5)

            local scroll = new("ScrollingFrame", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                CanvasSize = UDim2.new(),
                AutomaticCanvasSize = Enum.AutomaticSize.Y,
                ScrollBarThickness = 3,
                ScrollBarImageColor3 = Theme.Accent,
                ScrollBarImageTransparency = 0.5,
                ScrollingDirection = Enum.ScrollingDirection.Y,
            }, panel)
            stack(scroll, 2)
            pad(scroll, 6, 8, 6, 6)

            -- Enquanto o mouse esta sobre a lista aberta, a roda rola a lista (nao a pagina).
            bind(panel.MouseEnter, function()
                hoverList = panel
            end)
            bind(panel.MouseLeave, function()
                if hoverList == panel then
                    hoverList = nil
                end
            end)

            local Dropdown = { Value = nil, Type = "Dropdown", Index = index, Values = opts.Values or {}, Callbacks = {}, Open = false }
            local rows = {}

            local function paint()
                button.Text = tostring(Dropdown.Value or "--")
                for value, row in pairs(rows) do
                    if value == Dropdown.Value then
                        glide(row.Frame, { BackgroundColor3 = Theme.Accent, BackgroundTransparency = 0.84 })
                        glide(row.Edge, { Transparency = 0.45, Color = Theme.Accent })
                        glide(row.Label, { TextColor3 = Theme.Accent })
                    else
                        glide(row.Frame, { BackgroundColor3 = Theme.Accent, BackgroundTransparency = 1 })
                        glide(row.Edge, { Transparency = 1, Color = Theme.Line })
                        glide(row.Label, { TextColor3 = Theme.SubText })
                    end
                end
            end

            function Dropdown:SetValue(value, silent)
                Dropdown.Value = value
                paint()
                if silent then
                    return
                end
                if opts.Callback then
                    task.spawn(opts.Callback, value)
                end
                for _, fn in ipairs(Dropdown.Callbacks) do
                    task.spawn(fn, value)
                end
            end

            function Dropdown:OnChanged(fn)
                table.insert(Dropdown.Callbacks, fn)
                task.spawn(fn, Dropdown.Value)
                return Dropdown
            end

            local function collapse()
                Dropdown.Open = false
                panel.Visible = false
                panel.Size = UDim2.new(1, 0, 0, 0)
                if hoverList == panel then
                    hoverList = nil
                end
                glide(arrow, { Rotation = 90 })
                glide(edge, { Color = Theme.Line })
            end

            function Dropdown:SetValues(values)
                Dropdown.Values = values or {}
                rows = {}
                for _, child in ipairs(scroll:GetChildren()) do
                    if child:IsA("TextButton") then
                        child:Destroy()
                    end
                end
                for order, value in ipairs(Dropdown.Values) do
                    local entry = new("TextButton", {
                        Size = UDim2.new(1, 0, 0, 28),
                        BackgroundColor3 = Theme.Accent,
                        BackgroundTransparency = 1,
                        BorderSizePixel = 0,
                        Font = Enum.Font.GothamMedium,
                        TextSize = 13,
                        TextColor3 = Theme.SubText,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        TextTruncate = Enum.TextTruncate.AtEnd,
                        Text = "",
                        AutoButtonColor = false,
                        LayoutOrder = order,
                    }, scroll)
                    round(entry, UDim.new(0, 8))
                    local entryEdge = outline(entry, Theme.Accent, 1, 1)
                    local entryLabel = new("TextLabel", {
                        Size = UDim2.new(1, -24, 1, 0),
                        Position = UDim2.fromOffset(12, 0),
                        BackgroundTransparency = 1,
                        Font = Enum.Font.GothamMedium,
                        TextSize = 13,
                        TextColor3 = Theme.SubText,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        TextTruncate = Enum.TextTruncate.AtEnd,
                        Text = tostring(value),
                    }, entry)
                    rows[value] = { Frame = entry, Edge = entryEdge, Label = entryLabel }
                    bind(entry.MouseButton1Click, function()
                        Dropdown:SetValue(value)
                        collapse()
                    end)
                    bind(entry.MouseEnter, function()
                        if Dropdown.Value ~= value then
                            glide(entry, { BackgroundColor3 = Theme.Line, BackgroundTransparency = 0.5 })
                            glide(entryLabel, { TextColor3 = Theme.Text })
                        end
                    end)
                    bind(entry.MouseLeave, function()
                        if Dropdown.Value ~= value then
                            glide(entry, { BackgroundColor3 = Theme.Accent, BackgroundTransparency = 1 })
                            glide(entryLabel, { TextColor3 = Theme.SubText })
                        end
                    end)
                end
                paint()
            end

            bind(button.MouseButton1Click, function()
                Dropdown.Open = not Dropdown.Open
                if Dropdown.Open then
                    local height = math.clamp(#Dropdown.Values * 30 + 12, 40, 184)
                    panel.Visible = true
                    panel.Size = UDim2.new(1, 0, 0, 0)
                    ease(panel, { Size = UDim2.new(1, 0, 0, height) }, 0.26, Enum.EasingStyle.Quint)
                    glide(arrow, { Rotation = 270 })
                    glide(edge, { Color = Theme.Accent })
                else
                    collapse()
                end
            end)

            Dropdown:SetValues(opts.Values or {})
            Dropdown:SetValue(opts.Default, true)
            if opts.Default ~= nil and opts.Callback then
                task.spawn(opts.Callback, opts.Default)
            end

            Lib.Options[index] = Dropdown
            return Dropdown
        end

        function Group:AddInput(index, opts)
            opts = opts or {}
            local wrap = slot(0, true)
            stack(wrap, 6)
            attachTip(wrap, opts.Tooltip)

            caption(wrap, opts.Text or index)

            local field = new("TextBox", {
                Size = UDim2.new(1, 0, 0, 34),
                BackgroundColor3 = Theme.Raised,
                BorderSizePixel = 0,
                Font = UI_FONT,
                TextSize = 13,
                TextColor3 = Theme.Text,
                PlaceholderColor3 = Theme.Faint,
                PlaceholderText = opts.Placeholder or "",
                TextXAlignment = Enum.TextXAlignment.Left,
                ClearTextOnFocus = false,
                Text = opts.Default or "",
                LayoutOrder = 1,
            }, wrap)
            round(field, UDim.new(0, 8))
            local edge = outline(field, Theme.Line, 1, 0.6)
            pad(field, 12, 12, 0, 0)

            local Input = { Value = opts.Default or "", Type = "Input", Index = index, Callbacks = {} }

            local function push(value)
                Input.Value = value
                if opts.Callback then
                    task.spawn(opts.Callback, value)
                end
                for _, fn in ipairs(Input.Callbacks) do
                    task.spawn(fn, value)
                end
            end

            function Input:SetValue(value, silent)
                value = tostring(value or "")
                field.Text = value
                if silent then
                    Input.Value = value
                    return
                end
                push(value)
            end

            function Input:OnChanged(fn)
                table.insert(Input.Callbacks, fn)
                task.spawn(fn, Input.Value)
                return Input
            end

            bind(field.Focused, function()
                glide(edge, { Color = Theme.Accent, Transparency = 0 })
            end)

            bind(field.FocusLost, function()
                glide(edge, { Color = Theme.Line, Transparency = 0.6 })
                local value = field.Text
                if opts.Numeric and value ~= "" and not tonumber(value) then
                    field.Text = Input.Value
                    return
                end
                push(value)
            end)

            if not opts.Finished then
                bind(field:GetPropertyChangedSignal("Text"), function()
                    if field:IsFocused() then
                        local value = field.Text
                        if opts.Numeric and value ~= "" and not tonumber(value) then
                            return
                        end
                        push(value)
                    end
                end)
            end

            Lib.Options[index] = Input
            return Input
        end

        function Group:AddButton(a, b)
            local text, action
            if type(a) == "table" then
                text = a.Text
                action = a.Func or a.Callback
            else
                text = a
                action = b
            end

            local wrap = slot(34)
            local button = new("TextButton", {
                Size = UDim2.fromScale(1, 1),
                BackgroundColor3 = Theme.Raised,
                BorderSizePixel = 0,
                Font = Enum.Font.GothamBold,
                TextSize = 12,
                TextColor3 = Theme.Text,
                Text = text or "Button",
                AutoButtonColor = false,
            }, wrap)
            round(button, UDim.new(0, 8))
            local edge = outline(button, Theme.Line, 1, 0.5)
            local press = new("UIScale", { Scale = 1 }, button)
            local hovering = false

            -- Hover: o fundo clareia e o texto vai para o destaque. Clique: pulso na cor de destaque que relaxa
            -- de volta ao estado de hover, com leve escala de pressao.
            bind(button.MouseEnter, function()
                hovering = true
                glide(button, { BackgroundColor3 = Theme.Line, TextColor3 = Theme.Accent })
                glide(edge, { Color = Theme.Accent, Transparency = 0.6 })
            end)
            bind(button.MouseLeave, function()
                hovering = false
                glide(button, { BackgroundColor3 = Theme.Raised, TextColor3 = Theme.Text })
                glide(edge, { Color = Theme.Line, Transparency = 0.5 })
                ease(press, { Scale = 1 }, 0.18)
            end)
            bind(button.MouseButton1Down, function()
                ease(press, { Scale = 0.97 }, 0.1)
            end)
            bind(button.MouseButton1Up, function()
                ease(press, { Scale = 1 }, 0.2)
            end)
            bind(button.MouseButton1Click, function()
                button.BackgroundColor3 = Theme.Accent
                button.TextColor3 = Theme.OnAccent
                ease(button, {
                    BackgroundColor3 = hovering and Theme.Line or Theme.Raised,
                    TextColor3 = hovering and Theme.Accent or Theme.Text,
                }, 0.4, Enum.EasingStyle.Quint)
                if action then
                    task.spawn(action)
                end
            end)

            local Button = { Instance = button }
            function Button:SetText(value)
                button.Text = value
            end
            return Button
        end

        function Group:AddDivider()
            local wrap = slot(10)
            local line = new("Frame", {
                AnchorPoint = Vector2.new(0, 0.5),
                Position = UDim2.new(0, 0, 0.5, 0),
                Size = UDim2.new(1, 0, 0, 1),
                BackgroundColor3 = Theme.Line,
                BorderSizePixel = 0,
            }, wrap)
            shade(line, 0, ColorSequence.new(Color3.new(1, 1, 1)), NumberSequence.new({
                NumberSequenceKeypoint.new(0, 1),
                NumberSequenceKeypoint.new(0.5, 0.15),
                NumberSequenceKeypoint.new(1, 1),
            }))
            return { Instance = line }
        end

        function Group:AddLabel(text, wrapped)
            local wrap = slot(0, true)

            local label = new("TextLabel", {
                Size = UDim2.new(1, 0, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamMedium,
                TextSize = 13,
                TextColor3 = Theme.SubText,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextWrapped = wrapped and true or false,
                Text = text or "",
            }, wrap)

            local Label = { Instance = label }

            function Label:SetText(value)
                label.Text = value
                return Label
            end

            function Label:AddKeyPicker(index, opts)
                opts = opts or {}
                label.Size = UDim2.new(1, -66, 0, 0)

                local chip = new("TextButton", {
                    AnchorPoint = Vector2.new(1, 0),
                    Position = UDim2.new(1, 0, 0, 0),
                    Size = UDim2.fromOffset(62, 22),
                    BackgroundColor3 = Theme.Raised,
                    BorderSizePixel = 0,
                    Font = MONO,
                    TextSize = 12,
                    TextColor3 = Theme.Accent,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = "",
                    AutoButtonColor = false,
                }, wrap)
                round(chip, UDim.new(0, 8))
                local edge = outline(chip, Theme.Line, 1)

                local Picker = {
                    Value = opts.Default or "",
                    Mode = opts.Mode or "Toggle",
                    Type = "KeyPicker",
                    Index = index,
                    Label = opts.Text or text or index,
                    NoUI = opts.NoUI and true or false,
                    Active = false,
                    Callbacks = {},
                    Listening = false,
                }

                local function paint()
                    chip.Text = Picker.Listening and "..." or (Picker.Value ~= "" and Picker.Value or "None")
                    glide(edge, { Color = Picker.Listening and Theme.Accent or Theme.Line })
                end

                function Picker:SetValue(value, silent)
                    if type(value) == "table" then
                        Picker.Mode = value[2] or Picker.Mode
                        value = value[1]
                    end
                    Picker.Value = tostring(value or "")
                    paint()
                    refreshKeybindList()
                    if not silent then
                        for _, fn in ipairs(Picker.Callbacks) do
                            task.spawn(fn, Picker.Value)
                        end
                    end
                end

                function Picker:OnChanged(fn)
                    table.insert(Picker.Callbacks, fn)
                    return Picker
                end

                function Picker:GetState()
                    return Picker.Active
                end

                bind(chip.MouseButton1Click, function()
                    Picker.Listening = true
                    paint()
                end)

                bind(UserInputService.InputBegan, function(input, processed)
                    if Picker.Listening then
                        if input.UserInputType == Enum.UserInputType.Keyboard then
                            Picker.Listening = false
                            if input.KeyCode == Enum.KeyCode.Backspace then
                                Picker:SetValue("")
                            else
                                Picker:SetValue(input.KeyCode.Name)
                            end
                        end
                        return
                    end
                    if processed or Picker.Value == "" then
                        return
                    end
                    if UserInputService:GetFocusedTextBox() then
                        return
                    end
                    if input.UserInputType ~= Enum.UserInputType.Keyboard then
                        return
                    end
                    if input.KeyCode.Name ~= Picker.Value then
                        return
                    end
                    if Picker.Mode == "Toggle" then
                        Picker.Active = not Picker.Active
                    else
                        Picker.Active = true
                    end
                    if opts.Callback then
                        task.spawn(opts.Callback, Picker.Active)
                    end
                end)

                bind(UserInputService.InputEnded, function(input)
                    if Picker.Mode == "Hold" and input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode.Name == Picker.Value then
                        Picker.Active = false
                        if opts.Callback then
                            task.spawn(opts.Callback, false)
                        end
                    end
                end)

                table.insert(pickers, Picker)
                Picker:SetValue(opts.Default or "", true)
                Lib.Options[index] = Picker
                return Picker
            end

            return Label
        end

        return Group
    end

    local Shell, Scale, TabRail, PageHolder, ActiveTab

    function Lib:CreateWindow(config)
        config = config or {}

        local SHELL_ALPHA = 0.04
        -- Cor do "veu" usado nas transicoes: igual ao fundo da janela, assim o conteudo parece emergir do fundo.
        local VEIL = Theme.Shell
        local SLIDE = 28
        local openedAt = os.clock()

        Shell = new("Frame", {
            Name = tag(),
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(WIN_W, WIN_H),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BackgroundTransparency = SHELL_ALPHA,
            BorderSizePixel = 0,
            ClipsDescendants = true,
            Visible = false,
        }, Root)
        round(Shell, UDim.new(0, 8), true)
        -- Contorno "Ember Grid": linha fina com as pontas acesas (brasa -> ambar -> menta) e o meio apagado; gira devagar (pausa quando a janela esta oculta).
        local shellEdge = outline(Shell, Color3.new(1, 1, 1), 1.5, 0)
        local edgeGrad = new("UIGradient", {
            Rotation = 0,
            Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, Theme.Accent),
                ColorSequenceKeypoint.new(0.5, Theme.Accent2),
                ColorSequenceKeypoint.new(1, Theme.Accent3),
            }),
            Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.05),
                NumberSequenceKeypoint.new(0.5, 0.8),
                NumberSequenceKeypoint.new(1, 0.05),
            }),
        }, shellEdge)
        local edgeSpin = TweenService:Create(edgeGrad, TweenInfo.new(9, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1), { Rotation = 360 })
        Scale = new("UIScale", { Scale = 1 }, Shell)
        new("UIGradient", {
            Rotation = 115,
            Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, Theme.ShellTop),
                ColorSequenceKeypoint.new(0.55, Theme.Shell),
                ColorSequenceKeypoint.new(1, Color3.fromRGB(10, 15, 19)),
            }),
        }, Shell)

        -- Etiqueta "hazard" (listras brasa/ink) no canto superior esquerdo da janela.
        new("UIGradient", {
            Rotation = 35,
            Color = (function()
                local keys, total = {}, 8
                for i = 0, total - 1 do
                    local c = (i % 2 == 0) and Theme.Accent or Theme.Shell
                    keys[#keys + 1] = ColorSequenceKeypoint.new(i == 0 and 0 or (i / total + 0.001), c)
                    keys[#keys + 1] = ColorSequenceKeypoint.new(i == total - 1 and 1 or ((i + 1) / total), c)
                end
                return ColorSequence.new(keys)
            end)(),
        }, new("Frame", {
            Name = "HazardTab",
            Size = UDim2.fromOffset(64, 4),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
            ZIndex = 8,
        }, Shell))

        local function targetScale()
            local view = Root.AbsoluteSize
            if view.X < 1 or view.Y < 1 then
                local camera = workspace.CurrentCamera
                view = camera and camera.ViewportSize or Vector2.new(1280, 720)
            end
            local fit = math.min(1, (view.X - 24) / WIN_W, (view.Y - 24) / WIN_H)
            return math.clamp(math.min(Lib.DPI or 1, fit), 0.35, 2)
        end
        -- Durante o "pop" de abertura a escala e animada; o refit so volta a valer quando ele termina.
        local popping, popStamp = false, 0
        local function refit()
            if not Scale or popping then return end
            Scale.Scale = targetScale()
        end
        Lib.Refit = refit
        bind(Root:GetPropertyChangedSignal("AbsoluteSize"), refit)
        task.defer(refit)

        ---------------------------------------------------------------- cabecalho
        -- Brilho suave de brasa no topo da janela (atras de tudo).
        local headGlow = new("Frame", {
            Size = UDim2.new(1, 0, 0, 96),
            BackgroundColor3 = Theme.Accent,
            BackgroundTransparency = 0.91,
            BorderSizePixel = 0,
        }, Shell)
        shade(headGlow, 90, nil, NumberSequence.new(0, 1))

        local top = new("Frame", {
            Size = UDim2.new(1, 0, 0, HEAD_H),
            BackgroundTransparency = 1,
        }, Shell)
        dragify(top, Shell)

        -- Linha de destaque sob o cabecalho, com um brilho que vai e volta.
        local headLine = new("Frame", {
            Position = UDim2.fromOffset(0, HEAD_H - 1),
            Size = UDim2.new(1, 0, 0, 1),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
            ZIndex = 5,
        }, Shell)
        local headLineGrad = shade(headLine, 0, BRAND3, NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(0.14, 0.3),
            NumberSequenceKeypoint.new(0.86, 0.3),
            NumberSequenceKeypoint.new(1, 1),
        }))
        headLineGrad.Offset = Vector2.new(-0.35, 0)
        local lineSweep = TweenService:Create(headLineGrad, TweenInfo.new(3.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
            Offset = Vector2.new(0.35, 0),
        })

        -- Marca: duas esferas sobrepostas ("twin") + nome + contexto em cinza.
        local brand = new("Frame", {
            Position = UDim2.fromOffset(18, 0),
            Size = UDim2.new(0, 0, 1, 0),
            AutomaticSize = Enum.AutomaticSize.X,
            BackgroundTransparency = 1,
        }, top)
        local brandList = stack(brand, 9, Enum.FillDirection.Horizontal)
        brandList.VerticalAlignment = Enum.VerticalAlignment.Center

        local logo = makeLogo(brand, 24, true)
        logo.LayoutOrder = 1

        local brandName = new("TextLabel", {
            LayoutOrder = 2,
            Size = UDim2.fromOffset(0, 18),
            AutomaticSize = Enum.AutomaticSize.X,
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBlack,
            TextSize = 15,
            TextColor3 = Color3.new(1, 1, 1),
            Text = config.Title or "Menu",
        }, brand)
        shade(brandName, 0, ColorSequence.new(Color3.new(1, 1, 1), Theme.Glow))

        if config.Footer and config.Footer ~= "" then
            local sep = new("Frame", {
                LayoutOrder = 3,
                Size = UDim2.fromOffset(3, 3),
                BackgroundColor3 = Theme.Faint,
                BorderSizePixel = 0,
            }, brand)
            round(sep, PILL)
            new("TextLabel", {
                LayoutOrder = 4,
                Size = UDim2.fromOffset(0, 16),
                AutomaticSize = Enum.AutomaticSize.X,
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamMedium,
                TextSize = 11,
                TextColor3 = Theme.Faint,
                Text = config.Footer,
            }, brand)
        end

        -- Subtitulo da pagina atual, a direita (troca com deslize + fade a cada aba).
        local SUB_HOME = UDim2.new(1, -86, 0.5, 0)
        local pageSub = new("TextLabel", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = SUB_HOME,
            Size = UDim2.fromOffset(300, 16),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamMedium,
            TextSize = 11,
            TextColor3 = Theme.Faint,
            TextXAlignment = Enum.TextXAlignment.Right,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Text = "",
        }, top)

        local function setSubtitle(text, dir)
            pageSub.Text = text
            if dir == 0 then
                pageSub.TextTransparency = 0
                pageSub.Position = SUB_HOME
                return
            end
            pageSub.TextTransparency = 1
            pageSub.Position = SUB_HOME + UDim2.fromOffset(dir * 10, 0)
            ease(pageSub, { TextTransparency = 0, Position = SUB_HOME }, 0.34, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, 0.06)
        end

        -- Fechar: X de duas barras finas, sem contorno (so ganha fundo no hover).
        local hideButton = new("TextButton", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -16, 0.5, 0),
            Size = UDim2.fromOffset(26, 26),
            BackgroundColor3 = Theme.Raised,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Text = "",
            AutoButtonColor = false,
        }, top)
        round(hideButton, UDim.new(0, 8))
        local hideBars = {}
        for _, rot in ipairs({ 45, -45 }) do
            local bar = new("Frame", {
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.fromScale(0.5, 0.5),
                Size = UDim2.fromOffset(11, 1.5),
                Rotation = rot,
                BackgroundColor3 = Theme.SubText,
                BorderSizePixel = 0,
            }, hideButton)
            round(bar, PILL)
            table.insert(hideBars, bar)
        end
        bind(hideButton.MouseEnter, function()
            glide(hideButton, { BackgroundColor3 = Theme.Accent2, BackgroundTransparency = 0.7 })
            for _, bar in ipairs(hideBars) do
                glide(bar, { BackgroundColor3 = Theme.Text })
            end
        end)
        bind(hideButton.MouseLeave, function()
            glide(hideButton, { BackgroundTransparency = 1 })
            for _, bar in ipairs(hideBars) do
                glide(bar, { BackgroundColor3 = Theme.SubText })
            end
        end)
        bind(hideButton.MouseButton1Click, function()
            Shell.Visible = false
        end)

        local minimized = false
        local fullSize = Shell.Size

        local minButton = new("TextButton", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -48, 0.5, 0),
            Size = UDim2.fromOffset(26, 26),
            BackgroundColor3 = Theme.Raised,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Font = Enum.Font.GothamBold,
            TextSize = 16,
            TextColor3 = Theme.SubText,
            Text = "-",
            AutoButtonColor = false,
        }, top)
        round(minButton, UDim.new(0, 8))
        bind(minButton.MouseEnter, function()
            glide(minButton, { BackgroundTransparency = 0, TextColor3 = Theme.Text })
        end)
        bind(minButton.MouseLeave, function()
            glide(minButton, { BackgroundTransparency = 1, TextColor3 = Theme.SubText })
        end)

        ---------------------------------------------------------------- corpo: abas no topo + conteudo
        local body = new("Frame", {
            Position = UDim2.fromOffset(0, HEAD_H),
            Size = UDim2.new(1, 0, 1, -HEAD_H),
            BackgroundTransparency = 1,
        }, Shell)

        -- Sidebar fixa; a navegação vertical substitui a antiga faixa horizontal.
        local side = new("Frame", {
            Name = "NavigationSidebar",
            Size = UDim2.new(0, SIDEBAR_W, 1, 0),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
            ZIndex = 2,
        }, body)
        new("UIGradient", {
            Rotation = 90,
            Color = ColorSequence.new(Color3.fromRGB(15, 22, 27), Color3.fromRGB(8, 12, 15)),
        }, side)
        local sideRule = new("Frame", {
            Position = UDim2.new(1, -1, 0, 0),
            Size = UDim2.new(0, 1, 1, 0),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
        }, side)
        shade(sideRule, 90, BRAND, NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(0.5, 0.6),
            NumberSequenceKeypoint.new(1, 1),
        }))
        local sideBrand = new("TextLabel", {
            Position = UDim2.fromOffset(16, 14),
            Size = UDim2.new(1, -28, 0, 24),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBlack,
            TextSize = 14,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextColor3 = Theme.Text,
            Text = "NODT HUB",
            ZIndex = 3,
        }, side)
        shade(sideBrand, 0, ColorSequence.new(Color3.new(1, 1, 1), Theme.Glow))
        local sideAccent = new("Frame", {
            Position = UDim2.fromOffset(16, 43),
            Size = UDim2.fromOffset(34, 3),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
            ZIndex = 3,
        }, side)
        round(sideAccent, PILL)
        shade(sideAccent, 0, BRAND3)

        TabRail = new("ScrollingFrame", {
            Position = UDim2.fromOffset(10, 58),
            Size = UDim2.new(1, -20, 1, -70),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            CanvasSize = UDim2.new(),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            ScrollBarThickness = 2,
            ScrollBarImageColor3 = Theme.Accent,
            ScrollingDirection = Enum.ScrollingDirection.Y,
            ElasticBehavior = Enum.ElasticBehavior.Never,
            ZIndex = 2,
        }, side)
        local railList = stack(TabRail, 6, Enum.FillDirection.Vertical)
        railList.HorizontalAlignment = Enum.HorizontalAlignment.Center

        -- Indicador vertical lime na lateral da pílula ativa.
        local glow = new("Frame", {
            Position = UDim2.fromOffset(0, 0),
            Size = UDim2.fromOffset(3, 0),
            BackgroundColor3 = Theme.Accent,
            BackgroundTransparency = 0.75,
            BorderSizePixel = 0,
            ZIndex = 3,
        }, side)
        new("UIGradient", {
            Rotation = 0,
            Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.2),
                NumberSequenceKeypoint.new(1, 1),
            }),
        }, glow)
        local indicator = new("Frame", {
            Position = UDim2.fromOffset(0, 0),
            Size = UDim2.fromOffset(3, 0),
            BackgroundColor3 = Theme.Accent,
            BorderSizePixel = 0,
            ZIndex = 4,
        }, side)
        round(indicator, PILL)

        local function moveIndicator(btn, instant)
            if not btn or not btn.Parent then return end
            local s = Scale.Scale
            if s <= 0 then s = 1 end
            local h = btn.AbsoluteSize.Y / s
            if h < 1 then return end
            local y = (btn.AbsolutePosition.Y - side.AbsolutePosition.Y) / s
            local barPos = UDim2.fromOffset(5, y + 5)
            local barSize = UDim2.fromOffset(3, math.max(18, h - 10))
            local glowPos = UDim2.fromOffset(3, y + 2)
            local glowSize = UDim2.fromOffset(14, h - 4)
            if instant then
                indicator.Position, indicator.Size = barPos, barSize
                glow.Position, glow.Size = glowPos, glowSize
            else
                ease(indicator, { Position = barPos, Size = barSize }, 0.30, Enum.EasingStyle.Quint)
                ease(glow, { Position = glowPos, Size = glowSize }, 0.30, Enum.EasingStyle.Quint)
            end
        end
        bind(Scale:GetPropertyChangedSignal("Scale"), function()
            if ActiveTab then
                moveIndicator(ActiveTab.Button, true)
            end
        end)

        PageHolder = new("Frame", {
            Position = UDim2.fromOffset(SIDEBAR_W, 0),
            Size = UDim2.new(1, -SIDEBAR_W, 1, 0),
            BackgroundTransparency = 1,
            ClipsDescendants = true,
        }, body)

        local function setMinimized(state)
            minimized = state and true or false
            if minButton and minButton.Parent then
                minButton.Text = minimized and "+" or "-"
            end
            if not minimized then
                body.Visible = true
            end
            glide(Shell, { Size = minimized and UDim2.new(fullSize.X.Scale, fullSize.X.Offset, 0, HEAD_H) or fullSize }, 0.22)
            if minimized then
                task.delay(0.24, function()
                    if minimized then
                        body.Visible = false
                    end
                end)
            end
        end

        bind(minButton.MouseButton1Click, function()
            setMinimized(not minimized)
        end)

        local Window = { Instance = Shell }

        function Window:SetMinimized(state)
            setMinimized(state)
        end

        function Window:IsMinimized()
            return minimized
        end

        -- Cada card entra com um leve deslocamento + fade; o atraso cresce de card em card (0.04s),
        -- alternando entre as duas colunas para a cascata ler em ordem de leitura.
        local function cascadeIn(rec, index)
            rec.Cover.BackgroundTransparency = 0
            rec.Pad.PaddingTop = UDim.new(0, 10)
            local stagger = 0.05 + 0.04 * math.min(index, 7)
            ease(rec.Cover, { BackgroundTransparency = 1 }, 0.34, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, stagger)
            ease(rec.Pad, { PaddingTop = UDim.new(0, 0) }, 0.4, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, stagger)
        end
        local function cascadeAll(list)
            for _, rec in ipairs(list) do
                cascadeIn(rec, (rec.Row - 1) * 2 + rec.Side)
            end
        end

        -- Troca de aba: a pagina antiga sai deslizando + escurecendo, a nova entra na direcao da troca,
        -- o indicador desliza ate a nova aba e os cards chegam em cascata.
        local switchToken = 0

        function Window:AddTab(name, icon, accent, subtitle)
            local tabIndex = #pages + 1
            -- Cada aba tem a sua cor (3o argumento de AddTab); sem cor, usa o destaque do tema.
            local tabColor = typeof(accent) == "Color3" and accent or Theme.Accent
            local button = new("TextButton", {
                Size = UDim2.new(1, -4, 0, 36),
                AutomaticSize = Enum.AutomaticSize.None,
                BackgroundTransparency = 1,
                BackgroundColor3 = Theme.Raised,
                BorderSizePixel = 0,
                Text = "",
                AutoButtonColor = false,
                LayoutOrder = tabIndex,
            }, TabRail)
            round(button, UDim.new(0, 10))
            pad(button, 11, 8, 0, 0)
            local tabEdge = outline(button, tabColor, 1, 1)
            new("UIGradient", {
                Rotation = 0,
                Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(168, 188, 194)),
            }, button)

            local inner = new("Frame", {
                Size = UDim2.new(1, -6, 1, 0),
                AutomaticSize = Enum.AutomaticSize.None,
                BackgroundTransparency = 1,
            }, button)
            local innerList = stack(inner, 7, Enum.FillDirection.Horizontal)
            innerList.VerticalAlignment = Enum.VerticalAlignment.Center

            local iconSlot = new("Frame", {
                LayoutOrder = 1,
                Size = UDim2.fromOffset(16, 16),
                BackgroundTransparency = 1,
            }, inner)
            local tabDrawn = drawIcon(iconSlot, icon, 15, Theme.Faint, 1.5)
            if not tabDrawn then
                new("TextLabel", {
                    Size = UDim2.fromScale(1, 1),
                    BackgroundTransparency = 1,
                    Font = Enum.Font.GothamBold,
                    TextSize = 13,
                    TextColor3 = Theme.Faint,
                    Text = ICONS[icon or ""] or string.sub(name, 1, 1),
                }, iconSlot)
            end

            local tabLabel = new("TextLabel", {
                LayoutOrder = 2,
                Size = UDim2.fromOffset(0, 16),
                AutomaticSize = Enum.AutomaticSize.X,
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextColor3 = Theme.SubText,
                Text = name,
            }, inner)

            local boxes = {}
            local rowCount = {}

            local page = new("Frame", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Visible = false,
            }, PageHolder)
            pad(page, 20, 20, 14, 0)

            -- Veu da pagina inteira (usado so na saida da pagina antiga).
            local veil = new("Frame", {
                Size = UDim2.fromScale(1, 1),
                BackgroundColor3 = VEIL,
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                ZIndex = 50,
            }, page)

            -- Uma unica rolagem para a pagina; as duas colunas rolam juntas.
            local scroll = new("ScrollingFrame", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                CanvasSize = UDim2.new(),
                AutomaticCanvasSize = Enum.AutomaticSize.Y,
                ScrollBarThickness = 2,
                ScrollBarImageColor3 = Theme.Accent,
                ScrollBarImageTransparency = 0.55,
                ScrollingDirection = Enum.ScrollingDirection.Y,
            }, page)
            pad(scroll, 0, 8, 2, 24)

            local cols = new("Frame", {
                Size = UDim2.new(1, 0, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                BackgroundTransparency = 1,
            }, scroll)
            local colList = stack(cols, 14, Enum.FillDirection.Horizontal)
            colList.VerticalAlignment = Enum.VerticalAlignment.Top

            local left = new("Frame", {
                LayoutOrder = 1,
                Size = UDim2.new(0.5, -7, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                BackgroundTransparency = 1,
            }, cols)
            stack(left, 14)

            local right = new("Frame", {
                LayoutOrder = 2,
                Size = UDim2.new(0.5, -7, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                BackgroundTransparency = 1,
            }, cols)
            stack(right, 14)

            local function isShown()
                return page.Visible and Shell.Visible and not minimized
            end
            smoothScroll(scroll, isShown)

            local Tab = { Page = page, Left = left, Right = right, Button = button, Index = tabIndex, Veil = veil, Boxes = boxes }

            -- Se so existir coluna esquerda, ela ocupa a largura toda (sem buraco no layout).
            local function fitColumns()
                local solo = true
                for _, child in ipairs(right:GetChildren()) do
                    if child:IsA("Frame") then
                        solo = false
                        break
                    end
                end
                right.Visible = not solo
                left.Size = solo and UDim2.new(1, 0, 0, 0) or UDim2.new(0.5, -7, 0, 0)
            end

            -- Se um grupo entra na coluna da direita depois da aba ja ter sido selecionada, reajusta as colunas.
            bind(right.ChildAdded, function()
                task.defer(fitColumns)
            end)

            -- Estado visual da aba: ativa = texto claro + icone no destaque; inativa = apagada.
            local function paint(active)
                if active then
                    glide(tabLabel, { TextColor3 = Theme.Text })
                    glide(button, { BackgroundColor3 = Theme.AccentSoft, BackgroundTransparency = 0 })
                    glide(tabEdge, { Transparency = 0.55 })
                    if tabDrawn then
                        tabDrawn.tint(tabColor)
                    end
                else
                    glide(tabLabel, { TextColor3 = Theme.SubText })
                    glide(button, { BackgroundTransparency = 1 })
                    glide(tabEdge, { Transparency = 1 })
                    if tabDrawn then
                        tabDrawn.tint(Theme.Faint)
                    end
                end
            end

            bind(button:GetPropertyChangedSignal("AbsoluteSize"), function()
                if ActiveTab == Tab then
                    moveIndicator(button, true)
                end
            end)
            bind(button:GetPropertyChangedSignal("AbsolutePosition"), function()
                if ActiveTab == Tab then
                    moveIndicator(button, true)
                end
            end)

            function Tab:Select()
                local previous = ActiveTab
                local changed = previous ~= nil and previous ~= Tab
                switchToken = switchToken + 1
                local token = switchToken

                -- Todas as outras paginas somem na hora; so a pagina anterior fica visivel para animar a saida.
                for _, other in ipairs(pages) do
                    if other.Page ~= page then
                        other.Paint(false)
                        if not (changed and other.Tab == previous) then
                            other.Page.Visible = false
                            other.Page.Position = UDim2.fromOffset(0, 0)
                            other.Veil.BackgroundTransparency = 1
                        end
                    end
                end

                fitColumns()
                page.Visible = true
                paint(true)
                ActiveTab = Tab
                moveIndicator(button, not changed)
                if changed then
                    ease(indicator, { BackgroundColor3 = tabColor }, 0.35, Enum.EasingStyle.Quint)
                    ease(glow, { BackgroundColor3 = tabColor }, 0.35, Enum.EasingStyle.Quint)
                else
                    indicator.BackgroundColor3 = tabColor
                    glow.BackgroundColor3 = tabColor
                end

                if not changed then
                    setSubtitle(subtitle or "", 0)
                    return
                end

                local dir = Tab.Index > previous.Index and 1 or -1
                setSubtitle(subtitle or "", dir)

                -- Saida: a pagina antiga desliza para o lado oposto e escurece.
                local oldPage, oldVeil = previous.Page, previous.Veil
                oldPage.ZIndex = 2
                page.ZIndex = 1
                ease(oldPage, { Position = UDim2.fromOffset(-dir * SLIDE, 0) }, 0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
                ease(oldVeil, { BackgroundTransparency = 0 }, 0.18, Enum.EasingStyle.Quad)
                task.delay(0.24, function()
                    if switchToken == token then
                        oldPage.Visible = false
                        oldPage.Position = UDim2.fromOffset(0, 0)
                        oldVeil.BackgroundTransparency = 1
                    end
                end)

                -- Entrada: a pagina nova desliza para o lugar e os cards chegam em cascata.
                page.Position = UDim2.fromOffset(dir * SLIDE, 0)
                ease(page, { Position = UDim2.fromOffset(0, 0) }, 0.42, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, 0.04)
                cascadeAll(boxes)
            end

            -- Card de grupo: superficie um tom acima do fundo, sem contorno. Titulo com marca de destaque
            -- a esquerda e icone discreto a direita. O "holder" externo existe so para a animacao de entrada.
            local function makeBox(column, title, icon, hidden)
                rowCount[column] = (rowCount[column] or 0) + 1
                local holder = new("Frame", {
                    Size = UDim2.new(1, 0, 0, 0),
                    AutomaticSize = Enum.AutomaticSize.Y,
                    BackgroundTransparency = 1,
                    BorderSizePixel = 0,
                    LayoutOrder = #column:GetChildren(),
                }, column)
                local slidePad = pad(holder, 0, 0, 0, 0)
                if hidden then
                    holder.Visible = false
                end

                local box = new("Frame", {
                    Size = UDim2.new(1, 0, 0, 0),
                    AutomaticSize = Enum.AutomaticSize.Y,
                    BackgroundColor3 = Theme.Panel,
                    BorderSizePixel = 0,
                }, holder)
                round(box, UDim.new(0, Lib.CornerRadius), true)
                outline(box, Theme.Line, 1, 0.55)
                shade(box, 125, ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(188, 204, 210)))
                pad(box, 16, 16, 12, 14)
                stack(box, 0)

                local head = new("Frame", {
                    Size = UDim2.new(1, 0, 0, 26),
                    BackgroundTransparency = 1,
                    LayoutOrder = 0,
                }, box)

                local mark = new("Frame", {
                    AnchorPoint = Vector2.new(0, 0.5),
                    Position = UDim2.new(0, 0, 0.5, 0),
                    Size = UDim2.fromOffset(3, 14),
                    BackgroundColor3 = Color3.new(1, 1, 1),
                    BorderSizePixel = 0,
                }, head)
                round(mark, PILL)
                shade(mark, 90, BRAND)

                new("TextLabel", {
                    Position = UDim2.fromOffset(12, 0),
                    Size = UDim2.new(1, -36, 1, 0),
                    BackgroundTransparency = 1,
                    Font = Enum.Font.GothamBold,
                    TextSize = 13,
                    TextColor3 = Theme.Text,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = title or "",
                }, head)

                local iconHolder = new("Frame", {
                    AnchorPoint = Vector2.new(1, 0.5),
                    Position = UDim2.new(1, 0, 0.5, 0),
                    Size = UDim2.fromOffset(18, 18),
                    BackgroundTransparency = 1,
                }, head)
                if not drawIcon(iconHolder, icon, 14, Theme.Glow, 1.4) then
                    local glyph = ICONS[icon or ""]
                    if glyph then
                        new("TextLabel", {
                            Size = UDim2.fromScale(1, 1),
                            BackgroundTransparency = 1,
                            Font = Enum.Font.GothamBold,
                            TextSize = 13,
                            TextColor3 = Color3.new(1, 1, 1),
                            TextTransparency = 0.45,
                            Text = glyph,
                        }, iconHolder)
                    end
                end

                local content = new("Frame", {
                    Size = UDim2.new(1, 0, 0, 0),
                    AutomaticSize = Enum.AutomaticSize.Y,
                    BackgroundTransparency = 1,
                    LayoutOrder = 1,
                }, box)
                stack(content, 6)
                pad(content, 0, 0, 8, 0)

                local cover = new("Frame", {
                    Size = UDim2.fromScale(1, 1),
                    BackgroundColor3 = VEIL,
                    BackgroundTransparency = 1,
                    BorderSizePixel = 0,
                    ZIndex = 20,
                }, holder)
                round(cover, UDim.new(0, Lib.CornerRadius), true)
                local rec = { Cover = cover, Pad = slidePad, Row = rowCount[column], Side = column == right and 1 or 0 }
                table.insert(boxes, rec)

                -- Cards criados enquanto a janela ainda esta abrindo na aba ativa tambem entram em cascata.
                if ActiveTab == Tab and os.clock() - openedAt < 4 then
                    cascadeIn(rec, (rec.Row - 1) * 2 + rec.Side)
                end

                return makeGroup(content)
            end

            function Tab:AddLeftGroupbox(title, icon, hidden)
                return makeBox(left, title, icon, hidden)
            end

            function Tab:AddRightGroupbox(title, icon, hidden)
                return makeBox(right, title, icon, hidden)
            end

            bind(button.MouseButton1Click, function()
                Tab:Select()
            end)
            bind(button.MouseEnter, function()
                if ActiveTab ~= Tab then
                    glide(button, { BackgroundTransparency = 0.55 })
                    glide(tabLabel, { TextColor3 = Theme.Text })
                    if tabDrawn then
                        tabDrawn.tint(Theme.SubText)
                    end
                end
            end)
            bind(button.MouseLeave, function()
                if ActiveTab ~= Tab then
                    glide(button, { BackgroundTransparency = 1 })
                    glide(tabLabel, { TextColor3 = Theme.SubText })
                    if tabDrawn then
                        tabDrawn.tint(Theme.Faint)
                    end
                end
            end)

            table.insert(pages, { Tab = Tab, Page = page, Button = button, Veil = veil, Paint = paint })
            if #pages == 1 then
                Tab:Select()
            end
            return Tab
        end

        function Window:SetCornerRadius(radius)
            Lib.CornerRadius = radius
            for _, corner in ipairs(panels) do
                corner.CornerRadius = UDim.new(0, radius)
            end
        end

        function Window:Toggle()
            Shell.Visible = not Shell.Visible
        end

        Lib.Window = Window
        Lib:SetNotifySide(config.NotifySide or "Right")

        -- Abertura: "pop" de 0.95 -> 1.0 com leve overshoot, fade do fundo/contorno e de um veu sobre o conteudo.
        local shellVeil = new("Frame", {
            Size = UDim2.fromScale(1, 1),
            BackgroundColor3 = Theme.Shell,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ZIndex = 100,
        }, Shell)
        round(shellVeil, UDim.new(0, 14), true)

        -- Faixa de luz diagonal que varre a janela quando ela abre.
        local sweep = new("Frame", {
            Size = UDim2.fromScale(1, 1),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
            ZIndex = 99,
            Visible = false,
        }, Shell)
        round(sweep, UDim.new(0, 14), true)
        local sweepGrad = new("UIGradient", {
            Rotation = 25,
            Color = ColorSequence.new(Theme.Accent, Theme.Accent2),
            Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 1),
                NumberSequenceKeypoint.new(0.4, 1),
                NumberSequenceKeypoint.new(0.5, 0.86),
                NumberSequenceKeypoint.new(0.6, 1),
                NumberSequenceKeypoint.new(1, 1),
            }),
            Offset = Vector2.new(-1, 0),
        }, sweep)

        local function popIn()
            popping = true
            popStamp = popStamp + 1
            local stamp = popStamp
            local goal = targetScale()
            Shell.BackgroundTransparency = 1
            shellEdge.Transparency = 1
            shellVeil.BackgroundTransparency = 0.5
            Scale.Scale = goal * 0.95
            ease(Scale, { Scale = goal }, 0.36, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
            ease(Shell, { BackgroundTransparency = SHELL_ALPHA }, 0.24, Enum.EasingStyle.Quad)
            ease(shellEdge, { Transparency = 0 }, 0.3, Enum.EasingStyle.Quad)
            ease(shellVeil, { BackgroundTransparency = 1 }, 0.3, Enum.EasingStyle.Quad)
            sweep.Visible = true
            sweepGrad.Offset = Vector2.new(-1, 0)
            ease(sweepGrad, { Offset = Vector2.new(1, 0) }, 0.95, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, 0.05)
            task.delay(1.1, function()
                if popStamp == stamp then
                    sweep.Visible = false
                end
            end)
            task.delay(0.4, function()
                if popStamp == stamp then
                    popping = false
                    if Scale and not Lib.Unloaded then
                        Scale.Scale = targetScale()
                    end
                end
            end)
            -- Reabrir o menu repete a cascata dos cards da aba atual.
            if ActiveTab and ActiveTab.Boxes then
                cascadeAll(ActiveTab.Boxes)
            end
        end

        Shell.Visible = true
        popIn()

        -- Toda reabertura (tecla, botao ou Window:Toggle) repete a animacao.
        -- task.defer: roda depois do codigo que reabriu a janela (ex.: botao flutuante).
        bind(Shell:GetPropertyChangedSignal("Visible"), function()
            if Shell.Visible and not Lib.Unloaded then
                task.defer(function()
                    if Shell.Visible and not Lib.Unloaded then
                        popIn()
                    end
                end)
            end
        end)

        -- Animacoes em loop (contorno e linha do cabecalho) so rodam enquanto a janela esta visivel.
        -- No celular (toque) o contorno fica com o gradiente parado para poupar performance; o resto anima normal.
        local function ambient()
            if Shell.Visible and not Lib.Unloaded then
                if not UserInputService.TouchEnabled then
                    edgeSpin:Play()
                end
                lineSweep:Play()
            else
                edgeSpin:Pause()
                lineSweep:Pause()
            end
        end
        bind(Shell:GetPropertyChangedSignal("Visible"), ambient)
        ambient()

        return Window
    end

    bind(UserInputService.InputBegan, function(input, processed)
        if processed or Lib.Unloaded or not Shell then
            return
        end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then
            return
        end
        if UserInputService:GetFocusedTextBox() then
            return
        end
        local wanted = Lib.ToggleKeybind and Lib.ToggleKeybind.Value or Lib.DefaultToggleKey
        if wanted ~= "" and input.KeyCode.Name == wanted then
            Shell.Visible = not Shell.Visible
        end
    end)

    function Lib:SetDPIScale(percent)
        Lib.DPI = math.clamp((tonumber(percent) or 100) / 100, 0.5, 2)
        if Lib.Refit then
            Lib.Refit()
        elseif Scale then
            Scale.Scale = Lib.DPI
        end
    end

    function Lib:Unload()
        -- Guarda de reentrada: session.unload chama session.ui:Unload(), que voltaria aqui.
        if Lib.Unloaded then return end
        Lib.Unloaded = true

        -- Fix 2: restaura o inventario (session.unload) ao dar Unload pelo menu.
        do
            local genv = (type(getgenv) == "function" and getgenv()) or _G
            local session = rawget(genv, "NODT_SESSION") or genv.NODT_SESSION
            if type(session) == "table" and type(session.unload) == "function" then
                pcall(session.unload)
            end
        end

        for _, link in ipairs(conns) do
            pcall(function()
                link:Disconnect()
            end)
        end
        conns = {}

        local genv = (type(getgenv) == "function" and getgenv()) or _G
        local session = rawget(genv, "NODT_SESSION") or genv.NODT_SESSION
        if type(session) == "table" then
            if type(session.unhook) == "function" then
                pcall(session.unhook)
            end
            for _, link in ipairs(session.links or {}) do
                pcall(function()
                    link:Disconnect()
                end)
            end
            session.links = {}
            pcall(function()
                local tagged = {}
                for _, name in ipairs(session.tags or {}) do
                    tagged[name] = true
                end
                if not next(tagged) then return end
                local holders = {}
                if type(gethui) == "function" then
                    local reached, container = pcall(gethui)
                    if reached and container then table.insert(holders, container) end
                end
                table.insert(holders, game:GetService("CoreGui"))
                if workspace.CurrentCamera then
                    table.insert(holders, workspace.CurrentCamera)
                end
                if LocalPlayer then
                    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
                    if pg then table.insert(holders, pg) end
                end
                for _, holder in ipairs(holders) do
                    for _, child in ipairs(holder:GetChildren()) do
                        if tagged[child.Name] then
                            child:Destroy()
                        end
                    end
                end
                for _, model in ipairs(workspace:GetChildren()) do
                    if model:IsA("Model") and model.Name:match("^CLIENT_BALL_%d+$") then
                        for _, child in ipairs(model:GetChildren()) do
                            if tagged[child.Name] then
                                child:Destroy()
                            end
                        end
                    end
                end
                for _, other in ipairs(Players:GetPlayers()) do
                    if other.Character then
                        for _, child in ipairs(other.Character:GetChildren()) do
                            if tagged[child.Name] then
                                child:Destroy()
                            end
                        end
                    end
                end
            end)
        end

        -- Fix 3: restaura as configuracoes graficas do Anti-Lag. disableAntiLag e declarada
        -- bem depois da Library, entao chega aqui via Library.RestoreAntiLag.
        if type(Lib.RestoreAntiLag) == "function" then
            pcall(Lib.RestoreAntiLag)
        end

        -- Limpeza de hitboxes, props de emote, leadFeet e skins de bola (definida mais abaixo,
        -- onde essas funcoes ja existem, via Library.CleanupExtras).
        if type(Lib.CleanupExtras) == "function" then
            pcall(Lib.CleanupExtras)
        end

        Root:Destroy()
    end

    local function fileApi()
        local write = rawget(_G, "writefile") or writefile
        local read = rawget(_G, "readfile") or readfile
        local list = rawget(_G, "listfiles") or listfiles
        local exists = rawget(_G, "isfile") or isfile
        local folder = rawget(_G, "isfolder") or isfolder
        local mkdir = rawget(_G, "makefolder") or makefolder
        local remove = rawget(_G, "delfile") or delfile
        if type(write) ~= "function" or type(read) ~= "function" or type(list) ~= "function" then
            return nil
        end
        return { write = write, read = read, list = list, exists = exists, folder = folder, mkdir = mkdir, remove = remove }
    end

    function Lib:SetConfigFolder(name)
        configFolder = name
    end

    local function ensureFolder(api)
        if api.folder and api.mkdir then
            if not api.folder(configFolder) then
                api.mkdir(configFolder)
            end
            if not api.folder(configFolder .. "/configs") then
                api.mkdir(configFolder .. "/configs")
            end
        end
    end

    local function collect()
        local dump = { toggles = {}, options = {} }
        for index, toggle in pairs(Lib.Toggles) do
            dump.toggles[index] = toggle.Value
        end
        for index, option in pairs(Lib.Options) do
            if option.Type == "KeyPicker" then
                dump.options[index] = { option.Value, option.Mode }
            else
                dump.options[index] = option.Value
            end
        end
        return dump
    end

    local function restore(dump)
        for index, value in pairs(dump.toggles or {}) do
            local toggle = Lib.Toggles[index]
            if toggle then
                toggle:SetValue(value)
            end
        end
        for index, value in pairs(dump.options or {}) do
            local option = Lib.Options[index]
            if option and option.SetValue then
                option:SetValue(value)
            end
        end
    end

    function Lib:SaveConfig(name)
        local api = fileApi()
        if not api or not name or name == "" then
            return false
        end
        ensureFolder(api)
        local ok, encoded = pcall(HttpService.JSONEncode, HttpService, collect())
        if not ok then
            return false
        end
        return pcall(api.write, configFolder .. "/configs/" .. name .. ".json", encoded)
    end

    function Lib:LoadConfig(name)
        local api = fileApi()
        if not api or not name or name == "" then
            return false
        end
        local ok, raw = pcall(api.read, configFolder .. "/configs/" .. name .. ".json")
        if not ok or type(raw) ~= "string" then
            return false
        end
        local parsed, dump = pcall(HttpService.JSONDecode, HttpService, raw)
        if not parsed or type(dump) ~= "table" then
            return false
        end
        restore(dump)
        return true
    end

    function Lib:ListConfigs()
        local api = fileApi()
        local found = {}
        if not api then
            return found
        end
        ensureFolder(api)
        local ok, entries = pcall(api.list, configFolder .. "/configs")
        if not ok or type(entries) ~= "table" then
            return found
        end
        for _, path in ipairs(entries) do
            local name = string.match(path, "([^/\\]+)%.json$")
            if name then
                table.insert(found, name)
            end
        end
        return found
    end

    function Lib:LoadAutoloadConfig()
        local api = fileApi()
        if not api then
            return
        end
        local ok, name = pcall(api.read, configFolder .. "/autoload.txt")
        if ok and type(name) == "string" and name ~= "" then
            Lib:LoadConfig(name)
        end
    end

    function Lib:BuildConfigSection(tab)
        local group = tab:AddRightGroupbox("Configuration")
        local api = fileApi()

        if not api then
            group:AddLabel("This executor has no file API, configs are off", true)
            return group
        end

        local nameBox = group:AddInput("ConfigName", {
            Default = "",
            Text = "Config name",
            Placeholder = "default",
        })

        local picker = group:AddDropdown("ConfigList", {
            Values = Lib:ListConfigs(),
            Default = nil,
            Text = "Saved configs",
        })

        group:AddButton({
            Text = "Create",
            Func = function()
                if Lib:SaveConfig(nameBox.Value) then
                    picker:SetValues(Lib:ListConfigs())
                    Lib:Notify("Saved config " .. nameBox.Value)
                end
            end,
        })

        group:AddButton({
            Text = "Load",
            Func = function()
                if picker.Value and Lib:LoadConfig(picker.Value) then
                    Lib:Notify("Loaded config " .. picker.Value)
                end
            end,
        })

        group:AddButton({
            Text = "Overwrite",
            Func = function()
                if picker.Value and Lib:SaveConfig(picker.Value) then
                    Lib:Notify("Overwrote config " .. picker.Value)
                end
            end,
        })

        group:AddButton({
            Text = "Delete",
            Func = function()
                if picker.Value and api.remove then
                    pcall(api.remove, configFolder .. "/configs/" .. picker.Value .. ".json")
                    picker:SetValues(Lib:ListConfigs())
                    picker:SetValue(nil, true)
                    Lib:Notify("Deleted config")
                end
            end,
        })

        group:AddButton({
            Text = "Refresh list",
            Func = function()
                picker:SetValues(Lib:ListConfigs())
            end,
        })

        local autoLabel = group:AddLabel("Autoload: none", true)

        group:AddButton({
            Text = "Set as autoload",
            Func = function()
                if picker.Value then
                    pcall(api.write, configFolder .. "/autoload.txt", picker.Value)
                    autoLabel:SetText("Autoload: " .. picker.Value)
                end
            end,
        })

        group:AddButton({
            Text = "Clear autoload",
            Func = function()
                pcall(api.write, configFolder .. "/autoload.txt", "")
                autoLabel:SetText("Autoload: none")
            end,
        })

        local ok, current = pcall(api.read, configFolder .. "/autoload.txt")
        if ok and type(current) == "string" and current ~= "" then
            autoLabel:SetText("Autoload: " .. current)
        end

        return group
    end

    return Lib
end)()

do
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = genv.NODT_SESSION
    if type(session) == "table" then
        session.ui = Library
    end
end

local Options = Library.Options
local Toggles = Library.Toggles

Library.ForceCheckbox = false
Library.ShowToggleFrameInKeybinds = true

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local TeleportService = game:GetService("TeleportService")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera
local _AC = nil
pcall(function()
    local controllers = game:GetService("ReplicatedFirst"):WaitForChild("Controllers", 10)
    local module = controllers and controllers:WaitForChild("AnimationController", 10)
    if module then
        _AC = require(module)
    end
end)

local MARK = string.char(math.random(97, 122), math.random(97, 122), math.random(97, 122)) .. tostring(math.random(100000, 999999))
local MARK2 = string.char(math.random(97, 122), math.random(97, 122), math.random(97, 122)) .. tostring(math.random(100000, 999999))

do
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = genv.NODT_SESSION
    if type(session) == "table" and type(session.tags) == "table" then
        table.insert(session.tags, MARK)
        table.insert(session.tags, MARK2)
    end
end

local function track(connection)
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = genv.NODT_SESSION
    if type(session) == "table" and type(session.links) == "table" then
        table.insert(session.links, connection)
    end
    return connection
end

local hitboxEnabled = false
local hitboxScale = 5.0
local hitboxReach = 5.0
local hitboxHooked = false
local hitboxFollow = nil
local hitboxColor = Color3.fromRGB(0, 0, 255)
local hitboxTransparency = 0.3
local hitboxBoxes = {}
local SpikeReach = { reach = 300.0, expiry = 0 }

State.redirectSpikeEnabled = false
local redirectSpikeInstalled = false
State.sanjuTiltEnabled = false
local sanjuTiltInstalled = false
State.maxChargeEnabled = false
local maxChargeHookActive = false
State.newSilentSpikeEnabled = false
local newSpikeButton = nil
local stopBallButton = nil
local aimButton = nil
local stopBallVisible = false
local aimVisible = false
local dashButton = nil
State.akariDashEnabled = false
State.leadFeetEnabled = false
local leadFeetButton = nil
local leadFeetLink = nil
State.espJumpEnabled = false
local espHighlights = {}
local espConnections = {}
State.desyncEnabled = false
local desyncConnection = nil
State.autoReceiveEnabled = false
local Receive = { range = 10, lead = 0.35, stamp = 0, gap = 0.2 }

-- Servicos/modulos usados em callbacks de frame: carregar uma vez e tentar novamente no maximo a cada segundo.
local _BallController = nil
local _Physics = nil
local _GameHandlers = nil
local _GameConfig = nil
local _State = nil
local _lastCacheAttempt = 0

local function getCachedServices()
    if _BallController and _Physics and _GameHandlers and _GameConfig and _State then
        return true
    end
    local now = os.clock()
    if now - _lastCacheAttempt < 1 then
        return false
    end
    _lastCacheAttempt = now

    if not _BallController then
        local Knit = getKnitRoot()
        if Knit then
            pcall(function()
                _BallController = Knit.GetController("BallController")
            end)
        end
    end
    if not _GameHandlers then
        pcall(function()
            _GameHandlers = require(game:GetService("ReplicatedFirst").Controllers.GameController.Handlers)
        end)
    end
    if not _Physics then
        pcall(function()
            _Physics = require(ReplicatedStorage.Common.Physics)
        end)
    end
    if not _GameConfig then
        pcall(function()
            _GameConfig = require(ReplicatedStorage.Configuration.Game)
        end)
    end
    if not _State then
        pcall(function()
            _State = require(ReplicatedStorage.Common.State)
        end)
    end
    return _BallController ~= nil or _Physics ~= nil or _GameHandlers ~= nil
        or _GameConfig ~= nil or _State ~= nil
end
State.maxServeEnabled = false
local maxServeHookActive = false
State.airMovement = false
State.airMovementSpeed = 16
local bodyVelocity = nil
State.autoShiftLockEnabled = false
local shiftLockConnection = nil
local hitEffectEnabled = false
State.selectedEffect = "SupernovaScoreEffect"
local hasFired = false
local isLocalHit = false
local hitConnection = nil
local hitRemovedConnection = nil
local playerCardEnabled = false
State.selectedCard = "UltimateChampionPlayerCard"
local hasFiredCard = false
local isProcessing = false
local cardConnection = nil
local cardList = {}
State.selectedJersey = "DragonTuxedoJersey"
local pickedTeam = nil
local jerseyList = {}
State.selectedBallSkin = "ClassicBall"
local ballSkinList = {}
State.autoSpin = false
State.autoAbilitySpin = false
local desiredStyles = {}
local desiredAbilities = {}
State.spinType = "Normal"
State.abilitySpinType = "Normal"
State.autoApplyJersey = false
State.autoApplyBallSkin = false
State.fakeSpikeEnabled = false
State.protectEnabled = false
-- Estado e funcoes do Card Protect agrupados em uma tabela (limite de 200 locals no chunk).
local CardProtect = {
    enabled = false,
    bound = false,
    swapping = false,
    ours = setmetatable({}, { __mode = "k" }),
    bindName = "NODT_CardProtect",
    flag = "NODT_LocalCard",
    -- Janela em que um frame novo e tratado como o NOSSO card (jogo lento para mostrar).
    expectUntil = 0,
    lateWindow = 2,
    -- Reconexao automatica das pastas Interface/Persistent.
    listening = false,
    reconnecting = false,
    attachedTo = nil,
    guiConns = {},
    rootConn = nil,
    rootGui = nil,
    playerGuiConn = nil,
}
State.tshAnimationEnabled = false
State.hidariAnimationEnabled = false
State.kazanaBlueEnabled = false
State.kazanaWhiteEnabled = false
local originals = {}
local clones = {}
local seen = {}

local function clearCharacterVisuals()
    for model, holder in pairs(clones) do
        if holder and holder.Destroy then pcall(holder.Destroy, holder) end
        clones[model] = nil
    end
    clones = {}
    for player, highlight in pairs(espHighlights) do
        if highlight and highlight.Destroy then pcall(highlight.Destroy, highlight) end
        espHighlights[player] = nil
    end
    espHighlights = {}
end

track(LocalPlayer.CharacterAdded:Connect(function()
    clearCharacterVisuals()
end))

local linesEnabled = false
State.lineDistance = 50
local lines = {}
local lineColors = {
    Color3.fromRGB(255, 0, 0),
    Color3.fromRGB(0, 255, 0),
    Color3.fromRGB(0, 0, 255),
    Color3.fromRGB(255, 165, 0),
    Color3.fromRGB(128, 0, 128),
    Color3.fromRGB(255, 255, 0),
    Color3.fromRGB(139, 0, 0),
    Color3.fromRGB(0, 100, 0)
}

local changedProperties = {}
local oldQualityLevel
local oldSavedQualityLevel
local antilagConnections = {}

-- Retorna o ModuleScript "knit" dentro de Packages._Index (onde ficam as pastas Services/RE/RF).
-- Funcao global (sem "local") para nao gastar um dos 200 slots de local do chunk principal.
do
    local KnitNode = nil
    function getKnitNode()
        -- Cache valido so enquanto o no ainda estiver no jogo (teleport/reset de place descarta).
        if KnitNode and KnitNode:IsDescendantOf(game) then
            return KnitNode
        end
        KnitNode = nil
        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local index = ReplicatedStorage:FindFirstChild("Packages") and ReplicatedStorage.Packages:FindFirstChild("_Index")
        if not index then return nil end
        for _, child in ipairs(index:GetChildren()) do
            if child.Name:match("^sleitnick_knit@") then
                KnitNode = child:FindFirstChild("knit")
                return KnitNode
            end
        end
        return nil
    end
end

local BallService, Serve, EffectsRemote, doMove, GameEffectRemote, HitGround, Interact
do
    -- BallService (tabela da API do Knit) continua vindo do GetService; os remotes reais vem do no do Knit.
    local KnitRoot = getKnitRoot()
    if KnitRoot and type(KnitRoot.GetService) == "function" then
        local okBall, ball = pcall(KnitRoot.GetService, "BallService")
        if okBall then BallService = ball end
    end
    local KnitNode = getKnitNode()
    local BallServiceNode = KnitNode and KnitNode:FindFirstChild("Services") and KnitNode.Services:FindFirstChild("BallService")
    local GameServiceNode = KnitNode and KnitNode:FindFirstChild("Services") and KnitNode.Services:FindFirstChild("GameService")

    HitGround = BallServiceNode and BallServiceNode:FindFirstChild("RE") and BallServiceNode.RE:FindFirstChild("HitGround")
    EffectsRemote = BallServiceNode and BallServiceNode:FindFirstChild("RE") and BallServiceNode.RE:FindFirstChild("Effects")
    doMove = BallServiceNode and BallServiceNode:FindFirstChild("RE") and BallServiceNode.RE:FindFirstChild("DoMove")
    Interact = BallServiceNode and BallServiceNode:FindFirstChild("RF") and BallServiceNode.RF:FindFirstChild("Interact")
    Serve = GameServiceNode and GameServiceNode:FindFirstChild("RF") and GameServiceNode.RF:FindFirstChild("Serve")
    GameEffectRemote = GameServiceNode and GameServiceNode:FindFirstChild("RE") and GameServiceNode.RE:FindFirstChild("Effect")
    if not BallService then
        warn("[NodtHub] Knit nao encontrado ou BallService indisponivel, algumas funcoes vao falhar")
    end
end

-- Resolve servicos do Knit sem depender da versao do pacote (sleitnick_knit@x.y.z).
-- O cache do no raiz (KnitRoot) vive como upvalue de um bloco do...end: a funcao continua global,
-- mas nao gasta um dos 200 slots de local do chunk principal.
do
    local KnitRoot = nil
    local KnitRootNode = nil

    local function resolveKnitRoot()
        -- getKnitRoot retorna a tabela/API do Knit, nao o ModuleScript nem a Folder Services.
        -- A tabela nao tem IsDescendantOf: validamos pelo no do Knit guardado junto com ela.
        if KnitRootNode and not KnitRootNode:IsDescendantOf(game) then
            KnitRoot = nil
            KnitRootNode = nil
        end
        if type(KnitRoot) == "table" and type(KnitRoot.GetService) == "function" then
            return KnitRoot
        end
        local candidate = getKnitRoot()
        if type(candidate) == "table" and type(candidate.GetService) == "function" then
            KnitRoot = candidate
            KnitRootNode = getKnitNode()
        end
        return KnitRoot
    end

    function getPackageService(serviceName)
        local root = resolveKnitRoot()
        if not root or type(root.GetService) ~= "function" then
            return nil
        end
        local ok, service = pcall(root.GetService, serviceName)
        if ok then
            return service
        end
        return nil
    end

    -- Navega service -> filho -> filho... com pcall (funciona com Instance e com tabela do fallback).
    -- Retorna nil em vez de dar erro quando algum nivel nao existe.
    function getServiceChild(service, ...)
        if service == nil then return nil end
        local path = { ... }
        local ok, result = pcall(function()
            local current = service
            for _, name in ipairs(path) do
                if current == nil then return nil end
                if typeof(current) == "Instance" then
                    current = current:FindFirstChild(name)
                else
                    current = current[name]
                end
            end
            return current
        end)
        if ok then return result end
        return nil
    end
end

local NODT = {
    NameTag = "N\u{200B}odt Protect",
    Title = "<font color='#FF0000'><b>N\u{200B}odt</b></font>",
    NotifConn = nil,
    NotifConn2 = nil,
}

local function installSpikeEffectHook()
    hookNamecall("spikeEffect", function(callNext, self, method, ...)
        if not BallService then return callNext(self, method, ...) end
        if self == Interact and method == "InvokeServer" then
            local data = (...)
            if type(data) == "table" and data.Move == "Spike" then
                if State.tshAnimationEnabled and firesignal and LocalPlayer and LocalPlayer.Character then
                    firesignal(EffectsRemote.OnClientEvent, {
                        ["Character"] = LocalPlayer.Character,
                        ["Sound"] = "PowerSpike",
                        ["Effect"] = "SpecialChargeSpikeVFX",
                    })
                elseif State.hidariAnimationEnabled and firesignal and LocalPlayer and LocalPlayer.Character then
                    firesignal(EffectsRemote.OnClientEvent, {
                        ["Character"] = LocalPlayer.Character,
                        ["Sound"] = "PowerSpike",
                        ["Effect"] = "HidariSpikeVFX",
                    })
                end
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
end

if getrawmetatable and setreadonly and getnamecallmethod then
    local metaTested, metaAvailable = pcall(function()
        return getrawmetatable(game) ~= nil
    end)
    if metaTested and metaAvailable then
        installSpikeEffectHook()
    end
end

local function updateNametag()
    local player = LocalPlayer
    if player and player.Character then
        local nameTag = player.Character:FindFirstChild("Nametag")
        if nameTag then
            local label = nameTag:FindFirstChild("PlayerName")
            if label and label:IsA("TextLabel") then
                label.Text = NODT.NameTag
            end
        end
    end
end

local function updateTitle()
    local player = LocalPlayer
    if player then
        player:SetAttribute("User_Title", NODT.Title)
    end
end

local function processNotification(notification)
    if not notification then return end
    local player = LocalPlayer
    if not player then return end
    task.wait(0.2)
    local textLabel = notification:FindFirstChild("TextLabel")
    if not textLabel then
        for _, child in ipairs(notification:GetDescendants()) do
            if child:IsA("TextLabel") then
                textLabel = child
                break
            end
        end
    end
    if not textLabel then return end
    local text = textLabel.Text or ""
    if CardProtect.hasWord(text, player.Name) then
        textLabel.Text = CardProtect.replaceWord(text, player.Name, NODT.NameTag)
    end
end

local function setupNotifications()
    if NODT.NotifConn then 
        NODT.NotifConn:Disconnect() 
        NODT.NotifConn = nil 
    end
    if NODT.NotifConn2 then 
        NODT.NotifConn2:Disconnect() 
        NODT.NotifConn2 = nil 
    end
    local player = LocalPlayer
    if not player then return end
    local gui = player.PlayerGui:FindFirstChild("Interface")
    if gui then
        gui = gui:FindFirstChild("Persistent")
        if gui then
            gui = gui:FindFirstChild("Notifications")
        end
    end
    if not gui then return end
    for _, child in ipairs(gui:GetChildren()) do
        processNotification(child)
    end
    NODT.NotifConn = gui.ChildAdded:Connect(function(child)
        task.wait(0.2)
        processNotification(child)
    end)
    NODT.NotifConn2 = gui.DescendantAdded:Connect(function(child)
        if child:IsA("TextLabel") then
            task.wait(0.1)
            local player = LocalPlayer
            if not player then return end
            local text = child.Text or ""
            if CardProtect.hasWord(text, player.Name) then
                child.Text = CardProtect.replaceWord(text, player.Name, NODT.NameTag)
            end
        end
    end)
end

-- Quando ativo: o card customizado e aplicado no ponto E o nome e segurado em NODT.NameTag.
function CardProtect.isActive()
    return CardProtect.enabled
end

function CardProtect.findFrame()
    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local interface = playerGui and playerGui:FindFirstChild("Interface")
    local persistent = interface and interface:FindFirstChild("Persistent")
    return persistent and persistent:FindFirstChild("FlashPlayerCardFrame")
end

-- Decide uma unica vez, pelo texto real, se o Username e do jogador local.
-- Guarda o resultado no proprio label (atributo), assim o nome trocado depois nao engana a checagem.
-- Retorna true/false, ou nil enquanto o texto ainda nao foi preenchido.
-- Procura `word` em `text` (sem diferenciar maiusculas) exigindo borda de palavra:
-- "Bob" casa em "Bob" / "@Bob" / "Bob's", mas NAO em "Bobby" nem "SuperBob".
-- Caractere de palavra = letra, digito, "_" ou byte alto (UTF-8).
function CardProtect.hasWord(text, word)
    if type(text) ~= "string" or type(word) ~= "string" or word == "" then
        return false
    end
    local hay, needle = string.lower(text), string.lower(word)
    local wordChar = "[%w_\128-\255]"
    local init = 1
    while true do
        local first, last = string.find(hay, needle, init, true)
        if not first then return false end
        local before = first > 1 and string.sub(hay, first - 1, first - 1) or ""
        local after = last < #hay and string.sub(hay, last + 1, last + 1) or ""
        if not string.find(before, wordChar) and not string.find(after, wordChar) then
            return true
        end
        init = first + 1
    end
end

-- Substitui `word` por `replacement` somente onde ha borda de palavra (mesma regra do hasWord).
-- Retorna o texto novo (igual ao original se nada casou).
function CardProtect.replaceWord(text, word, replacement)
    if type(text) ~= "string" or type(word) ~= "string" or word == "" then
        return text
    end
    local hay, needle = string.lower(text), string.lower(word)
    local wordChar = "[%w_\128-\255]"
    local out, init, copied = {}, 1, 1
    while true do
        local first, last = string.find(hay, needle, init, true)
        if not first then break end
        local before = first > 1 and string.sub(hay, first - 1, first - 1) or ""
        local after = last < #hay and string.sub(hay, last + 1, last + 1) or ""
        if not string.find(before, wordChar) and not string.find(after, wordChar) then
            table.insert(out, string.sub(text, copied, first - 1))
            table.insert(out, replacement)
            copied = last + 1
            init = last + 1
        else
            init = first + 1
        end
    end
    if copied == 1 then return text end
    table.insert(out, string.sub(text, copied))
    return table.concat(out)
end

function CardProtect.classify(label)
    local flag = label:GetAttribute(CardProtect.flag)
    if flag ~= nil then return flag end
    local text = label.Text or ""
    if text == "" or text == NODT.NameTag then return nil end
    local result = CardProtect.hasWord(text, LocalPlayer.Name)
    local display = LocalPlayer.DisplayName or ""
    if display ~= "" and CardProtect.hasWord(text, display) then
        result = true
    end
    label:SetAttribute(CardProtect.flag, result)
    return result
end

-- Roda no render step com prioridade DEPOIS de "Last", ou seja, depois de todas as
-- animacoes/atualizacoes do jogo naquele frame. A ordem de conexoes do RenderStepped
-- nao e garantida; a prioridade do BindToRenderStep e.
function CardProtect.loop()
    if not CardProtect.isActive() then return end
    local flashFrame = CardProtect.findFrame()
    if not flashFrame then return end
    for _, label in ipairs(flashFrame:GetDescendants()) do
        if label.Name == "Username" and label:IsA("TextLabel") and CardProtect.classify(label) == true then
            if label.Text ~= NODT.NameTag then
                label.Text = NODT.NameTag
            end
        end
    end
end

function CardProtect.stop()
    if CardProtect.bound then
        CardProtect.bound = false
        pcall(RunService.UnbindFromRenderStep, RunService, CardProtect.bindName)
    end
end

function CardProtect.start()
    if CardProtect.bound then return end
    -- Remove qualquer bind com o mesmo nome deixado por uma execucao anterior.
    pcall(RunService.UnbindFromRenderStep, RunService, CardProtect.bindName)
    RunService:BindToRenderStep(CardProtect.bindName, Enum.RenderPriority.Last.Value + 1, function()
        if Library.Unloaded or not CardProtect.enabled then
            CardProtect.stop()
            return
        end
        CardProtect.loop()
    end)
    CardProtect.bound = true
    CardProtect.loop()
end

function CardProtect.set(state)
    CardProtect.enabled = state
    if state then
        CardProtect.start()
    else
        CardProtect.stop()
    end
end

-- True se algum Username do frame ja foi classificado (tem texto real).
function CardProtect.isDetermined(frame)
    for _, label in ipairs(frame:GetDescendants()) do
        if label.Name == "Username" and label:IsA("TextLabel") and CardProtect.classify(label) ~= nil then
            return true
        end
    end
    return false
end

-- True se o frame e do jogador local.
function CardProtect.isLocal(frame)
    for _, label in ipairs(frame:GetDescendants()) do
        if label.Name == "Username" and label:IsA("TextLabel") and CardProtect.classify(label) == true then
            return true
        end
    end
    return false
end

-- Depois de disparar, marca o frame novo como nosso para nao trocá-lo de novo.
function CardProtect.markNewFrame(previous)
    local deadline = os.clock() + 1
    repeat
        if Library.Unloaded then return nil end
        local frame = CardProtect.findFrame()
        -- Pode ja ter sido marcado pelo handler do ChildAdded (frame ~= previous basta).
        if frame and frame ~= previous then
            CardProtect.ours[frame] = true
            CardProtect.expectUntil = 0
            return frame
        end
        task.wait(0.05)
    until os.clock() > deadline
    return nil
end

local function fireCardRemote()
    if hasFiredCard or isProcessing or Library.Unloaded then return end
    local PlayerCardService = getPackageService("PlayerCardService")
    local Remote = PlayerCardService and getServiceChild(PlayerCardService, "RE", "OnFlashCard")
    if not Remote then
        warn("[NodtHub] service not found")
        return
    end
    if Remote and firesignal then
        isProcessing = true
        hasFiredCard = true
        -- pcall garante que as flags sempre sao liberadas, mesmo se algo der erro no meio.
        pcall(function()
            local before = CardProtect.findFrame()
            -- Abre a janela em que o frame que aparecer e considerado o nosso.
            CardProtect.expectUntil = os.clock() + CardProtect.lateWindow
            pcall(firesignal, Remote.OnClientEvent, {
                ["PlayerCardItemId"] = State.selectedCard,
                ["Context"] = {
                    ["Custom"] = {},
                    ["PlacementId"] = "ScoredPoint",
                },
                ["Player"] = LocalPlayer,
            })
            local shown = CardProtect.markNewFrame(before)
            if not shown then
                -- O jogo demorou mais de 1s: continua bloqueado (isProcessing) ate o frame tardio
                -- ser reivindicado pelo handler ou a janela acabar. Sem isso o frame tardio seria
                -- tratado como card do jogo, destruido e recriado em loop.
                local hardDeadline = os.clock() + 2
                while not Library.Unloaded and os.clock() < CardProtect.expectUntil do
                    if os.clock() > hardDeadline then break end
                    task.wait(0.05)
                end
            end
            CardProtect.expectUntil = 0
            task.wait(0.3)
        end)
        hasFiredCard = false
        isProcessing = false
    end
end

-- Chamada pelo toggle "Card Protect": aplica o card na hora, sem precisar do botao Apply.
-- Se ja houver um disparo em andamento, espera ele terminar (ate 3s) antes de disparar.
function CardProtect.forceApply()
    task.spawn(function()
        local deadline = os.clock() + 3
        while (isProcessing or hasFiredCard) and os.clock() < deadline and not Library.Unloaded do
            task.wait(0.05)
        end
        if Library.Unloaded or not CardProtect.enabled then return end
        pcall(fireCardRemote)
    end)
end

-- Trata um frame novo do jogo. Nao descarta o evento: se outro disparo esta em
-- andamento, espera ele terminar e so depois decide.
local function changePlayerCard(frame)
    if Library.Unloaded or not playerCardEnabled then return end
    if not frame or CardProtect.ours[frame] then return end

    -- Frame tardio gerado pelo NOSSO disparo (jogo demorou para mostrar): reivindica e sai,
    -- sem destruir/recriar.
    if os.clock() < CardProtect.expectUntil then
        CardProtect.ours[frame] = true
        CardProtect.expectUntil = 0
        return
    end

    -- O jogo pode preencher o texto depois de criar o frame: espera ate 1.5s.
    local deadline = os.clock() + 1.5
    while not CardProtect.isDetermined(frame) and os.clock() < deadline do
        if Library.Unloaded or not frame.Parent then return end
        task.wait(0.05)
    end

    while (isProcessing or CardProtect.swapping) and frame.Parent do
        if Library.Unloaded then return end
        task.wait(0.05)
    end
    if Library.Unloaded or not frame.Parent or CardProtect.ours[frame] then return end
    if not CardProtect.isLocal(frame) then return end

    CardProtect.swapping = true
    pcall(function()
        frame:Destroy()
        if Library.Unloaded then return end
        fireCardRemote()
    end)
    CardProtect.swapping = false
end

local function disconnectList(list)
    for index = #list, 1, -1 do
        local link = list[index]
        list[index] = nil
        pcall(function()
            link:Disconnect()
        end)
    end
end

-- Handler do ChildAdded da pasta Persistent.
function CardProtect.onChild(child)
    if Library.Unloaded or child.Name ~= "FlashPlayerCardFrame" then return end
    task.spawn(changePlayerCard, child)
end

-- Solta o ChildAdded do card e os vigias da pasta atual.
function CardProtect.detach()
    if cardConnection then
        pcall(function()
            cardConnection:Disconnect()
        end)
        cardConnection = nil
    end
    CardProtect.attachedTo = nil
    disconnectList(CardProtect.guiConns)
end

-- Conecta o ChildAdded em uma pasta Persistent e vigia se ela (ou a Interface) for destruida.
function CardProtect.attach(persistent)
    if Library.Unloaded or not CardProtect.listening or not persistent then return end
    if CardProtect.attachedTo == persistent and cardConnection and cardConnection.Connected then
        return
    end
    CardProtect.detach()
    CardProtect.attachedTo = persistent
    cardConnection = track(persistent.ChildAdded:Connect(CardProtect.onChild))

    -- Persistent destruida (ou Interface inteira destruida): solta e reconecta quando voltar.
    table.insert(CardProtect.guiConns, track(persistent.AncestryChanged:Connect(function()
        if Library.Unloaded or not CardProtect.listening then return end
        local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if not (playerGui and persistent:IsDescendantOf(playerGui)) then
            CardProtect.detach()
            CardProtect.reconnect()
        end
    end)))

    -- Uma nova Persistent apareceu dentro da mesma Interface.
    local interface = persistent.Parent
    if interface then
        table.insert(CardProtect.guiConns, track(interface.ChildAdded:Connect(function(child)
            if Library.Unloaded or not CardProtect.listening then return end
            if child.Name == "Persistent" and child ~= CardProtect.attachedTo then
                CardProtect.reconnect()
            end
        end)))
    end
end

-- Vigia o PlayerGui: se uma nova Interface for criada, reconecta.
function CardProtect.bindRoot(playerGui)
    if CardProtect.rootGui == playerGui and CardProtect.rootConn and CardProtect.rootConn.Connected then
        return
    end
    if CardProtect.rootConn then
        pcall(function()
            CardProtect.rootConn:Disconnect()
        end)
        CardProtect.rootConn = nil
    end
    CardProtect.rootGui = playerGui
    CardProtect.rootConn = track(playerGui.ChildAdded:Connect(function(child)
        if Library.Unloaded or not CardProtect.listening then return end
        if child.Name == "Interface" then
            CardProtect.reconnect()
        end
    end))
end

-- Reconnect: espera (ate 15s) Interface.Persistent existir e conecta o ChildAdded nela.
-- `reconnecting` evita varias esperas simultaneas.
function CardProtect.reconnect()
    if CardProtect.reconnecting or Library.Unloaded or not CardProtect.listening then return end
    CardProtect.reconnecting = true
    task.spawn(function()
        local deadline = os.clock() + 15
        repeat
            if Library.Unloaded or not CardProtect.listening then break end
            local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
            if playerGui then
                pcall(CardProtect.bindRoot, playerGui)
            end
            local interface = playerGui and playerGui:FindFirstChild("Interface")
            local persistent = interface and interface:FindFirstChild("Persistent")
            if persistent then
                pcall(CardProtect.attach, persistent)
                break
            end
            task.wait(0.25)
        until os.clock() > deadline
        CardProtect.reconnecting = false
    end)
end

local function enablePlayerCard()
    if not playerCardEnabled then return end
    CardProtect.listening = true
    -- Se o PlayerGui for recriado, o vigia sobre o LocalPlayer reconecta tudo.
    if not CardProtect.playerGuiConn then
        CardProtect.playerGuiConn = track(LocalPlayer.ChildAdded:Connect(function(child)
            if Library.Unloaded or not CardProtect.listening then return end
            if child:IsA("PlayerGui") then
                CardProtect.reconnect()
            end
        end))
    end
    if cardConnection and cardConnection.Connected then return end
    CardProtect.reconnect()
end

local function disablePlayerCard()
    CardProtect.listening = false
    CardProtect.detach()
    if CardProtect.rootConn then
        pcall(function()
            CardProtect.rootConn:Disconnect()
        end)
        CardProtect.rootConn = nil
        CardProtect.rootGui = nil
    end
    if CardProtect.playerGuiConn then
        pcall(function()
            CardProtect.playerGuiConn:Disconnect()
        end)
        CardProtect.playerGuiConn = nil
    end
end

-- Registra em session.links um "conector" que solta o render step e todos os vigias do card
-- no unload (o BindToRenderStep nao e uma conexao e nao entraria na tabela sozinho).
track({
    Disconnect = function()
        CardProtect.stop()
        pcall(disablePlayerCard)
    end,
})

_G.PlayerCard = {
    Enable = enablePlayerCard,
    Disable = disablePlayerCard,
    SetCard = function(cardName)
        State.selectedCard = cardName
    end,
    GetCard = function()
        return State.selectedCard
    end
}

local function toggleProtection(state)
    State.protectEnabled = state
    if state then
        updateNametag()
        updateTitle()
        setupNotifications()
    else
        if NODT.NotifConn then NODT.NotifConn:Disconnect() NODT.NotifConn = nil end
        if NODT.NotifConn2 then NODT.NotifConn2:Disconnect() NODT.NotifConn2 = nil end
        if LocalPlayer.Character then
            local char = LocalPlayer.Character
            local nameTag = char:FindFirstChild("Nametag")
            if nameTag then
                local label = nameTag:FindFirstChild("PlayerName")
                if label and label:IsA("TextLabel") then
                    label.Text = LocalPlayer.Name
                end
            end
        end
        local player = LocalPlayer
        if player then
            player:SetAttribute("User_Title", "")
        end
    end
end

track(LocalPlayer.CharacterAdded:Connect(function(character)
    if not State.protectEnabled then return end
    local tag = character:WaitForChild("Nametag", 10)
    if not tag or not State.protectEnabled or LocalPlayer.Character ~= character then return end
    tag:WaitForChild("PlayerName", 5)
    if not State.protectEnabled or LocalPlayer.Character ~= character then return end
    updateNametag()
    task.wait(0.5)
    if State.protectEnabled and LocalPlayer.Character == character then
        updateNametag()
    end
end))

local function findFirstPart(model)
    if model.PrimaryPart then
        return model.PrimaryPart
    end
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") and descendant.Name ~= MARK and descendant.Name ~= MARK2 then
            return descendant
        end
    end
    return nil
end

local function ballModels()
    local found = CollectionService:GetTagged("Ball")
    if found[1] then
        return found
    end
    local list = {}
    for _, model in ipairs(Workspace:GetChildren()) do
        if model:IsA("Model") and model.Name:match("^CLIENT_BALL_%d+$") then
            list[#list + 1] = model
        end
    end
    return list
end

local function getBallId()
    for _, model in ipairs(ballModels()) do
        local id = model.Name:match("^CLIENT_BALL_(%d+)$")
        if id then
            return tonumber(id)
        end
    end
    return nil
end

local function reachableBall(params, character, reach)
    if not character then return nil end
    local closest, shortest = nil, reach or hitboxReach
    for _, model in ipairs(params.FilterDescendantsInstances) do
        if model:IsA("Model") then
            local driver = model.PrimaryPart or findFirstPart(model)
            if driver then
                for _, piece in ipairs(character:GetChildren()) do
                    if piece:IsA("BasePart") then
                        local gap = (piece.Position - driver.Position).Magnitude
                        if gap <= shortest then
                            closest, shortest = driver, gap
                        end
                    end
                end
            end
        end
    end
    return closest
end

local function installHitboxHook()
    if hitboxHooked then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("hitbox", function(callNext, self, method, ...)
        if self == Workspace and method == "GetPartsInPart" then
            local spiking = SpikeReach.expiry > os.clock()
            if hitboxEnabled or spiking then
                local probe, params = ...
                if typeof(probe) == "Instance" and typeof(params) == "OverlapParams"
                    and params.FilterType == Enum.RaycastFilterType.Include then
                    local results = callNext(self, method, probe, params)
                    if type(results) == "table" and not results[1] then
                        local driver = reachableBall(params, LocalPlayer.Character, spiking and SpikeReach.reach or hitboxReach)
                        if driver then
                            results[1] = driver
                        end
                    end
                    return results
                end
            end
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        hitboxHooked = true
    end
end

local function adornHolder()
    local camera = Workspace.CurrentCamera or Camera
    local folder = camera:FindFirstChild(MARK)
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = MARK
        folder.Parent = camera
    end
    return folder
end

local function installHitboxFollow()
    if hitboxFollow then return end
    hitboxFollow = track(RunService.RenderStepped:Connect(function()
        for driver, shell in pairs(hitboxBoxes) do
            if driver.Parent and shell.Parent then
                shell.CFrame = driver.CFrame
            end
        end
    end))
end

local function updateHitboxes(scale)
    if not hitboxEnabled then return end
    hitboxReach = scale or hitboxReach
    installHitboxHook()
    installHitboxFollow()
    local folder = adornHolder()
    local live = {}
    for _, model in ipairs(ballModels()) do
        local driver = model.PrimaryPart or findFirstPart(model)
        if driver then
            live[driver] = true
            local shell = hitboxBoxes[driver]
            if not shell or not shell.Parent then
                shell = Instance.new("Part")
                shell.Name = MARK
                shell.Shape = Enum.PartType.Ball
                shell.Material = Enum.Material.ForceField
                shell.Anchored = true
                shell.CanCollide = false
                shell.CanTouch = false
                shell.CanQuery = false
                shell.CastShadow = false
                shell.Massless = true
                shell.Reflectance = 0
                shell.Parent = folder
                hitboxBoxes[driver] = shell
            end
            shell.Size = Vector3.new(2, 2, 2) * hitboxReach
            shell.CFrame = driver.CFrame
            shell.Color = hitboxColor
            shell.Transparency = hitboxTransparency
        end
    end
    for driver, shell in pairs(hitboxBoxes) do
        if not live[driver] then
            if shell.Parent then
                shell:Destroy()
            end
            hitboxBoxes[driver] = nil
        end
    end
end

local function removeHitboxes()
    if hitboxFollow then
        hitboxFollow:Disconnect()
        hitboxFollow = nil
    end
    for driver, shell in pairs(hitboxBoxes) do
        if shell.Parent then
            shell:Destroy()
        end
        hitboxBoxes[driver] = nil
    end
    local camera = Workspace.CurrentCamera or Camera
    local folder = camera:FindFirstChild(MARK)
    if folder then
        folder:Destroy()
    end
end

track(Workspace.ChildAdded:Connect(function(child)
    if child:IsA("Model") and child.Name:match("^CLIENT_BALL_%d+$") then
        for _ = 1, 40 do
            if findFirstPart(child) then
                break
            end
            task.wait(0.05)
        end
        if hitboxEnabled and child.Parent then
            updateHitboxes(hitboxScale)
        end
    end
end))

if hitboxEnabled then
    updateHitboxes(hitboxScale)
end

local function removeLine(player)
    local data = lines[player]
    if data then
        if data.beam then data.beam:Destroy() end
        if data.target and data.target.Parent then data.target:Destroy() end
        if data.attachment and data.attachment.Parent then data.attachment:Destroy() end
        lines[player] = nil
    end
end

local function updateLine(player, index)
    if not linesEnabled then
        removeLine(player)
        return
    end
    local character = player.Character
    if not character or not character:FindFirstChild("Head") or not character:FindFirstChild("HumanoidRootPart") then
        removeLine(player)
        return
    end
    local head = character.Head
    local rootPart = character.HumanoidRootPart
    if not lines[player] then
        local attachment = Instance.new("Attachment", head)
        local target = Instance.new("Part")
        target.Anchored = true
        target.CanCollide = false
        target.Transparency = 1
        target.Size = Vector3.new(0.1, 0.1, 0.1)
        target.Parent = Workspace
        local targetAttachment = Instance.new("Attachment", target)
        local beam = Instance.new("Beam")
        beam.Attachment0 = attachment
        beam.Attachment1 = targetAttachment
        beam.Width0 = 0.25
        beam.Width1 = 0.25
        beam.FaceCamera = true
        beam.LightEmission = 1
        beam.Transparency = NumberSequence.new(0.3)
        beam.Color = ColorSequence.new(lineColors[(index - 1) % #lineColors + 1])
        beam.Parent = head
        lines[player] = { beam = beam, target = target, attachment = attachment }
    end
    local data = lines[player]
    data.target.Position = head.Position + rootPart.CFrame.LookVector * State.lineDistance
end

track(RunService.RenderStepped:Connect(function()
    if linesEnabled then
        for index, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Team ~= LocalPlayer.Team then
                updateLine(player, index)
            else
                removeLine(player)
            end
        end
    else
        for player in pairs(lines) do
            removeLine(player)
        end
    end
end))

track(Players.PlayerRemoving:Connect(removeLine))

_G.Lines = {
    SetEnabled = function(value)
        linesEnabled = value
        if not value then
            for player in pairs(lines) do
                removeLine(player)
            end
        end
    end,
    SetDistance = function(value)
        State.lineDistance = value
    end,
    IsEnabled = function()
        return linesEnabled
    end,
    GetDistance = function()
        return State.lineDistance
    end
}

local function isOnGround()
    local character = LocalPlayer.Character
    if not character then return false end
    local humanoid = character:FindFirstChild("Humanoid")
    if not humanoid then return false end
    local state = humanoid:GetState()
    return state == Enum.HumanoidStateType.Running
        or state == Enum.HumanoidStateType.Landed
        or state == Enum.HumanoidStateType.Ragdoll
        or state == Enum.HumanoidStateType.GettingUp
end

local getNearestBall
do
    -- Cache das bolas (1a BasePart de cada CLIENT_BALL_*), reescaneado a cada 0.2s em vez de todo frame.
    local _ballCache = {}
    local _ballCacheTime = 0
    getNearestBall = function()
        local nearestBall = nil
        local nearestDistance = math.huge
        local character = LocalPlayer.Character
        if not character then return nil, nil end
        local rootPart = character:FindFirstChild("HumanoidRootPart")
        if not rootPart then return nil, nil end
        local now = os.clock()
        if now - _ballCacheTime > 0.2 then
            _ballCacheTime = now
            _ballCache = {}
            for _, model in ipairs(Workspace:GetChildren()) do
                if model:IsA("Model") and model.Name:match("^CLIENT_BALL_%d+$") then
                    for _, part in ipairs(model:GetDescendants()) do
                        if part:IsA("BasePart") then
                            table.insert(_ballCache, part)
                            break
                        end
                    end
                end
            end
        end
        for _, part in ipairs(_ballCache) do
            if part.Parent then
                local distance = (part.Position - rootPart.Position).Magnitude
                if distance < nearestDistance then
                    nearestDistance = distance
                    nearestBall = part
                end
            end
        end
        return nearestBall, nearestDistance
    end
end

local function ballDrift(part)
    getCachedServices()
    local controller = _BallController
    if type(controller) == "table" and type(controller.ActiveBalls) == "table" then
            for _, record in pairs(controller.ActiveBalls) do
                local model = record.Ball
                if model and model.Parent and model:IsAncestorOf(part) and typeof(record.Velocity) == "Vector3" then
                    return record.Velocity
                end
            end
    end
    local now = os.clock()
    local spot, when = Receive.spot, Receive.when
    local same = Receive.part == part
    Receive.part, Receive.spot, Receive.when = part, part.Position, now
    if same and spot and now > when then
        return (part.Position - spot) / (now - when)
    end
    return Vector3.zero
end

local function autoReceive()
    -- Limites (studs / segundos).
    local BASE_RADIUS = Receive.range or 5      -- raio minimo de pegada
    local SPEED_FACTOR = 0.1   -- raio = BASE_RADIUS + velocidade da bola * SPEED_FACTOR
    local MAX_RADIUS = 40      -- teto de seguranca para o raio dinamico
    local RELEASE_RANGE = 15   -- bola alem disso libera a trava
    local LOCK_TIME = 1        -- segundos maximos de trava apos o disparo

    local now = os.clock()
    local character = LocalPlayer.Character
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local alive = rootPart ~= nil and humanoid ~= nil and humanoid.Health > 0

    -- Trava anti toque duplo: enquanto ativa, ignora a bola.
    if Receive.locked then
        local release = false
        if not alive or now - Receive.stamp >= LOCK_TIME then
            -- Morreu, ou passou 1s desde o disparo (o pulo do proprio Set NAO solta a trava).
            release = true
        else
            local lockedBall = getNearestBall()
            if not lockedBall or not lockedBall.Parent
                or (lockedBall.Position - rootPart.Position).Magnitude > (Receive.releaseRange or RELEASE_RANGE) then
                -- Bola se afastou (ou sumiu).
                release = true
            end
        end
        if not release then return end
        Receive.locked = false
    end

    if not State.autoReceiveEnabled then return end
    if not alive then return end
    if not isOnGround() then return end

    local ball = getNearestBall()
    if not ball or not ball.Parent then return end

    -- Raio dinamico (anti-tunneling): quanto mais rapida a bola, maior o raio.
    -- Usa o maior entre a velocidade fisica e a velocidade registrada pelo controller da bola.
    local speed = math.max(ball.AssemblyLinearVelocity.Magnitude, ballDrift(ball).Magnitude)
    local radius = math.min(BASE_RADIUS + speed * SPEED_FACTOR, MAX_RADIUS)

    -- Hitbox ativa: soma o alcance configurado no slider (hitboxReach) ao raio de recepcao.
    -- Somado DEPOIS do teto, para o teto de seguranca nao "comer" o valor da hitbox.
    -- Hitbox desligada: o raio fica exatamente como era.
    if hitboxEnabled then
        radius = radius + hitboxReach
    end

    local ballAhead = ball.Position + ball.AssemblyLinearVelocity * (Receive.lead or 0)
    local distance = (ballAhead - rootPart.Position).Magnitude
    if distance >= radius then return end

    getCachedServices()
    local handlers = _GameHandlers
    if not handlers then return end
    if type(handlers) == "table" and handlers.States then
        local states = handlers.States
        if states.IsBusy:get() or states.IsServing:get() then
            return
        end
    end

    if firesignal then
        -- Trava ativada antes do disparo para impedir qualquer Set duplicado.
        Receive.locked = true
        Receive.stamp = now
        -- Com raio dinamico > 15, a trava so pode soltar por distancia depois que a bola passar do raio.
        Receive.releaseRange = math.max(RELEASE_RANGE, radius + 5)
        firesignal(doMove.OnClientEvent, "Set", false, false)
    end
end

track(RunService.RenderStepped:Connect(autoReceive))

track(LocalPlayer.CharacterAdded:Connect(function()
    Receive.stamp = 0
    Receive.part = nil
end))


local function enableRedirectSpike()
    State.redirectSpikeEnabled = true
    if redirectSpikeInstalled then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("redirectSpike", function(callNext, self, method, ...)
        if not BallService then return callNext(self, method, ...) end
        if self == Interact and method == "InvokeServer" then
            local data = (...)
            if type(data) == "table" and data.Move == "Spike" and State.redirectSpikeEnabled then
                local dir = Camera.CFrame.LookVector
                data.LookVector = dir
                data.Direction = dir
                if data.MoveDirection then
                    data.MoveDirection = dir
                end
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        redirectSpikeInstalled = true
    end
end

local function disableRedirectSpike()
    State.redirectSpikeEnabled = false
end

local AutoCorner = {
    enabled = false,
    side = "Auto",
    reach = "All",
}

local function enableSanjuTilt()
    State.sanjuTiltEnabled = true
    if sanjuTiltInstalled then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("sanjuTilt", function(callNext, self, method, ...)
        if not BallService then return callNext(self, method, ...) end
        if self == Interact and method == "InvokeServer" then
            local data = (...)
            if type(data) == "table" and data.Move == "Spike" and State.sanjuTiltEnabled then
                if data.TiltDirection and data.LookVector then
                    local tiltDir = data.TiltDirection
                    if math.abs(tiltDir.X) > 0.01 or math.abs(tiltDir.Z) > 0.01 then
                        local lookVec = data.LookVector
                        local bend = Vector3.new(tiltDir.X, 0, tiltDir.Z)
                        data.LookVector = Vector3.new(
                            lookVec.X + bend.X * 0.3,
                            lookVec.Y,
                            lookVec.Z + bend.Z * 0.3
                        ).Unit
                        data.TiltDirection = Vector3.new(
                            tiltDir.X * 1.35,
                            tiltDir.Y,
                            tiltDir.Z * 1.35
                        )
                    end
                end
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        sanjuTiltInstalled = true
    end
end

local function disableSanjuTilt()
    State.sanjuTiltEnabled = false
end

AutoCorner.physics = function()
    local reached, module = pcall(require, ReplicatedStorage.Common.Physics)
    return reached and module or nil
end

AutoCorner.bounds = function()
    local physics = AutoCorner.physics()
    if physics and physics._getCourtlines then
        local found, lines = pcall(physics._getCourtlines)
        if found and lines and lines:IsA("BasePart") then
            return lines.Position, lines.Size * 0.5, lines.Position.Y
        end
    end
    local map = Workspace:FindFirstChild("Map")
    local court = map and map:FindFirstChild("Court")
    if court then
        return court.Position, court.Size * 0.5 - Vector3.new(1, 0, 1), court.Position.Y + court.Size.Y * 0.5
    end
    return nil
end

AutoCorner.trackBall = function(ball, before, elapsed)
    if elapsed <= 0 then return end
    local drift = ball.Position - before
    AutoCorner.drift = drift / elapsed
end

AutoCorner.origin = function()
    local ball = getNearestBall()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not ball then
        return root and root.Position or Vector3.zero
    end

    local drift = AutoCorner.drift
    if not root or typeof(drift) ~= "Vector3" or drift.Magnitude < 1 then
        return ball.Position
    end

    local gap = ball.Position - root.Position
    local closing = drift - root.AssemblyLinearVelocity
    local speed = closing:Dot(closing)
    if speed < 1 then
        return ball.Position
    end

    local reach = math.clamp(-gap:Dot(closing) / speed, 0, 0.45)
    return ball.Position + drift * reach
end

local function cornerPoint()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local centre, half, surfaceY = AutoCorner.bounds()
    if not root or not centre then return nil end

    local halfX = math.max(half.X - 2, 1)
    local halfZ = math.max(half.Z - 2, 1)

    local map = Workspace:FindFirstChild("Map")
    local collide = map and map:FindFirstChild("BallCollideOnly")
    local net = collide and collide:FindFirstChild("Net")
    local netZ = net and net.Position.Z or centre.Z

    local index = LocalPlayer.Team and LocalPlayer.Team:GetAttribute("Index")
    local sign
    if index == 1 then
        sign = 1
    elseif index == 2 then
        sign = -1
    else
        sign = (root.Position.Z < netZ) and 1 or -1
    end

    local deepZ = centre.Z + sign * halfZ
    local leftX = centre.X + sign * halfX
    local rightX = centre.X - sign * halfX

    local pivot = AutoCorner.origin()
    local attackLine = half.Z / 3
    local standoff = math.abs(root.Position.Z - netZ)
    local hugging = 1 - math.clamp(standoff / attackLine, 0, 1)
    AutoCorner.lean = hugging

    local shortZ = centre.Z + sign * halfZ * 0.3
    local reach = AutoCorner.reach
    local wantsNear = reach == "Nearest" or (reach ~= "Back" and hugging > 0)

    local side = AutoCorner.side
    if side == "Left" then
        return Vector3.new(leftX, surfaceY, wantsNear and shortZ or deepZ)
    elseif side == "Right" then
        return Vector3.new(rightX, surfaceY, wantsNear and shortZ or deepZ)
    end

    local corners = {}
    if reach ~= "Nearest" then
        corners[#corners + 1] = { at = Vector3.new(leftX, surfaceY, deepZ), reward = 0 }
        corners[#corners + 1] = { at = Vector3.new(rightX, surfaceY, deepZ), reward = 0 }
    end
    if wantsNear then
        corners[#corners + 1] = { at = Vector3.new(leftX, surfaceY, shortZ), reward = 0.45 * hugging }
        corners[#corners + 1] = { at = Vector3.new(rightX, surfaceY, shortZ), reward = 0.45 * hugging }
    end

    local eye = Workspace.CurrentCamera or Camera
    local heading = eye and eye.CFrame.LookVector or root.CFrame.LookVector
    heading = Vector3.new(heading.X, 0, heading.Z)
    if heading.Magnitude < 0.01 then
        return corners[1].at
    end
    heading = heading.Unit

    local physics = AutoCorner.physics()
    local bounds = physics and physics._getCourtlines and physics._getCourtlines()

    local guards = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and (not LocalPlayer.Team or player.Team ~= LocalPlayer.Team) then
            local guardRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            if guardRoot then
                guards[#guards + 1] = Vector3.new(guardRoot.Position.X, surfaceY, guardRoot.Position.Z)
            end
        end
    end

    local aligned = {}
    for _, corner in ipairs(corners) do
        local legal = true
        if bounds and physics.isPositionInCourt then
            local ok, inside = pcall(physics.isPositionInCourt, corner.at, bounds, 0, nil)
            legal = not ok or inside
        end
        if legal then
            local line = Vector3.new(corner.at.X - pivot.X, 0, corner.at.Z - pivot.Z)
            if line.Magnitude > 0.01 then
                local dot = line.Unit:Dot(heading)
                aligned[#aligned + 1] = { spot = corner.at, dot = dot, reward = corner.reward }
            end
        end
    end
    if #aligned == 0 then return corners[1].at end

    local pick
    for _, entry in ipairs(aligned) do
        if not pick or entry.dot > pick.dot then pick = entry end
    end
    local wanted = pick.spot.X >= centre.X

    local best, bestScore
    for _, entry in ipairs(aligned) do
        if (entry.spot.X >= centre.X) == wanted then
            local nearest = 60
            for _, guard in ipairs(guards) do
                local gap = (guard - entry.spot).Magnitude
                if gap < nearest then nearest = gap end
            end
            local score = math.min(nearest, 45) / 45 + entry.reward
            if not bestScore or score > bestScore then
                bestScore = score
                best = entry.spot
            end
        end
    end
    return best or pick.spot
end

AutoCorner.facing = function()
    local spot = cornerPoint()
    if not spot then return nil end
    local pivot = AutoCorner.origin()
    local flat = Vector3.new(spot.X - pivot.X, 0, spot.Z - pivot.Z)

    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if root then
        local map = Workspace:FindFirstChild("Map")
        local collide = map and map:FindFirstChild("BallCollideOnly")
        local net = collide and collide:FindFirstChild("Net")
        local netZ = net and net.Position.Z
        if netZ then
            local ownSide = (root.Position.Z > netZ) and 1 or -1
            if flat.Z * ownSide >= 0 then
                flat = Vector3.new(spot.X - root.Position.X, 0, spot.Z - root.Position.Z)
            end
            if flat.Z * ownSide >= 0 then
                flat = Vector3.new(flat.X, 0, -ownSide * math.max(math.abs(flat.Z), 1))
            end
        end
    end

    if flat.Magnitude < 0.01 then return nil end
    return flat.Unit
end

AutoCorner.installAim = function()
    if AutoCorner.aimed then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("autoCornerAim", function(callNext, self, method, ...)
        if not BallService then return callNext(self, method, ...) end
        if self == Interact and method == "InvokeServer" then
            local data = (...)
            if AutoCorner.enabled and type(data) == "table" and (data.Move == "Spike" or data.Move == "ServeSpike") then
                local steer = AutoCorner.steer
                if typeof(steer) == "Vector3" then
                    local flat = Vector3.new(steer.X, 0, steer.Z)
                    if flat.Magnitude > 0.01 then
                        flat = flat.Unit
                        local aim = (flat - Vector3.new(0, 0.35, 0)).Unit
                        data.LookVector = aim
                        data.Direction = aim
                    end
                end
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        AutoCorner.aimed = true
    end
end

local function enableMaxCharge()
    State.maxChargeEnabled = true
    if maxChargeHookActive then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("maxCharge", function(callNext, self, method, ...)
        if not BallService then return callNext(self, method, ...) end
        if self == Interact and method == "InvokeServer" then
            local data = (...)
            if type(data) == "table" and data.Move == "Spike" and State.maxChargeEnabled then
                data.Charge = 1.0
                data.SpecialCharge = 1.0
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        maxChargeHookActive = true
    end
end

local function disableMaxCharge()
    State.maxChargeEnabled = false
end

local Hush = {
    active = false,
    links = {},
    damped = {},
    paused = {},
    loud = {
        [Enum.AnimationPriority.Action] = true,
        [Enum.AnimationPriority.Action2] = true,
        [Enum.AnimationPriority.Action3] = true,
        [Enum.AnimationPriority.Action4] = true,
    },
}

Hush.gag = function(signal)
    if type(getconnections) ~= "function" then return end
    local listed, cons = pcall(getconnections, signal)
    if not listed or type(cons) ~= "table" then return end
    for _, con in ipairs(cons) do
        pcall(function()
            if con.Enabled ~= false then
                con:Disable()
                Hush.paused[#Hush.paused + 1] = con
            end
        end)
    end
end

Hush.quiet = function(inst)
    if not inst:IsA("Sound") then return end
    Hush.damped[#Hush.damped + 1] = { inst = inst, level = inst.Volume }
    pcall(function()
        inst.Volume = 0
        inst:Stop()
    end)
end

Hush.start = function()
    if Hush.active then return end
    Hush.active = true

    Hush.gag(EffectsRemote.OnClientEvent)
    Hush.gag(GameEffectRemote.OnClientEvent)

    Hush.animUntil = os.clock() + 0.2
    local character = LocalPlayer.Character
    local animator = character and character:FindFirstChildWhichIsA("Animator", true)
    if animator then
        for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
            if Hush.loud[track.Priority] then
                pcall(track.Stop, track, 0)
            end
        end
        Hush.links[#Hush.links + 1] = animator.AnimationPlayed:Connect(function(track)
            if not Hush.active or os.clock() > Hush.animUntil then return end
            if Hush.loud[track.Priority] then
                pcall(track.Stop, track, 0)
            end
        end)
    end

    for _, root in ipairs({ Workspace, game:GetService("SoundService"), character }) do
        if root then
            Hush.links[#Hush.links + 1] = root.DescendantAdded:Connect(function(inst)
                if Hush.active then
                    Hush.quiet(inst)
                end
            end)
        end
    end
end

Hush.stop = function()
    if not Hush.active then return end
    Hush.active = false
    for _, link in ipairs(Hush.links) do
        pcall(function() link:Disconnect() end)
    end
    Hush.links = {}
    for _, con in ipairs(Hush.paused) do
        pcall(function() con:Enable() end)
    end
    Hush.paused = {}
    for _, record in ipairs(Hush.damped) do
        if record.inst.Parent then
            pcall(function() record.inst.Volume = record.level end)
        end
    end
    Hush.damped = {}
end

local function enemyAim()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local centre, half, surfaceY = AutoCorner.bounds()
    if not centre then return nil end

    local map = Workspace:FindFirstChild("Map")
    local collide = map and map:FindFirstChild("BallCollideOnly")
    local net = collide and collide:FindFirstChild("Net")
    local netZ = net and net.Position.Z or centre.Z
    local netTop = net and (net.Position.Y + net.Size.Y * 0.5) or surfaceY

    local index = LocalPlayer.Team and LocalPlayer.Team:GetAttribute("Index")
    local sign
    if index == 1 then
        sign = 1
    elseif index == 2 then
        sign = -1
    else
        sign = (root.Position.Z < netZ) and 1 or -1
    end

    local ball = getNearestBall()
    local origin = ball and ball.Position or (root.Position + Vector3.new(0, 6, 0))
    local headroom = origin.Y - netTop
    local standoff = math.max(math.abs(netZ - origin.Z), 2)
    local drop = math.clamp(0.45 * headroom / standoff, -0.05, 0.30)

    local halfZ = math.max(half.Z - 2, 1)
    local target = Vector3.new(centre.X + (origin.X - centre.X) * 0.25, surfaceY, centre.Z + sign * halfZ * 0.55)

    local flat = Vector3.new(target.X - origin.X, 0, target.Z - origin.Z)
    if flat.Magnitude < 0.01 then return nil end
    return (flat.Unit - Vector3.new(0, drop, 0)).Unit
end

local Silent = { steer = nil, expiry = 0, hooked = false }

Silent.install = function()
    if Silent.hooked then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("silentSpike", function(callNext, self, method, ...)
        if not BallService then return callNext(self, method, ...) end
        if self == Interact and method == "InvokeServer" then
            local data = (...)
            local steer = Silent.steer
            if steer ~= nil then
                if os.clock() >= Silent.expiry then
                    Silent.steer = nil
                    Silent.expiry = 0
                elseif type(data) == "table" and typeof(steer) == "Vector3" then
                    if data.Move == "Spike" or data.Move == "ServeSpike" then
                        data.LookVector = steer
                        data.Direction = steer
                        local ground = Vector3.new(steer.X, 0, steer.Z)
                        if typeof(data.TiltDirection) == "Vector3" and ground.Magnitude > 0.01 then
                            local power = Vector3.new(data.TiltDirection.X, 0, data.TiltDirection.Z).Magnitude
                            if power > 0.05 then
                                local lean = ground.Unit * power
                                data.TiltDirection = Vector3.new(lean.X, data.TiltDirection.Y, lean.Z)
                            end
                        end
                        -- one shot: the next spike the player throws must not be steered
                        Silent.steer = nil
                        Silent.expiry = 0
                    end
                end
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        Silent.hooked = true
    end
end

local function fireNewSpike()
    if not State.newSilentSpikeEnabled then return end
    if not firesignal then return end
    local newRemote = doMove
    if not newRemote then
        warn("[NodtHub] service not found")
        return
    end
    Hush.start()
    installHitboxHook()
    SpikeReach.expiry = os.clock() + 0.3
    local dir = enemyAim() or Camera.CFrame.LookVector
    local expiry = os.clock() + 0.8
    Silent.steer = dir
    Silent.expiry = expiry
    Silent.install()
    firesignal(newRemote.OnClientEvent, "Spike", false, false, dir)
    task.spawn(function()
        task.wait(0.3)
        Hush.stop()
    end)
    task.delay(0.8, function()
        if Silent.expiry == expiry then
            Silent.steer = nil
            Silent.expiry = 0
        end
    end)
end

local function createNewSpikeButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    screenGui.ResetOnSpawn = false
    newSpikeButton = Instance.new("TextButton")
    newSpikeButton.Size = UDim2.new(0, 50, 0, 50)
    newSpikeButton.Position = UDim2.new(0.5, -25, 0.85, -25)
    newSpikeButton.BackgroundColor3 = Color3.fromRGB(9, 13, 16)
    newSpikeButton.Text = "Spike"
    newSpikeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    newSpikeButton.TextScaled = true
    newSpikeButton.Font = Enum.Font.GothamBold
    newSpikeButton.Parent = screenGui
    newSpikeButton.BackgroundTransparency = 0.12
    newSpikeButton.BorderSizePixel = 0
    newSpikeButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = newSpikeButton
    local ring = Instance.new("UIStroke")
    ring.Color = Color3.fromRGB(255, 76, 46)
    ring.Thickness = 2
    ring.Transparency = 0.1
    ring.Parent = newSpikeButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    newSpikeButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = newSpikeButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    newSpikeButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            newSpikeButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    newSpikeButton.MouseButton1Click:Connect(function()
        fireNewSpike()
    end)
    newSpikeButton.Visible = false
    return newSpikeButton
end

newSpikeButton = createNewSpikeButton()

local function enableDesync()
    if desyncConnection then return end
    if not doMove then
        warn("[NodtHub] service not found")
        return
    end
    desyncConnection = UserInputService.JumpRequest:Connect(function()
        if State.desyncEnabled then
            task.wait(0.03)
            -- Com Auto Receive ativo: espera o jogador chegar a menos de 5 studs da bola
            -- antes de disparar (evita atropelar o deslize). Timeout de 2s cancela o disparo.
            if State.autoReceiveEnabled then
                local waitDeadline = os.clock() + 2
                local nearBall = false
                while State.autoReceiveEnabled and State.desyncEnabled and os.clock() < waitDeadline do
                    local _, ballDistance = getNearestBall()
                    if ballDistance and ballDistance < 5 then
                        nearBall = true
                        break
                    end
                    task.wait(0.03)
                end
                if not State.desyncEnabled then return end
                if State.autoReceiveEnabled and not nearBall then return end
            end
            -- Clamp de seguranca (apenas horizontal X/Z; Y livre para dive/LeadFeet).
            local desyncCharacter = LocalPlayer.Character
            local desyncRoot = desyncCharacter and desyncCharacter:FindFirstChild("HumanoidRootPart")
            if desyncRoot then
                local vel = desyncRoot.AssemblyLinearVelocity
                if math.abs(vel.X) > 50 or math.abs(vel.Z) > 50 then
                    desyncRoot.AssemblyLinearVelocity = Vector3.new(math.clamp(vel.X, -50, 50), vel.Y, math.clamp(vel.Z, -50, 50))
                end
            end
            if firesignal then
                firesignal(doMove.OnClientEvent, "Spike", false, false)
            end
        end
    end)
    State.desyncEnabled = true
end

local function disableDesync()
    if desyncConnection then
        desyncConnection:Disconnect()
        desyncConnection = nil
    end
    State.desyncEnabled = false
end

track(UserInputService.JumpRequest:Connect(function()
    if not State.kazanaBlueEnabled and not State.kazanaWhiteEnabled then
        return
    end
    local character = LocalPlayer.Character
    if not character or not character.PrimaryPart then
        return
    end
    if os.clock() - (seen.__kazanaAt or 0) < 0.35 then
        return
    end
    seen.__kazanaAt = os.clock()

    local white = State.kazanaWhiteEnabled
    local effectFolder = ReplicatedStorage.Assets:FindFirstChild("Effects")
    local module = effectFolder and effectFolder:FindFirstChild(white and "KazanaWhite" or "KazanaBlue")
    if not module then
        return
    end

    local restore = getthreadidentity and getthreadidentity()
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    pcall(function()
        require(module)(character)
        require(ReplicatedStorage.Tools.Sound).fromName(white and "Kazana_White" or "Kazana_Blue")({})
    end)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end
end))

local function playDashEffect(direction)
    local restore = getthreadidentity and getthreadidentity()
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    pcall(function()
        local Effect = require(ReplicatedStorage.Content.Effect)
        Effect:Play("KuraiDashFX")({
            Player = LocalPlayer,
            Direction = direction,
        })
    end)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end
end

local function akariDash()
    if not State.akariDashEnabled then return end
    local character = LocalPlayer.Character
    if not character then return end
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local direction, distance = nil, 10
    local ball = getNearestBall()
    if ball then
        local flat = Vector3.new(ball.Position.X - hrp.Position.X, 0, ball.Position.Z - hrp.Position.Z)
        if flat.Magnitude > 0.01 then
            direction = flat.Unit
            distance = math.clamp(flat.Magnitude - 1, 0, 16)
        end
    end
    if not direction then
        local forward = Camera.CFrame.LookVector
        direction = Vector3.new(forward.X, 0, forward.Z).Unit
    end
    playDashEffect(direction)
    local tween = game:GetService("TweenService"):Create(hrp, TweenInfo.new(0.2, Enum.EasingStyle.Linear), {
        CFrame = CFrame.new(hrp.Position + (direction * distance)) * CFrame.Angles(0, math.rad(hrp.Orientation.Y), 0)
    })
    tween:Play()
end

local function createDashButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    screenGui.ResetOnSpawn = false
    dashButton = Instance.new("TextButton")
    dashButton.Size = UDim2.new(0, 50, 0, 50)
    dashButton.Position = UDim2.new(0.15, -25, 0.8, -25)
    dashButton.BackgroundColor3 = Color3.fromRGB(9, 13, 16)
    dashButton.Text = "⚡"
    dashButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    dashButton.TextScaled = true
    dashButton.Font = Enum.Font.GothamBold
    dashButton.Parent = screenGui
    dashButton.BackgroundTransparency = 0.12
    dashButton.BorderSizePixel = 0
    dashButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = dashButton
    local ring = Instance.new("UIStroke")
    ring.Color = Color3.fromRGB(255, 76, 46)
    ring.Thickness = 2
    ring.Transparency = 0.1
    ring.Parent = dashButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    dashButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = dashButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    dashButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            dashButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    dashButton.MouseButton1Click:Connect(akariDash)
    dashButton.Visible = false
    return dashButton
end

createDashButton()

local function stopBall()
    if not BallService then return end
    local ballId = getBallId()
    if not ballId then return end
    local lookVector = Vector3.new(0, -1, 0)
    if Interact then
        Interact:InvokeServer({
            ["Charge"] = 1,
            ["Move"] = "Block",
            ["SpecialCharge"] = 0,
            ["TiltDirection"] = Vector3.new(-0.1260179579257965, 1, 0.992027997970581),
            ["LookVector"] = lookVector,
            ["MoveDirection"] = Vector3.new(0, 0, 0),
            ["ClientCanRunSpecial"] = false,
            ["From"] = "Client",
            ["BallId"] = ballId,
            ["Timestamp"] = tick(),
            ["CustomClient"] = {},
        })
    end
end

local function createStopBallButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    screenGui.ResetOnSpawn = false
    stopBallButton = Instance.new("TextButton")
    stopBallButton.Size = UDim2.new(0, 50, 0, 50)
    stopBallButton.Position = UDim2.new(0.35, -25, 0.8, -25)
    stopBallButton.BackgroundColor3 = Color3.fromRGB(9, 13, 16)
    stopBallButton.Text = "Stop"
    stopBallButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    stopBallButton.TextScaled = true
    stopBallButton.Font = Enum.Font.GothamBold
    stopBallButton.Parent = screenGui
    stopBallButton.BackgroundTransparency = 0.12
    stopBallButton.BorderSizePixel = 0
    stopBallButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = stopBallButton
    local ring = Instance.new("UIStroke")
    ring.Color = Color3.fromRGB(255, 92, 110)
    ring.Thickness = 2
    ring.Transparency = 0.1
    ring.Parent = stopBallButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    stopBallButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = stopBallButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    stopBallButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            stopBallButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    stopBallButton.MouseButton1Click:Connect(function()
        stopBall()
    end)
    stopBallButton.Visible = stopBallVisible
    return stopBallButton
end

local AutoCounter = (function()
    local ReplicatedFirst = game:GetService("ReplicatedFirst")

    local state = {
        enabled = false,
        move = "Auto",
        netRange = 9,
        lateral = 14,
        reach = 16,
        delay = 0.05,
        cooldown = 0.8,
        autoJump = true,
    }

    -- Constantes internas (studs / segundos).
    local ANTICIPATION = 0.1   -- antecipacao para compensar o ping
    local REARM_TIMEOUT = 3    -- rearme forcado caso a ameaca nunca desapareca

    local handlers = nil
    local controller = nil
    local firing = false
    local lastFire = 0
    local armed = true         -- so ataca de novo depois que o ataque atual terminar (ameaca sumir)
    local sample = { part = nil, pos = nil, time = 0 }

    local function elevate(fn)
        local restore = getthreadidentity and getthreadidentity()
        if setthreadidentity then
            pcall(setthreadidentity, 2)
        end
        local ok = pcall(fn)
        if setthreadidentity and restore then
            pcall(setthreadidentity, restore)
        end
        return ok
    end

    local lastBindAttempt = 0
    local function bind()
        if handlers and controller then return true end
        local now = os.clock()
        if now - lastBindAttempt < 1 then return false end
        lastBindAttempt = now
        elevate(function()
            handlers = require(ReplicatedFirst.Controllers.GameController.Handlers)
            local Knit = getKnitRoot()
            if not Knit then return end
            controller = Knit.GetController("GameController")
        end)
        return handlers ~= nil and controller ~= nil
    end

    -- Velocidade da bola para a antecipacao. Como a velocidade fisica costuma ser zero no cliente,
    -- a velocidade e medida pelo deslocamento visivel entre frames. Se nada se move, retorna zero
    -- (a antecipacao simplesmente nao muda nada e a deteccao antiga continua valendo).
    local function ballVelocity(part)
        local now = os.clock()
        local position = part.Position
        local measured = Vector3.zero
        if sample.part == part and sample.pos and now > sample.time and now - sample.time <= 0.25 then
            local candidate = (position - sample.pos) / (now - sample.time)
            if candidate.Magnitude <= 400 then
                measured = candidate
            end
        end
        sample.part, sample.pos, sample.time = part, position, now

        local physical = part.AssemblyLinearVelocity
        if physical.Magnitude > 0.5 then
            return physical
        end
        return measured
    end

    local function getNet()
        local tagged = CollectionService:GetTagged("Net")[1]
        if tagged and tagged:IsA("BasePart") then
            return tagged
        end
        local map = Workspace:FindFirstChild("Map")
        local collide = map and map:FindFirstChild("BallCollideOnly")
        return collide and collide:FindFirstChild("Net")
    end

    local function ownSide(root, netZ)
        local team = LocalPlayer.Team
        local index = team and team:GetAttribute("Index")
        if index == 1 then return -1 end
        if index == 2 then return 1 end
        return (root.Position.Z >= netZ) and 1 or -1
    end

    -- Deteccao antiga (inimigo com attribute "Jumping" + bola perto dele), com antecipacao de 0.1s.
    -- Retorna: bola, posicao da bola (+ANTICIPATION), netZ, side.
    local function findThreat(root, net)
        local netZ = net.Position.Z
        local netTop = net.Position.Y + net.Size.Y * 0.5
        local side = ownSide(root, netZ)

        local myGap = (root.Position.Z - netZ) * side
        if myGap < 0 or myGap > state.netRange then return nil end

        local ball = getNearestBall()
        if not ball or not ball.Parent then return nil end
        local ballVel = ballVelocity(ball)
        if ball.Position.Y < netTop - 3 then return nil end
        if math.abs(ball.Position.Z - netZ) > state.netRange + 6 then return nil end
        if math.abs(ball.Position.X - root.Position.X) > state.lateral then return nil end

        local ballAhead = ball.Position + ballVel * ANTICIPATION

        local myTeam = LocalPlayer.Team
        for _, player in ipairs(Players:GetPlayers()) do
            local hostile = player ~= LocalPlayer and (myTeam == nil or player.Team ~= myTeam)
            if hostile then
                local character = player.Character
                local enemyRoot = character and character:FindFirstChild("HumanoidRootPart")
                if enemyRoot and character:GetAttribute("Jumping") then
                    local enemyGap = (enemyRoot.Position.Z - netZ) * side
                    if enemyGap < 0 and -enemyGap <= state.netRange + 4
                        and math.abs(enemyRoot.Position.X - root.Position.X) <= state.lateral then
                        -- Bola perto do inimigo agora OU daqui a 0.1s (a antecipacao so adianta, nunca bloqueia).
                        local enemyAhead = enemyRoot.Position + enemyRoot.AssemblyLinearVelocity * ANTICIPATION
                        local near = (ball.Position - enemyRoot.Position).Magnitude <= state.reach
                            or (ballAhead - enemyAhead).Magnitude <= state.reach
                        if near then
                            return ball, ballAhead, netZ, side
                        end
                    end
                end
            end
        end
        return nil
    end

    local function pickMove(ahead, netZ, side)
        if state.move ~= "Auto" then return state.move end
        if (ahead.Z - netZ) * side > 0 then return "Spike" end
        return "Block"
    end

    local function fire(move)
        if not bind() then return false end
        local states = handlers.States
        if states.IsBusy:get() or states.IsStunned:get() or states.IsServing:get() then return false end
        if not states.IsPlaying:get() then return false end
        if ReplicatedStorage:GetAttribute("ServedByTeam") then return false end

        firing = true
        armed = false
        lastFire = os.clock() -- cooldown comeca na tentativa, nao so no fim
        task.spawn(function()
            if state.autoJump and not states.IsJumping:get() then
                elevate(function() controller:PerformJump() end)
            end
            if state.delay > 0 then
                task.wait(state.delay)
            end
            elevate(function()
                controller:DoMove({
                    ActionName = move,
                    IsAerial = true,
                    InputState = Enum.UserInputState.Begin,
                    Metadata = {},
                })
            end)
            lastFire = os.clock()
            firing = false
        end)
        return true
    end

    local function step()
        if Library.Unloaded then return end
        if not state.enabled or firing then return end
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not root then return end
        local net = getNet()
        if not net then return end

        local now = os.clock()
        local ball, ahead, netZ, side = findThreat(root, net)
        if not ball then
            armed = true -- a ameaca sumiu: libera para o proximo ataque
            return
        end
        if now - lastFire < state.cooldown then return end
        if not armed then
            -- Jogada ja tentada (mesmo que tenha falhado): espera o proximo ataque.
            if now - lastFire < REARM_TIMEOUT then return end
            armed = true
        end
        fire(pickMove(ahead, netZ, side))
    end

    track(RunService.Heartbeat:Connect(step))

    return { state = state }
end)()

local function getNearestTeammate()
    local nearest = nil
    local shortestDistance = math.huge
    local playerRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not playerRoot then return nil end
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Team == LocalPlayer.Team then
            local character = player.Character
            if character then
                local rootPart = character:FindFirstChild("HumanoidRootPart")
                if rootPart then
                    local distance = (rootPart.Position - playerRoot.Position).Magnitude
                    if distance < shortestDistance then
                        shortestDistance = distance
                        nearest = player
                    end
                end
            end
        end
    end
    return nearest
end

local function aim()
    if not BallService then return end
    local ballId = getBallId()
    if not ballId then return end
    local nearestTeammate = getNearestTeammate()
    if not nearestTeammate then return end
    if not nearestTeammate.Character then return end
    local targetRoot = nearestTeammate.Character:FindFirstChild("HumanoidRootPart")
    local playerRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not targetRoot or not playerRoot then return end
    local direction = (targetRoot.Position - playerRoot.Position).Unit
    local tiltDir = Vector3.new(direction.X, 1, direction.Z)
    local lookVec = Vector3.new(direction.X, 0, direction.Z)
    if lookVec.Magnitude > 0 then
        lookVec = lookVec.Unit
    else
        lookVec = Vector3.new(0.17569558322429657, 9.214759444375886e-08, -0.9844445586204529)
    end
    if Interact then
        Interact:InvokeServer({
            ["Charge"] = 1,
            ["Move"] = "JumpSet",
            ["SpecialCharge"] = 0.9999996364706223,
            ["TiltDirection"] = tiltDir,
            ["LookVector"] = lookVec,
            ["MoveDirection"] = Vector3.new(0, 0, 0),
            ["ClientCanRunSpecial"] = false,
            ["From"] = "Client",
            ["Timestamp"] = tick(),
            ["BallId"] = ballId,
            ["CustomClient"] = {},
        })
    end
end

local function createAimButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    screenGui.ResetOnSpawn = false
    aimButton = Instance.new("TextButton")
    aimButton.Size = UDim2.new(0, 50, 0, 50)
    aimButton.Position = UDim2.new(0.65, -25, 0.8, -25)
    aimButton.BackgroundColor3 = Color3.fromRGB(9, 13, 16)
    aimButton.Text = "Aim"
    aimButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    aimButton.TextScaled = true
    aimButton.Font = Enum.Font.GothamBold
    aimButton.Parent = screenGui
    aimButton.BackgroundTransparency = 0.12
    aimButton.BorderSizePixel = 0
    aimButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = aimButton
    local ring = Instance.new("UIStroke")
    ring.Color = Color3.fromRGB(255, 76, 46)
    ring.Thickness = 2
    ring.Transparency = 0.1
    ring.Parent = aimButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    aimButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = aimButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    aimButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            aimButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    aimButton.MouseButton1Click:Connect(function()
        aim()
    end)
    aimButton.Visible = aimVisible
    return aimButton
end

track(RunService.RenderStepped:Connect(function()
    if not State.airMovement then
        if bodyVelocity then
            bodyVelocity:Destroy()
            bodyVelocity = nil
        end
        return
    end

    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root then
        return
    end

    -- Clamp de seguranca (apenas horizontal X/Z; Y livre para dive/LeadFeet).
    local vel = root.AssemblyLinearVelocity
    if math.abs(vel.X) > 50 or math.abs(vel.Z) > 50 then
        root.AssemblyLinearVelocity = Vector3.new(math.clamp(vel.X, -50, 50), vel.Y, math.clamp(vel.Z, -50, 50))
    end

    if not bodyVelocity or bodyVelocity.Parent ~= root then
        if bodyVelocity then
            bodyVelocity:Destroy()
        end
        bodyVelocity = Instance.new("BodyVelocity")
        bodyVelocity.Name = MARK
        bodyVelocity.MaxForce = Vector3.zero
        bodyVelocity.Velocity = Vector3.zero
        bodyVelocity.P = 12500
        bodyVelocity.Parent = root
    end

    local direction = humanoid.MoveDirection
    if direction.Magnitude == 0 then
        if seen.__controls == nil then
            local reached, controls = pcall(function()
                return require(LocalPlayer.PlayerScripts.PlayerModule):GetControls()
            end)
            seen.__controls = (reached and controls) or false
        end
        if seen.__controls then
            local read, raw = pcall(seen.__controls.GetMoveVector, seen.__controls)
            if read and typeof(raw) == "Vector3" and raw.Magnitude > 0 then
                local camera = Workspace.CurrentCamera
                if camera then
                    raw = camera.CFrame:VectorToWorldSpace(raw)
                end
                direction = Vector3.new(raw.X, 0, raw.Z)
            end
        end
    end

    if humanoid.FloorMaterial == Enum.Material.Air and direction.Magnitude > 0 then
        bodyVelocity.MaxForce = Vector3.new(math.huge, 0, math.huge)
        bodyVelocity.Velocity = direction.Unit * State.airMovementSpeed
    else
        bodyVelocity.MaxForce = Vector3.zero
        bodyVelocity.Velocity = Vector3.zero
    end
end))
local function isEnemy(player)
    if player == LocalPlayer then return false end
    if not player.Team or not LocalPlayer.Team then return false end
    return player.Team ~= LocalPlayer.Team
end

local function applyESP(player)
    if not player.Character or espHighlights[player] then return end
    local tone = Color3.fromRGB(255, 72, 72)
    local highlight = Instance.new("Highlight")
    highlight.Name = MARK
    highlight.Adornee = player.Character
    highlight.FillColor = tone
    highlight.FillTransparency = 0.72
    highlight.OutlineTransparency = 0
    highlight.OutlineColor = tone
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Parent = player.Character
    espHighlights[player] = highlight
end

local function removeESP(player)
    if espHighlights[player] then
        espHighlights[player]:Destroy()
        espHighlights[player] = nil
    end
end

local function cleanupConnections(player)
    if espConnections[player] then
        for _, connection in pairs(espConnections[player]) do
            connection:Disconnect()
        end
        espConnections[player] = nil
    end
    removeESP(player)
end

local function setupESP(player)
    if player == LocalPlayer then return end
    local function onCharacterAdded(character)
        cleanupConnections(player)
        local humanoid = character:WaitForChild("Humanoid", 3)
        local head = character:FindFirstChild("Head")
        if not humanoid or not head then return end
        local stateConnection = humanoid.StateChanged:Connect(function(_, newState)
            if not State.espJumpEnabled or not isEnemy(player) then
                removeESP(player)
                return
            end
            if newState == Enum.HumanoidStateType.Jumping or newState == Enum.HumanoidStateType.Freefall then
                applyESP(player)
            elseif newState == Enum.HumanoidStateType.Landed or newState == Enum.HumanoidStateType.Running then
                removeESP(player)
            end
        end)
        local heartbeatConnection = RunService.Heartbeat:Connect(function()
            if not State.espJumpEnabled or not player.Character or not isEnemy(player) then
                removeESP(player)
                return
            end
            local state = humanoid:GetState()
            if state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall then
                applyESP(player)
            else
                removeESP(player)
            end
        end)
        espConnections[player] = { track(stateConnection), track(heartbeatConnection) }
    end
    if player.Character then
        onCharacterAdded(player.Character)
    end
    track(player.CharacterAdded:Connect(onCharacterAdded))
end

for _, player in ipairs(Players:GetPlayers()) do
    setupESP(player)
end
track(Players.PlayerAdded:Connect(setupESP))

local function enableMaxServe()
    State.maxServeEnabled = true
    if maxServeHookActive then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("maxServe", function(callNext, self, method, ...)
        if not Serve then return callNext(self, method, ...) end
        if self == Serve and method == "InvokeServer" and State.maxServeEnabled then
            local args = {...}
            args[2] = 5
            return callNext(self, method, unpack(args))
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        maxServeHookActive = true
    end
end

local function disableMaxServe()
    State.maxServeEnabled = false
end

local function leadFeetSlam()
    if not State.leadFeetEnabled then return end
    local character = LocalPlayer.Character
    if not character or not character.PrimaryPart then return end
    local root = character.PrimaryPart
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return end

    local tuning = { Acceleration = -10000, TerminalVelocity = -300, Duration = 2 }
    local controller = nil

    local restore = getthreadidentity and getthreadidentity()
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    pcall(function()
        local ability = require(ReplicatedStorage.Content.Ability.LeadFeet)
        if type(ability) == "table" and type(ability.Metadata) == "table" then
            tuning = ability.Metadata
        end
        local Knit = getKnitRoot()
        if not Knit then return end
        controller = Knit.GetController("GameController")
        if controller then
            controller.IsBusy:set(false)
        end
        require(ReplicatedStorage.Content.Effect):Play("LeadFeetFX")({ Player = LocalPlayer })
        require(game:GetService("ReplicatedFirst").Controllers.GameController.Actions.Move.Jump).stop()
        if controller then
            controller.IsBusy:set(true)
        end
    end)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end

    if leadFeetLink then
        leadFeetLink:Disconnect()
        leadFeetLink = nil
    end

    local expiry = os.clock() + (tuning.Duration or 2)
    leadFeetLink = RunService.Heartbeat:Connect(function(delta)
        if not root.Parent or humanoid.FloorMaterial ~= Enum.Material.Air or os.clock() >= expiry then
            if controller then
                controller.IsBusy:set(false)
            end
            if leadFeetLink then
                leadFeetLink:Disconnect()
                leadFeetLink = nil
            end
            return
        end
        local velocity = root.AssemblyLinearVelocity
        local drop = math.max(velocity.Y + (tuning.Acceleration or -10000) * delta, tuning.TerminalVelocity or -300)
        root.AssemblyLinearVelocity = Vector3.new(velocity.X, drop, velocity.Z)
    end)
end

local function createLeadFeetButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    screenGui.ResetOnSpawn = false
    leadFeetButton = Instance.new("TextButton")
    leadFeetButton.Size = UDim2.new(0, 50, 0, 50)
    leadFeetButton.Position = UDim2.new(0.25, -25, 0.8, -25)
    leadFeetButton.BackgroundColor3 = Color3.fromRGB(9, 13, 16)
    leadFeetButton.Text = "LF"
    leadFeetButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    leadFeetButton.TextScaled = true
    leadFeetButton.Font = Enum.Font.GothamBold
    leadFeetButton.Parent = screenGui
    leadFeetButton.BackgroundTransparency = 0.12
    leadFeetButton.BorderSizePixel = 0
    leadFeetButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = leadFeetButton
    local ring = Instance.new("UIStroke")
    ring.Color = Color3.fromRGB(255, 76, 46)
    ring.Thickness = 2
    ring.Transparency = 0.1
    ring.Parent = leadFeetButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    leadFeetButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = leadFeetButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    leadFeetButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            leadFeetButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    leadFeetButton.MouseButton1Click:Connect(leadFeetSlam)
    leadFeetButton.Visible = false
    return leadFeetButton
end

createLeadFeetButton()

local function loadJerseys()
    jerseyList = {
        "BlueOnesieJersey", "ClassicJersey", "CursedTournamentTop100Jersey", "CursedTournamentTop1Jersey", "CursedTournamentTop1KJersey", "DragonTuxedoJersey", "NeonJersey", "PajamasJersey", "PastelJersey", "PinkOnesieJersey", "PirateJersey", "RainbowJersey", "RefJersey", "SkeletonJersey", "SkeletonJerseySeason19", "SparkleTimeJersey", "T1TournamentJersey", "TournamentJersey", "TournamentTop100BeachJersey", "TournamentTop10BeachJersey", "TournamentTop1BeachJersey", "TuxedoJersey", "VampireJersey"
    }
    return jerseyList
end

loadJerseys()

local function loadBallSkins()
    ballSkinList = {
        "2026ChocolateEggBall", "2026EasterEggBall", "AcornBall", "AlienBall", "AngelHeadBall", "AngelicBall", "AngryEmojiBall", "AnimeVolleyBall", "ArrowBall", "AuroraBall", "BananaBall", "Basketball", "BeachBall", "BeachGlobeBall", "BlackBall", "BlueAndYellowBall", "BooBall", "BrainBall", "BronzeCannonBall", "BronzeCloverBall", "BronzeCoconutBall", "BronzeEggBall", "BronzeFestivalBall", "BronzeHeartBall", "BronzeOrnamentBall", "BronzeRibcageBall", "BronzeSeashellBall", "BunnyBall", "BunnyEggBall", "CakeBall", "CameraBall", "CandleBall", "CauldronBall", "CelestialOrbBall", "ChocolateBunnyHeadBall", "ChocolateCoveredBall", "ChocolateCoveredNerdBall", "ChocolateEggBall", "ChocolateHeartBall", "ChristmasLightsBall", "ClassicBall", "CloverBall", "ClownBall", "CoalBall", "CoconutBall", "CoralReefBall", "CrabBall", "CrackedBall", "CrackedEasterEggBall", "CraftyBall", "CryoFlareBall", "CursedKrakenEyeBall", "CuteKittyBall", "DarkBatBall", "DecoratedEasterEggBall", "DemonBall", "DevilBall", "DevilHeadBall", "DiamondAcornBall", "DiamondBall", "DiamondCannonBall", "DiamondCloverBall", "DiamondCoconutBall", "DiamondEggBall", "DiamondEyeBall", "DiamondFestivalBall", "DiamondHeartBall", "DiamondRibcageBall", "DiamondSantaBall", "DiamondSeashellBall", "DiamondSnowGlobeBall", "DiamondSnowmanBall", "DiscoBall", "EasterEggBall", "ElectrifiedBall", "EvilEyeBall", "FestivalBall", "FlameBall", "FlowerBall", "FlowerBlossomBall", "FourLeafCloverBall", "Frostball", "GalaxyBall", "GamerBall", "GhostBall", "GiftBall", "GingerbreadBall", "GodBall", "GoldCannonBall", "GoldCoconutBall", "GoldCoinBall", "GoldFestivalBall", "GoldHeartBall", "GoldRibcageBall", "GoldSeashellBall", "GoldenBall", "GoldenClockBall", "GoldenCloverBall", "GoldenDiamondBall", "GoldenEggBall", "GoldenPearlBall", "GoldenSkullBall", "GoldenSnowmanBall", "GoldenStarBall", "GoldenSunEggBall", "GradientBall", "HackerBall", "HamburgerBall", "HauntedBall", "HeadBall", "HeartBall", "HologramBall", "HolyHellBall", "HorseshoeBall", "HourglassBall", "IceCreamBall", "JellyfishBall", "KarasunoBall", "KareemBall", "KoiBall", "Level150Ball", "Level50Ball", "LifebuoyBall", "MagicCrystalBall", "MangoBall", "MechBall", "MoneyBall", "MonkeyBall", "MoonBall", "MoonFireBall", "NebulaBall", "NerdBall", "NewYearsDragonBall", "NinjaBall", "OrnamentBall", "OvergrownCrystalBall", "PaintSplatterBall", "PartyHatBall", "PartySunglassesBall", "PastelSwirlEggBall", "PearlBall", "PhantomBall", "PhoenixBall", "PhonkBall", "PinataBall", "PineappleBall", "PinkBall", "PinkBlossomBall", "PinkFlamingoBall", "PinkSummerHatBall", "PirateHatBall", "PixelBall", "PolyhedralBall", "PotOfGoldBall", "PotionBall", "PumpkinBall", "PurplePhoenixBall", "RainbowBall", "RainbowPrismBall", "RattlingJawBall", "ReaperBall", "RedDragonBall", "RedEyeBall", "RedGreenAndWhiteBall", "ReindeerBall", "RigBall", "RippedBall", "RubberDuckyBall", "SaturnBall", "ScarecrowBall", "ShellBall", "ShinyBunnyEggBall", "ShinyChocolateEggBall", "SilverBall", "SilverCannonBall", "SilverCloverBall", "SilverCoconutBall", "SilverEggBall", "SilverFestivalBall", "SilverHeartBall", "SilverLanternBall", "SilverMikageHeadBall", "SilverRibbonBall", "SilverRibcageBall", "SilverSeashellBall", "SilverTurkeyBall", "SlimeBall", "SnowGlobeBall", "Snowball", "SnowmanBall", "SoccerBall", "SoulBall", "SpikyBall", "SpiritBall", "StainedGlassBall", "SubspaceBall", "SummerHatBall", "SunBall", "SunglassesBall", "SuperSunBall", "TennisBall", "TigerBall", "TimeBall", "TitaniumBall", "TranslucentTurkeyBall", "TrollFaceBall", "TurkeyBall", "TuxedoBall", "UltraFastModeBall", "VIPBall", "ValentineCardBall", "WaterBall", "WhiteEggBall", "WingedBall", "WizardHatBall"
    }
    return ballSkinList
end

loadBallSkins()

local function applyJersey(id)
    local character = LocalPlayer.Character
    if not character or not character:FindFirstChild("UpperTorso") then
        return false
    end

    local jerseyFolder = ReplicatedStorage:FindFirstChild("Assets")
    jerseyFolder = jerseyFolder and jerseyFolder:FindFirstChild("Jersey")
    if not jerseyFolder then
        return false
    end

    if not seen.__jerseyHook then
        seen.__jerseyChar = character
        seen.__jerseyHook = track(LocalPlayer.CharacterAdded:Connect(function(character2)
            local oldChar = seen.__jerseyChar
            if oldChar and oldChar ~= character2 then
                originals[oldChar] = nil
            end
            seen.__jerseyChar = character2
            pickedTeam = nil
            if character2:WaitForChild("UpperTorso", 10) and State.autoApplyJersey then
                task.wait(1)
                applyJersey(State.selectedJersey)
            end
        end))
    end

    local function clearWorn()
        for _, child in ipairs(character:GetChildren()) do
            if child.Name == "JerseyFront" or child.Name == "JerseyBack"
                or child.Name == "_jerseyInstances"
                or child:IsA("Clothing") or child:IsA("ShirtGraphic") then
                child:Destroy()
            end
        end
    end

    if not State.autoApplyJersey then
        local backup = originals[character]
        if backup then
            clearWorn()
            for _, saved in ipairs(backup) do
                local restored = saved:Clone()
                if restored:IsA("SurfaceGui") then
                    restored.Adornee = character:FindFirstChild("UpperTorso")
                end
                restored.Parent = character
            end
            originals[character] = nil
        end
        pickedTeam = nil
        return true
    end

    if not originals[character] then
        local backup = {}
        for _, child in ipairs(character:GetChildren()) do
            if child.Name == "JerseyFront" or child.Name == "JerseyBack"
                or child:IsA("Clothing") or child:IsA("ShirtGraphic") then
                table.insert(backup, child:Clone())
            end
        end
        originals[character] = backup
    end

    local function resolveTeam()
        local worn = character:FindFirstChildOfClass("Shirt")
        if not worn then
            return nil
        end
        for _, asset in ipairs(jerseyFolder:GetChildren()) do
            for _, team in ipairs(asset:GetChildren()) do
                local shirt = team:FindFirstChild("Shirt")
                if shirt and shirt:IsA("Shirt") and shirt.ShirtTemplate == worn.ShirtTemplate then
                    return team.Name
                end
            end
        end
        return nil
    end

    local loaded, Jersey = pcall(require, ReplicatedStorage.Tools.Jersey)
    if not loaded or type(Jersey) ~= "table" or not Jersey.set then
        return false
    end

    pickedTeam = pickedTeam or resolveTeam()

    local applied, err = pcall(Jersey.set, {
        Player = LocalPlayer,
        Character = character,
        Id = id or State.selectedJersey,
        TeamName = pickedTeam,
    })
    if not applied then
        warn("[NODTHUB] jersey apply failed: " .. tostring(err))
        return false
    end

    pickedTeam = pickedTeam or resolveTeam()
    return true
end

local function sweep()
    local ballFolder = ReplicatedStorage:FindFirstChild("Assets")
    ballFolder = ballFolder and ballFolder:FindFirstChild("Ball")
    if not ballFolder then
        return
    end

    local function strip(model)
        local holder = clones[model]
        if holder then
            holder:Destroy()
            clones[model] = nil
        end
        local saved = originals[model]
        if saved then
            for piece, record in pairs(saved) do
                if piece.Parent then
                    pcall(function()
                        piece[record.field] = record.value
                    end)
                end
            end
            originals[model] = nil
        end
    end

    local function skin(model)
        local driver = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
        local source = ballFolder:FindFirstChild(State.selectedBallSkin)
        if not driver or not source then
            return
        end

        strip(model)

        local saved = {}
        local function stash(piece, field, value)
            saved[piece] = { field = field, value = piece[field] }
            piece[field] = value
        end
        for _, piece in ipairs(model:GetDescendants()) do
            if piece:IsA("BasePart") then
                if piece.Name ~= MARK then
                    stash(piece, "Transparency", 1)
                end
            elseif piece:IsA("Decal") or piece:IsA("Texture") then
                stash(piece, "Transparency", 1)
            elseif piece:IsA("Trail") or piece:IsA("ParticleEmitter") or piece:IsA("Beam") or piece:IsA("Light") or piece:IsA("Smoke") or piece:IsA("Fire") or piece:IsA("Sparkles") then
                stash(piece, "Enabled", false)
            end
        end
        originals[model] = saved

        local holder = source:Clone()
        holder.Name = MARK2
        holder.Parent = model
        local pieces = {}
        if holder:IsA("BasePart") then
            pieces[#pieces + 1] = holder
        end
        for _, candidate in ipairs(holder:GetDescendants()) do
            if candidate:IsA("BasePart") then
                pieces[#pieces + 1] = candidate
            end
        end

        local anchor = holder:IsA("Model") and holder.PrimaryPart or nil
        if not anchor then
            local bestScore
            for _, candidate in ipairs(pieces) do
                if candidate:IsA("BasePart") then
                    local vol = candidate.Size.X * candidate.Size.Y * candidate.Size.Z
                    local roundish = math.abs(candidate.Size.X - candidate.Size.Y) < 0.5 and math.abs(candidate.Size.Y - candidate.Size.Z) < 0.5
                    local score = vol
                    if candidate:IsA("Part") and candidate.Shape == Enum.PartType.Ball then
                        score = score * 6
                    elseif roundish then
                        score = score * 3
                    end
                    if not bestScore or score > bestScore then
                        bestScore = score
                        anchor = candidate
                    end
                end
            end
        end
        if anchor then
            local offset = holder:GetPivot():ToObjectSpace(anchor.CFrame)
            holder:PivotTo(driver.CFrame * offset:Inverse())
        else
            holder:PivotTo(driver.CFrame)
        end

        for _, part in ipairs(pieces) do
            part.Anchored = false
            part.CanCollide = false
            part.CanQuery = false
            part.CanTouch = false
            part.Massless = true
            local weld = Instance.new("WeldConstraint")
            weld.Part0 = driver
            weld.Part1 = part
            weld.Parent = part
        end

        clones[model] = holder
    end

    local tracked = {}
    for model in pairs(clones) do
        table.insert(tracked, model)
    end
    for _, model in ipairs(tracked) do
        strip(model)
    end

    if not State.autoApplyBallSkin then
        return
    end

    for _, model in ipairs(Workspace:GetChildren()) do
        if model:IsA("Model") and model.Name:match("^CLIENT_BALL_") then
            skin(model)
        end
    end

    if not seen.__ballHook then
        seen.__ballHook = track(Workspace.ChildAdded:Connect(function(child)
            if not State.autoApplyBallSkin or not child:IsA("Model") or not child.Name:match("^CLIENT_BALL_") then
                return
            end
            task.spawn(function()
                for _ = 1, 40 do
                    if child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart") then
                        break
                    end
                    task.wait(0.05)
                end
                if State.autoApplyBallSkin and child.Parent then
                    sweep()
                end
            end)
        end))
    end
end

local sweepBusy = false
local function safeSweep()
    if sweepBusy then return end
    sweepBusy = true
    pcall(sweep)
    task.wait(0.3)
    sweepBusy = false
end

local Kisuki = { enabled = false, hooked = false, charge = 1 }

Kisuki.effect = function(strong)
    local character = LocalPlayer.Character
    if not character or not character.PrimaryPart then return end
    local assets = ReplicatedStorage:FindFirstChild("Assets")
    local effects = assets and assets:FindFirstChild("Effects")
    local module = effects and effects:FindFirstChild("SuperDive")
    if not module then return end

    local restore = getthreadidentity and getthreadidentity()
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    pcall(function()
        task.spawn(require(module), character, { IsStrong = strong })
    end)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end
end

Kisuki.install = function()
    if Kisuki.hooked then return end
    local Knit = getKnitRoot()
    if not Knit then return end
    local found, controller = pcall(Knit.GetController, "GameController")
    if not found or type(controller) ~= "table" or type(controller.Dive) ~= "function" then return end

    local passthrough = controller.Dive
    controller.Dive = function(self, params, ...)
        if not Kisuki.enabled then
            return passthrough(self, params, ...)
        end

        local blend = math.clamp(Kisuki.charge, 0, 1)
        local styled, special = pcall(require, ReplicatedStorage.Content.Style.Kimiro.Special)
        local tuning = styled and type(special) == "table" and special.Metadata
        if type(tuning) == "table" then
            params = type(params) == "table" and params or {}
            params.MaxForce = tuning.MaxForce
            params.TimeScale = tuning.TimeScale
            params.StretchSpeedFactor = tuning.StretchSpeedFactor
            params.EasingStyle = tuning.EasingStyle
            params.Debounce = tuning.Debounce
            if not params.Target and typeof(tuning.Power) == "NumberRange" then
                local character = LocalPlayer.Character
                local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                local heading = humanoid and humanoid.MoveDirection or Vector3.zero
                if heading.Magnitude < 0.5 and character then
                    heading = character:GetPivot().LookVector
                end
                heading = Vector3.new(heading.X, 0, heading.Z)
                if heading.Magnitude > 0.01 then
                    local reach = tuning.Power.Min + (tuning.Power.Max - tuning.Power.Min) * blend
                    params.Target = heading.Unit * reach
                end
            end
        end

        local outcome = passthrough(self, params, ...)
        if outcome ~= nil then
            Kisuki.effect(blend >= 0.5)
        end
        return outcome
    end
    Kisuki.hooked = true
end

local Vault = { real = nil, want = {} }

Vault.mark = function(kind, on)
    Vault.want[kind] = on or nil
    if on then
        Vault.wear()
    end

    local Knit = getKnitRoot()
    if not Knit then return end
    local found, inventory = pcall(Knit.GetController, "InventoryController")
    if not found or type(inventory) ~= "table" or not inventory.Inventory then return end

    local held, current = pcall(function()
        return inventory.Inventory:get()
    end)
    if not held or type(current) ~= "table" then return end

    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = type(genv.NODT_SESSION) == "table" and genv.NODT_SESSION or nil

    if not Vault.real then
        local carried = session and session.vault or nil
        if carried and carried.inventory then
            Vault.real = carried.inventory
            Vault.realTitle = carried.title
            Vault.realEquipped = carried.equipped or {}
        else
            local snapshot = {}
            for id, count in pairs(current) do
                snapshot[id] = count
            end
            Vault.real = snapshot
            Vault.realTitle = LocalPlayer:GetAttribute("User_Title")
            local heldWorn, worn = pcall(function()
                return inventory.Equipped:get()
            end)
            local realEquipped = {}
            if heldWorn and type(worn) == "table" then
                for slot, value in pairs(worn) do
                    realEquipped[slot] = value
                end
            end
            Vault.realEquipped = realEquipped
            if session then
                session.vault = {
                    inventory = Vault.real,
                    title = Vault.realTitle,
                    equipped = Vault.realEquipped,
                }
            end
        end
    end

    local wanted = false
    for _ in pairs(Vault.want) do
        wanted = true
        break
    end
    if not wanted then
        pcall(function()
            inventory.Inventory:set(Vault.real)
        end)
        Vault.real = nil
        if session then
            session.vault = nil
        end
        return
    end

    local catalogued, Item = pcall(require, ReplicatedStorage.Content.Item)
    local entities = ReplicatedStorage.Content.Item:FindFirstChild("Entities")
    if not catalogued or not entities then return end

    local stocked = {}
    for id, count in pairs(Vault.real) do
        stocked[id] = count
    end
    for _, child in ipairs(entities:GetChildren()) do
        if child:IsA("ModuleScript") and not stocked[child.Name] then
            local read, entry = pcall(require, child)
            if read and type(entry) == "table" and entry.Type then
                for kindName in pairs(Vault.want) do
                    if entry.Type == Item.Type[kindName] then
                        stocked[child.Name] = 1
                        break
                    end
                end
            end
        end
    end
    pcall(function()
        inventory.Inventory:set(stocked)
    end)
end

Vault.typeOf = function(id)
    local module = ReplicatedStorage.Content.Item:FindFirstChild("Entities")
    module = module and module:FindFirstChild(id)
    if not module then return nil end
    local read, entry = pcall(require, module)
    if read and type(entry) == "table" and entry.Type then
        return entry.Type, entry
    end
    return nil
end

Vault.paint = function(kind, id, entry)
    local real = Vault.realEquipped or {}
    if kind == "Title" then
        pcall(function()
            local text = id and ((entry and entry.DisplayName) or id) or Vault.realTitle
            LocalPlayer:SetAttribute("User_Title", text)
        end)
    elseif kind == "ScoreEffect" then
        State.selectedEffect = id or real.ScoreEffect or "SupernovaScoreEffect"
    elseif kind == "Ball" then
        State.selectedBallSkin = id or real.Ball or "ClassicBall"
        task.spawn(safeSweep)
    elseif kind == "Jersey" then
        State.selectedJersey = id or real.Jersey or "DragonTuxedoJersey"
        pickedTeam = nil
        task.spawn(function()
            pcall(applyJersey, State.selectedJersey)
        end)
    elseif kind == "PlayerCard" then
        State.selectedCard = id or real.PlayerCard or "UltimateChampionPlayerCard"
        task.spawn(function()
            pcall(fireCardRemote)
        end)
    end
end

-- TITLE LIST (fixa): nome exibido + id do item
local titleList = {
    { name = "3-Strike God", id = "3StrikeGodTitle" },
    { name = "BOO", id = "CursedBooTitle" },
    { name = "EVIL", id = "CursedEvilTitle" },
    { name = "Feiko", id = "FeikoTitle" },
    { name = "Hinto", id = "HintoTitle" },
    { name = "No Life", id = "NoLifeTitle" },
    { name = "Owner", id = "OwnerTitle" },
    { name = "Ricochet", id = "RicochetTitle" },
    { name = "Sanju", id = "SanjuTitle" },
    { name = "Sunflower", id = "SunflowerTitle" },
    { name = "TSK", id = "TSKTitle" },
    { name = "JINKO", id = "JinkoTitle" },
    { name = "Argentina", id = "ArgentinaTitle" },
    { name = "Spain", id = "SpainTitle" },
    { name = "Beach Vibes", id = "BeachVibesTitle" },
    { name = "Wave", id = "WaveTitle" },
    { name = "Star Creator", id = "AllStarCreatorTitle" },
    { name = "Lucky", id = "LuckyTitle" },
    { name = "Watermelon", id = "WatermelonTitle" },
    { name = "Chocolate", id = "ChocolateTitle" },
    { name = "Confetti", id = "ConfettiTitle" },
    { name = "CC Manager", id = "ContentCreatorManagerTitle" },
    { name = "Content Creator", id = "ContentCreatorTitle" },
    { name = "Art Team", id = "ArtistTitle" },
    { name = "TAICHOU", id = "TaichouTitle" },
    { name = "Bunny", id = "BunnyTitle" },
    { name = "VIP", id = "VIPTitle" },
    { name = "John Doe", id = "JohnDoeTitle" },
    { name = "Staff", id = "StaffTitle" },
    { name = "UNC", id = "UncTitle" },
    { name = "Spooky", id = "SpookyTitle" },
    { name = "Heart", id = "HeartTitle" },
    { name = "Blue Heart", id = "BlueHeartTitle" },
    { name = "Fire", id = "FireTitle" },
    { name = "Angel", id = "AngelTitle" },
    { name = "Demon", id = "DemonTitle" },
    { name = "ROCKET", id = "RocketTitle" },
    { name = "Developer", id = "DeveloperTitle" },
    { name = "Potato", id = "PotatoTitle" },
    { name = "Egg", id = "EggTitle" },
    { name = "Kazana", id = "KazanaTitle" },
    { name = "QA Lead", id = "QALeadTitle" },
    { name = "Turkey", id = "TurkeyTitle" },
    { name = "Cursed", id = "CursedTitle" },
    { name = "Tester", id = "TesterTitle" },
}

-- EMOTE LIST (fixa): nome exibido + id do item
local emoteList = {
    { nome = "10 out of 10", id = "TenOutOfTenEmote", asset = "rbxassetid://117965285105587" },
    { nome = "67 Emote", id = "SixSevenEmote", asset = "rbxassetid://115537557551502" },
    { nome = "Backflip", id = "BackflipEmote", asset = "rbxassetid://129678508150221" },
    { nome = "Banana Slip", id = "BananaSlipEmote", asset = "rbxassetid://90988957936019" },
    { nome = "Beach Ball", id = "BeachBallEmote", asset = "rbxassetid://122099685243756" },
    { nome = "Become a Spider", id = "BecomeSpiderEmote", asset = "rbxassetid://131564679981855" },
    { nome = "Bird Emote", id = "BirdEmote", asset = "rbxassetid://88147389871668" },
    { nome = "Boom", id = "BoomEmote", asset = "rbxassetid://112311816508684" },
    { nome = "Breakdancer", id = "BreakdanceEmote", asset = "rbxassetid://90537409929734" },
    { nome = "Bunny Hop", id = "BunnyHopEmote", asset = "rbxassetid://111675566255592" },
    { nome = "Carrot", id = "CarrotEmote", asset = "rbxassetid://76449786642425" },
    { nome = "Cartwheel", id = "CartwheelEmote", asset = "rbxassetid://100187939722248" },
    { nome = "Celebrate!", id = "CelebrationEmote", asset = "rbxassetid://109181427868177" },
    { nome = "Clean Sweep", id = "CleanSweepEmote", asset = "rbxassetid://75002887986582" },
    { nome = "Crab Rave Dance", id = "CrabRaveEmote", asset = "rbxassetid://103778090790810" },
    { nome = "Dab", id = "DabEmote", asset = "rbxassetid://91163812088807" },
    { nome = "Default Dance", id = "DefaultDanceEmote", asset = "rbxassetid://76768307239914" },
    { nome = "Diamond", id = "DiamondEmote", asset = "rbxassetid://109871779124425" },
    { nome = "Dig In", id = "DigInEmote", asset = "rbxassetid://77650525280767" },
    { nome = "Drumset", id = "DrumsetEmote", asset = "rbxassetid://91163812088807" },
    { nome = "Eat Turkey", id = "EatTurkeyEmote", asset = "rbxassetid://137820111150114" },
    { nome = "Egg Spike", id = "EggSpikeEmote", asset = "rbxassetid://114578115631032" },
    { nome = "Egg Thrower", id = "EggThrowEmote", asset = "rbxassetid://95821497316213" },
    { nome = "Evil Laugh", id = "EvilLaughEmote", asset = "rbxassetid://99440464833577" },
    { nome = "Exploding Turkey", id = "TurkeyExplodingEmote", asset = "rbxassetid://132131095471775" },
    { nome = "Festival Guitar", id = "FestivalGuitarEmote", asset = "rbxassetid://97432175341381" },
    { nome = "Fish Flop", id = "FishFlopEmote", asset = "rbxassetid://125763872807638" },
    { nome = "Flamethrower", id = "FlamethrowerEmote", asset = "rbxassetid://113946301576816" },
    { nome = "Floating Dead in the Water", id = "FloatingDeadInTheWaterEmote", asset = "rbxassetid://104318190473926" },
    { nome = "Floss", id = "FlossEmote", asset = "rbxassetid://134153732540967" },
    { nome = "Front Flip", id = "FrontFlipEmote", asset = "rbxassetid://99352676434996" },
    { nome = "Gangnam", id = "GangnamEmote", asset = "rbxassetid://129163306477753" },
    { nome = "Giant Boulder Throw", id = "GiantBoulderThrowEmote", asset = "rbxassetid://78947840664761" },
    { nome = "Glow Stick Dance", id = "GlowStickDanceEmote", asset = "rbxassetid://124317486814333" },
    { nome = "Go To Heaven", id = "GoToHeavenEmote", asset = "rbxassetid://140293939309907" },
    { nome = "Gobble Gobble", id = "GobbleGobbleEmote", asset = "rbxassetid://84316069258030" },
    { nome = "Griddy", id = "GriddyEmote", asset = "rbxassetid://80937823369919" },
    { nome = "Guitar", id = "GuitarEmote", asset = "rbxassetid://113840100441066" },
    { nome = "Hakka's Skateboard", id = "HakkaSkateboardEmote", asset = "rbxassetid://136874317530219" },
    { nome = "Headless", id = "HeadlessEmote", asset = "rbxassetid://136572412954968" },
    { nome = "Heart Attack", id = "HeartAttackEmote", asset = "rbxassetid://88854342804798" },
    { nome = "Helicopter", id = "HelicopterEmote", asset = "rbxassetid://129742434202654" },
    { nome = "Howl Wolf", id = "HowlEmote", asset = "rbxassetid://70590812931797" },
    { nome = "I Win", id = "IWinEmote", asset = "rbxassetid://124833571897770" },
    { nome = "Jinko Juggle", id = "JinkoEmote", asset = "rbxassetid://116474536870493" },
    { nome = "Knee Slide", id = "KneeSlideEmote", asset = "rbxassetid://117677416319109" },
    { nome = "Laugh", id = "LaughEmote", asset = "rbxassetid://114969937667961" },
    { nome = "Lay Egg", id = "LayEggEmote", asset = "rbxassetid://106318256891329" },
    { nome = "Monster Mash", id = "MonsterMashEmote", asset = "rbxassetid://74010158851616" },
    { nome = "Popcorn", id = "PopcornEmote", asset = "rbxassetid://94741755790119" },
    { nome = "Pumpkin Dribble", id = "PumpkinDribbleEmote", asset = "rbxassetid://79391919388386" },
    { nome = "Pushups", id = "PushupEmote", asset = "rbxassetid://105075970606486" },
    { nome = "Ride A Firework", id = "RideAFireworkEmote", asset = "rbxassetid://138480626807228" },
    { nome = "Ride a Broom", id = "BroomEmote", asset = "rbxassetid://110412699020515" },
    { nome = "Ride a Turkey", id = "TurkeyRideEmote", asset = "rbxassetid://134337451655995" },
    { nome = "Robot Dance", id = "RobotDanceEmote", asset = "rbxassetid://91894188913501" },
    { nome = "Sad Trombone", id = "SadTromboneEmote", asset = "rbxassetid://101251252308358" },
    { nome = "Sad Violin", id = "SadViolinEmote", asset = "rbxassetid://100628745739325" },
    { nome = "Sailor Flex", id = "SailorFlexEmote", asset = "rbxassetid://91332215936540" },
    { nome = "Santa's Sled", id = "SantaSledEmote", asset = "rbxassetid://129027772041993" },
    { nome = "Scuba", id = "ScubaEmote", asset = "rbxassetid://100345578402081" },
    { nome = "Shield Bash", id = "ShieldBashEmote", asset = "rbxassetid://131424756819183" },
    { nome = "Skater", id = "SkateboardEmote", asset = "rbxassetid://136874317530219" },
    { nome = "Ski", id = "SkiEmote", asset = "rbxassetid://96827955174205" },
    { nome = "Sleeping", id = "SleepingEmote", asset = "rbxassetid://122831006386563" },
    { nome = "Slow Clap", id = "SlowClapEmote", asset = "rbxassetid://81554855590020" },
    { nome = "Snowball Toss", id = "SnowballTossEmote", asset = "rbxassetid://120555519032946" },
    { nome = "Spell Caster", id = "WandEmote", asset = "rbxassetid://125478268691034" },
    { nome = "Spyglass", id = "SpyglassEmote", asset = "rbxassetid://120134773083348" },
    { nome = "Take the L", id = "LEmote", asset = "rbxassetid://102885530381725" },
    { nome = "Tap Dancer", id = "TapDancerEmote", asset = "rbxassetid://10714076981" },
    { nome = "The Singer", id = "SingerEmote", asset = "rbxassetid://127349436630983" },
    { nome = "Tiki Drums", id = "TikiDrumEmote", asset = "rbxassetid://72737779363956" },
    { nome = "Tomato Throw", id = "TomatoThrowEmote", asset = "rbxassetid://120555519032946" },
    { nome = "Tongue Taunt", id = "TongueEmote", asset = "rbxassetid://114487267538974" },
    { nome = "Trick Or Treat", id = "TrickOrTreatEmote", asset = "rbxassetid://134115142685022" },
    { nome = "Turkey Squish", id = "TurkeySquishEmote", asset = "rbxassetid://101475634261140" },
    { nome = "Volcano", id = "VolcanoEmote", asset = "rbxassetid://112679048290528" },
    { nome = "Witches Brew", id = "WitchesBrewEmote", asset = "rbxassetid://97220451848000" },
    { nome = "Worm", id = "WormEmote", asset = "rbxassetid://137576934576880" },
    { nome = "Vomit", id = "VomitEmote", asset = "rbxassetid://128329219328127" },
}

local effectList, VisualApply
Vault.setSlot = function(kind, id)
    local Knit = getKnitRoot()
    if not Knit then return end
    local found, inventory = pcall(Knit.GetController, "InventoryController")
    if not found or type(inventory) ~= "table" or not inventory.Equipped then return end
    local held, worn = pcall(function()
        return inventory.Equipped:get()
    end)
    if not held or type(worn) ~= "table" then return end
    local dressed = {}
    for slot, value in pairs(worn) do
        dressed[slot] = value
    end
    if kind == "Emote" then
        -- slot real = "Emotes" (table de ids). id nil = restaura o snapshot.
        -- Retorna true/false (so este branch retorna valor).
        local current = worn.Emotes
        if Vault.realEmotes == nil then
            if type(current) == "table" then
                local copy = {}
                for k, v in pairs(current) do
                    copy[k] = v
                end
                Vault.realEmotes = copy
            else
                Vault.realEmotes = false
            end
        end
        if id == nil then
            local restored = nil
            if type(Vault.realEmotes) == "table" then
                restored = {}
                for k, v in pairs(Vault.realEmotes) do
                    restored[k] = v
                end
            end
            dressed.Emotes = restored
        else
            local known = false
            for _, item in ipairs(emoteList) do
                if item.id == id then
                    known = true
                    break
                end
            end
            if not known then
                return false
            end
            -- so edita formato array ({ "A", "B" }); outro formato: nao mexe
            if type(current) == "table" and next(current) ~= nil and current[1] == nil then
                return false
            end
            local nextEmotes = { id }
            if type(current) == "table" then
                for i, v in ipairs(current) do
                    if i ~= 1 and v ~= id then
                        table.insert(nextEmotes, v)
                    end
                end
            end
            dressed.Emotes = nextEmotes
        end
        pcall(function()
            inventory.Equipped:set(dressed)
        end)
        return true
    end
    if id ~= nil and type(VisualApply) == "table" and type(VisualApply.pick) == "function" then
        local list
        if kind == "ScoreEffect" then
            list = effectList
        elseif kind == "Jersey" then
            list = jerseyList
        elseif kind == "PlayerCard" then
            list = cardList
        elseif kind == "Ball" then
            list = ballSkinList
        elseif kind == "Title" then
            -- aceita so ids da titleList (ou o Title real do jogador, p/ o revert)
            local known = Vault.realEquipped ~= nil and Vault.realEquipped.Title == id
            for _, item in ipairs(titleList) do
                if item.id == id then
                    known = true
                    break
                end
            end
            if not known then
                return
            end
        end
        if list then
            local valid = VisualApply.pick(list, id)
            if valid == nil then
                return
            end
            id = valid
        end
    end
    dressed[kind] = id
    pcall(function()
        inventory.Equipped:set(dressed)
    end)
end

Vault.currentSlot = function(kind)
    local Knit = getKnitRoot()
    if not Knit then return nil end
    local found, inventory = pcall(Knit.GetController, "InventoryController")
    if not found or type(inventory) ~= "table" or not inventory.Equipped then return nil end
    local held, worn = pcall(function()
        return inventory.Equipped:get()
    end)
    if held and type(worn) == "table" then
        return worn[kind]
    end
    return nil
end

Vault.dress = function(id)
    local kind, entry = Vault.typeOf(id)
    if not kind then return false end
    if kind == "Title" or kind == "ScoreEffect" or kind == "Ball" or kind == "Jersey" or kind == "PlayerCard" then
        Vault.paint(kind, id, entry)
    elseif kind ~= "ProfileArt" then
        return false
    end
    Vault.setSlot(kind, id)
    return true
end

Vault.revert = function(kind)
    local realId = Vault.realEquipped and Vault.realEquipped[kind] or nil
    Vault.paint(kind, nil)
    Vault.setSlot(kind, realId)
end

Vault.wear = function()
    if Vault.worn then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local InventoryService = getPackageService("InventoryService")
    local remote = InventoryService and getServiceChild(InventoryService, "RF", "Equip")
    if not remote then
        warn("[NodtHub] service not found")
        return
    end

    local hooked = hookNamecall("vaultEquip", function(callNext, self, method, ...)
        if not remote then return callNext(self, method, ...) end
        if self == remote and method == "InvokeServer" then
            local id = (...)
            if type(id) == "string" and Vault.real then
                local kind, entry = Vault.typeOf(id)
                if kind == "Emote" then
                    -- emote vai direto pro servidor (nao e engolido pelo Vault)
                    return callNext(self, method, ...)
                end
                if not Vault.real[id] then
                    if kind and Vault.currentSlot(kind) == id then
                        Vault.revert(kind)
                        return true
                    end
                    Vault.dress(id)
                    return true
                elseif kind then
                    Vault.paint(kind, id, entry)
                end
            end
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        Vault.worn = true
    end
end

local Landing = {
    enabled = false,
    marker = nil,
    label = nil,
    tracked = nil,
    last = nil,
    stamp = 0,
    drift = Vector3.zero,
}

Landing.clear = function()
    if Landing.marker then
        Landing.marker:Destroy()
        Landing.marker = nil
        Landing.label = nil
    end
    Landing.tracked = nil
    Landing.last = nil
    Landing.drift = Vector3.zero
end

Landing.build = function()
    local disc = Instance.new("Part")
    disc.Name = MARK
    disc.Shape = Enum.PartType.Cylinder
    disc.Size = Vector3.new(0.2, 7, 7)
    disc.Anchored = true
    disc.CanCollide = false
    disc.CanQuery = false
    disc.CanTouch = false
    disc.Material = Enum.Material.Neon
    disc.Transparency = 0.35
    disc.CastShadow = false
    disc.Parent = Camera

    local board = Instance.new("BillboardGui")
    board.Size = UDim2.new(0, 90, 0, 30)
    board.StudsOffset = Vector3.new(0, 4, 0)
    board.AlwaysOnTop = true
    board.Parent = disc

    local text = Instance.new("TextLabel")
    text.Size = UDim2.fromScale(1, 1)
    text.BackgroundTransparency = 1
    text.TextScaled = true
    text.Font = Enum.Font.GothamBold
    text.TextStrokeTransparency = 0
    text.Parent = board

    Landing.marker = disc
    Landing.label = text
end

Landing.gravity = function()
    getCachedServices()
    local pulled, value = pcall(function()
        if not _GameConfig or not _State then return nil end
        return _State.get(ReplicatedStorage, _State.Id.Modifier, "BallGravity", _GameConfig.Physics.Gravity)
    end)
    if pulled and type(value) == "number" and value > 0 then
        return value
    end
    return 17
end

Landing.velocity = function(part)
    getCachedServices()
    local controller = _BallController
    if type(controller) == "table" and type(controller.ActiveBalls) == "table" then
            for _, record in pairs(controller.ActiveBalls) do
                local model = record.Ball
                if model and model.Parent and model:IsAncestorOf(part) and typeof(record.Velocity) == "Vector3" then
                    return record.Velocity
                end
            end
    end
    return Landing.drift
end

Landing.solve = function(pos, vel, gravity, floorY)
    local drop = pos.Y - floorY
    if drop < 0 then return nil end
    local disc = vel.Y * vel.Y + 2 * gravity * drop
    if disc < 0 then return nil end
    local flight = (vel.Y + math.sqrt(disc)) / gravity
    if flight ~= flight or flight <= 0 or flight > 15 then return nil end
    return flight
end

Landing.netHit = function(pos, vel, gravity, flight)
    local map = Workspace:FindFirstChild("Map")
    local collide = map and map:FindFirstChild("BallCollideOnly")
    local net = collide and collide:FindFirstChild("Net")
    if not net then return false end
    local netZ = net.Position.Z
    local gap = netZ - pos.Z
    if math.abs(vel.Z) < 0.01 then return false end
    local moment = gap / vel.Z
    if moment <= 0 or moment >= flight then return false end
    local height = pos.Y + vel.Y * moment - 0.5 * gravity * moment * moment
    local across = pos.X + vel.X * moment
    local top = net.Position.Y + net.Size.Y * 0.5
    local base = net.Position.Y - net.Size.Y * 0.5
    if height > top or height < base then return false end
    return math.abs(across - net.Position.X) <= net.Size.X * 0.5
end

Landing.predict = function(ball)
    getCachedServices()
    local module = _Physics
    if not module then return nil end

    local gravity = Landing.gravity()
    local pos = ball.Position
    local vel = Landing.velocity(ball)
    if typeof(vel) ~= "Vector3" then return nil end

    local floorY = module.LastFloorHeight
    if not floorY then
        local found, height = pcall(module.calculateFloorHeight, pos, true)
        floorY = found and height or nil
    end
    if not floorY then return nil end

    local flight = Landing.solve(pos, vel, gravity, floorY)
    if not flight then return nil end

    local spot = Vector3.new(pos.X + vel.X * flight, floorY, pos.Z + vel.Z * flight)
    local probed, ground = pcall(module.calculateFloorHeight, Vector3.new(spot.X, pos.Y, spot.Z), true)
    if probed and type(ground) == "number" and math.abs(ground - floorY) > 0.05 then
        local refined = Landing.solve(pos, vel, gravity, ground)
        if refined then
            flight = refined
            spot = Vector3.new(pos.X + vel.X * flight, ground, pos.Z + vel.Z * flight)
        end
    end

    return spot, module, flight, Landing.netHit(pos, vel, gravity, flight)
end

track(RunService.RenderStepped:Connect(function()
    if not Landing.enabled then
        if Landing.marker then Landing.clear() end
        return
    end

    local ball = getNearestBall()
    if not ball then
        if Landing.marker then Landing.marker.Transparency = 1 end
        Landing.last = nil
        return
    end

    local now = os.clock()
    if Landing.tracked == ball and Landing.last and now > Landing.stamp then
        Landing.drift = (ball.Position - Landing.last) / (now - Landing.stamp)
    end
    Landing.tracked = ball
    Landing.last = ball.Position
    Landing.stamp = now

    local spot, physics, flight, netted = Landing.predict(ball)
    if not spot then
        if Landing.marker then Landing.marker.Transparency = 1 end
        return
    end

    if not Landing.marker then Landing.build() end
    local bounds = physics._getCourtlines and physics._getCourtlines()
    local inside = true
    if bounds and physics.isPositionInCourt then
        local ok, verdict = pcall(physics.isPositionInCourt, spot, nil, ball.Size.X * 0.5, nil)
        inside = not ok or verdict
    end

    local tone, verdictText
    if netted then
        tone = Color3.fromRGB(250, 180, 40)
        verdictText = "NET"
    elseif inside then
        tone = Color3.fromRGB(60, 220, 90)
        verdictText = "IN"
    else
        tone = Color3.fromRGB(235, 60, 60)
        verdictText = "OUT"
    end

    local urgency = math.clamp(1 - flight / 2, 0, 1)
    local span = 6 + urgency * 3
    Landing.marker.Size = Vector3.new(0.2, span, span)
    Landing.marker.Transparency = 0.35 - urgency * 0.15
    Landing.marker.Color = tone
    Landing.marker.CFrame = CFrame.new(spot + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90))
    Landing.label.Text = verdictText .. "  " .. string.format("%.1fs", flight)
    Landing.label.TextColor3 = tone
end))

effectList = {}
local function loadEffects()
    effectList = {
        "2026ScoreEffect", "AtomicExplosionScoreEffect", "AuroraScoreEffect", "BallPortalScoreEffect", "BananaSlipScoreEffect", "BeachSpiralScoreEffect", "BeachSplashScoreEffect", "BeatOfMadnessScoreEffect", "BinaryScoreEffect", "BlackHoleScoreEffect", "BloodMoonScoreEffect", "BlueHeartScoreEffect", "BotFaceEmojiScoreEffect", "BubbleScoreEffect", "BunnyHopScoreEffect", "CandyCaneScoreEffect", "CandyCrunchScoreEffect", "CannonBallRainScoreEffect", "CauldronSplashScoreEffect", "ChickScoreEffect", "ChocolateBeamScoreEffect", "ChocolateEggHatchingScoreEffect", "ChocolateSpiralScoreEffect", "ChocolateSplashScoreEffect", "CloudburstScoreEffect", "ColonThreeScoreEffect", "ColorfulFireScoreEffect", "CombiningHeartsScoreEffect", "ConfettiBurstScoreEffect", "CookieSplashScoreEffect", "CoolBunnyScoreEffect", "CoralScoreEffect", "CosmicSpiralScoreEffect", "CrabBeamScoreEffect", "CrabScurryScoreEffect", "CryoFlareScoreEffect", "CursedCrateScoreEffect", "CursedScoreEffect", "CyberWaveScoreEffect", "DarkStarScoreEffect", "DiamondScoreEffect", "DivineStrikeScoreEffect", "DynamiteScoreEffect", "EasterBeamScoreEffect", "EasterEggBasketScoreEffect", "EasterSwirlScoreEffect", "EggHatchScoreEffect", "EggMeteorScoreEffect", "EggRainScoreEffect", "ElectricScoreEffect", "EverybodyDanceScoreEffect", "FallingAcornScoreEffect", "FallingAnchorScoreEffect", "FallingAnvilScoreEffect", "FallingPianoScoreEffect", "FishExplosionScoreEffect", "FistSlamScoreEffect", "FlameScoreEffect", "FlamethrowerScoreEffect", "FloppyFishScoreEffect", "FountainScoreEffect", "FourLeafCloverSpiralScoreEffect", "GenieLampScoreEffect", "GhostVortexScoreEffect", "GiantEggDropScoreEffect", "GiantPlayerScoreEffect", "GiantSoccerKickScoreEffect", "GiantTongueScoreEffect", "GlowStickDanceScoreEffect", "GobbleStormScoreEffect", "GoldCoinPopScoreEffect", "GoldScoreEffect", "GoldenConfettiBurstScoreEffect", "GoldenEggPopScoreEffect", "GoldenWaveScoreEffect", "GravyWaveScoreEffect", "GreenEnergyScoreEffect", "GroundCrackScoreEffect", "HakkaScoreEffect", "HeartBeamScoreEffect", "HeartBubbleScoreEffect", "HeartScoreEffect", "HoneyScoreEffect", "IceCreamScoreEffect", "IceScoreEffect", "JohnDoeScoreEffect", "KittySpiralScoreEffect", "KrakenPullScoreEffect", "LaughingScoreEffect", "LavaSplashScoreEffect", "LeafExplosionScoreEffect", "Level100ScoreEffect", "Level200ScoreEffect", "LightShowScoreEffect", "LightningStrikeScoreEffect", "LuckyCloverScoreEffect", "LuckyStrikeScoreEffect", "MagicBurstScoreEffect", "MegaSunbeamScoreEffect", "MetaBlastScoreEffect", "MeteorScoreEffect", "MoneyExplosionScoreEffect", "MoonlightBeamScoreEffect", "MusicNoteStormScoreEffect", "NewYearsWrathScoreEffect", "NinjaStarScoreEffect", "NorthStarScoreEffect", "NukeScoreEffect", "OceanicSpiralScoreEffect", "PalmTreeHammockScoreEffect", "PastelRainbowScoreEffect", "PastelSwirlScoreEffect", "PineappleScoreEffect", "PinkCosmicSpiralScoreEffect", "PinkHeartScoreEffect", "PixelExplosionScoreEffect", "PlayerBubbleScoreEffect", "PlushieScoreEffect", "PotExplosionScoreEffect", "PotionSplashScoreEffect", "PumpkinPieBurstScoreEffect", "PumpkinSmashScoreEffect", "RainbowScoreEffect", "RainbowStarScoreEffect", "RainbowStrikeScoreEffect", "RandomFavoriteScoreEffect", "RankedWinsScoreEffect", "RedDragonScoreEffect", "RosePetalScoreEffect", "SantasWrathScoreEffect", "SeaCreatureExplosionScoreEffect", "Season0ProScoreEffect", "Season10ProScoreEffect", "Season11ProScoreEffect", "Season12ProScoreEffect", "Season13ProScoreEffect", "Season14ProScoreEffect", "Season15ProScoreEffect", "Season16ProScoreEffect", "Season17ProScoreEffect", "Season18ProScoreEffect", "Season19ProScoreEffect", "Season1ProScoreEffect", "Season2ProScoreEffect", "Season3ProScoreEffect", "Season4ProScoreEffect", "Season5ProScoreEffect", "Season6ProScoreEffect", "Season7ProScoreEffect", "Season8ProScoreEffect", "Season9ProScoreEffect", "ShockwaveBlastScoreEffect", "SixSeven2ScoreEffect", "SixSevenScoreEffect", "SkeletonGrabScoreEffect", "SkullScoreEffect", "SlimeSplashScoreEffect", "SnowTornadoScoreEffect", "SpellCasterScoreEffect", "SpiderInfestationScoreEffect", "SpiritExplosionScoreEffect", "SpringSunScoreEffect", "StPatricksBurstScoreEffect", "StormyWaveScoreEffect", "StrobeLightScoreEffect", "SupernovaScoreEffect", "TapDancerScoreEffect", "ThunderstormScoreEffect", "TimeStopperEasterScoreEffect", "TimeStopperScoreEffect", "TongueScoreEffect", "TrampolineScoreEffect", "TreasureChestScoreEffect", "TsunamiScoreEffect", "VioletBeamScoreEffect", "WaterSplashScoreEffect", "WatermelonSmashScoreEffect", "WhirlpoolScoreEffect", "WindBurstScoreEffect", "WolfEmojiScoreEffect", "XDScoreEffect", "XylophoneScoreEffect"
    }
    table.sort(effectList)
    return effectList
end

effectList = loadEffects()

cardList = {}
local function loadCards()
    cardList = {}
    local ItemEntities = ReplicatedStorage.Content.Item.Entities
    if ItemEntities then
        for _, child in ipairs(ItemEntities:GetChildren()) do
            if child:IsA("ModuleScript") then
                local name = child.Name
                if string.match(name, "Card") or string.match(name, "PlayerCard") then
                    table.insert(cardList, name)
                end
            end
        end
    end
    table.sort(cardList)
    if #cardList == 0 then
        table.insert(cardList, "ContentCreatorPlayerCard")
    end
    return cardList
end

cardList = loadCards()

local function enableHitEffect()
    if hitConnection then return end
    hasFired = false
    isLocalHit = false
    local lastHitTime = 0
    local lastVaultTime = 0
    local Remote = HitGround
    if not Remote then
        warn("[NodtHub] service not found")
        return false
    end
    -- guardada em Library.HitRemoteConn para poder ser desconectada junto com as outras
    -- (sem gastar um slot de local do chunk principal).
    if Library.HitRemoteConn then
        Library.HitRemoteConn:Disconnect()
        Library.HitRemoteConn = nil
    end
    Library.HitRemoteConn = track(Remote.OnClientEvent:Connect(function(...)
        local args = {...}
        local myName = LocalPlayer.Name
        for _, val in pairs(args) do
            if tostring(val) == myName then
                isLocalHit = true
                break
            end
        end
    end))
    local function fireHitRemote(hitPos)
        if hasFired then return end
        if not isLocalHit then return end
        if not hitEffectEnabled then return end
        if os.clock() - lastHitTime <= 0.5 then return end
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if root and root.AssemblyLinearVelocity.Magnitude > 50 then return end
        lastHitTime = os.clock()
        hasFired = true
        local myUsername = LocalPlayer.Name
        local targetObject = workspace:FindFirstChild(myUsername) or workspace:FindFirstChild("uwuwuwiiwuw6")
        local effectId = State.selectedEffect
        local hardHit = true
        if effectId == "GroundHit1" or effectId == "GroundHit2" then
            hardHit = effectId == "GroundHit2"
            effectId = nil
        end
        if firesignal then
            -- [NOVO] sincroniza o slot do inventário antes do disparo
            -- Cooldown: evita flood de chamadas ao Vault (no maximo 1 a cada 0.5s).
            if os.clock() - lastVaultTime > 0.5 then
                lastVaultTime = os.clock()
                Vault.setSlot("ScoreEffect", State.selectedEffect)
            end
            -- [NOVO] delay antes do firesignal
            task.wait(math.random(9, 11) / 100)
            firesignal(Remote.OnClientEvent, table.unpack({
                hitPos,
                hardHit,
                false,
                5,
                effectId,
                targetObject,
                Vector3.new(-0.000002088591600113432, 1, -0.000004710930170404026)
            }, 1, 7))
        end
        task.wait(0.5)
        hasFired = false
        isLocalHit = false
    end
    hitConnection = track(workspace.ChildAdded:Connect(function(child)
        if child.Name == "HitIndicator" then
            if child.Color == Color3.fromRGB(0, 255, 0) then
                fireHitRemote(child.Position)
            end
        end
    end))
    hitRemovedConnection = track(workspace.DescendantRemoving:Connect(function(child)
        if child.Name == "HitIndicator" then
            hasFired = false
            isLocalHit = false
        end
    end))
    return true
end

local function setupCharacter(character)
    local humanoid = character:WaitForChild("Humanoid")
    local rootPart = character:WaitForChild("HumanoidRootPart")
    
    if shiftLockConnection then
        shiftLockConnection:Disconnect()
        shiftLockConnection = nil
    end

    shiftLockConnection = humanoid:GetPropertyChangedSignal("Jump"):Connect(function()
        if humanoid.Jump and (State.autoShiftLockEnabled or AutoCorner.enabled) then
            task.defer(function()
                local tracked = AutoCorner.enabled and getNearestBall()
                local before = tracked and tracked.Position
                local stamp = os.clock()
                task.wait(0.03)
                if tracked and before and tracked.Parent then
                    AutoCorner.trackBall(tracked, before, os.clock() - stamp)
                end
                local lookVector = AutoCorner.enabled and AutoCorner.facing()
                if not lookVector and State.autoShiftLockEnabled then
                    lookVector = Vector3.new(Camera.CFrame.LookVector.X, 0, Camera.CFrame.LookVector.Z)
                end
                if lookVector and lookVector.Magnitude > 0 then
                    AutoCorner.steer = lookVector
                    if State.autoShiftLockEnabled or AutoCorner.enabled then
                        rootPart.CFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + lookVector.Unit)
                        humanoid.AutoRotate = false
                    end
                end
            end)
        else
            if not State.autoShiftLockEnabled and not AutoCorner.enabled then
                if humanoid.FloorMaterial == Enum.Material.Air then
                    humanoid.AutoRotate = false
                else
                    humanoid.AutoRotate = true
                end
            end
        end
    end)

    humanoid:GetPropertyChangedSignal("FloorMaterial"):Connect(function()
        if State.autoShiftLockEnabled or AutoCorner.enabled then
            return
        end
        if humanoid.FloorMaterial == Enum.Material.Air then
            humanoid.AutoRotate = false
        else
            humanoid.AutoRotate = true
        end
    end)
end

local function toggleShiftLock(state)
    State.autoShiftLockEnabled = state
    if not state and not AutoCorner.enabled then
        local char = LocalPlayer.Character
        if char then
            local humanoid = char:FindFirstChild("Humanoid")
            if humanoid then
                if humanoid.FloorMaterial == Enum.Material.Air then
                    humanoid.AutoRotate = false
                else
                    humanoid.AutoRotate = true
                end
            end
        end
    end
end

if LocalPlayer.Character then
    setupCharacter(LocalPlayer.Character)
end
track(LocalPlayer.CharacterAdded:Connect(setupCharacter))

local function doFakeSpike()
    if not State.fakeSpikeEnabled then return end
    local char = LocalPlayer.Character
    if not char then return end
    
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end

    if _AC and _AC.PlayAnimation then
        hum.Jump = true
        _AC:PlayAnimation("SpikeJump")

        task.delay(0.28, function()
            _AC:PlayAnimation("Spike")
        end)
    end
end

track(UserInputService.JumpRequest:Connect(function()
    if State.fakeSpikeEnabled then
        doFakeSpike()
    end
end))

local function startAutoSpin()
    coroutine.wrap(function()
        while State.autoSpin do
            local currentStyle = LocalPlayer.PlayerGui.Interface.Lobby.Styles.TopPanel.DisplayName.Text
            for _, style in ipairs(desiredStyles) do
                if currentStyle == style then
                    State.autoSpin = false
                    return
                end
            end
            local args = { [1] = (State.spinType == "Lucky") }
            local StyleService = getPackageService("StyleService")
            local Roll = StyleService and getServiceChild(StyleService, "RF", "Roll")
            if not Roll then
                warn("[NodtHub] service not found")
                return
            end
            Roll:InvokeServer(unpack(args))
            task.wait(0)
        end
    end)()
end

local function startAutoAbilitySpin()
    coroutine.wrap(function()
        while State.autoAbilitySpin do
            local currentAbility = LocalPlayer.PlayerGui.Interface.Lobby.Abilities.TopPanel.DisplayName.Text
            for _, ability in ipairs(desiredAbilities) do
                if currentAbility == ability then
                    State.autoAbilitySpin = false
                    return
                end
            end
            local args = { [1] = (State.abilitySpinType == "Lucky") }
            local AbilityService = getPackageService("AbilityService")
            local Roll = AbilityService and getServiceChild(AbilityService, "RF", "Roll")
            if not Roll then
                warn("[NodtHub] service not found")
                return
            end
            Roll:InvokeServer(unpack(args))
            task.wait(0)
        end
    end)()
end

local function enableAntiLag()
    local function safeGet(instance, propertyName)
        local reached, value = pcall(function()
            return instance[propertyName]
        end)
        if reached then
            return value
        end
        return nil
    end

    local function safeSet(instance, propertyName, value)
        instance[propertyName] = value
    end

    local function rememberProperty(instance, propertyName)
        if not instance then return end
        local data = changedProperties[instance]
        if not data then
            data = {}
            changedProperties[instance] = data
        end
        if data[propertyName] == nil then
            local current = safeGet(instance, propertyName)
            if current == nil then return false end
            data[propertyName] = current
        end
        return true
    end

    local function rememberAndSet(instance, propertyName, value)
        if not instance then return end
        if not rememberProperty(instance, propertyName) then return end
        safeSet(instance, propertyName, value)
    end

    local function shouldSkip(instance)
        if not instance then return true end
        local character = LocalPlayer.Character
        if character and instance:IsDescendantOf(character) then
            return true
        end
        return false
    end

    local function optimizeInstance(instance)
        if shouldSkip(instance) then return end
        
        if instance:IsA("BasePart") then
            rememberAndSet(instance, "Material", Enum.Material.SmoothPlastic)
            rememberAndSet(instance, "Reflectance", 0)
            rememberAndSet(instance, "CastShadow", false)
            if instance:IsA("MeshPart") then
                rememberAndSet(instance, "RenderFidelity", Enum.RenderFidelity.Performance)
                rememberAndSet(instance, "TextureID", "")
            end
        elseif instance:IsA("Decal") or instance:IsA("Texture") then
            rememberAndSet(instance, "Transparency", 1)
        elseif instance:IsA("ParticleEmitter") or instance:IsA("Trail") or instance:IsA("Beam") or instance:IsA("Smoke") or instance:IsA("Fire") or instance:IsA("Sparkles") then
            rememberAndSet(instance, "Enabled", false)
        elseif instance:IsA("PointLight") or instance:IsA("SpotLight") or instance:IsA("SurfaceLight") then
            rememberAndSet(instance, "Enabled", false)
        elseif instance:IsA("SpecialMesh") then
            rememberAndSet(instance, "TextureId", "")
        elseif instance:IsA("SurfaceAppearance") then
            rememberAndSet(instance, "ColorMap", "")
            rememberAndSet(instance, "MetalnessMap", "")
            rememberAndSet(instance, "NormalMap", "")
            rememberAndSet(instance, "RoughnessMap", "")
        end
    end

    local function optimizeLighting()
        rememberAndSet(Lighting, "Technology", Enum.Technology.Compatibility)
        rememberAndSet(Lighting, "GlobalShadows", false)
        rememberAndSet(Lighting, "FogEnd", 1e9)
        rememberAndSet(Lighting, "ShadowSoftness", 0)
        
        for _, effect in ipairs(Lighting:GetChildren()) do
            if effect:IsA("PostEffect") then
                rememberAndSet(effect, "Enabled", false)
            elseif effect:IsA("Atmosphere") then
                rememberAndSet(effect, "Density", 0)
                rememberAndSet(effect, "Haze", 0)
                rememberAndSet(effect, "Glare", 0)
            elseif effect:IsA("Sky") then
                rememberAndSet(effect, "CelestialBodiesShown", false)
                rememberAndSet(effect, "StarCount", 0)
            end
        end
    end

    local function optimizeTerrain()
        local terrain = workspace:FindFirstChildOfClass("Terrain")
        if not terrain then return end
        
        rememberAndSet(terrain, "Decoration", false)
        rememberAndSet(terrain, "WaterWaveSize", 0)
        rememberAndSet(terrain, "WaterWaveSpeed", 0)
        rememberAndSet(terrain, "WaterReflectance", 0)
        rememberAndSet(terrain, "WaterTransparency", 1)
    end

    local function setLowestQuality()
        local rendering = settings().Rendering
        if oldQualityLevel == nil then
            oldQualityLevel = rendering.QualityLevel
        end
        rendering.QualityLevel = Enum.QualityLevel.Level01
        
        local userGameSettings = UserSettings():GetService("UserGameSettings")
        if oldSavedQualityLevel == nil then
            oldSavedQualityLevel = userGameSettings.SavedQualityLevel
        end
        userGameSettings.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1
    end

    setLowestQuality()
    optimizeLighting()
    optimizeTerrain()
    
    local count = 0
    for _, instance in ipairs(workspace:GetDescendants()) do
        optimizeInstance(instance)
        count = count + 1
        if count % 100 == 0 then task.wait() end
    end
    
    local conn = workspace.DescendantAdded:Connect(function(instance)
        optimizeInstance(instance)
    end)
    table.insert(antilagConnections, conn)
end

local function disableAntiLag()
    for instance, props in pairs(changedProperties) do
        for prop, value in pairs(props) do
            instance[prop] = value
        end
    end
    changedProperties = {}
    
    if oldQualityLevel ~= nil then
        settings().Rendering.QualityLevel = oldQualityLevel
        oldQualityLevel = nil
    end
    
    if oldSavedQualityLevel ~= nil then
        UserSettings():GetService("UserGameSettings").SavedQualityLevel = oldSavedQualityLevel
        oldSavedQualityLevel = nil
    end
    
    for _, conn in ipairs(antilagConnections) do
        conn:Disconnect()
    end
    antilagConnections = {}
end
Library.RestoreAntiLag = disableAntiLag

local Window = Library:CreateWindow({
    Title = "Nodt Hub",
    Footer = "Volleyball Legends",
    NotifySide = "Right",
})

local Tabs = {
    Main = Window:AddTab("Main", "crosshair", Color3.fromRGB(255, 96, 58), "Ferramentas principais e automações"),
    Character = Window:AddTab("Personagem", "user", Color3.fromRGB(46, 230, 190), "Ajustes do personagem"),
    Visuals = Window:AddTab("Visuals", "eye", Color3.fromRGB(255, 184, 40), "Efeitos e visual do jogo"),
    Misc = Window:AddTab("Misc", "settings", Color3.fromRGB(64, 196, 255), "Opções diversas"),
    GameJoin = Window:AddTab("Game Join", "gamepad-2", Color3.fromRGB(190, 240, 70), "Entrada e seleção de partidas"),
    ["UI Settings"] = Window:AddTab("UI Settings", "sliders-horizontal", Color3.fromRGB(140, 166, 176), "Tema e configurações da interface"),
}

local UI = {}

UI.LeftGroupBox = Tabs.Main:AddLeftGroupbox("Spike Settings", "crosshair")

UI.LeftGroupBox:AddToggle("redirectspike", {
    Text = "Redirect Spike",
    Tooltip = "Redirect spike to camera direction",
    Default = false,
    Callback = function(Value)
        if Value then
            enableRedirectSpike()
        else
            disableRedirectSpike()
        end
    end,
})

UI.LeftGroupBox:AddToggle("autocorner", {
    Text = "Auto Corner",
    Tooltip = "Aims to the corner sides of the enemy's goal",
    Default = false,
    Callback = function(Value)
        AutoCorner.enabled = Value
        if Value then
            AutoCorner.installAim()
        else
            if not State.autoShiftLockEnabled then
                local char = LocalPlayer.Character
                local humanoid = char and char:FindFirstChild("Humanoid")
                if humanoid then
                    if humanoid.FloorMaterial == Enum.Material.Air then
                        humanoid.AutoRotate = false
                    else
                        humanoid.AutoRotate = true
                    end
                end
            end
        end
    end,
})

UI.LeftGroupBox:AddDropdown("autocornerside", {
    Values = {"Auto", "Left", "Right"},
    Default = "Auto",
    Text = "Corner Side",
    Callback = function(Value)
        AutoCorner.side = Value
    end,
})

UI.LeftGroupBox:AddDropdown("autocornerreach", {
    Values = {"All", "Back", "Nearest"},
    Default = "All",
    Text = "Corner Depth",
    Callback = function(Value)
        AutoCorner.reach = Value
    end,
})

UI.LeftGroupBox:AddLabel("Auto Corner bind"):AddKeyPicker("autocornerbind", {
    Default = "C",
    Mode = "Press",
    Text = "Auto Corner",
    Callback = function()
        local toggle = Toggles.autocorner
        if toggle then
            toggle:SetValue(not toggle.Value)
        end
    end,
})

UI.LeftGroupBox:AddToggle("newspike", {
    Text = "Silent Spike",
    Tooltip = "Spike with no animation or sound",
    Default = false,
    Callback = function(Value)
        State.newSilentSpikeEnabled = Value
        if newSpikeButton then
            newSpikeButton.Visible = Value
        end
    end,
})

UI.LeftGroupBox:AddLabel("Silent Spike bind"):AddKeyPicker("newspikebind", {
    Default = "R",
    Mode = "Press",
    Text = "Silent Spike",
    Callback = function()
        fireNewSpike()
    end,
})

UI.LeftGroupBox:AddToggle("sanju", {
    Text = "Sanju Tilt",
    Tooltip = "Sanju tilt effect",
    Default = false,
    Callback = function(Value)
        if Value then
            enableSanjuTilt()
        else
            disableSanjuTilt()
        end
    end,
})

UI.LeftGroupBox:AddToggle("maxcharge", {
    Text = "Max Charge Special",
    Tooltip = "Max charge your special",
    Default = false,
    Callback = function(Value)
        if Value then
            enableMaxCharge()
        else
            disableMaxCharge()
        end
    end,
})

UI.LeftGroupBox:AddToggle("fakespike", {
    Text = "Fake Spike",
    Tooltip = "Auto fake spike when jumping",
    Default = false,
    Callback = function(Value)
        State.fakeSpikeEnabled = Value
    end,
})

UI.LeftGroupBox:AddToggle("autocounter", {
    Text = "Auto Counter",
    Tooltip = "Counters an enemy spike when both of you are at the net",
    Default = false,
    Callback = function(Value)
        AutoCounter.state.enabled = Value
    end,
})

UI.LeftGroupBox:AddDropdown("autocountermove", {
    Values = {"Auto", "Block", "Spike"},
    Default = "Auto",
    Text = "Counter Move",
    Tooltip = "Auto: block while the ball is still on their half, spike once it crosses",
    Callback = function(Value)
        AutoCounter.state.move = Value
    end,
})

UI.LeftGroupBox:AddSlider("autocounternetrange", {
    Text = "Counter Net Range",
    Default = 9,
    Min = 3,
    Max = 20,
    Rounding = 1,
    Callback = function(Value)
        AutoCounter.state.netRange = Value
    end,
})

UI.LeftGroupBox:AddSlider("autocounterlateral", {
    Text = "Counter Width",
    Default = 14,
    Min = 4,
    Max = 30,
    Rounding = 1,
    Callback = function(Value)
        AutoCounter.state.lateral = Value
    end,
})

UI.LeftGroupBox:AddSlider("autocounterdelay", {
    Text = "Counter Delay",
    Default = 0.05,
    Min = 0,
    Max = 0.5,
    Rounding = 2,
    Callback = function(Value)
        AutoCounter.state.delay = Value
    end,
})

UI.LeftGroupBox:AddToggle("autocounterjump", {
    Text = "Counter Auto Jump",
    Tooltip = "Jump before the counter, the block hitbox dies the moment you land",
    Default = true,
    Callback = function(Value)
        AutoCounter.state.autoJump = Value
    end,
})

UI.LeftGroupBox:AddLabel("Auto Counter bind"):AddKeyPicker("autocounterbind", {
    Default = "N",
    Mode = "Press",
    Text = "Auto Counter",
    Callback = function()
        local toggle = Toggles.autocounter
        if toggle then
            toggle:SetValue(not toggle.Value)
        end
    end,
})

UI.HitboxGroup = Tabs.Main:AddRightGroupbox("Hitbox Settings", "box")

UI.HitboxGroup:AddToggle("hitboxenable", {
    Text = "Enable Hitbox",
    Tooltip = "Turn Hitbox ON/OFF",
    Default = false,
    Callback = function(Value)
        hitboxEnabled = Value
        if Value then
            updateHitboxes(hitboxScale)
        else
            removeHitboxes()
        end
    end,
})

UI.HitboxGroup:AddSlider("hitboxsize", {
    Text = "Hitbox Size",
    Tooltip = "Reach in studs, the server refuses anything past 20",
    Default = 5,
    Min = 0,
    Max = 20,
    Rounding = 1,
    Callback = function(Value)
        hitboxScale = Value
        if hitboxEnabled then
            updateHitboxes(Value)
        end
    end,
})

UI.HitboxGroup:AddDropdown("hitboxcolor", {
    Values = {"Invisible", "White", "Green", "Blue", "Red", "Yellow", "Purple", "Orange", "Pink"},
    Default = "Blue",
    Text = "Hitbox Color",
    Callback = function(Value)
        local colors = {
            Invisible = Color3.fromRGB(255, 255, 255),
            White = Color3.fromRGB(255, 255, 255),
            Green = Color3.fromRGB(0, 255, 0),
            Blue = Color3.fromRGB(0, 0, 255),
            Red = Color3.fromRGB(255, 0, 0),
            Yellow = Color3.fromRGB(255, 255, 0),
            Purple = Color3.fromRGB(128, 0, 128),
            Orange = Color3.fromRGB(255, 165, 0),
            Pink = Color3.fromRGB(255, 105, 180)
        }
        local transparencies = {
            Invisible = 1,
            White = 0.3,
            Green = 0.3,
            Blue = 0.3,
            Red = 0.3,
            Yellow = 0.3,
            Purple = 0.3,
            Orange = 0.3,
            Pink = 0.3
        }
        hitboxColor = colors[Value] or Color3.fromRGB(0, 0, 255)
        hitboxTransparency = transparencies[Value] or 0.3
        if hitboxEnabled then
            updateHitboxes(hitboxScale)
        end
    end,
})

UI.HitboxGroup:AddButton({
    Text = "Remove Hitboxes",
    Func = function()
        removeHitboxes()
    end,
})

UI.HitboxGroup:AddButton({
    Text = "Show Stop Ball",
    Func = function()
        stopBallVisible = not stopBallVisible
        if stopBallButton then
            stopBallButton.Visible = stopBallVisible
        else
            stopBallButton = createStopBallButton()
        end
    end,
})

UI.HitboxGroup:AddButton({
    Text = "Show Aim",
    Func = function()
        aimVisible = not aimVisible
        if aimButton then
            aimButton.Visible = aimVisible
        else
            aimButton = createAimButton()
        end
    end,
})

UI.PerfGroup = Tabs.Main:AddLeftGroupbox("Performance", "gauge")

UI.PerfGroup:AddToggle("antilag", {
    Text = "Anti-Lag",
    Tooltip = "Reduce graphics for better performance",
    Default = false,
    Callback = function(Value)
        if Value then
            enableAntiLag()
        else
            disableAntiLag()
        end
    end,
})

UI.MoveGroup = Tabs.Main:AddRightGroupbox("Movement", "move")

UI.MoveGroup:AddToggle("desync", {
    Text = "Desync",
    Tooltip = "Desync movement",
    Default = false,
    Callback = function(Value)
        if Value then
            enableDesync()
        else
            disableDesync()
        end
    end,
})

UI.MoveGroup:AddToggle("autoreceive", {
    Text = "Auto Receive",
    Tooltip = "Auto receive the ball",
    Default = false,
    Callback = function(Value)
        State.autoReceiveEnabled = Value
    end,
})

UI.MoveGroup:AddSlider("autoreceiverange", {
    Text = "Receive Range",
    Default = 10,
    Min = 3,
    Max = 20,
    Rounding = 1,
    Callback = function(Value)
        Receive.range = Value
    end,
})

UI.MoveGroup:AddSlider("autoreceivelead", {
    Text = "Receive Lead",
    Default = 0.35,
    Min = 0,
    Max = 1,
    Rounding = 2,
    Callback = function(Value)
        Receive.lead = Value
    end,
})

UI.MoveGroup:AddLabel("Auto Receive bind"):AddKeyPicker("autoreceivebind", {
    Default = "X",
    Mode = "Press",
    Text = "Auto Receive",
    Callback = function()
        local toggle = Toggles.autoreceive
        if toggle then
            toggle:SetValue(not toggle.Value)
        end
    end,
})

UI.MoveGroup:AddToggle("kisukidive", {
    Text = "Kisuki Dive",
    Tooltip = "Kisuki super dive",
    Default = false,
    Callback = function(Value)
        Kisuki.enabled = Value
        if Value then
            Kisuki.install()
        end
    end,
})

UI.MoveGroup:AddSlider("kisukicharge", {
    Text = "Dive Charge",
    Tooltip = "Lerps Kimiro's real 19.5-45 power range, past 0.5 the FX go strong",
    Default = 1,
    Min = 0,
    Max = 1,
    Rounding = 2,
    Callback = function(Value)
        Kisuki.charge = Value
    end,
})

UI.MoveGroup:AddToggle("akaridash", {
    Text = "Akari Dash",
    Tooltip = "Dash into the ball",
    Default = false,
    Callback = function(Value)
        State.akariDashEnabled = Value
        if dashButton then
            dashButton.Visible = Value
        end
    end,
})

UI.MoveGroup:AddLabel("Akari Dash bind"):AddKeyPicker("akaridashbind", {
    Default = "F",
    Mode = "Press",
    Text = "Akari Dash",
    Callback = function()
        akariDash()
    end,
})

UI.MoveGroup:AddToggle("leadfeet", {
    Text = "Lead Feet",
    Tooltip = "Slams you down at the ability's own -10000 acceleration",
    Default = false,
    Callback = function(Value)
        State.leadFeetEnabled = Value
        if leadFeetButton then
            leadFeetButton.Visible = Value
        end
    end,
})

UI.MoveGroup:AddLabel("Lead Feet bind"):AddKeyPicker("leadfeetbind", {
    Default = "G",
    Mode = "Press",
    Text = "Lead Feet",
    Callback = function()
        leadFeetSlam()
    end,
})

UI.MaxServeGroup = Tabs.Main:AddLeftGroupbox("Max Serve", "server")

UI.MaxServeGroup:AddToggle("maxserve", {
    Text = "Max Serve",
    Tooltip = "Max serve power",
    Default = false,
    Callback = function(Value)
        if Value then
            enableMaxServe()
        else
            disableMaxServe()
        end
    end,
})

UI.MaxServeGroup:AddToggle("esp", {
    Text = "Jump ESP",
    Tooltip = "Highlight enemies while they are jumping",
    Default = false,
    Callback = function(Value)
        State.espJumpEnabled = Value
        if not Value then
            for player in pairs(espHighlights) do
                removeESP(player)
            end
        end
    end,
})

UI.DataGroup = Tabs.Main:AddRightGroupbox("Data", "database")

UI.DataGroup:AddButton({
    Text = "Data Rollback",
    Func = function()
        local packages = ReplicatedStorage:FindFirstChild("Packages")
        local index = packages and packages:FindFirstChild("_Index")
        if not index then
            Library:Notify("Data Rollback: _Index nao encontrado")
            return
        end
        local knitPkg
        for _, child in ipairs(index:GetChildren()) do
            if child.Name:match("^sleitnick_knit@") then
                knitPkg = child
                break
            end
        end
        if not knitPkg then
            Library:Notify("Data Rollback: pacote Knit nao encontrado")
            return
        end
        local knitRoot = knitPkg:FindFirstChild("knit")
        local services = knitRoot and knitRoot:FindFirstChild("Services")
        local settings = services and services:FindFirstChild("SettingsService")
        local rf = settings and settings:FindFirstChild("RF")
        local updateKeybind = rf and rf:FindFirstChild("UpdateKeybind")
        if not updateKeybind then
            Library:Notify("Data Rollback: UpdateKeybind nao encontrado")
            return
        end
        updateKeybind:InvokeServer("MouseButton1", true, "Spike\xE2\x80\x8B\x8F")
        game:GetService("TeleportService"):Teleport(game.PlaceId)
    end,
})

UI.CharAttrGroup = Tabs.Character:AddLeftGroupbox("Attributes", "sliders-horizontal")

UI.CharAttrGroup:AddInput("divespeed", {
    Default = "",
    Numeric = true,
    Finished = true,
    Text = "Dive Speed",
    Placeholder = "0.95",
    Callback = function(Value)
        local num = tonumber(Value)
        if num then
            LocalPlayer:SetAttribute("Multiplier_DiveSpeed", num)
        end
    end,
})

UI.CharAttrGroup:AddInput("jumppower", {
    Default = "",
    Numeric = true,
    Finished = true,
    Text = "Jump Power",
    Placeholder = "1.1",
    Callback = function(Value)
        local num = tonumber(Value)
        if num then
            LocalPlayer:SetAttribute("Multiplier_JumpPower", num)
        end
    end,
})

UI.CharAttrGroup:AddInput("speed", {
    Default = "",
    Numeric = true,
    Finished = true,
    Text = "Speed",
    Placeholder = "0.85",
    Callback = function(Value)
        local num = tonumber(Value)
        if num then
            LocalPlayer:SetAttribute("Multiplier_Speed", num)
        end
    end,
})

UI.CharMoveGroup = Tabs.Character:AddRightGroupbox("Movement", "move")

UI.CharMoveGroup:AddToggle("airmove", {
    Text = "Air Movement",
    Tooltip = "Move in the air",
    Default = false,
    Callback = function(Value)
        State.airMovement = Value
        if not Value and bodyVelocity then
            bodyVelocity:Destroy()
            bodyVelocity = nil
        end
    end,
})

UI.CharMoveGroup:AddSlider("airspeed", {
    Text = "Air Movement Speed",
    Default = 16,
    Min = 0,
    Max = 100,
    Rounding = 0,
    Callback = function(Value)
        State.airMovementSpeed = Value
    end,
})

UI.CharMoveGroup:AddToggle("autoshiftlock", {
    Text = "Auto Shift Lock",
    Tooltip = "Auto rotate to camera when jumping",
    Default = false,
    Callback = function(Value)
        toggleShiftLock(Value)
    end,
})

UI.CharMoveGroup:AddToggle("characterlines", {
    Text = "Character Enemy/Team Line",
    Tooltip = "Show colored beams to enemies",
    Default = false,
    Callback = function(Value)
        linesEnabled = Value
        if not Value then
            for player in pairs(lines) do
                removeLine(player)
            end
        end
    end,
})

UI.CharMoveGroup:AddSlider("linedistance", {
    Text = "Line Distance",
    Default = 50,
    Min = 10,
    Max = 200,
    Rounding = 1,
    Callback = function(Value)
        State.lineDistance = Value
    end,
})

Tabs.Visuals:AddRightGroupbox("Ball Prediction", "target"):AddToggle("ballmarker", {
    Text = "Landing Marker",
    Tooltip = "Predict where the ball land and say if it's out or not",
    Default = false,
    Callback = function(Value)
        Landing.enabled = Value
        if not Value then
            Landing.clear()
        end
    end,
})

-- VISUAL APPLY (dropdown selects, button applies on demand)
VisualApply = {}

function VisualApply.pick(list, wanted)
    if table.find(list, wanted) then
        return wanted
    end
    return list[1]
end

State.selectedEffect = VisualApply.pick(effectList, State.selectedEffect)
State.selectedCard = VisualApply.pick(cardList, State.selectedCard)
State.selectedBallSkin = VisualApply.pick(ballSkinList, State.selectedBallSkin)

function VisualApply.score()
    -- o toggle "Score Effect ON" controla hitEffectEnabled (callback seta true)
    local toggle = UI.ScoreEffectToggle
    if toggle then
        toggle:SetValue(true)
    end
    local ok = pcall(enableHitEffect)
    if not ok or not hitConnection then
        hitEffectEnabled = false
        State.hitEffectEnabled = false
        if toggle and toggle.SetValue then toggle:SetValue(false, true) end
        Library:Notify("Score effect failed to enable")
        return
    end
    Vault.mark("ScoreEffect", true)
    Vault.setSlot("ScoreEffect", State.selectedEffect)
    Library:Notify("Score effect applied: " .. State.selectedEffect)
end

function VisualApply.card()
    playerCardEnabled = true
    pcall(enablePlayerCard)
    Vault.mark("PlayerCard", true)
    Vault.setSlot("PlayerCard", State.selectedCard)
    task.spawn(function()
        pcall(fireCardRemote)
    end)
    Library:Notify("Player card applied: " .. State.selectedCard)
end

function VisualApply.ball()
    State.autoApplyBallSkin = true
    Vault.mark("Ball", true)
    Vault.setSlot("Ball", State.selectedBallSkin)
    task.spawn(safeSweep)
    Library:Notify("Ball applied: " .. State.selectedBallSkin)
end

function VisualApply.jersey()
    State.autoApplyJersey = true
    local jerseyToggle = Toggles.autoapplyjersey
    if jerseyToggle and jerseyToggle.SetValue then
        jerseyToggle:SetValue(true, true)
    end
    pickedTeam = nil
    task.spawn(function()
        pcall(applyJersey, State.selectedJersey)
    end)
    Library:Notify("Jersey applied: " .. State.selectedJersey)
end

UI.VisualScoreGroup = Tabs.Visuals:AddLeftGroupbox("Score Effect", "sparkles")

UI.VisualScoreGroup:AddDropdown("effectselect", {
    Values = effectList,
    Default = State.selectedEffect,
    Text = "Select Score Effect",
    Callback = function(Value)
        State.selectedEffect = Value
    end,
})

UI.ScoreEffectToggle = UI.VisualScoreGroup:AddToggle("scoreeffecton", {
    Text = "Score Effect ON",
    Tooltip = "Liga/desliga o Score Effect",
    Default = false,
    Callback = function(Value)
        hitEffectEnabled = Value
        if Value then
            local ok = pcall(enableHitEffect)
            if not ok or not hitConnection then
                hitEffectEnabled = false
                State.hitEffectEnabled = false
                local toggle = UI.ScoreEffectToggle
                if toggle and toggle.SetValue then toggle:SetValue(false, true) end
                Library:Notify("[NodtHub] Score effect failed to enable")
                return
            end
            Vault.mark("ScoreEffect", true)
            Vault.setSlot("ScoreEffect", State.selectedEffect)
        else
            Vault.mark("ScoreEffect", false)
            hitEffectEnabled = false
            -- Fix 6: solta os listeners do workspace/remote para nao ficarem ativos com o efeito off.
            if hitConnection then hitConnection:Disconnect() hitConnection = nil end
            if hitRemovedConnection then hitRemovedConnection:Disconnect() hitRemovedConnection = nil end
            if Library.HitRemoteConn then Library.HitRemoteConn:Disconnect() Library.HitRemoteConn = nil end
        end
    end,
})

UI.VisualScoreGroup:AddButton({
    Text = "Apply Score Effect",
    Func = VisualApply.score,
})

UI.VisualProtectGroup = Tabs.Visuals:AddRightGroupbox("Protection", "shield")

UI.VisualProtectGroup:AddToggle("protect", {
    Text = "Protect",
    Tooltip = "Enable/Disable all protection features",
    Default = false,
    Callback = function(Value)
        toggleProtection(Value)
    end,
})

UI.VisualProtectGroup:AddToggle("tshanimation", {
    Text = "TSH Animation",
    Tooltip = "PowerSpike + SpecialChargeSpikeVFX on spike",
    Default = false,
    Callback = function(Value)
        State.tshAnimationEnabled = Value
    end,
})

UI.VisualProtectGroup:AddToggle("hidarianimation", {
    Text = "Hidari Animation",
    Tooltip = "PowerSpike + HidariSpikeVFX on spike",
    Default = false,
    Callback = function(Value)
        State.hidariAnimationEnabled = Value
    end,
})

UI.VisualProtectGroup:AddToggle("kazanabluejump", {
    Text = "Kazana Blue Jump",
    Tooltip = "Fires KazanaBlue on jump",
    Default = false,
    Callback = function(Value)
        State.kazanaBlueEnabled = Value
    end,
})

UI.VisualProtectGroup:AddToggle("kazanawhitejump", {
    Text = "Kazana White Jump",
    Tooltip = "Fires KazanaWhite on jump",
    Default = false,
    Callback = function(Value)
        State.kazanaWhiteEnabled = Value
    end,
})

UI.PlayerCardGroup = Tabs.Visuals:AddLeftGroupbox("Player Card", "id-card")

UI.PlayerCardGroup:AddDropdown("cardselect", {
    Values = cardList,
    Default = State.selectedCard,
    Text = "Select Player Card",
    Callback = function(Value)
        State.selectedCard = Value
    end,
})

UI.PlayerCardGroup:AddButton({
    Text = "Apply Player Card",
    Func = VisualApply.card,
})

UI.PlayerCardGroup:AddButton({
    Text = "Reset Card",
    Func = function()
        playerCardEnabled = false
        -- tira o card da lista de re-aplicacao (respawn) para o reset nao ser desfeito.
        Vault.mark("PlayerCard", false)
        if Vault.realEquipped and Vault.realEquipped.PlayerCard then
            Vault.setSlot("PlayerCard", Vault.realEquipped.PlayerCard)
        end
        Library:Notify("Player card reset")
    end,
})

UI.PlayerCardGroup:AddToggle("cardprotect", {
    Text = "Card Protect",
    Tooltip = "Hide your name on the Player Card",
    Default = false,
    Callback = function(Value)
        CardProtect.set(Value)
        if Value and not Library.Unloaded then
            CardProtect.forceApply()
        end
    end,
})

UI.TitleGroup = Tabs.Visuals:AddRightGroupbox("Title Changer", "tag")

UI.TitleGroup:AddToggle("titleunlock", {
    Text = "Title Changer",
    Tooltip = "Change title",
    Default = false,
    Callback = function(Value)
        Vault.mark("Title", Value)
    end,
})

UI.TitleNames = {}
UI.TitleIdByName = {}
for _, item in ipairs(titleList) do
    table.insert(UI.TitleNames, item.name)
    UI.TitleIdByName[item.name] = item.id
end
UI.TitleSelected = UI.TitleNames[1]

UI.TitleGroup:AddDropdown("titleselect", {
    Values = UI.TitleNames,
    Default = UI.TitleSelected,
    Text = "Select Title",
    Callback = function(Value)
        UI.TitleSelected = Value
    end,
})

UI.TitleGroup:AddButton({
    Text = "Apply Title",
    Func = function()
        local id = UI.TitleIdByName[UI.TitleSelected]
        if not id then
            Library:Notify("Select a title first")
            return
        end
        Vault.mark("Title", true)
        Vault.setSlot("Title", id)
        Library:Notify("Title applied: " .. UI.TitleSelected)
    end,
})

UI.TitleGroup:AddButton({
    Text = "Reset Title",
    Func = function()
        if not Vault.real then
            Library:Notify("No title to reset")
            return
        end
        Vault.revert("Title")
        Library:Notify("Title reset")
    end,
})

-- BALL SKIN UI
UI.BallSkinGroup = Tabs.Visuals:AddLeftGroupbox("Ball Changer", "circle")

UI.BallSkinGroup:AddDropdown("ballselect", {
    Values = ballSkinList,
    Default = State.selectedBallSkin,
    Text = "Select Ball",
    Callback = function(Value)
        State.selectedBallSkin = Value
    end,
})

UI.BallSkinGroup:AddButton({
    Text = "Apply Ball",
    Func = VisualApply.ball,
})

UI.BallSkinGroup:AddButton({
    Text = "Remove Ball Skin",
    Func = function()
        State.autoApplyBallSkin = false
        Vault.mark("Ball", false)
        task.spawn(safeSweep)
        Library:Notify("Ball skin removed")
    end,
})

-- EMOTE UI (slot "Emotes" = table; aplica via Vault.setSlot("Emote", id))
UI.EmoteGroup = Tabs.Visuals:AddLeftGroupbox("Emote Changer", "sparkles")

UI.EmoteNames = {}
UI.EmoteIdByName = {}
for _, item in ipairs(emoteList) do
    table.insert(UI.EmoteNames, item.nome)
    UI.EmoteIdByName[item.nome] = item.id
end
UI.EmoteSelected = UI.EmoteNames[1]

UI.EmoteGroup:AddDropdown("emoteselect", {
    Values = UI.EmoteNames,
    Default = UI.EmoteSelected,
    Text = "Select Emote",
    Callback = function(Value)
        UI.EmoteSelected = Value
    end,
})

-- EMOTE INJECTION (client-side): icone na roda + animacao local. Nada vai pro servidor.
UI.EmoteInject = { slots = {}, cursor = 1 }

UI.EmoteInject.norm = function(value)
    if typeof(value) == "Instance" and value:IsA("Animation") then
        value = value.AnimationId
    end
    if type(value) == "number" then
        return "rbxassetid://" .. tostring(value)
    end
    if type(value) == "string" and value ~= "" then
        if value:match("^%d+$") then
            return "rbxassetid://" .. value
        end
        return value
    end
    return nil
end

-- le o modulo do emote: acha animacao (Asset/Animation) e icone (Image/Icon/Thumbnail)
UI.EmoteInject.resolve = function(id)
    local _, entry = Vault.typeOf(id)
    if type(entry) ~= "table" then return nil end
    local norm = UI.EmoteInject.norm
    local meta = type(entry.Metadata) == "table" and entry.Metadata or {}
    local asset = type(entry.Asset) == "table" and entry.Asset or {}
    local anim = norm(asset.Animation) or norm(asset.Id) or norm(asset.AnimationId)
        or (type(entry.Asset) ~= "table" and norm(entry.Asset) or nil)
        or norm(entry.Animation) or norm(entry.AnimationId)
        or norm(meta.Animation) or norm(meta.AnimationId)
    local icon = norm(asset.Image) or norm(asset.Icon) or norm(asset.Thumbnail)
        or norm(meta.Image) or norm(meta.Icon) or norm(meta.Thumbnail) or norm(meta.ImageId)
        or norm(entry.Image) or norm(entry.Icon) or norm(entry.Thumbnail)
    local keys = {}
    for k in pairs(entry) do
        table.insert(keys, tostring(k))
    end
    for k in pairs(meta) do
        table.insert(keys, "M." .. tostring(k))
    end
    return { anim = anim, icon = icon, keys = table.concat(keys, ",") }
end

UI.EmoteInject.equipped = function()
    local Knit = getKnitRoot()
    if not Knit then return nil end
    local found, inventory = pcall(Knit.GetController, "InventoryController")
    if not found or type(inventory) ~= "table" or not inventory.Equipped then return nil end
    local held, worn = pcall(function()
        return inventory.Equipped:get()
    end)
    if not held or type(worn) ~= "table" then return nil end
    return inventory, (type(worn.Emotes) == "table" and worn.Emotes or {})
end

-- asset embutido na emoteList = id da animacao que o boneco do ViewportFrame vai tocar. Vazio (NONE) = nil
UI.EmoteInject.assets = {}
for _, item in ipairs(emoteList) do
    UI.EmoteInject.assets[item.id] = item.asset
end

UI.EmoteInject.animId = function(id)
    local asset = UI.EmoteInject.assets[id]
    if type(asset) ~= "string" or asset == "" then return nil end
    return UI.EmoteInject.norm(asset)
end

UI.EmoteInject.wheel = function()
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not pg then return nil end
    local static = pg:FindFirstChild("Static")
    return (static and static:FindFirstChild("EmoteWheel")) or pg:FindFirstChild("EmoteWheel", true)
end

-- EMOTE PROPS (client-side): objeto do emote (skate, guitarra...) clonado de ReplicatedStorage e soldado no personagem.
-- id do emote -> caminho a partir de ReplicatedStorage. "" = emote sem objeto.
UI.EmoteInject.EMOTE_PROPS = {
    HakkaSkateboardEmote = "Assets.Misc.EmoteAssets.HakkaSkateboard.SkateboardMesh",
    SkateboardEmote = "Assets.Misc.Skateboard",
    CopySkateboardEmote = "Assets.Misc.Skateboard",
    FestivalGuitarEmote = "Assets.Misc.EmoteAssets.FestivalGuitar.03_Guitar",
    GuitarEmote = "Assets.Misc.Guitar",
    EatTurkeyEmote = "Assets.Misc.EmoteAssets.EatTurkey.TurkeyLeg",
    TurkeyRideEmote = "Assets.Misc.EmoteAssets.RideTurkey.Turkey",
    BroomEmote = "Assets.Misc.WitchBroom",
    VolcanoEmote = "Assets.Misc.VolcanoEmote",
    RideAFireworkEmote = "Assets.Misc.EmoteAssets.RideAFirework.01_Firework",
    GiantBoulderThrowEmote = "Assets.Misc.EmoteAssets.BoulderThrow.Boulder",
    BananaSlipEmote = "Assets.Misc.EmoteAssets.BananaSlip.Banana",
    SkiEmote = "Assets.Misc.EmoteAssets.Skiing.LeftSki",
    SnowballTossEmote = "Assets.Misc.EmoteAssets.TossSnowball.Snowball",
    TomatoThrowEmote = "Assets.Misc.EmoteAssets.ThrowTomato.Rig.Tomato",
    SpyglassEmote = "Assets.Misc.EmoteAssets.Spyglass.Spyglass",
    ShieldBashEmote = "Assets.Misc.EmoteAssets.ShieldBash.Shield",
    SingerEmote = "Assets.Misc.SingerMicrophone",
    TikiDrumEmote = "Assets.Misc.TikiDrum",
    WandEmote = "Assets.Misc.Wand",
    TongueEmote = "Assets.Misc.Tongue",
    FlamethrowerEmote = "Assets.Misc.Flamethrower",
    CarrotEmote = "Assets.Misc.Carrot",
    DiamondEmote = "Assets.Misc.Diamond",
    PopcornEmote = "Assets.Misc.Popcorn",
    EggSpikeEmote = "Assets.Misc.Egg",
    BeachBallEmote = "Assets.Misc.BeachBall",
    SadTromboneEmote = "Assets.Misc.Trombone",
    SadViolinEmote = "Assets.Misc.Violin",
    HeadlessEmote = "", -- nao tem objeto
    PumpkinDribbleEmote = "Assets.Misc.EmoteAssets.PumpkinDribble.Pumpkin",
}

-- onde soldar cada objeto. Fora desta lista = HumanoidRootPart (padrao quando nao ha certeza).
UI.EmoteInject.PROP_ATTACH = {
    -- pe: o personagem fica em cima
    HakkaSkateboardEmote = "RightFoot",
    SkateboardEmote = "RightFoot",
    CopySkateboardEmote = "RightFoot",
    BroomEmote = "RightFoot",
    RideAFireworkEmote = "RightFoot",
    SkiEmote = "RightFoot",
    -- mao
    FestivalGuitarEmote = "RightHand",
    GuitarEmote = "RightHand",
    SadViolinEmote = "RightHand",
    SingerEmote = "RightHand",
    WandEmote = "RightHand",
    ShieldBashEmote = "RightHand",
    EatTurkeyEmote = "RightHand", -- TurkeyLeg e uma coxa de peru (segura na mao); troque p/ HumanoidRootPart se ficar estranho
    -- grandes (HumanoidRootPart)
    TurkeyRideEmote = "HumanoidRootPart",
}

-- chute inicial do usuario: alvo.CFrame * CFrame.new(0, -1, 0). Ajuste fino por emote em PROP_OFFSETS.
UI.EmoteInject.PROP_DEFAULT_OFFSET = CFrame.new(0, -1, 0)
UI.EmoteInject.PROP_OFFSETS = {
    -- exemplo: SkateboardEmote = CFrame.new(0, -0.6, 0) * CFrame.Angles(0, math.rad(90), 0),
}

-- R15 -> R6 (fallback quando o boneco nao tem RightFoot/RightHand)
UI.EmoteInject.LIMB_ALIASES = {
    RightFoot = { "RightFoot", "Right Leg" },
    RightHand = { "RightHand", "Right Arm" },
    HumanoidRootPart = { "HumanoidRootPart" },
}

-- resolve o caminho a partir de ReplicatedStorage, passo a passo (pcall). Retorna o template (sem clonar) ou nil. Falha sempre vai pro warn.
UI.EmoteInject.getProp = function(id)
    local path = UI.EmoteInject.EMOTE_PROPS[id]
    if type(path) ~= "string" or path == "" then return nil end
    local node = ReplicatedStorage
    local walked = "RepStorage"
    for step in path:gmatch("[^%.]+") do
        local ok, child = pcall(function()
            return node:FindFirstChild(step)
        end)
        if not ok then
            warn("[NodtHub] getProp FAIL [" .. tostring(id) .. "] erro em '" .. step .. "' (percorrido: " .. walked .. ")", child)
            return nil
        end
        if not child then
            warn("[NodtHub] getProp FAIL [" .. tostring(id) .. "] parou em '" .. step .. "' (percorrido: " .. walked .. ")")
            return nil
        end
        node = child
        walked = walked .. "." .. step
    end
    return node
end

-- destroi o objeto atual (e solta o listener do Stopped)
UI.EmoteInject.clearProp = function()
    local Inj = UI.EmoteInject
    if Inj.propCon then
        pcall(function()
            Inj.propCon:Disconnect()
        end)
        Inj.propCon = nil
    end
    local prop = Inj.prop
    Inj.prop = nil
    if prop then
        pcall(function()
            prop:Destroy()
        end)
    end
end

-- clona o objeto do emote e solda no personagem. Retorna o clone ou nil (emote sem objeto / falha).
UI.EmoteInject.attachProp = function(id, name)
    local Inj = UI.EmoteInject
    local tag = "[NodtHub] attachProp: "
    local sid = tostring(id)
    local hasPath = type(Inj.EMOTE_PROPS[id]) == "string" and Inj.EMOTE_PROPS[id] ~= ""
    if not hasPath then return nil end -- sem objeto: comportamento atual
    local template = Inj.getProp(id) -- ja faz warn com o passo exato que quebrou
    if not template then
        Library:Notify("Prop not found in ReplicatedStorage: " .. tostring(name))
        return nil
    end

    local char = LocalPlayer.Character
    if not (char and char:IsDescendantOf(workspace)) then
        warn(tag .. "personagem ausente ou fora do workspace [" .. sid .. "]")
        return nil
    end

    local cloned, prop = pcall(function()
        return template:Clone()
    end)
    if not cloned or not prop then
        warn(tag .. "Clone falhou [" .. sid .. "]", prop)
        Library:Notify("Prop could not be cloned: " .. tostring(name))
        return nil
    end

    -- sem scripts rodando dentro do clone
    for _, d in ipairs(prop:GetDescendants()) do
        if d:IsA("LuaSourceContainer") then
            local destroyed, destroyErr = pcall(function()
                d:Destroy()
            end)
            if not destroyed then
                warn(tag .. "nao destruiu script do clone [" .. sid .. "] " .. d.Name, destroyErr)
            end
        end
    end

    local parts = {}
    if prop:IsA("BasePart") then table.insert(parts, prop) end
    for _, d in ipairs(prop:GetDescendants()) do
        if d:IsA("BasePart") then table.insert(parts, d) end
    end
    if #parts == 0 then
        prop:Destroy()
        warn(tag .. "template sem BasePart [" .. sid .. "] " .. Inj.EMOTE_PROPS[id])
        Library:Notify("Prop has no parts: " .. tostring(name))
        return nil
    end

    -- peca raiz: a propria peca, PrimaryPart do Model, ou a maior peca
    local root
    if prop:IsA("BasePart") then
        root = prop
    elseif prop:IsA("Model") and prop.PrimaryPart then
        root = prop.PrimaryPart
    else
        local best = -1
        for _, p in ipairs(parts) do
            local volume = p.Size.X * p.Size.Y * p.Size.Z
            if volume > best then
                best = volume
                root = p
            end
        end
    end

    -- alvo do weld (com fallback R6 e depois HumanoidRootPart)
    local want = Inj.PROP_ATTACH[id] or "HumanoidRootPart"
    local target
    for _, limb in ipairs(Inj.LIMB_ALIASES[want] or { want }) do
        target = char:FindFirstChild(limb)
        if target and target:IsA("BasePart") then break end
        target = nil
    end
    if not target then
        target = char:FindFirstChild("HumanoidRootPart")
    end
    if not (target and target:IsDescendantOf(workspace)) then
        warn(tag .. "alvo do weld ausente ou fora do workspace [" .. sid .. "] queria '" .. tostring(want) .. "'")
        prop:Destroy()
        return nil
    end

    -- objeto so local: sem colisao, sem peso, sem ancora
    for _, p in ipairs(parts) do
        p.Anchored = false
        p.CanCollide = false
        p.CanTouch = false
        p.CanQuery = false
        p.Massless = true
    end

    -- posiciona ANTES de soldar (WeldConstraint grava o offset no momento da criacao)
    local offset = Inj.PROP_OFFSETS[id] or Inj.PROP_DEFAULT_OFFSET
    local placement = target.CFrame * offset
    if prop:IsA("Model") then
        prop:PivotTo(placement)
    else
        prop.CFrame = placement
    end

    -- parenta no personagem ANTES de criar qualquer weld (morre junto com o personagem)
    prop.Parent = char

    -- pecas internas sem nenhuma junta: soldadas na raiz (ja com o prop no personagem)
    local jointed = {}
    for _, d in ipairs(prop:GetDescendants()) do
        if d:IsA("JointInstance") or d:IsA("WeldConstraint") then
            if d.Part0 then jointed[d.Part0] = true end
            if d.Part1 then jointed[d.Part1] = true end
        end
    end
    for _, p in ipairs(parts) do
        if p ~= root and not jointed[p] then
            local inner = Instance.new("WeldConstraint")
            inner.Name = MARK
            inner.Part0 = root
            inner.Part1 = p
            inner.Parent = root
        end
    end

    local weld = Instance.new("WeldConstraint")
    weld.Name = MARK
    weld.Part0 = target
    weld.Part1 = root
    weld.Parent = root

    Inj.prop = prop
    print("[NodtHub] prop OK [" .. sid .. "] soldado em " .. target.Name)

    -- aviso (warn) se o weld nao segurou: objeto longe / fora do workspace
    task.delay(0.4, function()
        if Inj.prop ~= prop then return end
        local hrp = char:FindFirstChild("HumanoidRootPart")
        local dist = hrp and (root.Position - hrp.Position).Magnitude or nil
        if not prop:IsDescendantOf(workspace) then
            warn(tag .. "prop fora do workspace apos 0.4s [" .. sid .. "] (" .. tostring(name) .. ")")
        elseif dist and dist > 15 then
            warn(tag .. string.format("prop longe do personagem: %.1f studs [%s] (%s) alvo=%s - ajuste PROP_OFFSETS / PROP_ATTACH", dist, sid, tostring(name), target.Name))
        end
    end)
    return prop
end

-- personagem renasceu: o prop do personagem antigo e orfao. Listener unico.
if not UI.EmoteInject.charCon then
    UI.EmoteInject.charCon = LocalPlayer.CharacterAdded:Connect(function()
        if UI.EmoteInject.prop then
            UI.EmoteInject.clearProp()
        end
    end)
    track(UI.EmoteInject.charCon)
end

-- diagnostico: roda no executor com _G.NODTHUB_PROPS_DIAG()
_G.NODTHUB_PROPS_DIAG = function()
    if type(UI) ~= "table" or type(UI.EmoteInject) ~= "table"
        or type(UI.EmoteInject.EMOTE_PROPS) ~= "table" then
        warn("[NodtHub] PROPS_DIAG: UI ainda nao carregado, tente de novo em 2s")
        return
    end
    local map = {
        "SkateboardEmote", "HakkaSkateboardEmote", "CopySkateboardEmote",
        "GuitarEmote", "FestivalGuitarEmote", "BroomEmote", "WandEmote",
        "ShieldBashEmote", "SingerEmote", "SadViolinEmote",
        "EatTurkeyEmote", "TurkeyRideEmote",
    }
    for _, id in ipairs(map) do
        local path = UI.EmoteInject.EMOTE_PROPS[id]
        if not path or path == "" then
            print("[PROPS] " .. id .. " → sem path")
        else
            local node, ok, fail = ReplicatedStorage, true, nil
            for step in path:gmatch("[^%.]+") do
                local c = node:FindFirstChild(step)
                if not c then ok, fail = false, step; break end
                node = c
            end
            print("[PROPS] " .. id .. " → " .. path .. " → " .. (ok and "OK" or ("FALHOU em '" .. tostring(fail) .. "'")))
        end
    end
end

-- personagem real: Animator:LoadAnimation(anim):Play() direto no personagem. O rig do Viewport (applyRig) e separado.
UI.EmoteInject.play = function(id, name)
    local Inj = UI.EmoteInject
    local tag = "[NodtHub] play: "
    local sid = tostring(id)
    local sname = tostring(name)

    local info = Inj.resolve(id)

    Inj.clearProp() -- clicou de novo: destroi o objeto do emote anterior
    if Inj.playing then
        local stopOk, stopErr = pcall(function()
            Inj.playing:Stop(0.1)
        end)
        if not stopOk then
            warn(tag .. "Stop falhou [" .. sid .. "]", stopErr)
        end
        Inj.playing = nil
    end

    local animId = (info and info.anim) or Inj.animId(id)
    if not animId then
        warn(tag .. "sem animId [" .. sid .. "]")
        Library:Notify("[NodtHub] No animation id for emote: " .. sname)
        return
    end

    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local animator = (hum and hum:FindFirstChildOfClass("Animator"))
        or (char and char:FindFirstChildWhichIsA("Animator", true))
    if not animator then
        warn(tag .. "sem Animator no personagem [" .. sid .. "]")
        Library:Notify("Character animator not found: " .. sname)
        return
    end

    local prop = Inj.attachProp(id, name) -- objeto (se o emote tiver) antes da animacao

    local anim = Instance.new("Animation")
    anim.AnimationId = animId
    local loaded, trackObj = pcall(function()
        return animator:LoadAnimation(anim)
    end)
    if not loaded or not trackObj then
        warn(tag .. "LoadAnimation falhou [" .. sid .. "] animId=" .. tostring(animId), trackObj)
        Library:Notify("[NodtHub] Could not load animation for emote: " .. sname .. " (animId=" .. tostring(animId) .. ")")
        if prop then Inj.clearProp() end
        return
    end

    trackObj.Priority = Enum.AnimationPriority.Action4
    trackObj.Looped = false
    local playOk, playErr = pcall(function()
        trackObj:Play()
    end)
    if not playOk then
        warn(tag .. "Play falhou [" .. sid .. "]", playErr)
        Library:Notify("Could not play emote: " .. sname)
        if prop then Inj.clearProp() end
        return
    end
    Inj.playing = trackObj

    if prop then
        Inj.propCon = trackObj.Stopped:Connect(function()
            if Inj.prop == prop then
                Inj.clearProp()
            end
        end)
    end

    task.delay(0.6, function()
        if Inj.playing ~= trackObj then return end
        if trackObj.Length == 0 then
            warn(tag .. "track.Length=0 [" .. sid .. "]")
            Library:Notify("Emote animation did not load (" .. sname .. ")")
            if prop and Inj.prop == prop then
                Inj.clearProp()
            end
        end
    end)
end

-- acha no botao: Animation + Animator + Humanoid do RigTemplate (boneco 3D do ViewportFrame)
UI.EmoteInject.findRig = function(btn)
    local rig = btn:FindFirstChild("RigTemplate", true)
    if not rig then
        local vp = btn:FindFirstChildWhichIsA("ViewportFrame", true)
        local root = vp and (vp:FindFirstChildOfClass("WorldModel") or vp)
        rig = root and root:FindFirstChildWhichIsA("Model", true)
    end
    local item = btn:FindFirstChild("ItemDisplay")
    local anim = (rig and rig:FindFirstChildWhichIsA("Animation", true))
        or (item and item:FindFirstChildWhichIsA("Animation", true))
    local animator = rig and rig:FindFirstChildWhichIsA("Animator", true)
    local hum = rig and rig:FindFirstChildWhichIsA("Humanoid", true)
    return anim, animator, hum
end

-- troca o AnimationId do boneco e toca de novo. Retorna true, ou false + motivo (completo, tambem vai pro warn)
UI.EmoteInject.applyRig = function(state)
    local tag = "[NodtHub] applyRig: "
    local label = tostring(state.name) .. " [" .. tostring(state.id) .. "]"
    local animId = state.anim
    if not animId then return false, "no animation id, rig keeps the game animation" end
    local anim, animator, hum = UI.EmoteInject.findRig(state.button)
    if not (anim and animator) then return false, "rig not found yet (RigTemplate/Animation/Animator)" end
    if state.rigAnim ~= anim then
        if state.animCon then state.animCon:Disconnect() end
        state.rigAnim = anim
        state.rigOriginalId = anim.AnimationId
        state.animCon = anim:GetPropertyChangedSignal("AnimationId"):Connect(function()
            -- o jogo devolveu o id classico: reaplica o nosso (so se for diferente, sem loop)
            if state.anim and anim.AnimationId ~= state.anim and not state.rigPending then
                state.rigPending = true
                task.delay(0.1, function()
                    state.rigPending = false
                    UI.EmoteInject.applyRig(state)
                end)
            end
        end)
    end
    state.rigAnimator = animator
    anim.AnimationId = animId
    if state.rigTrack then
        local stopOk, stopErr = pcall(function()
            state.rigTrack:Stop(0)
        end)
        if not stopOk then
            warn(tag .. "rigTrack:Stop falhou " .. label, stopErr)
        end
        state.rigTrack = nil
    end
    -- para o que o jogo ja estava tocando no boneco (o AnimationId novo nao troca uma track ja carregada)
    local clearOk, clearErr = pcall(function()
        for _, playing in ipairs(animator:GetPlayingAnimationTracks()) do
            playing:Stop(0)
        end
    end)
    if not clearOk then
        warn(tag .. "GetPlayingAnimationTracks/Stop falhou " .. label, clearErr)
    end
    local loaded, trackObj = pcall(function()
        return animator:LoadAnimation(anim)
    end)
    local via = "Animator"
    if not loaded or not trackObj then
        local firstError = tostring(trackObj)
        local secondError = nil
        if hum then
            loaded, trackObj = pcall(function()
                return hum:LoadAnimation(anim)
            end)
            via = "Humanoid"
            if not loaded or not trackObj then
                secondError = tostring(trackObj)
            end
        end
        if not loaded or not trackObj then
            local reason = "rig LoadAnimation failed: Animator: " .. firstError
            if secondError then
                reason = reason .. " | Humanoid: " .. secondError
            end
            warn(tag .. reason .. " " .. label .. " animId=" .. tostring(animId))
            return false, reason
        end
    end
    trackObj.Looped = true
    local playOk, playErr = pcall(function()
        trackObj:Play()
    end)
    if not playOk then
        local reason = "rig Play failed via " .. via .. ": " .. tostring(playErr)
        warn(tag .. reason .. " " .. label)
        return false, reason
    end
    state.rigTrack = trackObj
    task.delay(0.6, function()
        local stillCurrent = state.rigTrack == trackObj
        local animStillMatches = state.rigAnim and state.rigAnim.AnimationId == animId
        if stillCurrent and animStillMatches and trackObj.Length == 0 then
            warn(tag .. "track.Length=0 via " .. via .. " " .. label)
            Library:Notify("Rig animation did not load via " .. via .. " (Animator shared/locked?): " .. tostring(state.name))
        end
    end)
    return true
end

UI.EmoteInject.restore = function()
    for _, state in pairs(UI.EmoteInject.slots) do
        pcall(function()
            state.anim = nil
            if state.click then state.click:Disconnect() end
            if state.addCon then state.addCon:Disconnect() end
            if state.animCon then state.animCon:Disconnect() end
            if state.nameCon then state.nameCon:Disconnect() end
            if state.nameLabel and state.nameOriginal ~= nil then
                state.nameLabel.Text = state.nameOriginal
            end
            if state.rigTrack then
                pcall(function()
                    state.rigTrack:Stop(0)
                end)
                state.rigTrack = nil
            end
            if state.rigAnim and state.rigOriginalId then
                state.rigAnim.AnimationId = state.rigOriginalId
                -- devolve a animacao original ao boneco
                pcall(function()
                    local originalTrack = state.rigAnimator:LoadAnimation(state.rigAnim)
                    originalTrack.Looped = true
                    originalTrack:Play()
                end)
            end
            for _, con in ipairs(state.disabled) do
                pcall(function()
                    con:Enable()
                end)
            end
        end)
    end
    UI.EmoteInject.slots = {}
    UI.EmoteInject.clearProp()
    pcall(function()
        if UI.EmoteInject.playing then UI.EmoteInject.playing:Stop(0) end
    end)
end

-- retorna true (ok) ou true + aviso (nome trocado, mas o boneco nao); false se nao achou o botao
UI.EmoteInject.place = function(wheel, slot, id, name, info)
    local btn = wheel:FindFirstChild("WheelButton_" .. slot)
    if not btn then return false end
    local state = UI.EmoteInject.slots[slot]
    if not state then
        state = { button = btn, disabled = {} }
        -- limpa label sobreposto de versoes antigas (TwinEmoteLabel) que ficou no botao
        local staleFound = false
        for _, d in ipairs(btn:GetDescendants()) do
            if d.Name == "TwinEmoteLabel" then
                staleFound = true
                pcall(function()
                    d:Destroy()
                end)
            end
        end
        -- desliga os handlers do jogo nesse botao (so se o executor tem getconnections)
        if type(getconnections) == "function" then
            for _, signalName in ipairs({ "MouseButton1Click", "Activated" }) do
                local listed, cons = pcall(getconnections, btn[signalName])
                if listed and type(cons) == "table" then
                    for _, con in ipairs(cons) do
                        pcall(function()
                            if con.Enabled ~= false then
                                con:Disable()
                                table.insert(state.disabled, con)
                            end
                        end)
                    end
                end
            end
        end
        state.click = btn.MouseButton1Click:Connect(function()
            local Inj = UI.EmoteInject
            local clickId, clickName = state.id, state.name
            print("[NodtHub] click slot=" .. tostring(slot) .. " id=" .. tostring(clickId))

            -- debounce por slot: busy + cooldown curto (cobre play que nao faz yield)
            local now = os.clock()
            if state.busy or (state.lastClick and now - state.lastClick < 0.25) then
                print("[NodtHub] click ignorado (debounce) slot=" .. tostring(slot))
                return
            end
            state.busy = true
            state.lastClick = now

            -- deadman: se o play travar e o busy nao voltar, libera em 5s
            state.clickToken = (state.clickToken or 0) + 1
            local myToken = state.clickToken
            task.delay(5, function()
                if state.busy and state.clickToken == myToken then
                    warn("[NodtHub] click: deadman liberou busy do slot=" .. tostring(slot))
                    state.busy = false
                end
            end)

            -- 1) fecha a roda ANTES de tudo, sincrono (Static.EmoteWheel.Visible = false)
            local wheelGui = Inj.wheel()
            if wheelGui then
                local closed, closeErr = pcall(function()
                    wheelGui.Visible = false
                end)
                if not closed then
                    warn("[NodtHub] click: falha ao fechar roda slot=" .. tostring(slot), closeErr)
                end
            else
                warn("[NodtHub] click: roda nao encontrada slot=" .. tostring(slot))
            end

            -- 2) play fora do handler (yield de LoadAnimation/attachProp nao trava nada)
            task.spawn(function()
                local ok, err = pcall(Inj.play, clickId, clickName)
                if not ok then
                    warn("[NodtHub] click: play lancou erro slot=" .. tostring(slot) .. " id=" .. tostring(clickId), err)
                end
                state.busy = false -- "finally": roda com ou sem erro
                print("[NodtHub] click done slot=" .. tostring(slot))
            end)
        end)

        -- nome: reaproveita o DisplayName do jogo (sem criar label novo); guarda o texto original
        local nameLabel = btn:FindFirstChild("DisplayName")
        if not (nameLabel and nameLabel:IsA("TextLabel")) then
            nameLabel = btn:FindFirstChildWhichIsA("TextLabel", true)
        end
        if nameLabel then
            state.nameLabel = nameLabel
            state.nameOriginal = nameLabel.Text
            if staleFound and not nameLabel.Visible then
                nameLabel.Visible = true -- versao antiga tinha escondido o nome do jogo
            end
            state.nameCon = nameLabel:GetPropertyChangedSignal("Text"):Connect(function()
                -- o jogo reescreveu o nome classico: poe o nosso de volta (so se diferente, sem loop)
                if state.name and nameLabel.Text ~= state.name then
                    nameLabel.Text = state.name
                end
            end)
        end

        -- se o jogo recriar o boneco (RigTemplate), reaplica a animacao (debounce; ignora enquanto o rig atual vale)
        state.addCon = btn.DescendantAdded:Connect(function()
            if state.rigAnim and state.rigAnim:IsDescendantOf(btn) then return end
            if state.rigPending then return end
            state.rigPending = true
            task.delay(0.2, function()
                state.rigPending = false
                if UI.EmoteInject.slots[slot] == state then
                    UI.EmoteInject.applyRig(state)
                end
            end)
        end)

        UI.EmoteInject.slots[slot] = state
        if not UI.EmoteInject.tracked then
            UI.EmoteInject.tracked = true
            track({ Disconnect = function() UI.EmoteInject.restore() end })
        end
    end
    state.id = id
    state.name = name
    state.anim = UI.EmoteInject.animId(id) or (info and info.anim) or nil
    if state.nameLabel then
        state.nameLabel.Text = name
    end
    local applied, reason = UI.EmoteInject.applyRig(state)
    if not state.nameLabel then
        return true, "DisplayName not found" .. (applied and "" or (", " .. tostring(reason)))
    end
    if not applied then
        return true, reason
    end
    return true
end

UI.EmoteGroup:AddButton({
    Text = "Apply Emote",
    Func = function()
        local name = UI.EmoteSelected
        local id = UI.EmoteIdByName[name]
        if not id then
            Library:Notify("Select an emote first")
            return
        end
        task.spawn(function()
            local Inj = UI.EmoteInject
            for slot, state in pairs(Inj.slots) do
                if state.id == id then
                    Library:Notify("Emote already injected (slot " .. slot .. "): " .. name)
                    return
                end
            end

            -- 1) Equip real (so pega se o jogador tem o emote; hook do Vault deixa passar)
            local inventory, emotes = Inj.equipped()
            if inventory and not table.find(emotes, id) then
                local InventoryService = getPackageService("InventoryService")
                local remote = InventoryService and getServiceChild(InventoryService, "RF", "Equip")
                if remote then
                    pcall(function()
                        remote:InvokeServer(id)
                    end)
                    task.wait(0.4)
                    local _, after = Inj.equipped()
                    if after and table.find(after, id) then
                        Library:Notify("Emote equipped (remote Equip): " .. name)
                        return
                    end
                end
            end

            -- 2) injecao client-side na roda
            local wheel = Inj.wheel()
            if not wheel then
                Library:Notify("EmoteWheel not found (Static.EmoteWheel)")
                return
            end
            local _, current = Inj.equipped()
            current = current or {}
            local slot = nil
            for i = 1, 4 do
                if not Inj.slots[i] and (current[i] == nil or current[i] == "") then
                    slot = i
                    break
                end
            end
            if not slot then
                slot = Inj.cursor
                Inj.cursor = slot % 4 + 1
            end
            local info = Inj.resolve(id)
            local placed, status = Inj.place(wheel, slot, id, name, info)
            if not placed then
                Library:Notify("WheelButton_" .. slot .. " not found")
                return
            end
            if status then
                Library:Notify("Injected slot " .. slot .. " (" .. status .. "): " .. name)
            else
                Library:Notify("Emote injected (slot " .. slot .. "): " .. name)
            end
        end)
    end,
})

-- JERSEY UI (FIXED - AUTO APPLY ENABLED BY DEFAULT)
UI.JerseyGroup = Tabs.Visuals:AddRightGroupbox("Jersey Changer", "shirt")

UI.JerseyGroup:AddToggle("autoapplyjersey", {
    Text = "Auto Apply Jersey",
    Tooltip = "Automatically apply selected jersey",
    Hidden = true,
    Default = false,
    Callback = function(Value)
        State.autoApplyJersey = Value
        applyJersey(State.selectedJersey)
    end,
})

UI.JerseyGroup:AddDropdown("jerseyselect", {
    Values = #jerseyList > 0 and jerseyList or {"No Jerseys Found"},
    Default = #jerseyList > 0 and jerseyList[1] or "No Jerseys Found",
    Text = "Select Jersey",
    Callback = function(Value)
        State.selectedJersey = Value
        pickedTeam = nil
        if State.autoApplyJersey then
            applyJersey(State.selectedJersey)
        end
    end,
})

UI.JerseyGroup:AddButton({
    Text = "Apply Jersey",
    Func = VisualApply.jersey,
})

UI.MiscStyleGroup = Tabs.Misc:AddLeftGroupbox("Auto Style Spin", "refresh-cw")

UI.MiscStyleGroup:AddToggle("autostyle", {
    Text = "Auto Style Spin",
    Tooltip = "Auto spin until target style obtained",
    Default = false,
    Callback = function(Value)
        State.autoSpin = Value
        if Value then
            startAutoSpin()
        end
    end,
})

UI.MiscStyleGroup:AddDropdown("spintype", {
    Values = {"Normal", "Lucky"},
    Default = "Normal",
    Text = "Spin Type",
    Callback = function(Value)
        State.spinType = Value
    end,
})

UI.MiscStyleGroup:AddInput("targetstyle", {
    Default = "",
    Text = "Target Style (Type manually)",
    Placeholder = "Sanju",
    Callback = function(Value)
        desiredStyles = {Value}
    end,
})

UI.MiscStyleGroup:AddDropdown("stylelist", {
    Values = {
        "Ronin", "Hidari", "Jinko", "Timeskip Hinto", "Timeskip Kyamo",
        "Akuto", "Taichou", "Sanju", "Mikage", "Kazana", "Timeskip Okazu",
        "Kisuki", "Bakuri", "Kyamo", "Okazu", "Hirakumi",
        "Kozai", "Azmei", "Uchikai", "Yokai", "Yogan",
        "Sazuroku", "Kyoshin", "Yomosuke", "Oyatsu", "Tsuchiro",
        "Imaezi", "Tonkura", "Ninyoku", "Hinto", "Hakochi", "Yakisukai", "Sagumi", "Koshoti"
    },
    Default = "Ronin",
    Text = "Style List (Select to auto-fill)",
    Callback = function(Value)
        Options.targetstyle:SetValue(Value)
        desiredStyles = {Value}
    end,
})

UI.MiscAbilityGroup = Tabs.Misc:AddRightGroupbox("Auto Ability Spin", "zap")

UI.MiscAbilityGroup:AddToggle("autoabilityspin", {
    Text = "Auto Ability Spin",
    Tooltip = "Auto spin until target ability obtained",
    Default = false,
    Callback = function(Value)
        State.autoAbilitySpin = Value
        if Value then
            startAutoAbilitySpin()
        end
    end,
})

UI.MiscAbilityGroup:AddDropdown("abilityspintype", {
    Values = {"Normal", "Lucky"},
    Default = "Normal",
    Text = "Ability Spin Type",
    Callback = function(Value)
        State.abilitySpinType = Value
    end,
})

UI.MiscAbilityGroup:AddInput("targetability", {
    Default = "",
    Text = "Target Ability (Type manually)",
    Placeholder = "Shield Breaker",
    Callback = function(Value)
        desiredAbilities = {Value}
    end,
})

UI.MiscAbilityGroup:AddDropdown("abilitylist", {
    Values = {
        "Shield Breaker", "Magnetic Pull", "Lead Feet", "Extra Touch", "Godly",
        "Redirection Jump", "Curve Spike", "Divine Strength", "Legendary",
        "Steel Block", "Zero Gravity Set", "Rare", "Boom Jump", "Moonball",
        "Common", "Super Sprint", "Team Spirit", "Rolling Thunder"
    },
    Default = "Shield Breaker",
    Text = "Ability List (Select to auto-fill)",
    Callback = function(Value)
        Options.targetability:SetValue(Value)
        desiredAbilities = {Value}
    end,
})

UI.MiscShopGroup = Tabs.Misc:AddLeftGroupbox("Shop", "shopping-bag")

UI.MiscShopGroup:AddButton({
    Text = "Buy Emote",
    Func = function()
        local PackService = getPackageService("PackService")
        local Open = PackService and getServiceChild(PackService, "RF", "Open")
        if not Open then
            warn("[NodtHub] service not found")
            return
        end
        Open:InvokeServer("Emote1")
    end,
})

UI.MiscShopGroup:AddButton({
    Text = "Buy Effect",
    Func = function()
        local PackService = getPackageService("PackService")
        local Open = PackService and getServiceChild(PackService, "RF", "Open")
        if not Open then
            warn("[NodtHub] service not found")
            return
        end
        Open:InvokeServer("ScoreEffect1")
    end,
})

UI.MiscShopGroup:AddButton({
    Text = "Buy Extreme Ball",
    Func = function()
        local PackService = getPackageService("PackService")
        local Open = PackService and getServiceChild(PackService, "RF", "Open")
        if not Open then
            warn("[NodtHub] service not found")
            return
        end
        Open:InvokeServer("Extreme")
    end,
})

UI.MiscShopGroup:AddButton({
    Text = "Buy Medium Ball",
    Func = function()
        local PackService = getPackageService("PackService")
        local Open = PackService and getServiceChild(PackService, "RF", "Open")
        if not Open then
            warn("[NodtHub] service not found")
            return
        end
        Open:InvokeServer("Medium")
    end,
})

UI.MiscShopGroup:AddButton({
    Text = "Buy Basic Ball",
    Func = function()
        local PackService = getPackageService("PackService")
        local Open = PackService and getServiceChild(PackService, "RF", "Open")
        if not Open then
            warn("[NodtHub] service not found")
            return
        end
        Open:InvokeServer("Basic")
    end,
})

UI.MiscClaimGroup = Tabs.Misc:AddRightGroupbox("Claim Rewards", "gift")

UI.MiscClaimGroup:AddButton({
    Text = "Claim Level Rewards",
    Func = function()
        local LevelService = getPackageService("LevelService")
        local ClaimLevelRewards = LevelService and getServiceChild(LevelService, "RF", "ClaimLevelRewards")
        if not ClaimLevelRewards then
            warn("[NodtHub] service not found")
            return
        end
        ClaimLevelRewards:InvokeServer()
    end,
})

UI.MiscClaimGroup:AddButton({
    Text = "Claim Quest Rewards",
    Func = function()
        local QuestService = getPackageService("QuestService")
        local ClaimAll = QuestService and getServiceChild(QuestService, "RF", "ClaimAll")
        if not ClaimAll then
            warn("[NodtHub] service not found")
            return
        end
        ClaimAll:InvokeServer(true)
    end,
})

UI.MiscClaimGroup:AddButton({
    Text = "Redeem All Codes",
    Func = function()
        local function fetchNewCodes()
            local success, data = pcall(function()
                return httpGet("https://beebom.com/haikyuu-legends-codes/")
            end)
            if not success or not data then
                return {}
            end
            local newCodes = {}
            local processed = {}
            for line in string.gmatch(data, "[^\n]+") do
                if string.find(line, "(NEW)") then
                    local code = string.match(line, "(%u+[%u%d_]+)")
                    if code and not processed[code] then
                        processed[code] = true
                        table.insert(newCodes, code)
                    end
                end
                if #newCodes >= 3 then
                    break
                end
            end
            return newCodes
        end
        local newCodes = fetchNewCodes()
        if #newCodes > 0 then
            for i, code in pairs(newCodes) do
                local CodeService = getPackageService("CodeService")
                local Redeem = CodeService and getServiceChild(CodeService, "RF", "Redeem")
                if not Redeem then
                    warn("[NodtHub] service not found")
                    return
                end
                Redeem:InvokeServer(code)
                task.wait(0.01)
            end
        end
    end,
})

UI.GameJoinGroup = Tabs.GameJoin:AddLeftGroupbox("Game Modes", "gamepad-2")

UI.GameJoinGroup:AddButton({
    Text = "Chaos Mode",
    Func = function()
        local PartyService = getPackageService("PartyService")
        local RequestTeleport = PartyService and getServiceChild(PartyService, "RF", "RequestTeleport")
        if not RequestTeleport then
            warn("[NodtHub] service not found")
            return
        end
        RequestTeleport:InvokeServer("ChaosMode")
    end,
})

UI.GameJoinGroup:AddButton({
    Text = "1v1 Mini Map",
    Func = function()
        local PartyService = getPackageService("PartyService")
        local RequestTeleport = PartyService and getServiceChild(PartyService, "RF", "RequestTeleport")
        if not RequestTeleport then
            warn("[NodtHub] service not found")
            return
        end
        RequestTeleport:InvokeServer("OnesMini")
    end,
})

UI.GameJoinGroup:AddButton({
    Text = "2v2 Ranked",
    Func = function()
        local PartyService = getPackageService("PartyService")
        local RequestTeleport = PartyService and getServiceChild(PartyService, "RF", "RequestTeleport")
        if not RequestTeleport then
            warn("[NodtHub] service not found")
            return
        end
        RequestTeleport:InvokeServer("Twos")
    end,
})

UI.GameJoinGroup:AddButton({
    Text = "3v3 Ranked",
    Func = function()
        local PartyService = getPackageService("PartyService")
        local RequestTeleport = PartyService and getServiceChild(PartyService, "RF", "RequestTeleport")
        if not RequestTeleport then
            warn("[NodtHub] service not found")
            return
        end
        RequestTeleport:InvokeServer("Threes")
    end,
})

UI.GameJoinGroup:AddButton({
    Text = "4v4 Ranked",
    Func = function()
        local PartyService = getPackageService("PartyService")
        local RequestTeleport = PartyService and getServiceChild(PartyService, "RF", "RequestTeleport")
        if not RequestTeleport then
            warn("[NodtHub] service not found")
            return
        end
        RequestTeleport:InvokeServer("Fours")
    end,
})

UI.GameJoinGroup:AddButton({
    Text = "6v6 Ranked",
    Func = function()
        local PartyService = getPackageService("PartyService")
        local RequestTeleport = PartyService and getServiceChild(PartyService, "RF", "RequestTeleport")
        if not RequestTeleport then
            warn("[NodtHub] service not found")
            return
        end
        RequestTeleport:InvokeServer("Sixes")
    end,
})

UI.GameJoinGroup:AddButton({
    Text = "Training",
    Func = function()
        local PartyService = getPackageService("PartyService")
        local RequestTeleport = PartyService and getServiceChild(PartyService, "RF", "RequestTeleport")
        if not RequestTeleport then
            warn("[NodtHub] service not found")
            return
        end
        RequestTeleport:InvokeServer("Training")
    end,
})

local MenuGroup = Tabs["UI Settings"]:AddLeftGroupbox("Menu", "wrench")

MenuGroup:AddToggle("KeybindMenuOpen", {
    Default = Library.KeybindFrame.Visible,
    Text = "Open Keybind Menu",
    Callback = function(value)
        Library.KeybindFrame.Visible = value
    end,
})

MenuGroup:AddDropdown("NotificationSide", {
    Values = { "Left", "Right" },
    Default = "Right",
    Text = "Notification Side",
    Callback = function(Value)
        Library:SetNotifySide(Value)
    end,
})

MenuGroup:AddDropdown("DPIDropdown", {
    Values = { "50%", "75%", "100%", "125%", "150%", "175%", "200%" },
    Default = "100%",
    Text = "DPI Scale",
    Callback = function(Value)
        Value = Value:gsub("%%", "")
        local DPI = tonumber(Value)
        Library:SetDPIScale(DPI)
    end,
})

MenuGroup:AddSlider("UICornerSlider", {
    Text = "Corner Radius",
    Default = Library.CornerRadius,
    Min = 0,
    Max = 20,
    Rounding = 0,
    Callback = function(value)
        Window:SetCornerRadius(value)
    end
})

MenuGroup:AddDivider()
MenuGroup:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", { Default = "RightShift", NoUI = true, Text = "Menu keybind" })

Library.CleanupExtras = function()
    pcall(removeHitboxes)
    pcall(UI.EmoteInject.clearProp)
    if leadFeetLink then pcall(function() leadFeetLink:Disconnect() end) end
    -- autoApplyBallSkin off para o sweep so remover as skins (sem reaplicar).
    State.autoApplyBallSkin = false
    if sweepBusy == false then pcall(task.spawn, safeSweep) end
end

MenuGroup:AddButton("Unload", function()
    Library:Unload()
end)

Library.ToggleKeybind = Options.MenuKeybind

Library:SetConfigFolder("NODT")
Library:BuildConfigSection(Tabs["UI Settings"])
Library:LoadAutoloadConfig()
-- Botão Flutuante NODT
task.spawn(function()
    local WinShell = Library.Window.Instance
    local WinRoot = Library.Root
    local TweenService = game:GetService("TweenService")

    for _, desc in ipairs(WinShell:GetDescendants()) do
        if desc:IsA("TextButton") and desc.Text == "-" then
            desc.Visible = false
        end
    end

    local FloatBtn = Instance.new("TextButton")
    FloatBtn.Name = "NODTHub_FloatBtn"
    FloatBtn.Size = UDim2.fromOffset(56, 56)
    FloatBtn.Position = UDim2.new(0, 20, 0.5, -28)
    FloatBtn.BackgroundTransparency = 1
    FloatBtn.Text = ""
    FloatBtn.AutoButtonColor = false
    FloatBtn.BorderSizePixel = 0
    FloatBtn.Visible = false
    FloatBtn.ZIndex = 999
    FloatBtn.Parent = WinRoot

    -- Bolinha "orb" Ember Grid: nucleo escuro quadrado-arredondado com anel segmentado giratorio (brasa -> ambar -> menta),
    -- faisca menta em orbita, ondas de luz, scanner interno e a marca twin. Mesmo tema da janela e da caixa de key.
    -- As animacoes em loop so rodam enquanto a bolinha esta visivel (economiza processamento com a janela aberta).
    do
        local theme = Library.Theme
        local ember, amber, mint = theme.Accent, theme.Accent2, theme.Accent3

        local function make(class, props, parent)
            local inst = Instance.new(class)
            for key, value in pairs(props) do
                inst[key] = value
            end
            inst.Parent = parent
            return inst
        end

        local loops = {}
        local function loop(inst, info, goal)
            local tw = TweenService:Create(inst, info, goal)
            table.insert(loops, tw)
            return tw
        end

        -- Anel segmentado: 4 tracos duros (visivel/invisivel alternando) que giram em volta do nucleo.
        local ringColor = ColorSequence.new({
            ColorSequenceKeypoint.new(0, ember),
            ColorSequenceKeypoint.new(0.5, amber),
            ColorSequenceKeypoint.new(1, mint),
        })
        local dashKeys = {}
        do
            local total = 8
            for i = 0, total - 1 do
                local a = (i % 2 == 0) and 0 or 1
                dashKeys[#dashKeys + 1] = NumberSequenceKeypoint.new(i == 0 and 0 or (i / total + 0.001), a)
                dashKeys[#dashKeys + 1] = NumberSequenceKeypoint.new(i == total - 1 and 1 or ((i + 1) / total), a)
            end
        end
        local ringAlpha = NumberSequence.new(dashKeys)

        -- Brilho fixo atras do nucleo.
        local aura = make("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromScale(1.45, 1.45),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BackgroundTransparency = 0.84,
            BorderSizePixel = 0,
            ZIndex = 1,
        }, FloatBtn)
        make("UICorner", { CornerRadius = UDim.new(0, 20) }, aura)
        make("UIGradient", { Rotation = 45, Color = ColorSequence.new(ember, amber) }, aura)
        loop(aura, TweenInfo.new(2.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
            BackgroundTransparency = 0.93,
        })

        -- Duas ondas de luz (quadrados que expandem e somem), defasadas.
        for index = 1, 2 do
            local wave = make("Frame", {
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.fromScale(0.5, 0.5),
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                ZIndex = 1,
            }, FloatBtn)
            make("UICorner", { CornerRadius = UDim.new(0, 14) }, wave)
            local waveStroke = make("UIStroke", {
                ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
                Color = index == 1 and ember or mint,
                Thickness = 1.6,
                Transparency = 0.35,
            }, wave)
            local waveScale = make("UIScale", { Scale = 1 }, wave)
            local waveInfo = TweenInfo.new(2.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1, false, index == 1 and 0 or 1.2)
            loop(waveScale, waveInfo, { Scale = 1.7 })
            loop(waveStroke, waveInfo, { Transparency = 1 })
        end

        local core = make("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.new(1, -6, 1, -6),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
            ClipsDescendants = true,
            ZIndex = 2,
        }, FloatBtn)
        make("UICorner", { CornerRadius = UDim.new(0, 14) }, core)
        make("UIGradient", {
            Rotation = 135,
            Color = ColorSequence.new(Color3.fromRGB(26, 38, 46), Color3.fromRGB(7, 10, 13)),
        }, core)
        local hoverScale = make("UIScale", { Scale = 1 }, core)

        -- Anel segmentado girando em volta do nucleo.
        local ring = make("UIStroke", {
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
            Color = Color3.new(1, 1, 1),
            Thickness = 2.4,
        }, core)
        local ringGrad = make("UIGradient", { Color = ringColor, Transparency = ringAlpha }, ring)
        loop(ringGrad, TweenInfo.new(3.4, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1), { Rotation = 360 })

        -- Contorno fixo fininho por baixo do anel (a base do "quadro" continua visivel entre os tracos).
        make("UIStroke", {
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
            Color = theme.Line,
            Thickness = 1,
            Transparency = 0.2,
        }, core)

        -- Scanner: linha menta que desce pelo nucleo.
        local scan = make("Frame", {
            Position = UDim2.new(0, 0, 0, 0),
            Size = UDim2.new(1, 0, 0, 1),
            BackgroundColor3 = mint,
            BackgroundTransparency = 0.8,
            BorderSizePixel = 0,
            ZIndex = 3,
        }, core)
        loop(scan, TweenInfo.new(2.6, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1), {
            Position = UDim2.new(0, 0, 1, -1),
        })

        -- Etiqueta "hazard" (listras brasa/ink) no topo do nucleo.
        local hazardKeys = {}
        do
            local total = 6
            for i = 0, total - 1 do
                local c = (i % 2 == 0) and ember or Color3.fromRGB(7, 10, 13)
                hazardKeys[#hazardKeys + 1] = ColorSequenceKeypoint.new(i == 0 and 0 or (i / total + 0.001), c)
                hazardKeys[#hazardKeys + 1] = ColorSequenceKeypoint.new(i == total - 1 and 1 or ((i + 1) / total), c)
            end
        end
        local hazard = make("Frame", {
            AnchorPoint = Vector2.new(0.5, 0),
            Position = UDim2.new(0.5, 0, 0, 4),
            Size = UDim2.fromOffset(18, 3),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
            ZIndex = 4,
        }, core)
        make("UIGradient", { Rotation = 35, Color = ColorSequence.new(hazardKeys) }, hazard)

        -- Marca twin: duas esferas sobrepostas no centro do orb.
        local twin = make("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0.5, 0, 0.5, 2),
            Size = UDim2.fromOffset(30, 30),
            BackgroundTransparency = 1,
            ZIndex = 4,
        }, core)
        local ballD = 19
        local ballA = make("Frame", {
            Position = UDim2.fromOffset(1, 10),
            Size = UDim2.fromOffset(ballD, ballD),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
            ZIndex = 4,
        }, twin)
        make("UICorner", { CornerRadius = UDim.new(1, 0) }, ballA)
        make("UIGradient", { Rotation = 45, Color = ColorSequence.new(ember, amber) }, ballA)
        local ballB = make("Frame", {
            Position = UDim2.fromOffset(10, 1),
            Size = UDim2.fromOffset(ballD, ballD),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ZIndex = 5,
        }, twin)
        make("UICorner", { CornerRadius = UDim.new(1, 0) }, ballB)
        make("UIStroke", { Color = theme.Text, Thickness = 1.7, Transparency = 0 }, ballB)

        -- Faisca que orbita o anel (um quadro que gira, com um losango menta na borda).
        local orbit = make("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ZIndex = 6,
        }, FloatBtn)
        local spark = make("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0.5, 0, 0, 1),
            Size = UDim2.fromOffset(7, 7),
            Rotation = 45,
            BackgroundColor3 = mint,
            BorderSizePixel = 0,
            ZIndex = 6,
        }, orbit)
        make("UIStroke", { Color = theme.Shell, Thickness = 1.5, Transparency = 0 }, spark)
        loop(orbit, TweenInfo.new(2.8, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1), { Rotation = 360 })

        -- Quadradinho de "online" no canto.
        local dot = make("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.86, 0.86),
            Size = UDim2.fromOffset(9, 9),
            BackgroundColor3 = mint,
            BorderSizePixel = 0,
            ZIndex = 7,
        }, FloatBtn)
        make("UICorner", { CornerRadius = UDim.new(0, 2) }, dot)
        make("UIStroke", { Color = theme.Shell, Thickness = 2 }, dot)
        loop(dot, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
            BackgroundTransparency = 0.5,
        })

        -- Flutuacao suave (so o nucleo; o arrasto mexe no botao inteiro).
        loop(core, TweenInfo.new(1.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
            Position = UDim2.new(0.5, 0, 0.5, -3),
        })

        -- Hover (mouse): o nucleo cresce com um leve "pulo".
        FloatBtn.MouseEnter:Connect(function()
            TweenService:Create(hoverScale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.1 }):Play()
        end)
        FloatBtn.MouseLeave:Connect(function()
            TweenService:Create(hoverScale, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
        end)

        local function runLoops(on)
            for _, tw in ipairs(loops) do
                if on then
                    tw:Play()
                else
                    tw:Pause()
                end
            end
        end
        FloatBtn:GetPropertyChangedSignal("Visible"):Connect(function()
            runLoops(FloatBtn.Visible)
        end)
        runLoops(FloatBtn.Visible)
    end

    local pop = Instance.new("UIScale")
    pop.Scale = 1
    pop.Parent = FloatBtn

    WinShell:GetPropertyChangedSignal("Visible"):Connect(function()
        FloatBtn.Visible = not WinShell.Visible
        if FloatBtn.Visible then
            pop.Scale = 0.5
            TweenService:Create(pop, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
        end
    end)

    local dragging, dragStart, startPos, moved = false, nil, nil, false
    FloatBtn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            moved = false
            dragStart = input.Position
            startPos = FloatBtn.Position
            TweenService:Create(pop, TweenInfo.new(0.12, Enum.EasingStyle.Quad), { Scale = 0.92 }):Play()
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    TweenService:Create(pop, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
                end
            end)
        end
    end)

    FloatBtn.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            if delta.Magnitude > 6 then
                moved = true
            end
            FloatBtn.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)

    FloatBtn.MouseButton1Click:Connect(function()
        if moved then
            return
        end
        WinShell.Visible = true
        WinShell.Position = UDim2.fromScale(0.5, 0.5)
        local winSize = Library.WinSize or Vector2.new(1040, 520)
        WinShell.Size = UDim2.fromOffset(winSize.X, winSize.Y)
        if Library.Window.SetMinimized then
            Library.Window:SetMinimized(false)
        end
    end)
end)

-- Re-aplica os visuais ativos apos o respawn.
-- Guarda o ultimo Title aplicado (nao existe variavel "selectedTitle").
Vault.paintBase = Vault.paint
Vault.paint = function(kind, id, entry)
    if kind == "Title" then
        Vault.titleId = id
    end
    return Vault.paintBase(kind, id, entry)
end

track(LocalPlayer.CharacterAdded:Connect(function()
    Vault.respawnToken = (Vault.respawnToken or 0) + 1
    local token = Vault.respawnToken
    task.wait(1.5)
    -- Respawns seguidos: so o ultimo continua. Script descarregado: nao faz nada.
    if token ~= Vault.respawnToken or Library.Unloaded then return end

    for kind in pairs(Vault.want) do
        if kind == "ScoreEffect" then
            Vault.setSlot("ScoreEffect", State.selectedEffect)
        elseif kind == "Ball" then
            Vault.setSlot("Ball", State.selectedBallSkin)
            task.spawn(safeSweep)
        elseif kind == "PlayerCard" then
            Vault.setSlot("PlayerCard", State.selectedCard)
        elseif kind == "Title" and Vault.titleId then
            pcall(Vault.dress, Vault.titleId)
        end
    end

    -- Jersey: so se estava ativo (Auto Apply Jersey ou marcado no Vault).
    if State.autoApplyJersey or Vault.want.Jersey then
        Vault.setSlot("Jersey", State.selectedJersey)
    end
end))
