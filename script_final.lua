--[[
════════════════════════════════════════════════════════════════
  NODT HUB v1.0.0
════════════════════════════════════════════════════════════════

  Script de cliente para Roblox. Requer executor com suporte a:
    - getrawmetatable / setreadonly / getnamecallmethod (hooks)
    - firesignal (disparo de RemoteEvents do cliente)
    - HTTP request (auth + update check)
    - file API (writefile / readfile / listfiles) para cache de token e configs
    - queue_on_teleport (persistência entre servidores)

  ─── EXECUÇÃO ───
    1. Cole a URL raw do script no loader
    2. Primeira execução pede KEY (validada contra HWID)
    3. Se key válida -> token salvo em NODT/token.json
    4. Próximas execuções usam o token sem pedir key

  ─── FLUXO ───

    [1] loader carrega URL
         │
    [2] bootstrapCompatibility (Delta/Wave/Synapse)
         │
    [3] Library carrega (UI library, sem jogo)
         │
    [4] checkAuth (HWID + verify + token cache)
         │
    [5] hookNamecall instala __namecall central
         │
    [6] getKnitRoot resolve controllers
         │
    [7] Features registram hooks (hitbox, silent, redirect...)
         │
    [8] UI bindings chamam Core.ToggleX
         │
    [9] session.unload → unhook LIFO → Root:Destroy

  ─── ESTRUTURA ───
    [NET]       Helpers de rede (NET.pace, NET.callCritical, hooks de identity)
    [CORE]      Estado, eventos, fachada pública via Core.ToggleX
    [UI]        Library de UI (abaixo do Core, ordem invertida por design)
    [AUTH]      Key client (HWID, verify, token cache)
    [KNIT]      Resolver de controllers/remotes do jogo (via Packages._Index)
    [HOOKS]     Central __namecall registry (hookNamecall)
    [FEATURES]  Todas as features agrupadas por namespace (State.X, HitboxState, etc.)
    [UI BIND]   Bindings UI -> Core.ToggleX

  ─── VERSÃO ───
    1.0.0 — build pós 7 passadas de audit + 3 passadas de polish

  ─── API DO CORE (para quem for estender) ───
    Spike:       ToggleRedirectSpike, ToggleAutoCorner, ToggleSilentSpike,
                 ToggleSanjuTilt, ToggleMaxCharge, ToggleFakeSpike,
                 ToggleAutoCounter, ToggleAutoSetAim, ToggleAutoSpike,
                 ToggleSpikeTrajectory
    Hitbox:      ToggleHitbox, SetHitboxSize, SetHitboxColor, RemoveHitboxes
    Movement:    ToggleDesync, ToggleAutoBlock, ToggleAutoReceive, SetReceiveRange,
                 SetReceiveLead, ToggleKisukiDive, SetKisukiCharge, ToggleAkariDash,
                 ToggleLeadFeet, ToggleMaxServe, ToggleAirMovement, SetAirSpeed,
                 ToggleAutoShiftLock, ToggleCharacterLines, SetLineDistance
    Visuals:     ToggleLandingMarker (só API, UI pode remover), ToggleScoreEffect,
                 ApplyScoreEffect, ToggleCardProtect, ApplyPlayerCard, ApplyBall,
                 ApplyJersey, ToggleAutoApplyJersey, ToggleTitleChanger
    Character:   SetDiveSpeed, SetJumpPower, SetSpeed, ToggleProtect,
                 ToggleTshAnimation, ToggleHidariAnimation, ToggleKazanaBlue,
                 ToggleKazanaWhite, SelectJersey
    Performance: ToggleAntiLag, ToggleAutoReady, ToggleAntiAFK, ToggleAutoSave
    Misc:        ToggleJumpESP, ToggleAutoRejoin

  ─── EVENTOS DO CORE ───
    Core.On("Notify", fn)    -> ouvir notificações emitidas pelo Core
    Core.Emit("Notify", ...) -> emitir (a UI escuta e chama Library:Notify)

  ─── GLOBAIS ───
    _G.NODT.Core         → tabela Core (usado por: scripts externos, loader)
    _G.NODT.Session      → sessão atual (usado por: interno, scripts irmãos)
    _G.NODT.AuthPassed   → true se auth ok (usado por: interno, loader)
    _G.NODT.PlayerCard   → API pública do Player Card (usado por: extensões externas)
    _G.NODT.Lines        → API pública das linhas visuais (usado por: extensões externas)

  ─── UNLOAD ───
    Library:Unload()     -> teardown completo (hooks, connections, GUI, session)

  ─── ESTADO ───
    Limite de 200 locals do Luau forçou agrupar estado em tabelas:
      State, HitboxState, MovementState, VisualState, TrajectoryState,
      CardState, CardProtect, AntiLagState, ServiceCache, ButtonState,
      HookState, Vault, Landing, Kisuki, AutoCorner
    Cada tabela é declarada antes de qualquer função que a usa.

════════════════════════════════════════════════════════════════
]]
-- [NET] constantes hoisted e helpers de rede. Um unico local no escopo raiz (limite de 200 locals do Luau).
local NET = {
	K = {
		INVOKE = "InvokeServer",
		FIRE = "FireServer",
		KICK = "Kick",
		INTERACT = "Interact",
		DOMOVE = "DoMove",
		SPIKE = "Spike",
		SERVESPIKE = "ServeSpike",
		BLOCK = "Block",
		JUMPSET = "JumpSet",
	},
	INTERVAL = 0.08,
	slots = setmetatable({}, { __mode = "k" }),
	identity = nil,
	identityRetry = 0,
}

NET.resolveIds = function()
    NET._setId = NET._setId or setthreadidentity or set_thread_identity or setidentity
    NET._getId = NET._getId or getthreadidentity or get_thread_identity or getidentity
    if not NET.identity and NET._getId then
        NET.identityRetry = (NET.identityRetry or 0) + 1
        -- tenta 1x por chamada ate 100 tentativas; depois para de tentar
        if NET.identityRetry <= 100 then
            local ok, id = pcall(NET._getId)
            if ok and type(id) == "number" then NET.identity = id end
        end
    end
    return NET._setId, NET._getId
end

NET.refreshIdentity = function()
    NET.identity = nil
    NET.identityRetry = 0
    NET.resolveIds()
end

-- Espaca os disparos do mesmo remote. Nenhuma chamada e descartada, so atrasada.
function NET.pace(remote)
	if not remote then return end
	local now = os.clock()
	local start = math.max(now, NET.slots[remote] or 0)
	NET.slots[remote] = start + NET.INTERVAL
	local wait = start - now
	if wait > 0 then pcall(task.wait, wait) end
end

-- Identidade so em InvokeServer; restaurada mesmo com erro; erro repropagado.
function NET.callCritical(callNext, self, method, ...)
    local setId, getId = NET.resolveIds()
    -- identidade so troca em InvokeServer; demais metodos passam direto (chamado em todo namecall, custo minimo)
    if method ~= NET.K.INVOKE or not (setId and getId and NET.identity) then
        return callNext(self, method, ...)
    end
    local okP, prev = pcall(getId)
    pcall(setId, NET.identity)
    local packed = table.pack(pcall(callNext, self, method, ...))
    if okP then pcall(setId, prev) end
	if not packed[1] then error(packed[2], 0) end
	return table.unpack(packed, 2, packed.n)
end
local State = {}

-- ============================================================
-- [CORE] Núcleo do script — estado, eventos e fachada pública
-- ============================================================
-- A UI NÃO deve acessar lógica interna diretamente.
-- Use Core.ToggleX / Core.EnableX / Core.Emit / Core.On.
local Core = {
	State = State,
	_listeners = {},
	_fsWarned = {},
}

function Core.On(event, callback)
	if type(event) ~= "string" or type(callback) ~= "function" then
		return
	end
	local list = Core._listeners[event]
	if not list then
		list = {}
		Core._listeners[event] = list
	end
	table.insert(list, callback)
	return function()
		for i, fn in ipairs(list) do
			if fn == callback then
				table.remove(list, i)
				break
			end
		end
	end
end

function Core.Emit(event, ...)
	local list = Core._listeners[event]
	if not list then
		return
	end
	for _, fn in ipairs(list) do
		task.spawn(fn, ...)
	end
end

-- Notificações: o jogo emite; a UI escuta e chama Library:Notify
function Core.Notify(payload, seconds)
	Core.Emit("Notify", payload, seconds)
end

_G.NODT = _G.NODT or {}
_G.NODT.Core = Core

-- ============================================================
-- [UI] LIBRARY — Clean / Minimal (sem lógica de jogo)
-- ============================================================
local Library = (function()
--[[
	NODT STUDIO — UI Library v2 (Luau / Roblox)
	Deep dark + violeta neon. Hierarquia visual com respiro.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

--// ───────────────────────── TEMA NODT STUDIO ─────────────────────────
local Theme = {
	-- Fundos
	Shell       = Color3.fromRGB(10, 10, 14),    -- #0A0A0E fundo da janela
	Panel       = Color3.fromRGB(18, 18, 24),    -- #121218 painel (sidebar, footer)
	Raised      = Color3.fromRGB(26, 26, 34),    -- #1A1A22 card de option / hover
	Sunken      = Color3.fromRGB(8, 8, 12),      -- #08080C input / track de slider
	Card        = Color3.fromRGB(22, 22, 30),    -- #16161E groupbox
	Line        = Color3.fromRGB(44, 44, 56),    -- #2C2C38 bordas visíveis
	LineSoft    = Color3.fromRGB(30, 30, 40),    -- #1E1E28 bordas internas / dividers

	-- Accent violeta profundo (nada de pastel)
	Accent      = Color3.fromRGB(168, 85, 247),  -- #A855F7 primário
	AccentHover = Color3.fromRGB(192, 132, 252), -- #C084FC hover
	AccentDeep  = Color3.fromRGB(126, 34, 206),  -- #7E22CE deep (gradiente)
	AccentSoft  = Color3.fromRGB(76, 29, 122),   -- #4C1D7A fundo sutil de accent
	AccentText  = Color3.fromRGB(216, 180, 254), -- #D8B4FE texto sobre accent
	OnAccent    = Color3.fromRGB(18, 18, 24),    -- texto escuro sobre violeta
	Glow        = Color3.fromRGB(168, 85, 247),  -- glow do knob

	-- Estados
	Error       = Color3.fromRGB(220, 38, 38),   -- #DC2626 vermelho sangue
	Success     = Color3.fromRGB(22, 163, 74),   -- #16A34A verde escuro
	Warning     = Color3.fromRGB(234, 88, 12),   -- #EA580C laranja profundo

	-- Texto
	Text        = Color3.fromRGB(244, 244, 248), -- #F4F4F8 principal
	SubText     = Color3.fromRGB(138, 138, 154), -- #8A8A9A secundário
	Faint       = Color3.fromRGB(82, 82, 94),    -- #52525E terciário / placeholder
	Bright      = Color3.fromRGB(255, 255, 255), -- branco puro (destaque)
	Knob        = Color3.fromRGB(244, 244, 248), -- knob do toggle (branco)
}

-- Compat (mantém nomes antigos apontando pros novos)
Theme.Wine        = Theme.AccentDeep
Theme.WineHi      = Theme.Accent
Theme.WineDeep    = Theme.AccentDeep
Theme.ShellTop    = Theme.Shell
Theme.PanelLow    = Theme.Panel
Theme.Accent2     = Theme.Error

--// ───────────────────────── CONSTANTES ─────────────────────────
local WIN_W, WIN_H = 860, 540
local HEAD_H  = 64
local SIDE_W  = 172
local FOOT_H  = 28
local PILL    = UDim.new(1, 0)
local FONT    = Enum.Font.GothamMedium
local FONT_B  = Enum.Font.GothamBold
local FONT_MONO = Enum.Font.Code

-- Animações (todas com TweenService, zero RenderStepped)
local TWEEN_FAST     = TweenInfo.new(0.12, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)
local TWEEN_INFO     = TweenInfo.new(0.20, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local TWEEN_SLIDE    = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local TWEEN_SPRING   = TweenInfo.new(0.16, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)
local TWEEN_SQUISH_D = TweenInfo.new(0.10, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)
local TWEEN_SQUISH_U = TweenInfo.new(0.20, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)

local Lib = {
	Options = {},
	Toggles = {},
	Theme = Theme,
	CornerRadius = 12,
	ForceCheckbox = false,
	ShowToggleFrameInKeybinds = true,
	NotifySide = "Right",
	MaxNotifications = 5,
	Unloaded = false,
	ToggleKeybind = nil,
	DefaultToggleKey = "RightShift",
	DPI = 1,
	WinSize = Vector2.new(WIN_W, WIN_H),
}

local conns = {}
local trackedCorners = {}
local pickers = {}
local Shell, Scale, Overlay, Window
local activeClose = nil
local configFolder = "NODT"

--// ───────────────────────── HELPERS ─────────────────────────
local function tag()
	local out = {}
	for i = 1, 12 do out[i] = string.char(math.random(97, 122)) end
	return table.concat(out)
end

local function new(class, props, parent)
	local inst = Instance.new(class)
	for k, v in pairs(props or {}) do inst[k] = v end
	if parent then inst.Parent = parent end
	return inst
end

local function glide(inst, props, info)
	if type(info) == "number" then
		info = TweenInfo.new(info)
	end
	info = info or TWEEN_INFO
	local tw = TweenService:Create(inst, info, props)
	tw:Play()
	return tw
end

local function bind(signal, fn)
	local c = signal:Connect(fn)
	table.insert(conns, c)
	return c
end

local function corner(inst, radius, tracked)
	local udim = typeof(radius) == "UDim" and radius or UDim.new(0, radius)
	local c = new("UICorner", { CornerRadius = udim }, inst)
	if tracked and typeof(radius) == "number" then
		table.insert(trackedCorners, { corner = c, add = radius - Lib.CornerRadius })
	end
	return c
end

local function stroke(inst, color, thickness, transparency)
	return new("UIStroke", {
		Color = color or Theme.Line,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, inst)
end

local function pad(inst, l, r, t, b)
	return new("UIPadding", {
		PaddingLeft = UDim.new(0, l or 0),
		PaddingRight = UDim.new(0, r or 0),
		PaddingTop = UDim.new(0, t or 0),
		PaddingBottom = UDim.new(0, b or 0),
	}, inst)
end

local function gradient(inst, rotation, c0, c1, transparency)
	return new("UIGradient", {
		Rotation = rotation or 0,
		Color = ColorSequence.new(c0, c1),
		Transparency = transparency or NumberSequence.new(0),
	}, inst)
end

local function neonGradient(inst, rotation)
	return new("UIGradient", {
		Rotation = rotation or 90,
		Color = ColorSequence.new(Theme.Accent, Theme.AccentDeep),
	}, inst)
end

local function brightGradient(inst, rotation)
	return new("UIGradient", {
		Rotation = rotation or 90,
		Color = ColorSequence.new(Theme.AccentHover, Theme.Accent),
	}, inst)
end

local function silverText(inst, rotation)
	inst.TextColor3 = Color3.new(1, 1, 1)
	return new("UIGradient", {
		Rotation = rotation or 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
			ColorSequenceKeypoint.new(0.6, Color3.fromRGB(220, 220, 228)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(160, 160, 170)),
		}),
	}, inst)
end

local function silverStroke(inst, thickness, transparency, spin)
	local s = new("UIStroke", {
		Color = Color3.new(1, 1, 1),
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, inst)
	local g = new("UIGradient", {
		Rotation = 35,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Theme.Line),
			ColorSequenceKeypoint.new(0.3, Theme.Accent),
			ColorSequenceKeypoint.new(0.5, Theme.Line),
			ColorSequenceKeypoint.new(0.7, Theme.Accent),
			ColorSequenceKeypoint.new(1, Theme.Line),
		}),
	}, s)
	-- Tween de giro infinito removido: forca re-raster do stroke a 60fps.
	-- A borda continua com o gradiente estatico.
	return s, g
end

local function fadeLine(inst, rotation)
	return new("UIGradient", {
		Rotation = rotation or 0,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.65, 0.45),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, inst)
end

local ACCENT_UPPER = {
	["á"] = "Á", ["à"] = "À", ["â"] = "Â", ["ã"] = "Ã", ["é"] = "É", ["ê"] = "Ê",
	["í"] = "Í", ["ó"] = "Ó", ["ô"] = "Ô", ["õ"] = "Õ", ["ú"] = "Ú", ["ç"] = "Ç",
}
local function upperText(text)
	local out = string.upper(tostring(text or ""))
	for lower, upper in pairs(ACCENT_UPPER) do
		out = string.gsub(out, lower, upper)
	end
	return out
end

local function label(parent, props)
	local base = {
		BackgroundTransparency = 1,
		Font = FONT,
		TextSize = 13,
		TextColor3 = Theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
	}
	for k, v in pairs(props or {}) do base[k] = v end
	return new("TextLabel", base, parent)
end

local function guiParent()
	if type(gethui) == "function" then
		local ok, hui = pcall(gethui)
		if ok and typeof(hui) == "Instance" then return hui end
	end
	local ok, core = pcall(function() return game:GetService("CoreGui") end)
	if ok and core then
		local probe = Instance.new("Folder")
		local parented = pcall(function() probe.Parent = core end)
		probe:Destroy()
		if parented then return core end
	end
	local playerGui = LocalPlayer:WaitForChild("PlayerGui", 10)
	if not playerGui then warn("[NodtHub] PlayerGui nao encontrado (timeout 10s)") end
	return playerGui
end

local function mountGui(gui)
	if type(syn) == "table" and type(syn.protect_gui) == "function" then
		pcall(syn.protect_gui, gui)
	end
	gui.Parent = guiParent()
end

local KEY_NAMES = {
	LeftShift = "LShift", RightShift = "RShift", LeftControl = "LCtrl", RightControl = "RCtrl",
	LeftAlt = "LAlt", RightAlt = "RAlt", Return = "Enter", Backspace = "Bksp",
	One = "1", Two = "2", Three = "3", Four = "4", Five = "5",
	Six = "6", Seven = "7", Eight = "8", Nine = "9", Zero = "0",
}
local function keyText(value)
	if value == nil or value == "" then return "None" end
	return KEY_NAMES[value] or value
end

--// ───────────────────────── ROOT ─────────────────────────
local Root = new("ScreenGui", {
	Name = tag(),
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 99998,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
mountGui(Root)
Lib.Root = Root

--// ───────────────────────── TOOLTIP ─────────────────────────
local TipCard = new("Frame", {
	Visible = false,
	AutomaticSize = Enum.AutomaticSize.XY,
	Size = UDim2.fromOffset(0, 0),
	BackgroundColor3 = Theme.Panel,
	BorderSizePixel = 0,
	ZIndex = 300,
}, Root)
corner(TipCard, 8)
stroke(TipCard, Theme.Accent, 1, 0.4)
pad(TipCard, 12, 12, 8, 8)
local TipText = label(TipCard, {
	AutomaticSize = Enum.AutomaticSize.XY,
	Size = UDim2.fromOffset(0, 0),
	Font = FONT,
	TextSize = 12,
	TextColor3 = Theme.Text,
	TextWrapped = true,
	ZIndex = 301,
})
new("UISizeConstraint", { MaxSize = Vector2.new(240, 400) }, TipText)

local function pointer()
	return UserInputService:GetMouseLocation()
end

local function attachTip(frame, text)
	if not text or text == "" then return end
	bind(frame.MouseEnter, function()
		TipText.Text = text
		local at = pointer()
		TipCard.Position = UDim2.fromOffset(at.X + 14, at.Y + 16)
		TipCard.Visible = true
	end)
	bind(frame.MouseMoved, function()
		if TipCard.Visible then
			local at = pointer()
			TipCard.Position = UDim2.fromOffset(at.X + 14, at.Y + 16)
		end
	end)
	bind(frame.MouseLeave, function()
		TipCard.Visible = false
	end)
end

--// ───────────────────────── NOTIFICAÇÕES ─────────────────────────
local NotifyHolder = new("Frame", {
	Name = "Notify",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -20, 0, 20),
	Size = UDim2.new(0, 300, 1, -40),
	BackgroundTransparency = 1,
	ZIndex = 200,
}, Root)
new("UIListLayout", {
	Padding = UDim.new(0, 10),
	SortOrder = Enum.SortOrder.LayoutOrder,
	HorizontalAlignment = Enum.HorizontalAlignment.Right,
}, NotifyHolder)

local notifyCount = 0
function Lib:Notify(payload, seconds)
	local title, text
	if type(payload) == "table" then
		title = payload.Title
		text = payload.Description or payload.Text or ""
		seconds = seconds or payload.Time
	else
		text = tostring(payload)
	end
	-- limite de cards vivos: descarta o mais antigo (LayoutOrder menor) quando o limite e atingido
	local alive = 0
	for _, child in ipairs(NotifyHolder:GetChildren()) do
		if child:IsA("Frame") then alive = alive + 1 end
	end
	if alive >= (Lib.MaxNotifications or 5) then
		local oldest = nil
		local oldestOrder = math.huge
		for _, child in ipairs(NotifyHolder:GetChildren()) do
			if child:IsA("Frame") and (child.LayoutOrder or 0) < oldestOrder then
				oldest = child
				oldestOrder = child.LayoutOrder or 0
			end
		end
		if oldest then
			pcall(function() oldest:Destroy() end)
		end
	end
	notifyCount = notifyCount + 1

	local card = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = notifyCount,
		Position = UDim2.fromOffset(30, 0),
	}, NotifyHolder)
	corner(card, 10)
	local edge = stroke(card, Theme.Accent, 1.2, 1)
	pad(card, 16, 14, 12, 12)

	local bar = new("Frame", {
		Position = UDim2.new(0, -8, 0, 0),
		Size = UDim2.new(0, 3, 1, 0),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, card)
	corner(bar, PILL)
	neonGradient(bar, 90)

	local prog = new("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 9),
		Size = UDim2.new(1, 0, 0, 2),
		BackgroundColor3 = Theme.Accent,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, card)
	corner(prog, PILL)

	local content = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, card)
	new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, content)

	local texts = {}
	if title then
		local titleLabel = label(content, {
			Size = UDim2.new(1, 0, 0, 16),
			Font = FONT_B,
			TextSize = 13,
			TextColor3 = Theme.AccentHover,
			Text = tostring(title),
			TextTransparency = 1,
			LayoutOrder = 1,
		})
		table.insert(texts, titleLabel)
	end
	table.insert(texts, label(content, {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = FONT,
		TextSize = 12,
		TextColor3 = Theme.SubText,
		TextWrapped = true,
		Text = tostring(text),
		TextTransparency = 1,
		LayoutOrder = 2,
	}))

	glide(card, { BackgroundTransparency = 0.02, Position = UDim2.fromOffset(0, 0) }, TWEEN_SLIDE)
	glide(edge, { Transparency = 0.4 }, TWEEN_INFO)
	glide(bar, { BackgroundTransparency = 0 })
	glide(prog, { BackgroundTransparency = 0.35 })
	TweenService:Create(prog, TweenInfo.new(seconds or 4, Enum.EasingStyle.Linear), { Size = UDim2.new(0, 0, 0, 2) }):Play()
	for _, t in ipairs(texts) do glide(t, { TextTransparency = 0 }) end

	task.delay(seconds or 4, function()
		if not card.Parent then return end
		glide(card, { BackgroundTransparency = 1, Position = UDim2.fromOffset(30, 0) }, TWEEN_INFO)
		glide(edge, { Transparency = 1 })
		glide(bar, { BackgroundTransparency = 1 })
		glide(prog, { BackgroundTransparency = 1 })
		for _, t in ipairs(texts) do glide(t, { TextTransparency = 1 }) end
		task.wait(0.24)
		card:Destroy()
	end)
end

function Lib:SetNotifySide(side)
	Lib.NotifySide = side
	if side == "Left" then
		NotifyHolder.AnchorPoint = Vector2.new(0, 0)
		NotifyHolder.Position = UDim2.new(0, 20, 0, 20)
		NotifyHolder:FindFirstChildOfClass("UIListLayout").HorizontalAlignment = Enum.HorizontalAlignment.Left
	else
		NotifyHolder.AnchorPoint = Vector2.new(1, 0)
		NotifyHolder.Position = UDim2.new(1, -20, 0, 20)
		NotifyHolder:FindFirstChildOfClass("UIListLayout").HorizontalAlignment = Enum.HorizontalAlignment.Right
	end
end

--// ───────────────────────── KEYBINDS ─────────────────────────
local KeybindFrame = new("Frame", {
	Name = "Keybinds",
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 16, 0.5, 0),
	Size = UDim2.fromOffset(190, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = Theme.Panel,
	BorderSizePixel = 0,
	Visible = false,
	ZIndex = 150,
}, Root)
corner(KeybindFrame, 12)
stroke(KeybindFrame, Theme.Line, 1, 0.2)
pad(KeybindFrame, 14, 14, 12, 12)
new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, KeybindFrame)
do
	local head = new("Frame", { Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, LayoutOrder = 0 }, KeybindFrame)
	local headBar = new("Frame", {
		Position = UDim2.fromOffset(0, 3), Size = UDim2.fromOffset(3, 14),
		BackgroundColor3 = Theme.Accent, BorderSizePixel = 0,
	}, head)
	corner(headBar, PILL)
	neonGradient(headBar, 90)
	label(head, {
		Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -12, 1, 0),
		Font = FONT_B, TextSize = 13, TextColor3 = Theme.Text, Text = "Keybinds",
	})
end
Lib.KeybindFrame = KeybindFrame

local function rebuildKeybinds()
	for _, child in ipairs(KeybindFrame:GetChildren()) do
		if child:IsA("Frame") and child.Name == "Row" then child:Destroy() end
	end
	local order = 0
	for _, picker in ipairs(pickers) do
		if not picker.NoUI and picker.Value ~= "" then
			order = order + 1
			local row = new("Frame", {
				Name = "Row", Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, LayoutOrder = order,
			}, KeybindFrame)
			label(row, {
				Size = UDim2.new(1, -56, 1, 0), TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = picker.Active and Theme.Text or Theme.SubText, Text = picker.Label,
			})
			label(row, {
				AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0, 50, 1, 0),
				Font = FONT_MONO, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Right,
				TextColor3 = picker.Active and Theme.AccentHover or Theme.Faint, Text = "[" .. keyText(picker.Value) .. "]",
			})
		end
	end
end

local kbQueued = false
local function refreshKeybinds()
	if kbQueued then return end
	kbQueued = true
	task.defer(function()
		kbQueued = false
		if KeybindFrame.Visible then rebuildKeybinds() end
	end)
end
bind(KeybindFrame:GetPropertyChangedSignal("Visible"), function()
	if KeybindFrame.Visible then rebuildKeybinds() end
end)

local pickerHooked = false
local function hookPickers()
	if pickerHooked then return end
	pickerHooked = true
	bind(UserInputService.InputBegan, function(input, processed)
		for _, picker in ipairs(pickers) do
			pcall(picker.OnInputBegan, input, processed)
		end
	end)
	bind(UserInputService.InputEnded, function(input)
		for _, picker in ipairs(pickers) do
			pcall(picker.OnInputEnded, input)
		end
	end)
end

--// ───────────────────────── GROUPBOX ─────────────────────────
local function makeGroup(scroller, title, icon, hidden)
	local Card = new("Frame", {
		Name = "Card",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.Card,
		BorderSizePixel = 0,
		Visible = not hidden,
	}, scroller)
	corner(Card, 14, true)
	local cardStroke = stroke(Card, Theme.Line, 1, 0.15)
	pad(Card, 24, 24, 22, 22)
	new("UIListLayout", { Padding = UDim.new(0, 16), SortOrder = Enum.SortOrder.LayoutOrder }, Card)

	-- Título
	local titleRow = new("Frame", { Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, LayoutOrder = 1 }, Card)
	local titleBar = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(3, 16),
		BackgroundColor3 = Theme.Accent, BorderSizePixel = 0,
	}, titleRow)
	corner(titleBar, PILL)
	neonGradient(titleBar, 90)
	local groupTitle = label(titleRow, {
		Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -12, 1, 0), Font = FONT_B, TextSize = 13,
		TextTruncate = Enum.TextTruncate.AtEnd, Text = upperText(title), TextColor3 = Theme.Text,
	})

	local divider = new("Frame", {
		Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Theme.LineSoft, BorderSizePixel = 0, LayoutOrder = 2,
	}, Card)
	fadeLine(divider)

	local Group = { Instance = Card, Container = Card, Title = title, Icon = icon }
	local order = 10
	local function nextOrder()
		order = order + 1
		return order
	end

	local function slot(height)
		return new("Frame", {
			Size = UDim2.new(1, 0, 0, height),
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, Card)
	end

	local function autoSlot(gap)
		local frame = new("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, Card)
		if gap then
			new("UIListLayout", { Padding = UDim.new(0, gap), SortOrder = Enum.SortOrder.LayoutOrder }, frame)
		end
		return frame
	end

	local function caption(parent, text)
		return label(parent, {
			Size = UDim2.new(1, 0, 0, 14), Font = FONT, TextSize = 11,
			TextColor3 = Theme.SubText, Text = text, LayoutOrder = 0,
		})
	end

	function Group:SetVisible(state)
		Card.Visible = state and true or false
	end

	function Group:AddDivider()
		local line = new("Frame", {
			Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Theme.LineSoft, BorderSizePixel = 0, LayoutOrder = nextOrder(),
		}, Card)
		fadeLine(line)
		return line
	end

	--// TOGGLE (card próprio + respiro)
	function Group:AddToggle(index, opts)
		opts = opts or {}
		local hasDesc = (opts.Description or opts.Desc) ~= nil
		local row = slot(hasDesc and 68 or 56)

		local optionCard = new("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.Raised,
			BackgroundTransparency = 0.85,
			BorderSizePixel = 0,
		}, row)
		corner(optionCard, 8)
		local cardEdge = stroke(optionCard, Theme.Line, 1, 0.5)

		local accentStripe = new("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 0, 0.5, 0),
			Size = UDim2.fromOffset(3, 0),
			BackgroundColor3 = Theme.Accent,
			BorderSizePixel = 0,
			ZIndex = 2,
		}, optionCard)
		corner(accentStripe, PILL)
		local stripeHeight = hasDesc and 36 or 24

		local hit = new("TextButton", {
			Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, ZIndex = 5,
		}, row)
		attachTip(hit, opts.Tooltip)

		local text = label(row, {
			Position = UDim2.fromOffset(18, hasDesc and 14 or 0),
			Size = UDim2.new(1, -84, 0, hasDesc and 20 or 56),
			Font = FONT_B,
			TextTruncate = Enum.TextTruncate.AtEnd, Text = opts.Text or index, TextColor3 = Theme.Text,
		})
		if hasDesc then
			label(row, {
				Position = UDim2.fromOffset(18, 38), Size = UDim2.new(1, -84, 0, 16), Font = FONT,
				TextSize = 11, TextColor3 = Theme.SubText, TextTruncate = Enum.TextTruncate.AtEnd,
				Text = opts.Description or opts.Desc,
			})
		end

		local track = new("Frame", {
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -18, 0.5, 0), Size = UDim2.fromOffset(52, 28),
			BackgroundColor3 = Theme.Sunken, BorderSizePixel = 0,
		}, row)
		corner(track, PILL)
		local trackEdge = stroke(track, Theme.Line, 1, 0.3)
		local trackFill = new("Frame", {
			Size = UDim2.fromScale(0, 1), BackgroundColor3 = Theme.Accent, BackgroundTransparency = 1,
			BorderSizePixel = 0,
		}, track)
		corner(trackFill, PILL)
		neonGradient(trackFill, 90)
		local knob = new("Frame", {
			AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 4, 0.5, 0), Size = UDim2.fromOffset(20, 20),
			BackgroundColor3 = Theme.Knob, BorderSizePixel = 0,
		}, track)
		corner(knob, PILL)
		local knobGlow = stroke(knob, Theme.Accent, 0, 1)

		local Toggle = { Value = false, Type = "Toggle", Index = index, Callbacks = {} }
		local hovering = false

		local function paint()
			if Toggle.Value then
				glide(track, { BackgroundColor3 = Theme.Sunken }, TWEEN_FAST)
				glide(trackEdge, { Color = Theme.Accent, Transparency = 0.2 })
				glide(trackFill, { BackgroundTransparency = 0, Size = UDim2.fromScale(1, 1) }, TWEEN_SPRING)
				glide(knob, { Position = UDim2.new(1, -24, 0.5, 0), BackgroundColor3 = Theme.Bright }, TWEEN_SPRING)
				glide(knobGlow, { Thickness = 2, Transparency = 0.4 })
				glide(accentStripe, { Size = UDim2.fromOffset(3, stripeHeight) }, TWEEN_SPRING)
			else
				glide(track, { BackgroundColor3 = Theme.Sunken }, TWEEN_FAST)
				glide(trackEdge, { Color = hovering and Theme.Accent or Theme.Line, Transparency = 0.3 })
				glide(trackFill, { BackgroundTransparency = 1, Size = UDim2.fromScale(0, 1) }, TWEEN_SPRING)
				glide(knob, { Position = UDim2.new(0, 4, 0.5, 0), BackgroundColor3 = Theme.Knob }, TWEEN_SPRING)
				glide(knobGlow, { Thickness = 0, Transparency = 1 })
				if not hovering then
					glide(accentStripe, { Size = UDim2.fromOffset(3, 0) }, TWEEN_FAST)
				else
					glide(accentStripe, { Size = UDim2.fromOffset(3, stripeHeight) }, TWEEN_SPRING)
				end
			end
		end

		function Toggle:SetValue(value, silent)
			Toggle.Value = value and true or false
			paint()
			if silent then return end
			if opts.Callback then task.spawn(opts.Callback, Toggle.Value) end
			for _, fn in ipairs(Toggle.Callbacks) do task.spawn(fn, Toggle.Value) end
		end

		function Toggle:OnChanged(fn)
			table.insert(Toggle.Callbacks, fn)
			task.spawn(fn, Toggle.Value)
			return Toggle
		end

		function Toggle:SetVisible(state)
			row.Visible = state and true or false
		end

		bind(hit.MouseEnter, function()
			hovering = true
			glide(optionCard, { BackgroundTransparency = 0.78 }, TWEEN_FAST)
			glide(cardEdge, { Color = Theme.Accent, Transparency = 0.25 }, TWEEN_FAST)
			if not Toggle.Value then glide(trackEdge, { Color = Theme.Accent }) end
			glide(accentStripe, { Size = UDim2.fromOffset(3, stripeHeight) }, TWEEN_SPRING)
		end)
		local pressed = false
		local function releaseKnob()
			if not pressed then return end
			pressed = false
			TweenService:Create(knob, TWEEN_SQUISH_U, {
				Size = UDim2.fromOffset(20, 20),
				Position = UDim2.new(Toggle.Value and 1 or 0, Toggle.Value and -24 or 4, 0.5, 0),
			}):Play()
		end
		bind(hit.MouseLeave, function()
			hovering = false
			glide(optionCard, { BackgroundTransparency = 0.85 }, TWEEN_FAST)
			glide(cardEdge, { Color = Theme.Line, Transparency = 0.5 }, TWEEN_FAST)
			if not Toggle.Value then
				glide(trackEdge, { Color = Theme.Line })
				glide(accentStripe, { Size = UDim2.fromOffset(3, 0) }, TWEEN_FAST)
			end
			releaseKnob()
		end)
		bind(hit.MouseButton1Down, function()
			pressed = true
			local goal = { Size = UDim2.fromOffset(24, 20) }
			if Toggle.Value then goal.Position = UDim2.new(1, -28, 0.5, 0) end
			TweenService:Create(knob, TWEEN_SQUISH_D, goal):Play()
		end)
		bind(hit.MouseButton1Up, releaseKnob)
		bind(hit.MouseButton1Click, function()
			Toggle:SetValue(not Toggle.Value)
		end)

		Toggle:SetValue(opts.Default and true or false, true)
		if opts.Default and opts.Callback then task.spawn(opts.Callback, true) end

		Lib.Toggles[index] = Toggle
		return Toggle
	end

	--// SLIDER (track fino + knob violeta)
	function Group:AddSlider(index, opts)
		opts = opts or {}
		local minimum = opts.Min or 0
		local maximum = opts.Max or 100
		local step = 10 ^ (opts.Rounding or 0)
		local row = slot(66)
		attachTip(row, opts.Tooltip)

		local optionCard = new("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.Raised,
			BackgroundTransparency = 0.94,
			BorderSizePixel = 0,
		}, row)
		corner(optionCard, 8)
		local cardEdge = stroke(optionCard, Theme.Line, 1, 0.85)

		label(row, {
			Position = UDim2.fromOffset(14, 10), Size = UDim2.new(1, -76, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd,
			Text = opts.Text or index, TextColor3 = Theme.Text,
		})
		local readout = label(row, {
			AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 10), Size = UDim2.fromOffset(60, 18),
			Font = FONT_B, TextSize = 13, TextColor3 = Theme.AccentHover, TextXAlignment = Enum.TextXAlignment.Right,
		})

		local bar = new("TextButton", {
			Position = UDim2.fromOffset(14, 34), Size = UDim2.new(1, -28, 0, 24), BackgroundTransparency = 1,
			Text = "", AutoButtonColor = false,
		}, row)
		local track = new("Frame", {
			AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 9, 0.5, 0), Size = UDim2.new(1, -18, 0, 4),
			BackgroundColor3 = Theme.Sunken, BorderSizePixel = 0,
		}, bar)
		corner(track, PILL)
		stroke(track, Theme.Line, 1, 0.4)
		local fill = new("Frame", {
			Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = Theme.Accent, BorderSizePixel = 0,
		}, track)
		corner(fill, PILL)
		neonGradient(fill, 0)
		local knob = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(16, 16),
			BackgroundColor3 = Theme.Bright, BorderSizePixel = 0, ZIndex = 2,
		}, track)
		corner(knob, PILL)
		local knobStroke = stroke(knob, Theme.Accent, 2, 0.2)

		local Slider = { Value = minimum, Type = "Slider", Index = index, Callbacks = {}, Min = minimum, Max = maximum }
		local sliding = false

		local function paint()
			local span = maximum - minimum
			local ratio = span > 0 and math.clamp((Slider.Value - minimum) / span, 0, 1) or 0
			glide(fill, { Size = UDim2.new(ratio, 0, 1, 0) }, TWEEN_FAST)
			glide(knob, { Position = UDim2.new(ratio, 0, 0.5, 0) }, TWEEN_FAST)
			readout.Text = tostring(Slider.Value) .. (opts.Suffix or "")
		end

		function Slider:SetValue(value, silent)
			value = tonumber(value) or minimum
			value = math.clamp(value, minimum, maximum)
			value = math.floor(value * step + 0.5) / step
			Slider.Value = value
			paint()
			if silent then return end
			if opts.Callback then task.spawn(opts.Callback, value) end
			for _, fn in ipairs(Slider.Callbacks) do task.spawn(fn, value) end
		end

		function Slider:OnChanged(fn)
			table.insert(Slider.Callbacks, fn)
			task.spawn(fn, Slider.Value)
			return Slider
		end

		local function seek(x)
			local width = track.AbsoluteSize.X
			if width <= 0 then return end
			local ratio = math.clamp((x - track.AbsolutePosition.X) / width, 0, 1)
			local value = minimum + (maximum - minimum) * ratio
			value = math.floor(value * step + 0.5) / step
			if value ~= Slider.Value then Slider:SetValue(value) end
		end

		local moveConn, endConn
		local function stopSliding()
			if moveConn then moveConn:Disconnect() moveConn = nil end
			if endConn then endConn:Disconnect() endConn = nil end
			if not sliding then return end
			sliding = false
			glide(knob, { Size = UDim2.fromOffset(16, 16) }, TWEEN_FAST)
			glide(knobStroke, { Thickness = 2, Transparency = 0.2, Color = Theme.Accent })
		end
		bind(bar.InputBegan, function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				sliding = true
				glide(knob, { Size = UDim2.fromOffset(20, 20) }, TWEEN_FAST)
				glide(knobStroke, { Thickness = 3, Transparency = 0, Color = Theme.AccentHover })
				seek(input.Position.X)
				if moveConn then moveConn:Disconnect() end
				if endConn then endConn:Disconnect() end
				moveConn = UserInputService.InputChanged:Connect(function(changed)
					if changed.UserInputType == Enum.UserInputType.MouseMovement or changed.UserInputType == Enum.UserInputType.Touch then
						seek(changed.Position.X)
					end
				end)
				endConn = UserInputService.InputEnded:Connect(function(ended)
					if ended.UserInputType == Enum.UserInputType.MouseButton1 or ended.UserInputType == Enum.UserInputType.Touch then
						stopSliding()
					end
				end)
			end
		end)
		bind(bar.MouseEnter, function()
			if not sliding then glide(knob, { Size = UDim2.fromOffset(18, 18) }, TWEEN_FAST) end
			glide(optionCard, { BackgroundTransparency = 0.88 }, TWEEN_FAST)
			glide(cardEdge, { Color = Theme.Accent, Transparency = 0.5 }, TWEEN_FAST)
		end)
		bind(bar.MouseLeave, function()
			if not sliding then glide(knob, { Size = UDim2.fromOffset(16, 16) }, TWEEN_FAST) end
			glide(optionCard, { BackgroundTransparency = 0.94 }, TWEEN_FAST)
			glide(cardEdge, { Color = Theme.Line, Transparency = 0.85 }, TWEEN_FAST)
		end)

		Slider:SetValue(opts.Default or minimum, true)
		if opts.Default ~= nil and opts.Callback then task.spawn(opts.Callback, Slider.Value) end

		Lib.Options[index] = Slider
		return Slider
	end

	--// DROPDOWN
	function Group:AddDropdown(index, opts)
		opts = opts or {}
		local multi = opts.Multi and true or false
		local wrap = autoSlot(6)
		attachTip(wrap, opts.Tooltip)
		caption(wrap, opts.Text or index)

		local button = new("TextButton", {
			Size = UDim2.new(1, 0, 0, 36), BackgroundColor3 = Theme.Sunken, BorderSizePixel = 0,
			Text = "", AutoButtonColor = false, LayoutOrder = 1,
		}, wrap)
		corner(button, 10)
		local edge = stroke(button, Theme.Line, 1, 0.25)
		local valueText = label(button, {
			Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -42, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = Theme.Text,
		})
		local arrow = label(button, {
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0), Size = UDim2.fromOffset(12, 12),
			Font = FONT_B, TextSize = 11, TextColor3 = Theme.SubText, TextXAlignment = Enum.TextXAlignment.Center, Text = "v",
		})

		local Dropdown = {
			Value = multi and {} or nil, Type = "Dropdown", Index = index, Multi = multi,
			Values = opts.Values or {}, Callbacks = {}, Open = false,
		}
		local rows = {}
		local built = false
		local buildToken = 0

		local popup = new("Frame", {
			Visible = false, BackgroundColor3 = Theme.Panel, BorderSizePixel = 0, ClipsDescendants = true, ZIndex = 62,
		}, Overlay)
		corner(popup, 10)
		stroke(popup, Theme.Accent, 1, 0.35)
		local scroll = new("ScrollingFrame", {
			Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 1, -12), BackgroundTransparency = 1, BorderSizePixel = 0,
			ScrollBarThickness = 3, ScrollBarImageColor3 = Theme.Accent, CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
		}, popup)
		new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, scroll)

		local function isSelected(value)
			if multi then return type(Dropdown.Value) == "table" and Dropdown.Value[value] == true end
			return Dropdown.Value == value
		end

		local function paint()
			if multi then
				local picked = {}
				for _, v in ipairs(Dropdown.Values) do
					if isSelected(v) then table.insert(picked, tostring(v)) end
				end
				valueText.Text = #picked > 0 and table.concat(picked, ", ") or "--"
			else
				valueText.Text = tostring(Dropdown.Value == nil and "--" or Dropdown.Value)
			end
			for value, r in pairs(rows) do
				local sel = isSelected(value)
				if r.Sel ~= sel then
					r.Sel = sel
					local frameGoal = sel and { BackgroundColor3 = Theme.Accent, BackgroundTransparency = 0.8 }
						or { BackgroundColor3 = Theme.Raised, BackgroundTransparency = 1 }
					local textGoal = { TextColor3 = sel and Theme.Bright or Theme.Text }
					if Dropdown.Open then
						glide(r.Frame, frameGoal, TWEEN_FAST)
						glide(r.Label, textGoal, TWEEN_FAST)
					else
						for k, v in pairs(frameGoal) do r.Frame[k] = v end
						r.Label.TextColor3 = textGoal.TextColor3
					end
				end
			end
		end

		local function push(value)
			if opts.Callback then task.spawn(opts.Callback, value) end
			for _, fn in ipairs(Dropdown.Callbacks) do task.spawn(fn, value) end
		end

		function Dropdown:SetValue(value, silent)
			if multi then
				local map = {}
				if type(value) == "table" then
					for k, v in pairs(value) do
						if type(k) == "number" then map[v] = true
						elseif v then map[k] = true end
					end
				end
				Dropdown.Value = map
			else
				if type(value) == "number" and Dropdown.Values[value] ~= nil then
					value = Dropdown.Values[value]
				end
				Dropdown.Value = value
			end
			paint()
			if not silent then push(Dropdown.Value) end
		end

		function Dropdown:OnChanged(fn)
			table.insert(Dropdown.Callbacks, fn)
			task.spawn(fn, Dropdown.Value)
			return Dropdown
		end

		local function close()
			if not Dropdown.Open then return end
			Dropdown.Open = false
			Overlay.Visible = false
			activeClose = nil
			glide(arrow, { Rotation = 0 })
			glide(edge, { Color = Theme.Line })
			glide(button, { BackgroundColor3 = Theme.Sunken })
			glide(popup, { BackgroundTransparency = 1 })
			task.delay(0.14, function()
				if not Dropdown.Open then popup.Visible = false end
			end)
		end

		local function addRow(order, value)
			local entry = new("TextButton", {
				Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = Theme.Raised, BackgroundTransparency = 1,
				BorderSizePixel = 0, Text = "", AutoButtonColor = false, LayoutOrder = order,
			}, scroll)
			corner(entry, 6)
			local entryLabel = label(entry, {
				Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -24, 1, 0),
				TextTruncate = Enum.TextTruncate.AtEnd, Text = tostring(value), TextColor3 = Theme.Text,
			})
			local sel = isSelected(value)
			if sel then
				entry.BackgroundColor3 = Theme.Accent
				entry.BackgroundTransparency = 0.8
				entryLabel.TextColor3 = Theme.Bright
			end
			rows[value] = { Frame = entry, Label = entryLabel, Sel = sel }
			bind(entry.MouseEnter, function()
				if not isSelected(value) then
					glide(entry, { BackgroundTransparency = 0.6 }, TWEEN_FAST)
				end
			end)
			bind(entry.MouseLeave, function()
				if not isSelected(value) then
					glide(entry, { BackgroundTransparency = 1 }, TWEEN_FAST)
				end
			end)
			bind(entry.MouseButton1Click, function()
				if multi then
					local map = Dropdown.Value
					map[value] = (not map[value]) or nil
					paint()
					push(map)
				else
					Dropdown:SetValue(value)
					close()
				end
			end)
		end

		local function build()
			buildToken = buildToken + 1
			local token = buildToken
			for _, child in ipairs(scroll:GetChildren()) do
				if child:IsA("TextButton") then child:Destroy() end
			end
			rows = {}
			built = true
			local values = Dropdown.Values
			local count = #values
			local first = math.min(count, 30)
			for order = 1, first do addRow(order, values[order]) end
			if count > first then
				task.spawn(function()
					for order = first + 1, count do
						if token ~= buildToken or Lib.Unloaded or not popup.Parent then return end
						addRow(order, values[order])
						if (order - first) % 40 == 0 then task.wait() end
					end
				end)
			end
		end

		function Dropdown:SetValues(values)
			Dropdown.Values = values or {}
			built = false
			buildToken = buildToken + 1
			if Dropdown.Open then build() else paint() end
		end

		local function open()
			if activeClose then activeClose() end
			Dropdown.Open = true
			activeClose = close
			Overlay.Visible = true
			if not built then build() end

			local sc = math.max(Scale.Scale, 0.01)
			local sAbs, sSize = Shell.AbsolutePosition, Shell.AbsoluteSize
			local bAbs, bSize = button.AbsolutePosition, button.AbsoluteSize
			local x = (bAbs.X - sAbs.X) / sc
			local top = (bAbs.Y - sAbs.Y) / sc
			local bh = bSize.Y / sc
			local w = bSize.X / sc
			local shellH = sSize.Y / sc
			local want = math.min(#Dropdown.Values * 30 + 12, 200)
			local below = shellH - (top + bh) - 12
			local above = top - HEAD_H - 8
			local h, y
			if want <= below or below >= above then
				h = math.min(want, math.max(below, 60))
				y = top + bh + 6
			else
				h = math.min(want, math.max(above, 60))
				y = top - h - 6
			end
			popup.Position = UDim2.fromOffset(x, y)
			popup.Size = UDim2.fromOffset(w, 0)
			popup.Visible = true
			popup.BackgroundTransparency = 1
			glide(popup, { Size = UDim2.fromOffset(w, h), BackgroundTransparency = 0 }, TWEEN_SLIDE)
			glide(arrow, { Rotation = 180 })
			glide(edge, { Color = Theme.Accent })
			glide(button, { BackgroundColor3 = Theme.Panel })
		end

		bind(button.MouseEnter, function()
			if not Dropdown.Open then
				glide(edge, { Color = Theme.Accent })
				glide(button, { BackgroundColor3 = Theme.Panel })
			end
		end)
		bind(button.MouseLeave, function()
			if not Dropdown.Open then
				glide(edge, { Color = Theme.Line })
				glide(button, { BackgroundColor3 = Theme.Sunken })
			end
		end)
		bind(button.MouseButton1Click, function()
			if Dropdown.Open then close() else open() end
		end)

		local default = opts.Default
		if default ~= nil then
			Dropdown:SetValue(default, true)
			if opts.Callback then task.spawn(opts.Callback, Dropdown.Value) end
		else
			paint()
		end

		Lib.Options[index] = Dropdown
		return Dropdown
	end

	--// INPUT
	function Group:AddInput(index, opts)
		opts = opts or {}
		local wrap = autoSlot(6)
		attachTip(wrap, opts.Tooltip)
		caption(wrap, opts.Text or index)

		local field = new("TextBox", {
			Size = UDim2.new(1, 0, 0, 36), BackgroundColor3 = Theme.Sunken, BorderSizePixel = 0, Font = FONT,
			TextSize = 13, TextColor3 = Theme.Text, PlaceholderColor3 = Theme.Faint, PlaceholderText = opts.Placeholder or "",
			TextXAlignment = Enum.TextXAlignment.Left, ClearTextOnFocus = false, Text = opts.Default or "", LayoutOrder = 1,
		}, wrap)
		corner(field, 10)
		local edge = stroke(field, Theme.Line, 1, 0.3)
		pad(field, 14, 14, 0, 0)

		local Input = { Value = opts.Default or "", Type = "Input", Index = index, Callbacks = {} }

		local function push(value)
			Input.Value = value
			if opts.Callback then task.spawn(opts.Callback, value) end
			for _, fn in ipairs(Input.Callbacks) do task.spawn(fn, value) end
		end

		function Input:SetValue(value, silent)
			value = tostring(value or "")
			field.Text = value
			Input.Value = value
			if not silent then push(value) end
		end

		function Input:OnChanged(fn)
			table.insert(Input.Callbacks, fn)
			task.spawn(fn, Input.Value)
			return Input
		end

		bind(field.Focused, function()
			glide(edge, { Color = Theme.Accent, Thickness = 2 })
		end)
		bind(field.FocusLost, function()
			glide(edge, { Color = Theme.Line, Thickness = 1 })
			if opts.Numeric then
				local filtered = field.Text:gsub("[^%d%.%-]", "")
				if filtered ~= field.Text then field.Text = filtered end
			end
			if opts.Finished then push(field.Text) end
		end)
		bind(field:GetPropertyChangedSignal("Text"), function()
			if opts.Numeric then
				local filtered = field.Text:gsub("[^%d%.%-]", "")
				if filtered ~= field.Text then field.Text = filtered return end
			end
			if opts.MaxLength and #field.Text > opts.MaxLength then
				field.Text = string.sub(field.Text, 1, opts.MaxLength)
				return
			end
			Input.Value = field.Text
			if not opts.Finished then push(field.Text) end
		end)
		bind(field.MouseEnter, function()
			if not field:IsFocused() then glide(edge, { Color = Theme.Line }) end
		end)
		bind(field.MouseLeave, function()
			if not field:IsFocused() then glide(edge, { Color = Theme.Line, Thickness = 1 }) end
		end)

		Lib.Options[index] = Input
		return Input
	end

	--// BUTTON
	function Group:AddButton(a, b)
		local text, action, tooltip
		if type(a) == "table" then
			text = a.Text
			action = a.Func or a.Callback
			tooltip = a.Tooltip
		else
			text, action = a, b
		end

		local row = slot(48)
		local button = new("TextButton", {
			Size = UDim2.fromScale(1, 1), BackgroundColor3 = Theme.Raised, BorderSizePixel = 0, Font = FONT_B,
			TextSize = 13, TextColor3 = Theme.Text, Text = tostring(text or "Button"), AutoButtonColor = false,
		}, row)
		corner(button, 10)
		local edge = stroke(button, Theme.Line, 1, 0.2)
		attachTip(button, tooltip)

		bind(button.MouseEnter, function()
			glide(button, { BackgroundColor3 = Theme.AccentSoft, TextColor3 = Theme.Bright }, TWEEN_FAST)
			glide(edge, { Color = Theme.Accent, Thickness = 2, Transparency = 0.15 }, TWEEN_FAST)
		end)
		bind(button.MouseLeave, function()
			glide(button, { BackgroundColor3 = Theme.Raised, TextColor3 = Theme.Text }, TWEEN_FAST)
			glide(edge, { Color = Theme.Line, Thickness = 1, Transparency = 0.2 }, TWEEN_FAST)
		end)
		bind(button.MouseButton1Down, function()
			glide(button, { BackgroundColor3 = Theme.Sunken }, TWEEN_FAST)
		end)
		bind(button.MouseButton1Up, function()
			glide(button, { BackgroundColor3 = Theme.AccentSoft }, TWEEN_FAST)
		end)
		bind(button.MouseButton1Click, function()
			if action then task.spawn(action) end
		end)

		local Button = { Instance = button }
		function Button:SetText(value)
			button.Text = tostring(value)
			return Button
		end
		return Button
	end

	--// LABEL (+ KEYPICKER)
	function Group:AddLabel(text, wrapped)
		local row = autoSlot()
		local textLabel = label(row, {
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextColor3 = Theme.SubText,
			TextWrapped = wrapped and true or false, Text = text or "",
		})

		local Label = { Instance = textLabel }

		function Label:SetText(value)
			textLabel.Text = tostring(value)
			return Label
		end

		function Label:AddKeyPicker(index, opts)
			opts = opts or {}
			row.AutomaticSize = Enum.AutomaticSize.None
			row.Size = UDim2.new(1, 0, 0, 34)
			textLabel.AutomaticSize = Enum.AutomaticSize.None
			textLabel.Size = UDim2.new(1, -78, 1, 0)
			textLabel.TextYAlignment = Enum.TextYAlignment.Center
			textLabel.TextTruncate = Enum.TextTruncate.AtEnd

			local chip = new("TextButton", {
				AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(0, 30),
				AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = Theme.Raised, BorderSizePixel = 0, Font = FONT_B,
				TextSize = 12, TextColor3 = Theme.Bright, Text = "", AutoButtonColor = false,
			}, row)
			corner(chip, 8)
			local edge = stroke(chip, Theme.Line, 1, 0.2)
			pad(chip, 14, 14, 0, 0)
			new("UISizeConstraint", { MinSize = Vector2.new(60, 30) }, chip)

			local Picker = {
				Value = opts.Default or "", Mode = opts.Mode or "Toggle", Type = "KeyPicker", Index = index,
				Label = opts.Text or text or index, NoUI = opts.NoUI and true or false, Active = false,
				Callbacks = {}, Listening = false, LastBind = 0,
			}

			local function paint()
				chip.Text = Picker.Listening and "..." or keyText(Picker.Value)
				glide(edge, { Color = Picker.Listening and Theme.Accent or Theme.Line })
			end

			function Picker:SetValue(value, silent)
				if type(value) == "table" then
					Picker.Mode = value[2] or Picker.Mode
					value = value[1]
				end
				Picker.Value = tostring(value or "")
				paint()
				refreshKeybinds()
				if not silent then
					for _, fn in ipairs(Picker.Callbacks) do task.spawn(fn, Picker.Value) end
				end
			end

			function Picker:OnChanged(fn)
				table.insert(Picker.Callbacks, fn)
				return Picker
			end

			function Picker:GetState()
				return Picker.Active
			end

			bind(chip.MouseEnter, function()
				if not Picker.Listening then glide(edge, { Color = Theme.Accent }) end
			end)
			bind(chip.MouseLeave, function()
				if not Picker.Listening then glide(edge, { Color = Theme.Line }) end
			end)
			bind(chip.MouseButton1Click, function()
				Picker.Listening = true
				paint()
			end)

			Picker.OnInputBegan = function(input, processed)
				if Picker.Listening then
					if input.UserInputType == Enum.UserInputType.Keyboard then
						Picker.Listening = false
						Picker.LastBind = os.clock()
						if input.KeyCode == Enum.KeyCode.Backspace or input.KeyCode == Enum.KeyCode.Escape then
							Picker:SetValue("")
						else
							Picker:SetValue(input.KeyCode.Name)
						end
					end
					return
				end
				if processed or Picker.Value == "" then return end
				if UserInputService:GetFocusedTextBox() then return end
				if input.UserInputType ~= Enum.UserInputType.Keyboard or input.KeyCode.Name ~= Picker.Value then return end
				if Picker.Mode == "Toggle" then
					Picker.Active = not Picker.Active
				else
					Picker.Active = true
				end
				refreshKeybinds()
				if opts.Callback then task.spawn(opts.Callback, Picker.Active) end
			end

			Picker.OnInputEnded = function(input)
				if Picker.Mode ~= "Toggle" and Picker.Active and input.UserInputType == Enum.UserInputType.Keyboard
					and input.KeyCode.Name == Picker.Value then
					Picker.Active = false
					refreshKeybinds()
					if Picker.Mode == "Hold" and opts.Callback then
						task.spawn(opts.Callback, false)
					end
				end
			end

			table.insert(pickers, Picker)
			hookPickers()
			Picker:SetValue(opts.Default or "", true)
			Lib.Options[index] = Picker
			return Picker
		end

		return Label
	end

	return Group
end

--// ───────────────────────── ORB FLUTUANTE (Premium) ─────────────────────────
function Lib:CreateFloatButton()
	if Lib.FloatButton and Lib.FloatButton.Parent then
		return Lib.FloatButton
	end
	assert(Shell, "[NodtHub] Crie a janela (CreateWindow) antes da bolinha flutuante.")

	local SIZE = 52

	local ball = new("TextButton", {
		Name = "NODTHub_FloatBtn",
		Size = UDim2.fromOffset(SIZE, SIZE),
		Position = UDim2.new(0, 22, 0.5, -SIZE / 2),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Visible = not Shell.Visible,
		ZIndex = 999,
		Active = true,
	}, Root)

	local body = new("Frame", {
		Name = "Body",
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0, 0.06),
		BackgroundColor3 = Theme.Shell,
		BorderSizePixel = 0,
		ZIndex = 1000,
	}, ball)
	corner(body, PILL)
	local bodyStroke = silverStroke(body, 1.6, 0, true)

	local ripple = new("Frame", {
		Name = "Ripple",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 1000,
	}, body)
	corner(ripple, PILL)
	local rippleStroke = new("UIStroke", {
		Color = Theme.Accent,
		Thickness = 1.5,
		Transparency = 0.35,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, ripple)
	local rippleScale = new("UIScale", { Scale = 1 }, ripple)

	local orbit = new("Frame", {
		Name = "Orbit",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 1001,
	}, body)
	local dot = new("Frame", {
		Name = "Dot",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(6, 6),
		BackgroundColor3 = Theme.AccentHover,
		BorderSizePixel = 0,
		ZIndex = 1001,
	}, orbit)
	corner(dot, PILL)
	new("UIStroke", {
		Color = Theme.AccentHover,
		Thickness = 3,
		Transparency = 0.65,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, dot)

	local logo = label(body, {
		Name = "Logo",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Font = Enum.Font.GothamBlack,
		TextSize = 24,
		TextColor3 = Color3.new(1, 1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		Text = "N",
		ZIndex = 1002,
	})
	local logoScale = new("UIScale", { Scale = 1 }, logo)
	local shimmer = new("UIGradient", {
		Rotation = 20,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Theme.Accent),
			ColorSequenceKeypoint.new(0.42, Theme.Accent),
			ColorSequenceKeypoint.new(0.5, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(0.58, Theme.Accent),
			ColorSequenceKeypoint.new(1, Theme.Accent),
		}),
		Offset = Vector2.new(-1, 0),
	}, logo)

	local pressScale = new("UIScale", { Scale = 1 }, ball)

	local anims = {
		TweenService:Create(body, TweenInfo.new(1.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
			Position = UDim2.fromScale(0, -0.06),
		}),
		TweenService:Create(logoScale, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
			Scale = 1.12,
		}),
		TweenService:Create(shimmer, TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, false, 0.6), {
			Offset = Vector2.new(1, 0),
		}),
	}
	local function setAnimating(on)
		for _, tw in ipairs(anims) do
			if on then tw:Play() else tw:Pause() end
		end
	end

	bind(Shell:GetPropertyChangedSignal("Visible"), function()
		ball.Visible = not Shell.Visible
		setAnimating(ball.Visible)
		if ball.Visible then
			pressScale.Scale = 0.7
			glide(pressScale, { Scale = 1 }, TWEEN_SPRING)
		end
	end)
	setAnimating(ball.Visible)

	local dragging, dragStart, startPos, dragInput = false, nil, nil, nil
	local moved = false
	bind(ball.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, moved = true, false
			dragStart, startPos = input.Position, ball.Position
			glide(pressScale, { Scale = 0.88 }, TWEEN_FAST)
			local c
			c = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					glide(pressScale, { Scale = 1 }, TWEEN_FAST)
					c:Disconnect()
				end
			end)
		end
	end)
	bind(ball.InputChanged, function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			dragInput = input
		end
	end)
	bind(UserInputService.InputChanged, function(input)
		if dragging and input == dragInput then
			local delta = input.Position - dragStart
			if delta.Magnitude > 5 then moved = true end
			if moved then
				ball.Position = UDim2.new(
					startPos.X.Scale, startPos.X.Offset + delta.X,
					startPos.Y.Scale, startPos.Y.Offset + delta.Y
				)
			end
		end
	end)

	bind(ball.MouseEnter, function()
		glide(pressScale, { Scale = 1.1 }, TWEEN_INFO)
		glide(bodyStroke, { Thickness = 2.4 }, TWEEN_INFO)
	end)
	bind(ball.MouseLeave, function()
		if not dragging then
			glide(pressScale, { Scale = 1 }, TWEEN_INFO)
		end
		glide(bodyStroke, { Thickness = 1.6 }, TWEEN_INFO)
	end)

	bind(ball.Activated, function()
		if moved then return end
		if Window then
			Window:SetVisible(true)
		else
			Shell.Visible = true
		end
	end)

	Lib.FloatButton = ball
	return ball
end

--// ───────────────────────── JANELA ─────────────────────────
function Lib:SetDPIScale(percent)
	Lib.DPI = math.clamp((tonumber(percent) or 100) / 100, 0.5, 2)
	if Lib.Refit then Lib.Refit()
	elseif Scale then Scale.Scale = Lib.DPI end
end

function Lib:CreateWindow(config)
	config = config or {}
	local titleText = tostring(config.Title or "Nodt Hub")
	if config.NotifySide then Lib:SetNotifySide(config.NotifySide) end

	if type(hidegui) == "function" then
		pcall(hidegui, Root)
	end

	-- SHELL
	Shell = new("Frame", {
		Name = tag(),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(WIN_W, WIN_H),
		BackgroundColor3 = Theme.Shell,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Active = true,
	}, Root)
	corner(Shell, 16, true)
	silverStroke(Shell, 1.4, 0.1, true)
	Scale = new("UIScale", { Scale = 1 }, Shell)

	local function targetScale()
		local view = Root.AbsoluteSize
		if view.X < 1 or view.Y < 1 then
			local camera = workspace.CurrentCamera
			view = camera and camera.ViewportSize or Vector2.new(1280, 720)
		end
		local fit = math.min((view.X - 24) / WIN_W, (view.Y - 24) / WIN_H)
		return math.clamp(math.min(Lib.DPI, fit), 0.35, 2)
	end
	local popping = false
	local function refit()
		if Scale and not popping then Scale.Scale = targetScale() end
	end
	Lib.Refit = refit
	bind(Root:GetPropertyChangedSignal("AbsoluteSize"), refit)

	popping = true
	Scale.Scale = targetScale() * 0.94
	task.defer(function()
		local tween = glide(Scale, { Scale = targetScale() }, 0.34)
		tween.Completed:Wait()
		popping = false
		refit()
	end)

	-- Overlay dropdowns
	Overlay = new("Frame", {
		Name = "Overlay", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, ZIndex = 60,
	}, Shell)
	local blocker = new("TextButton", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, ZIndex = 60,
	}, Overlay)
	bind(blocker.MouseButton1Click, function()
		if activeClose then activeClose() end
	end)

	-- HEADER
	local Header = new("Frame", {
		Name = "Header", Size = UDim2.new(1, 0, 0, HEAD_H), BackgroundTransparency = 1, Active = true,
	}, Shell)
	local headGlow = new("Frame", {
		Size = UDim2.fromScale(1, 1), BackgroundColor3 = Theme.Accent, BackgroundTransparency = 0.94,
		BorderSizePixel = 0,
	}, Header)
	new("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new(0, 1),
	}, headGlow)
	local headLine = new("Frame", {
		Position = UDim2.new(0, 0, 1, -1), Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = Theme.Accent, BackgroundTransparency = 0.4, BorderSizePixel = 0,
	}, Header)
	new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, headLine)

	-- Logo circular
	local logo = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 20, 0.5, -6), Size = UDim2.fromOffset(40, 40),
		BackgroundColor3 = Theme.Shell, BorderSizePixel = 0,
	}, Header)
	corner(logo, PILL)
	local logoRing = stroke(logo, Color3.new(1, 1, 1), 1.6, 0)
	new("UIGradient", {
		Rotation = 45,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Theme.AccentHover),
			ColorSequenceKeypoint.new(0.5, Theme.AccentDeep),
			ColorSequenceKeypoint.new(1, Theme.AccentHover),
		}),
	}, logoRing)
	local logoLetter = label(logo, {
		Size = UDim2.fromScale(1, 1), Font = Enum.Font.GothamBlack, TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Center, Text = "N", TextColor3 = Theme.Bright,
	})

	local titleLabel = label(Header, {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 72, 0.5, -12), Size = UDim2.new(0.6, 0, 0, 20),
		Font = FONT_B, TextSize = 17, Text = titleText, TextColor3 = Theme.Text,
	})
	local subtitleLabel = label(Header, {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 72, 0.5, 8), Size = UDim2.new(0.6, 0, 0, 16),
		Font = FONT, TextSize = 11, Text = "v1.0", TextColor3 = Theme.SubText,
	})

	local function headerButton(text, rightOffset, hoverColor, hoverText)
		local btn = new("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, rightOffset, 0.5, 0), Size = UDim2.fromOffset(34, 34),
			BackgroundColor3 = Theme.Card, BorderSizePixel = 0, Font = FONT_B, TextSize = 14, TextColor3 = Theme.SubText,
			Text = text, AutoButtonColor = false,
		}, Header)
		corner(btn, 8)
		local edge = stroke(btn, Theme.LineSoft, 1, 0.1)
		bind(btn.MouseEnter, function()
			glide(btn, { BackgroundColor3 = hoverColor, TextColor3 = hoverText }, TWEEN_FAST)
			glide(edge, { Color = Theme.Accent })
		end)
		bind(btn.MouseLeave, function()
			glide(btn, { BackgroundColor3 = Theme.Card, TextColor3 = Theme.SubText }, TWEEN_FAST)
			glide(edge, { Color = Theme.LineSoft })
		end)
		return btn
	end
	local closeBtn = headerButton("X", -20, Theme.Error, Theme.Bright)

	-- Drag
	local dragging, dragStart, startPos, dragInput = false, nil, nil, nil
	bind(Header.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart, startPos = input.Position, Shell.Position
			local c
			c = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					c:Disconnect()
				end
			end)
		end
	end)
	bind(Header.InputChanged, function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			dragInput = input
		end
	end)
	bind(UserInputService.InputChanged, function(input)
		if dragging and input == dragInput then
			local delta = input.Position - dragStart
			Shell.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
			)
		end
	end)

	-- MAIN (sidebar + conteúdo + footer)
	local Main = new("Frame", {
		Name = "Main", Position = UDim2.fromOffset(0, HEAD_H), Size = UDim2.new(1, 0, 1, -HEAD_H), BackgroundTransparency = 1,
	}, Shell)

	-- Sidebar
	new("Frame", {
		Name = "SideBg", Size = UDim2.new(0, SIDE_W, 1, -FOOT_H), BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.15, BorderSizePixel = 0,
	}, Main)

	local TabStrip = new("ScrollingFrame", {
		Name = "Tabs", Position = UDim2.fromOffset(0, 0), Size = UDim2.new(0, SIDE_W, 1, -FOOT_H), BackgroundTransparency = 1,
		BorderSizePixel = 0, ScrollBarThickness = 0, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, Main)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
	}, TabStrip)
	pad(TabStrip, 12, 12, 14, 14)

	local sideLine = new("Frame", {
		Position = UDim2.fromOffset(SIDE_W, 0), Size = UDim2.new(0, 1, 1, -FOOT_H),
		BackgroundColor3 = Theme.Line, BorderSizePixel = 0,
	}, Main)

	-- Content
	local Content = new("Frame", {
		Name = "Content", Position = UDim2.fromOffset(SIDE_W + 1, 0), Size = UDim2.new(1, -(SIDE_W + 1), 1, -FOOT_H),
		BackgroundTransparency = 1,
	}, Main)

	local PageHead = new("Frame", { Name = "PageHead", Size = UDim2.new(1, 0, 0, 72), BackgroundTransparency = 1 }, Content)
	local pageBar = new("Frame", {
		Position = UDim2.fromOffset(20, 18), Size = UDim2.fromOffset(4, 36),
		BackgroundColor3 = Theme.Accent, BorderSizePixel = 0,
	}, PageHead)
	corner(pageBar, PILL)
	neonGradient(pageBar, 90)
	local PageTitle = label(PageHead, {
		Position = UDim2.fromOffset(36, 16), Size = UDim2.new(1, -52, 0, 24), Font = FONT_B, TextSize = 20, Text = "",
		TextColor3 = Theme.Text,
	})
	local PageSub = label(PageHead, {
		Position = UDim2.fromOffset(36, 42), Size = UDim2.new(1, -52, 0, 16), Font = FONT, TextSize = 11,
		TextColor3 = Theme.SubText, TextTruncate = Enum.TextTruncate.AtEnd, Text = "",
	})
	local pageLine = new("Frame", {
		Position = UDim2.new(0, 0, 0, 72), Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = Theme.Line, BorderSizePixel = 0,
	}, Content)
	fadeLine(pageLine)

	local Body = new("Frame", {
		Name = "Body", Position = UDim2.fromOffset(16, 84), Size = UDim2.new(1, -32, 1, -92), BackgroundTransparency = 1,
	}, Content)

	local PageCover = new("Frame", {
		Name = "Cover", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Theme.Shell, BackgroundTransparency = 1,
		BorderSizePixel = 0, ZIndex = 20,
	}, Body)

	-- Footer
	local Footer = new("Frame", {
		Name = "Status", AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 14, 1, -6), Size = UDim2.new(1, -28, 0, 20),
		BackgroundTransparency = 1,
	}, Main)
	local statusDot = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(6, 6),
		BackgroundColor3 = Theme.AccentHover, BorderSizePixel = 0,
	}, Footer)
	corner(statusDot, PILL)
	-- Tween de pulso infinito removido (custo de re-render por frame sem ganho visual real).
	local statusText = label(Footer, {
		Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -20, 1, 0), Font = FONT_B, TextSize = 10,
		TextColor3 = Theme.SubText, Text = upperText(config.Status or "Sessão ativa"),
	})

	Window = { Instance = Shell, TabList = {}, Tabs = {}, ActiveTab = nil, Minimized = false }
	Lib.Window = Window

	function Window:SetStatus(text)
		statusText.Text = upperText(text)
	end

	function Window:AddTab(name, icon, accent, subtitle)
		local Tab = { Name = name, Icon = icon, Accent = accent, Subtitle = subtitle }

		local btn = new("Frame", {
			Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = Theme.Raised, BackgroundTransparency = 1, BorderSizePixel = 0,
			LayoutOrder = #Window.TabList + 1,
		}, TabStrip)
		corner(btn, 8, true)
		local accentBar = new("Frame", {
			AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(3, 0),
			BackgroundColor3 = Theme.Accent, BorderSizePixel = 0,
		}, btn)
		corner(accentBar, PILL)
		local btnScale = new("UIScale", { Scale = 1 }, btn)
		local fill = new("Frame", {
			Size = UDim2.fromScale(1, 1), BackgroundColor3 = Theme.Raised, BackgroundTransparency = 1,
			BorderSizePixel = 0, ZIndex = 1,
		}, btn)
		corner(fill, 8, true)
		local btnText = label(btn, {
			Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -22, 1, 0), Font = FONT, TextSize = 13,
			TextColor3 = Theme.SubText, TextTruncate = Enum.TextTruncate.AtEnd, Text = tostring(name), ZIndex = 2,
		})
		local hit = new("TextButton", {
			Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, ZIndex = 3,
		}, btn)
		Tab.Button = btn

		local page = new("Frame", { Name = "Page", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, Body)
		Tab.Page = page

		local function scroller(position, size)
			local sf = new("ScrollingFrame", {
				Position = position, Size = size, BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
				ScrollBarImageColor3 = Theme.Accent, ScrollBarImageTransparency = 0.35, CanvasSize = UDim2.new(),
				AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
			}, page)
			new("UIListLayout", { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, sf)
			pad(sf, 0, 8, 0, 4)
			return sf
		end
		local left = scroller(UDim2.fromOffset(0, 0), UDim2.new(0.5, -6, 1, 0))
		local right = scroller(UDim2.new(0.5, 6, 0, 0), UDim2.new(0.5, -6, 1, 0))

		local function paint(active)
			glide(fill, { BackgroundTransparency = active and 0.94 or 1 }, TWEEN_INFO)
			glide(btnText, { TextColor3 = active and Theme.Text or Theme.SubText, Position = UDim2.fromOffset(active and 18 or 14, 0) }, TWEEN_INFO)
			btnText.Font = active and FONT_B or FONT
			glide(accentBar, { Size = UDim2.fromOffset(3, active and 18 or 0) }, TWEEN_SPRING)
			if not active then glide(btn, { BackgroundTransparency = 1 }, TWEEN_FAST) end
		end

		function Tab:Select()
			if Window.ActiveTab == Tab then return end
			if activeClose then activeClose() end
			local prev = Window.ActiveTab
			if prev then
				prev.Active = false
				prev.Page.Visible = false
				prev:Paint(false)
			end
			Tab.Active = true
			Window.ActiveTab = Tab
			PageTitle.Text = tostring(Tab.Name)
			PageSub.Text = tostring(Tab.Subtitle or "")
			PageCover.BackgroundTransparency = 0
			page.Position = UDim2.fromOffset(12, 0)
			page.Visible = true
			glide(page, { Position = UDim2.fromOffset(0, 0) }, TWEEN_SLIDE)
			glide(PageCover, { BackgroundTransparency = 1 }, TWEEN_INFO)
			paint(true)
		end

		function Tab:Paint(active)
			paint(active)
		end

		bind(hit.MouseEnter, function()
			if not Tab.Active then
				glide(btn, { BackgroundTransparency = 0.6 }, TWEEN_FAST)
				glide(btnText, { TextColor3 = Theme.Text }, TWEEN_FAST)
			end
		end)
		bind(hit.MouseLeave, function()
			if not Tab.Active then
				glide(btn, { BackgroundTransparency = 1 }, TWEEN_FAST)
				glide(btnText, { TextColor3 = Theme.SubText }, TWEEN_FAST)
			end
			glide(btnScale, { Scale = 1 }, TWEEN_FAST)
		end)
		bind(hit.MouseButton1Down, function()
			glide(btnScale, { Scale = 0.97 }, TWEEN_FAST)
		end)
		bind(hit.MouseButton1Up, function()
			glide(btnScale, { Scale = 1 }, TWEEN_INFO)
		end)
		bind(hit.MouseButton1Click, function()
			Tab:Select()
		end)

		function Tab:AddLeftGroupbox(title, groupIcon, hidden)
			return makeGroup(left, title, groupIcon, hidden)
		end
		function Tab:AddRightGroupbox(title, groupIcon, hidden)
			return makeGroup(right, title, groupIcon, hidden)
		end

		table.insert(Window.TabList, Tab)
		Window.Tabs[name] = Tab
		if #Window.TabList == 1 then
			Tab:Select()
		end
		return Tab
	end

	function Window:SetMinimized(state)
		state = state and true or false
		Window.Minimized = state
		if activeClose then activeClose() end
		if state then
			glide(Shell, { Size = UDim2.fromOffset(WIN_W, HEAD_H) })
			task.delay(0.2, function()
				if Window.Minimized then Main.Visible = false end
			end)
		else
			Main.Visible = true
			glide(Shell, { Size = UDim2.fromOffset(WIN_W, WIN_H) })
		end
	end

	function Window:IsMinimized()
		return Window.Minimized
	end

	function Window:SetVisible(state)
		state = state and true or false
		if activeClose and not state then activeClose() end
		if state then
			if Window.Minimized then Window:SetMinimized(false) end
			if not Shell.Visible then
				Shell.Visible = true
				popping = true
				Scale.Scale = targetScale() * 0.94
				local tween = glide(Scale, { Scale = targetScale() }, 0.34)
				tween.Completed:Connect(function()
					popping = false
					refit()
				end)
			end
		else
			Shell.Visible = false
			TipCard.Visible = false
		end
	end

	function Window:Toggle()
		Window:SetVisible(not Shell.Visible)
	end

	function Window:SetCornerRadius(radius)
		radius = tonumber(radius) or Lib.CornerRadius
		Lib.CornerRadius = radius
		for _, entry in ipairs(trackedCorners) do
			if entry.corner and entry.corner.Parent then
				entry.corner.CornerRadius = UDim.new(0, math.max(0, radius + entry.add))
			end
		end
	end

	bind(closeBtn.MouseButton1Click, function()
		Window:SetVisible(false)
	end)

	bind(UserInputService.InputBegan, function(input, processed)
		if Lib.Unloaded or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		if UserInputService:GetFocusedTextBox() then return end
		local keybind = Lib.ToggleKeybind
		local key = Lib.DefaultToggleKey
		if keybind then
			if keybind.Listening or (os.clock() - (keybind.LastBind or 0)) < 0.2 then return end
			key = keybind.Value
		end
		if key and key ~= "" and input.KeyCode.Name == key then
			Window:Toggle()
		end
	end)

	if config.FloatButton ~= false then
		Lib:CreateFloatButton()
	end

	return Window
end

--// ───────────────────────── UNLOAD ─────────────────────────
function Lib:Unload()
	if Lib.Unloaded then return end
	Lib.Unloaded = true

	local genv = (type(getgenv) == "function" and getgenv()) or _G
	local session = (genv.NODT and genv.NODT.Session) or rawget(genv, "NODT_SESSION") or genv.NODT_SESSION
	if type(session) == "table" and type(session.unload) == "function" then
		pcall(session.unload)
	end

	for _, link in ipairs(conns) do
		pcall(function() link:Disconnect() end)
	end
	conns = {}

	if type(session) == "table" then
		if type(session.unhook) == "function" then pcall(session.unhook) end
		for _, link in ipairs(session.links or {}) do
			pcall(function() link:Disconnect() end)
		end
		session.links = {}

		pcall(function()
			local tagged = {}
			for _, name in ipairs(session.tags or {}) do tagged[name] = true end
			if not next(tagged) then return end
			local holders = {}
			if type(gethui) == "function" then
				local ok, container = pcall(gethui)
				if ok and container then table.insert(holders, container) end
			end
			table.insert(holders, game:GetService("CoreGui"))
			if workspace.CurrentCamera then table.insert(holders, workspace.CurrentCamera) end
			local pg = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
			if pg then table.insert(holders, pg) end
			for _, holder in ipairs(holders) do
				for _, child in ipairs(holder:GetChildren()) do
					if tagged[child.Name] then child:Destroy() end
				end
			end
			for _, model in ipairs(workspace:GetChildren()) do
				if model:IsA("Model") and model.Name:match("^CLIENT_BALL_%d+$") then
					for _, child in ipairs(model:GetChildren()) do
						if tagged[child.Name] then child:Destroy() end
					end
				end
			end
			for _, other in ipairs(Players:GetPlayers()) do
				if other.Character then
					for _, child in ipairs(other.Character:GetChildren()) do
						if tagged[child.Name] then child:Destroy() end
					end
				end
			end
		end)
	end

	if type(Lib.RestoreAntiLag) == "function" then pcall(Lib.RestoreAntiLag) end
	if type(Lib.CleanupExtras) == "function" then pcall(Lib.CleanupExtras) end

	Root:Destroy()
end

--// ───────────────────────── CONFIGS ─────────────────────────
local function fileApi()
	local genv = (type(getgenv) == "function" and getgenv()) or _G
	local write = rawget(_G, "writefile") or genv.writefile or writefile
	local read = rawget(_G, "readfile") or genv.readfile or readfile
	local list = rawget(_G, "listfiles") or genv.listfiles or listfiles
	local exists = rawget(_G, "isfile") or genv.isfile or isfile
	local folder = rawget(_G, "isfolder") or genv.isfolder or isfolder
	local mkdir = rawget(_G, "makefolder") or genv.makefolder or makefolder
	local remove = rawget(_G, "delfile") or genv.delfile or delfile
	if type(write) ~= "function" or type(read) ~= "function" or type(list) ~= "function" then
		return nil
	end
	local function guardBool(fn)
		if type(fn) ~= "function" then return nil end
		return function(...)
			return (pcall(fn, ...))
		end
	end
	local function guardValue(fn, fallback)
		if type(fn) ~= "function" then return nil end
		return function(...)
			local ok, res = pcall(fn, ...)
			if ok and res ~= nil then return res end
			return fallback
		end
	end
	return {
		write = guardBool(write),
		read = guardValue(read, nil),
		list = guardValue(list, nil),
		exists = guardValue(exists, false),
		folder = guardValue(folder, false),
		mkdir = guardBool(mkdir),
		remove = guardBool(remove),
	}
end

	Lib.FileApi = fileApi

function Lib:SetConfigFolder(name)
	configFolder = name
end

local function ensureFolder(api)
	if api.folder and api.mkdir then
		if not api.folder(configFolder) then api.mkdir(configFolder) end
		if not api.folder(configFolder .. "/configs") then api.mkdir(configFolder .. "/configs") end
	end
end

local function collect()
	local dump = { toggles = {}, options = {} }
	for index, toggle in pairs(Lib.Toggles) do dump.toggles[index] = toggle.Value end
	for index, option in pairs(Lib.Options) do
		if option.Type == "KeyPicker" then
			dump.options[index] = { option.Value, option.Mode }
		else
			dump.options[index] = option.Value
		end
	end
	return dump
end

	Lib.CollectConfig = collect

local restoreToken = 0
local function restore(dump)
	restoreToken = restoreToken + 1
	local token = restoreToken
	local jobs = {}

	for index, value in pairs(dump.options or {}) do
		local option = Lib.Options[index]
		if option and option.SetValue then
			local current = option.Value
			local target = value
			if option.Type == "KeyPicker" and type(value) == "table" then target = value[1] end
			local same = type(target) ~= "table" and current == target
			if not same then
				table.insert(jobs, { fn = function() option:SetValue(value) end, heavy = false })
			end
		end
	end

	for index, value in pairs(dump.toggles or {}) do
		local toggle = Lib.Toggles[index]
		if toggle and (toggle.Value and true or false) ~= (value and true or false) then
			table.insert(jobs, { fn = function() toggle:SetValue(value) end, heavy = true })
		end
	end

	if #jobs == 0 then return end
	task.spawn(function()
		task.wait(0.75)
		local light, heavy = 0, 0
		local function breathe()
			local dt = RunService.Heartbeat:Wait()
			local tries = 0
			while dt > 0.04 and tries < 24 do
				dt = RunService.Heartbeat:Wait()
				tries = tries + 1
			end
		end
		for _, job in ipairs(jobs) do
			if Lib.Unloaded or token ~= restoreToken then return end
			local t0 = os.clock()
			pcall(job.fn)
			local took = os.clock() - t0
			if job.heavy then
				heavy = heavy + 1
				breathe()
				if took > 0.03 then task.wait(0.15) end
				if heavy % 3 == 0 then task.wait(0.06) end
			else
				light = light + 1
				if light % 6 == 0 then task.wait() end
			end
		end
	end)
end

function Lib:SaveConfig(name)
	local api = fileApi()
	if not api or not name or name == "" then return false end
	ensureFolder(api)
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, collect())
	if not ok then return false end
	return api.write(configFolder .. "/configs/" .. name .. ".json", encoded) == true
end

function Lib:LoadConfig(name)
	local api = fileApi()
	if not api or not name or name == "" then return false end
	local ok, raw = pcall(api.read, configFolder .. "/configs/" .. name .. ".json")
	if not ok or type(raw) ~= "string" then return false end
	local parsed, dump = pcall(HttpService.JSONDecode, HttpService, raw)
	if not parsed or type(dump) ~= "table" then return false end
	restore(dump)
	return true
end

function Lib:ListConfigs()
	local api = fileApi()
	local found = {}
	if not api then return found end
	ensureFolder(api)
	local ok, entries = pcall(api.list, configFolder .. "/configs")
	if not ok or type(entries) ~= "table" then return found end
	for _, path in ipairs(entries) do
		local name = string.match(path, "([^/\\]+)%.json$")
		if name then table.insert(found, name) end
	end
	return found
end

function Lib:LoadAutoloadConfig()
	local api = fileApi()
	if not api then return end
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

	local nameBox = group:AddInput("ConfigName", { Default = "", Text = "Config name", Placeholder = "default" })
	local picker = group:AddDropdown("ConfigList", { Values = Lib:ListConfigs(), Text = "Saved configs" })

	group:AddButton("Create", function()
		if Lib:SaveConfig(nameBox.Value) then
			picker:SetValues(Lib:ListConfigs())
			Lib:Notify("Saved config " .. nameBox.Value)
		end
	end)
	group:AddButton("Load", function()
		if picker.Value and Lib:LoadConfig(picker.Value) then
			Lib:Notify("Loaded config " .. picker.Value)
		end
	end)
	group:AddButton("Overwrite", function()
		if picker.Value and Lib:SaveConfig(picker.Value) then
			Lib:Notify("Overwrote config " .. picker.Value)
		end
	end)
	group:AddButton("Delete", function()
		if picker.Value and api.remove then
			pcall(api.remove, configFolder .. "/configs/" .. picker.Value .. ".json")
			picker:SetValues(Lib:ListConfigs())
			picker:SetValue(nil, true)
			Lib:Notify("Deleted config")
		end
	end)
	group:AddButton("Refresh list", function()
		picker:SetValues(Lib:ListConfigs())
	end)

	local autoLabel = group:AddLabel("Autoload: none", true)
	group:AddButton("Set as autoload", function()
		if picker.Value then
			pcall(api.write, configFolder .. "/autoload.txt", picker.Value)
			autoLabel:SetText("Autoload: " .. picker.Value)
		end
	end)
	group:AddButton("Clear autoload", function()
		pcall(api.write, configFolder .. "/autoload.txt", "")
		autoLabel:SetText("Autoload: none")
	end)

	local ok, current = pcall(api.read, configFolder .. "/autoload.txt")
	if ok and type(current) == "string" and current ~= "" then
		autoLabel:SetText("Autoload: " .. current)
	end
	return group
end

--// ───────────────────────── PROMPT KEY (Premium) ─────────────────────────
function Lib.promptKey(config)
	config = type(config) == "table" and config or {}

	local gui = new("ScreenGui", {
		Name = tag(),
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 99999,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	mountGui(gui)

	local submitted = Instance.new("BindableEvent")
	local busy = false

	local frame = new("Frame", {
		Name = "KeyPanel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(310, 200),
		BackgroundColor3 = Theme.Shell,
		BorderSizePixel = 0,
	}, gui)
	corner(frame, 16)
	local frameEdge = stroke(frame, Theme.Accent, 1, 0.2)
	local frameScale = new("UIScale", { Scale = 0.92 }, frame)

	local topMark = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.fromOffset(40, 3),
		BackgroundColor3 = Theme.Accent,
		BorderSizePixel = 0,
	}, frame)
	corner(topMark, PILL)
	neonGradient(topMark, 0)

	local function fitScale()
		local view = gui.AbsoluteSize
		if view.X < 1 then return 1 end
		return math.clamp((view.X - 20) / 310, 0.5, 1)
	end

	label(frame, {
		Position = UDim2.fromOffset(20, 18), Size = UDim2.new(1, -40, 0, 22), Font = FONT_B, TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Center, Text = config.Title or "Nodt Hub — Key", TextColor3 = Theme.Text,
	})
	label(frame, {
		Position = UDim2.fromOffset(20, 42), Size = UDim2.new(1, -40, 0, 16), Font = FONT, TextSize = 11,
		TextColor3 = Theme.SubText, TextXAlignment = Enum.TextXAlignment.Center,
		Text = config.Subtitle or "HWID vinculado na 1ª ativação",
	})

	local box = new("TextBox", {
		Position = UDim2.fromOffset(20, 70), Size = UDim2.new(1, -40, 0, 38), BackgroundColor3 = Theme.Sunken,
		BorderSizePixel = 0, ClearTextOnFocus = false, Font = FONT, TextSize = 13, TextColor3 = Theme.Text,
		PlaceholderText = config.Placeholder or "Cole sua key aqui", PlaceholderColor3 = Theme.Faint, Text = "",
		TextXAlignment = Enum.TextXAlignment.Center,
	}, frame)
	corner(box, 10)
	local boxEdge = stroke(box, Theme.LineSoft, 1, 0.2)
	pad(box, 12, 12, 0, 0)

	local errorText = label(frame, {
		Position = UDim2.fromOffset(20, 114), Size = UDim2.new(1, -40, 0, 16), Font = FONT, TextSize = 11,
		TextColor3 = Theme.Error, TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "",
	})

	local submit = new("TextButton", {
		Position = UDim2.fromOffset(20, 138), Size = UDim2.new(1, -40, 0, 40), BackgroundColor3 = Theme.Accent,
		BorderSizePixel = 0, AutoButtonColor = false, Font = FONT_B, TextSize = 13, TextColor3 = Theme.Bright,
		Text = config.ButtonText or "ATIVAR",
	}, frame)
	corner(submit, 10)
	neonGradient(submit, 90)
	local submitScale = new("UIScale", { Scale = 1 }, submit)

	bind(box.Focused, function() glide(boxEdge, { Color = Theme.Accent }) end)
	bind(box.FocusLost, function() glide(boxEdge, { Color = Theme.LineSoft }) end)
	bind(box.MouseEnter, function()
		if not box:IsFocused() then glide(boxEdge, { Color = Theme.Line }) end
	end)
	bind(box.MouseLeave, function()
		if not box:IsFocused() then glide(boxEdge, { Color = Theme.LineSoft }) end
	end)
	bind(submit.MouseEnter, function()
		glide(submit, { BackgroundColor3 = Theme.AccentHover }, TWEEN_FAST)
		if not busy then glide(submitScale, { Scale = 1.02 }, TWEEN_FAST) end
	end)
	bind(submit.MouseLeave, function()
		glide(submit, { BackgroundColor3 = Theme.Accent }, TWEEN_FAST)
		if not busy then glide(submitScale, { Scale = 1 }, TWEEN_FAST) end
	end)
	bind(submit.MouseButton1Down, function()
		glide(submitScale, { Scale = 0.96 }, TWEEN_FAST)
	end)
	bind(submit.MouseButton1Up, function()
		glide(submitScale, { Scale = 1 }, TWEEN_FAST)
	end)

	local function setBusy(state)
		busy = state and true or false
		submit.Text = busy and "VALIDANDO..." or (config.ButtonText or "ATIVAR")
	end

	local function shake()
		task.spawn(function()
			local base = frame.Position
			for _, dx in ipairs({ 8, -8, 5, -5, 0 }) do
				if not frame.Parent then return end
				glide(frame, { Position = UDim2.new(base.X.Scale, base.X.Offset + dx, base.Y.Scale, base.Y.Offset) }, 0.05)
				task.wait(0.05)
			end
		end)
	end

	local function send()
		if busy then return end
		errorText.Text = ""
		setBusy(true)
		submitted:Fire(box.Text)
	end
	bind(submit.MouseButton1Click, send)
	bind(box.FocusLost, function(enterPressed)
		if enterPressed then send() end
	end)

	local prompt = { Instance = frame }

	function prompt:WaitForKey()
		setBusy(false)
		return submitted.Event:Wait()
	end

	function prompt:SetError(message)
		setBusy(false)
		errorText.Text = tostring(message or "")
		if errorText.Text ~= "" then
			shake()
			glide(frameEdge, { Color = Theme.Error })
			task.delay(0.9, function()
				if frame.Parent then glide(frameEdge, { Color = Theme.Accent }) end
			end)
		end
	end

	function prompt:SetBusy(state)
		setBusy(state)
	end

	function prompt:Destroy()
		pcall(function() submitted:Destroy() end)
		pcall(function() gui:Destroy() end)
	end

	glide(frameScale, { Scale = fitScale() })
	task.defer(function()
		local started = os.clock()
		local function focus()
			if os.clock() - started >= 2 then return end
			if box.Parent and box:IsDescendantOf(game) then
				pcall(function() box:CaptureFocus() end)
				local focused = false
				pcall(function() focused = box:IsFocused() end)
				if focused then return end
			end
			task.delay(0.2, focus)
		end
		focus()
	end)

	return prompt
end
Lib.PromptKey = Lib.promptKey
Lib.promptkey = Lib.promptKey

return Lib
end)()


-- ============================================================
-- [CORE] KEY CLIENT / AUTH (v1)
-- ============================================================
_G.NODT.AuthPassed = false

do
    local API_URL = "https://nodt-jz6jdzp7.manus.space"
    local TOKEN_FILE = "NODT/token.json"

    State.SessionToken = nil
    State.KeyExpiresAt = 0

    local function getHwid()
        local okClient, clientId = pcall(function()
            return game:GetService("RbxAnalyticsService"):GetClientId()
        end)
        if okClient and typeof(clientId) == "string" and #clientId > 10 then
            return "rbx_" .. clientId
        end

        local okHwid, hwid = pcall(function()
            if type(gethwid) == "function" then return gethwid() end
            if type(getserial) == "function" then return getserial() end
            if type(syn) == "table" and type(syn.get_hwid) == "function" then return syn.get_hwid() end
        end)
        if okHwid and typeof(hwid) == "string" and #hwid > 5 then
            return "ext_" .. hwid
        end

        local okUid, uid = pcall(function()
            return game:GetService("Players").LocalPlayer.UserId
        end)
        if okUid and uid then return "uid_" .. tostring(uid) end

        return "unknown_hwid"
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

        local ok, response
        for attempt = 1, 3 do
            local finished = false
            local result = nil
            task.spawn(function()
                local success, res = pcall(req, {
                    Url = API_URL .. endpoint,
                    Method = method,
                    Headers = headers,
                    Body = payload
                })
                if success then result = res end
                finished = true
            end)

            local t0 = os.clock()
            while not finished and os.clock() - t0 < 8 do
                task.wait(0.1)
            end

            if not finished then
                warn("[NodtHub] Request timeout (tentativa " .. attempt .. "/3)")
                if attempt < 3 then task.wait(2) end
            else
                ok, response = true, result
                if response and response.Body and response.StatusCode < 500 then
                    break
                end
                if attempt < 3 then
                    warn("[NodtHub] Servidor acordando (tentativa " .. attempt .. "/3)...")
                    task.wait(2)
                end
            end
        end

        if not ok or not response or not response.Body then return nil, "Network timeout/error" end
        local decoded = jsonDecode(response.Body)
        if not decoded then return nil, "Invalid JSON from server" end
        return decoded, response.StatusCode
    end

    local function saveToken(token, expiresAt)
        local exp = tonumber(expiresAt)
        if not exp then exp = os.time() + 86400 end
        if exp > 100000000000 then exp = math.floor(exp / 1000) end

        local data = jsonEncode({ token = token, expires_at = exp })
        if not data then return false end

        local genv = (type(getgenv) == "function" and getgenv()) or _G
        local writeFn = rawget(_G, "writefile") or genv.writefile or writefile
        if type(writeFn) ~= "function" then return false end

        local ok = pcall(writeFn, "NODT/token.json", data)
        if ok then return true end

        local mkdirFn = rawget(_G, "makefolder") or genv.makefolder or makefolder
        if type(mkdirFn) == "function" then
            pcall(mkdirFn, "NODT")
            ok = pcall(writeFn, "NODT/token.json", data)
        end
        return ok == true
    end

    local function loadToken()
        local genv = (type(getgenv) == "function" and getgenv()) or _G
        local readFn = rawget(_G, "readfile") or genv.readfile or readfile
        if type(readFn) ~= "function" then return nil end

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

    local promptKey = Library.promptKey

    local function checkAuth()
        local okLoad, cachedToken, cachedExp = pcall(loadToken)
        if okLoad and cachedToken and cachedExp then
            State.SessionToken = cachedToken
            State.KeyExpiresAt = cachedExp
            _G.NODT.AuthPassed = true
            return true
        end

        warn("[NodtHub] Autenticação necessária.")
        warn("[NodtHub] Digite sua key na janela e clique em Autenticar.")

        local prompt = promptKey()
        if not prompt then
            warn("[NodtHub] Falha ao criar prompt de key. Abortando.")
            return false
        end
        while true do
            local key = prompt:WaitForKey()
            if not key or #key < 5 then
                prompt:SetError("Key inválida. Verifique e tente novamente.")
            else
                warn("[NodtHub] Validando key...")
                local hwid = getHwid()
                local resp, status = apiRequest("POST", "/api/nodt/verify", { key = key, hwid = hwid })

                if status == 200 and resp and resp.valid == true then
                    State.SessionToken = resp.token or "token_ok"
                    local exp = tonumber(resp.expires_at) or (os.time() + 86400)
                    if exp > 100000000000 then exp = math.floor(exp / 1000) end
                    State.KeyExpiresAt = exp

                    if saveToken(State.SessionToken, State.KeyExpiresAt) then
                        warn("[NodtHub] Key válida! Token salvo com sucesso.")
                    else
                        warn("[NodtHub] Key válida, mas não foi possível salvar o cache.")
                    end

                    prompt:Destroy()
                    _G.NODT.AuthPassed = true
                    return true
                elseif status == nil or (resp == nil and status ~= "Executor sem request HTTP") then
                    -- Rede falhou / servidor offline (apiRequest devolve nil, "<motivo>"). NAO descarta a key digitada.
                    warn("[NodtHub] Falha de rede na validação: " .. tostring(status))
                    prompt:SetError("Servidor offline ou sem conexão. Tente novamente em 30s.")
                elseif status == 429 then
                    -- Rate limit
                    prompt:SetError("Muitas tentativas. Aguarde 1 minuto.")
                else
                    -- Falha real (key invalida, HWID divergente, 400/401/403, etc.)
                    local motivo = (resp and resp.error) or status or "Erro desconhecido"
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

    local okAuth, errAuth = pcall(checkAuth)
    if not okAuth then
        warn("[NodtHub] Erro no checkAuth: " .. tostring(errAuth))
    end
end

if not _G.NODT.AuthPassed then
    pcall(function() Library:Unload() end)
    return
end
-- ============================================================

-- Delta: persiste o script entre teleports
-- ATENCAO: substitua "URL_DO_SCRIPT_RAW" pela URL raw REAL do seu script
-- (ex: GitHub raw, pastebin raw, etc). Enquanto nao for substituida, nao funciona.
if type(queue_on_teleport) == "function" then
    -- fallback em cadeia: URLs 2 e 3 sao placeholders; substitua pelas URLs reais dos fallbacks.
    local urls = {
        "https://nodt-loader.vercel.app/api/script",
        "https://raw.githubusercontent.com/nodt-hub/loader/main/script.lua",
        "https://pastebin.com/raw/nodt-fallback",
    }
    local payload = 'local urls = {' ..
        '"' .. urls[1] .. '",' ..
        '"' .. urls[2] .. '",' ..
        '"' .. urls[3] .. '"' ..
        '} ' ..
        'for _, u in ipairs(urls) do ' ..
        '  local ok, src = pcall(game.HttpGet, game, u) ' ..
        '  if ok and type(src) == "string" and #src > 0 then ' ..
        '    local fn = loadstring and loadstring(src) ' ..
        '    if fn then pcall(fn) return end ' ..
        '  end ' ..
        'end'
    pcall(queue_on_teleport, payload)
end


-- [CORE] Thread identity seguro (Delta)
local function safeGetIdentity()
    if type(getthreadidentity) == "function" then
        local ok, id = pcall(getthreadidentity)
        if ok and type(id) == "number" then return id end
    end
    return nil
end

local function safeSetIdentity(id)
    if type(setthreadidentity) == "function" and id then
        pcall(setthreadidentity, id)
    end
end



-- [CORE] Knit root resolver
local function getKnitRoot()
    local ReplicatedStorage = game:GetService("ReplicatedStorage")

    local restore = safeGetIdentity()
    safeSetIdentity(2)
    local ok, knit = pcall(function()
        return require(ReplicatedStorage.Packages.Knit)
    end)
    safeSetIdentity(restore)
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
                    local restore = safeGetIdentity()
                    safeSetIdentity(2)
                    local loaded, result = pcall(require, module)
                    safeSetIdentity(restore)
                    if loaded and type(result) == "table" and type(result.GetController) == "function" then
                        return result
                    end
                end
            end
        end
    end

    warn("[NodtHub] Knit root nao encontrado")
    if not Core._fsWarned.knitRootMissing then
        Core._fsWarned.knitRootMissing = true
        Library:Notify({ Title = "Nodt Hub", Description = "Knit não encontrado — features de inventário limitadas" })
    end
    return nil
end

-- [CORE] Compatibilidade de executor
local function bootstrapCompatibility()
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local fenv = (pcall(getfenv, 1) and getfenv(1)) or _G

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
            return
        end
        -- so publica se ninguem publicou antes (evita sobrescrever outro hub)
        if not rawget(genv, name) then
            pcall(function()
                genv[name] = value
            end)
        end
        if not rawget(fenv, name) then
            pcall(function()
                fenv[name] = value
            end)
        end
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
        local restore = safeGetIdentity()
        safeSetIdentity(2)
        local fired, firedErr = pcall(fire, signal, ...)
        safeSetIdentity(restore)
        -- devolve a falha pro chamador (pcall + log unico em fireCardRemote/fireNewSpike)
        if not fired then error(firedErr, 0) end
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
        local playerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui", 10)
        if playerGui then gui.Parent = playerGui end
    end)

end

bootstrapCompatibility()

local hookNamecall
local Kisuki -- forward decl: tabela atribuida mais abaixo (Kisuki = { ... }); session.unload usa em runtime
local AutoCounter -- forward decl: AutoCounter IIFE e declarado depois do callback de teleport
local Vault -- forward decl: tabela atribuida mais abaixo; session.unload usa em runtime

do
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local prior = (genv.NODT and genv.NODT.Session) or rawget(genv, "NODT_SESSION") or genv.NODT_SESSION
    local carried = type(prior) == "table" and prior.vault or nil
    if type(prior) == "table" and type(prior.unload) == "function" then
        pcall(prior.unload)
    end
    local session = {}
    session.vault = carried or {}

    -- Central __namecall registry: one real hook on the metatable, any number of
    -- named handlers stacked on top of it. Newest handler runs first (same order
    -- the old per-feature hooks had), unload walks the stack LIFO.
    local hub = { stack = {}, byId = {}, installed = false, dead = false }
    local dispatch

    dispatch = function(level, self, method, ...)
        if type(checkcaller) == "function" and checkcaller() then
            return hub.original(self, ...)
        end
        while level > 0 do
            local entry = hub.stack[level]
            if entry and entry.alive then
                -- handler protegido. 'passed' marca se o handler ja delegou para a
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
        -- handlers fazem namecalls (FindFirstChild, IsA, Raycast...) antes de delegar;
        -- isso sobrescreve o namecall method da thread. Restaura antes do original.
        if type(setnamecallmethod) == "function" then
            pcall(setnamecallmethod, method)
        end
        return hub.original(self, ...)
    end

    -- Fast path: todos os handlers do hub so agem nesses metodos (InvokeServer, Kick,
    -- GetPartsInPart). Qualquer outro namecall do jogo vai direto pro original, sem
    -- closure/pack/pcall por nivel da chain. Handler novo com outro metodo: incluir aqui.
    hub.methods = { InvokeServer = true, Kick = true, GetPartsInPart = true }
    local function central(self, ...)
        local method = getnamecallmethod()
        if not hub.methods[method] then
            return hub.original(self, ...)
        end
        return dispatch(#hub.stack, self, method, ...)
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
                -- rawOriginal guarda o __namecall verdadeiro (para restaurar no unhook);
                -- original e o que o dispatch chama, embrulhado em newcclosure quando suportado.
                hub.rawOriginal = live
                hub.original = live
                if type(newcclosure) == "function" then
                    local wrapOk, wrapped = pcall(newcclosure, live)
                    if wrapOk and type(wrapped) == "function" then
                        hub.original = wrapped
                    end
                end
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
            if not entry.alive then return false end
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
            return true
        end

        hub.stack[entry.index] = entry
        hub.byId[id] = entry
        return entry.release
    end
    session.isHookActive = function(id)
        local entry = hub.byId[id]
        return entry ~= nil and entry.alive == true
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
            local candidate = hub.rawOriginal or hub.original
            local probe = Instance.new("BindableEvent")
            local ok = pcall(function() candidate(probe, "Fire") end)
            probe:Destroy()
            if not ok then
                warn("[NodtHub] Hook anterior inválido; mantendo o hook central em pass-through.")
                hub.rawOriginal = hub.original
                hub.stack = {}
                hub.dead = true
            else
                writeNamecall(hub.mt, candidate)
            end
        end
        hub.installed = false
    end
    session.unload = function()
        if session.unloaded then return end
        session.unloaded = true
        if session.vault then
            if session.vault.wornRelease then pcall(session.vault.wornRelease) end
            session.vault.wornRelease = nil
            session.vault.worn = false
        end
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
        -- N1/X1/Y2: limpa _applied DEPOIS de ui:Unload e links.
        -- Antes, a ordem deixava sweep (task.spawn de CleanupExtras) rodar
        -- depois do clear, mexendo em Vault._applied via Vault.setSlot e
        -- reintroduzindo ids no cache. Agora o clear e o ultimo passo.
        if Vault then
            Vault._applied = {}
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
        if Kisuki and Kisuki.uninstall then
            pcall(Kisuki.uninstall)
        end
        pcall(session.unhook)
    end
    session.links = {}
    session.tags = {}
    genv.NODT = genv.NODT or _G.NODT or {}
    genv.NODT.Session = session
    _G.NODT.Session = session
    -- ALIAS de compatibilidade (remover numa proxima passada quando confirmar que nada mais usa)
    genv.NODT_SESSION = session
end


do
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = (genv.NODT and genv.NODT.Session) or rawget(genv, "NODT_SESSION") or genv.NODT_SESSION
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
do
    local restore = safeGetIdentity()
    safeSetIdentity(2)
    pcall(function()
        local controllers = game:GetService("ReplicatedFirst"):WaitForChild("Controllers", 10)
        local module = controllers and controllers:WaitForChild("AnimationController", 10)
        if module then
            _AC = require(module)
        end
    end)
    safeSetIdentity(restore)
end

local MARK = string.char(math.random(97, 122), math.random(97, 122), math.random(97, 122)) .. tostring(math.random(100000, 999999))
local MARK2 = string.char(math.random(97, 122), math.random(97, 122), math.random(97, 122)) .. tostring(math.random(100000, 999999))

do
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = (genv.NODT and genv.NODT.Session) or rawget(genv, "NODT_SESSION") or genv.NODT_SESSION
    if type(session) == "table" and type(session.tags) == "table" then
        table.insert(session.tags, MARK)
        table.insert(session.tags, MARK2)
    end
end

local function track(connection)
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = (genv.NODT and genv.NODT.Session) or rawget(genv, "NODT_SESSION") or genv.NODT_SESSION
    if type(session) == "table" and type(session.links) == "table" then
        table.insert(session.links, connection)
    end
    return connection
end

-- ============================================================
-- Estado agrupado em tabelas: o Luau limita 200 locals no escopo raiz.
-- Cada variavel solta virou campo (ex.: HitboxState.hitboxEnabled).
-- ============================================================
-- Hitbox: estado e hooks
local HitboxState = {
    hitboxEnabled = false,
    hitboxScale = 5.0,
    hitboxReach = 5.0,
    hitboxHooked = false,
    hitboxFollow = nil,
    hitboxColor = Color3.fromRGB(0, 0, 255),
    hitboxTransparency = 0.3,
    hitboxBoxes = {},
    -- cache de BaseParts do character usado por reachableBall (ver getCharParts)
    charPartsCache = nil,           -- {character = Instance, parts = {BasePart, ...}, hits = 0, misses = 0, at = os.clock()}
    charPartsCacheDisabled = false, -- set true se fallback disparar N vezes
    charPartsCacheTTL = 1,          -- refresh periodico (s): limita staleness de parts que chegam/saem depois do build
    -- a invalidacao primaria e por cache.character ~= character
    -- o reset explicito em clearCharacterVisuals (CharacterAdded) e cinto-e-suspensorios
}

-- Flags de instalacao de hooks
local HookState = {
    redirectSpikeInstalled = false,
    sanjuTiltInstalled = false,
    maxChargeHookActive = false,
    autoRejoinInstalled = false,
    autoSetAimInstalled = false,
    maxServeHookActive = false,
}

-- Botoes flutuantes / labels da UI
local ButtonState = {
    newSpikeButton = nil,
    stopBallButton = nil,
    aimButton = nil,
    stopBallVisible = false,
    aimVisible = false,
    dashButton = nil,
    leadFeetButton = nil,
    leadFeetLink = nil,
}

-- Conexoes, threads e movimento
local MovementState = {
    desyncConnection = nil,
    autoBlockConnection = nil,
    autoReceiveConn = nil,
    bodyVelocity = nil,
    shiftLockConnection = nil,
    floorMaterialConnection = nil,
    stateChangedConnection = nil,
    autoSpikeConn = nil,
    autoSpikeLastFire = 0,
    antiAfkConnection = nil,
    autoReadyThread = nil,
}

-- Trajetoria do spike
local TrajectoryState = {
    trajectoryBeam = nil,
    trajectoryAttach0 = nil,
    trajectoryAttach1 = nil,
    trajectoryPart = nil,
}

-- ESP, clones e linhas
local VisualState = {
    linesConn = nil,
    espHighlights = {},
    espConnections = {},
    originals = setmetatable({}, { __mode = "k" }),
    clones = setmetatable({}, { __mode = "k" }),
    seen = {},
    linesEnabled = false,
    lines = {},
}

-- Cards, jerseys, skins e efeitos de hit
local CardState = {
    hitEffectEnabled = false,
    hasFired = false,
    isLocalHit = false,
    hitConnection = nil,
    hitRemovedConnection = nil,
    playerCardEnabled = false,
    hasFiredCard = false,
    isProcessing = false,
    cardConnection = nil,
    cardList = {},
    pickedTeam = nil,
    jerseyList = {},
    ballSkinList = {},
    desiredStyles = {},
    desiredAbilities = {},
    sweepBusy = false,
}

-- Anti-lag
local AntiLagState = {
    enabled = false,
    changedProperties = setmetatable({}, { __mode = "k" }),
    oldQualityLevel = nil,
    oldSavedQualityLevel = nil,
    antilagConnections = {},
}

-- Cache de modulos do jogo / habilidades
local ServiceCache = {
    _BallController = nil,
    _Physics = nil,
    _GameHandlers = nil,
    _GameConfig = nil,
    _State = nil,
    _lastCacheAttempt = 0,
    _LeadFeetAbility = nil,
    _EffectModule = nil,
    _JumpAction = nil,
}

-- Remotes do Knit (preenchidos mais abaixo)
local Remotes = {
    BallService = nil,
    Serve = nil,
    EffectsRemote = nil,
    doMove = nil,
    GameEffectRemote = nil,
    HitGround = nil,
    Interact = nil,
}

-- [CORE] Features: hitbox, spike, movement, visuals, vault
local SpikeReach = { reach = 300.0, expiry = 0 }

State.redirectSpikeEnabled = false
State.sanjuTiltEnabled = false
State.maxChargeEnabled = false
State.newSilentSpikeEnabled = false
State.akariDashEnabled = false
State.leadFeetEnabled = false
State.espJumpEnabled = false
State.desyncEnabled = false
State.autoBlockEnabled = false
State.autoSaveRunning = false
State.autoSetAimEnabled = false
State.crosshairEnabled = false
State.spikeTrajectoryEnabled = false
State.crosshairSize = 6
State.crosshairColor = Color3.fromRGB(255, 255, 255)
State.fpsUnlockEnabled = false
State.autoRejoinEnabled = false
State.autoReadyEnabled = false
State.autoSaveEnabled = false
State.lastSaveState = nil
State.autoSpikeEnabled = false
State.autoSpikeAim = false
State.akariDashMultiplier = 1.0
State.lineAimMode = false
State.autoReceiveEnabled = false
local Receive = { range = 10, lead = 0.35, stamp = 0, gap = 0.2, only_closest = false, ping_comp = 0 }

-- Servicos/modulos usados em callbacks de frame: carregar uma vez e tentar novamente no maximo a cada segundo.

local function getCachedServices()
    if ServiceCache._fullyCached then return true end
    if ServiceCache._BallController and ServiceCache._Physics and ServiceCache._GameHandlers and ServiceCache._GameConfig and ServiceCache._State then
        ServiceCache._fullyCached = true
        return true
    end
    local now = os.clock()
    if now - ServiceCache._lastCacheAttempt < 1 then
        return false
    end
    ServiceCache._lastCacheAttempt = now

    if not ServiceCache._BallController then
        local Knit = getKnitRoot()
        if Knit then
            pcall(function()
                ServiceCache._BallController = Knit.GetController("BallController")
            end)
        end
    end
    if not ServiceCache._GameHandlers then
        local restore = safeGetIdentity()
        safeSetIdentity(2)
        pcall(function()
            ServiceCache._GameHandlers = require(game:GetService("ReplicatedFirst").Controllers.GameController.Handlers)
        end)
        safeSetIdentity(restore)
    end
    if not ServiceCache._Physics then
        local restore = safeGetIdentity()
        safeSetIdentity(2)
        pcall(function()
            ServiceCache._Physics = require(ReplicatedStorage.Common.Physics)
        end)
        safeSetIdentity(restore)
    end
    if not ServiceCache._GameConfig then
        local restore = safeGetIdentity()
        safeSetIdentity(2)
        pcall(function()
            ServiceCache._GameConfig = require(ReplicatedStorage.Configuration.Game)
        end)
        safeSetIdentity(restore)
    end
    if not ServiceCache._State then
        local restore = safeGetIdentity()
        safeSetIdentity(2)
        pcall(function()
            ServiceCache._State = require(ReplicatedStorage.Common.State)
        end)
        safeSetIdentity(restore)
    end
    local allReady = ServiceCache._BallController ~= nil and ServiceCache._Physics ~= nil
        and ServiceCache._GameHandlers ~= nil and ServiceCache._GameConfig ~= nil
        and ServiceCache._State ~= nil
    if allReady then ServiceCache._fullyCached = true end
    return ServiceCache._BallController ~= nil or ServiceCache._Physics ~= nil or ServiceCache._GameHandlers ~= nil
        or ServiceCache._GameConfig ~= nil or ServiceCache._State ~= nil
end
State.maxServeEnabled = false
State.airMovement = false
State.airMovementSpeed = 16
State.autoShiftLockEnabled = false
State.selectedEffect = "SupernovaScoreEffect"
State.selectedCard = "UltimateChampionPlayerCard"
State.selectedJersey = "DragonTuxedoJersey"
State.selectedBallSkin = "ClassicBall"
State.autoSpin = false
State.autoAbilitySpin = false
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

local function clearCharacterVisuals()
    for model, holder in pairs(VisualState.clones) do
        if holder and holder.Destroy then pcall(holder.Destroy, holder) end
        VisualState.clones[model] = nil
    end
    VisualState.clones = setmetatable({}, { __mode = "k" })
    for player, highlight in pairs(VisualState.espHighlights) do
        if highlight and highlight.Destroy then pcall(highlight.Destroy, highlight) end
        VisualState.espHighlights[player] = nil
    end
    VisualState.espHighlights = {}
    HitboxState.charPartsCache = nil
end

track(LocalPlayer.CharacterAdded:Connect(function()
    VisualState.seen.__controls = nil
    clearCharacterVisuals()
end))

-- Reset do cache de servicos em teleport (o Knit recria controllers no novo servidor)
if LocalPlayer.OnTeleport then
    track(LocalPlayer.OnTeleport:Connect(function(status)
        if status == Enum.TeleportState.Started then
            if type(AutoCounter) == "table" and AutoCounter.reset then AutoCounter.reset() end
            if Kisuki and Kisuki.reset then Kisuki.reset() end
            ServiceCache._fullyCached = nil
            ServiceCache._BallController = nil
            ServiceCache._Physics = nil
            ServiceCache._GameHandlers = nil
            ServiceCache._GameConfig = nil
            ServiceCache._State = nil
            ServiceCache._lastCacheAttempt = 0
        end
    end))
end

State.lineDistance = 50
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

do
    -- BallService (tabela da API do Knit) continua vindo do GetService; os remotes reais vem do no do Knit.
    local KnitRoot = getKnitRoot()
    if KnitRoot and type(KnitRoot.GetService) == "function" then
        local okBall, ball = pcall(KnitRoot.GetService, "BallService")
        if okBall then Remotes.BallService = ball end
    end
    local KnitNode = getKnitNode()
    local BallServiceNode = KnitNode and KnitNode:FindFirstChild("Services") and KnitNode.Services:FindFirstChild("BallService")
    local GameServiceNode = KnitNode and KnitNode:FindFirstChild("Services") and KnitNode.Services:FindFirstChild("GameService")

    Remotes.HitGround = BallServiceNode and BallServiceNode:FindFirstChild("RE") and BallServiceNode.RE:FindFirstChild("HitGround")
    Remotes.EffectsRemote = BallServiceNode and BallServiceNode:FindFirstChild("RE") and BallServiceNode.RE:FindFirstChild("Effects")
    Remotes.doMove = BallServiceNode and BallServiceNode:FindFirstChild("RE") and BallServiceNode.RE:FindFirstChild(NET.K.DOMOVE)
    Remotes.Interact = BallServiceNode and BallServiceNode:FindFirstChild("RF") and BallServiceNode.RF:FindFirstChild(NET.K.INTERACT)
    Remotes.Serve = GameServiceNode and GameServiceNode:FindFirstChild("RF") and GameServiceNode.RF:FindFirstChild("Serve")
    Remotes.GameEffectRemote = GameServiceNode and GameServiceNode:FindFirstChild("RE") and GameServiceNode.RE:FindFirstChild("Effect")
    if not Remotes.BallService then
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
        local KnitNode = getKnitNode()
        if KnitNode then
            local services = KnitNode:FindFirstChild("Services")
            local found = services and services:FindFirstChild(serviceName)
            if found then return found end
        end

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
        if not Remotes.BallService then return callNext(self, method, ...) end
        if self == Remotes.Interact and method == NET.K.INVOKE then
            NET.pace(self)
            local data = (...)
            if type(data) == "table" and data.Move == NET.K.SPIKE then
                if State.tshAnimationEnabled and firesignal and LocalPlayer and LocalPlayer.Character then
                    pcall(function()
                        firesignal(Remotes.EffectsRemote.OnClientEvent, {
                            ["Character"] = LocalPlayer.Character,
                            ["Sound"] = "PowerSpike",
                            ["Effect"] = "SpecialChargeSpikeVFX",
                        })
                    end)
                elseif State.hidariAnimationEnabled and firesignal and LocalPlayer and LocalPlayer.Character then
                    pcall(function()
                        firesignal(Remotes.EffectsRemote.OnClientEvent, {
                            ["Character"] = LocalPlayer.Character,
                            ["Sound"] = "PowerSpike",
                            ["Effect"] = "HidariSpikeVFX",
                        })
                    end)
                end
            end
            return NET.callCritical(callNext, self, method, data)
        end
        return callNext(self, method, ...)
    end)
end

-- (Removido o installSpikeEffectHook() incondicional do boot. Ele sera instalado
-- apenas quando State.tshAnimationEnabled ou State.hidariAnimationEnabled forem ligados.)

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
    local pg = player:FindFirstChildOfClass("PlayerGui")
    local gui = pg and pg:FindFirstChild("Interface")
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
    -- Debounce: em vez de task.wait(0.1) por item (que acumula 1s de lag se 10
    -- notificacoes chegam no mesmo frame), acumula os itens e processa em lote
    -- com cooldown de 0.2s.
    NODT.NotifPending = NODT.NotifPending or {}
    NODT.NotifPendingLabels = NODT.NotifPendingLabels or {}
    local flushing = false
    local function flushNotifs()
        if flushing then return end
        flushing = true
        task.defer(function()
            local pending = NODT.NotifPending
            local labels = NODT.NotifPendingLabels
            NODT.NotifPending = {}
            NODT.NotifPendingLabels = {}
            task.wait(0.1)
            local player = LocalPlayer
            if player then
                for _, notif in ipairs(pending) do
                    pcall(processNotification, notif)
                end
                for _, lbl in ipairs(labels) do
                    if lbl.Parent and lbl:IsA("TextLabel") then
                        local text = lbl.Text or ""
                        if CardProtect.hasWord(text, player.Name) then
                            lbl.Text = CardProtect.replaceWord(text, player.Name, NODT.NameTag)
                        end
                    end
                end
            end
            flushing = false
            if #(NODT.NotifPending) > 0 or #(NODT.NotifPendingLabels) > 0 then
                flushNotifs()
            end
        end)
    end
    NODT.NotifConn = gui.ChildAdded:Connect(function(child)
        table.insert(NODT.NotifPending, child)
        flushNotifs()
    end)
    NODT.NotifConn2 = gui.DescendantAdded:Connect(function(child)
        if child:IsA("TextLabel") then
            table.insert(NODT.NotifPendingLabels, child)
            flushNotifs()
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
function CardProtect.dropCache()
    if CardProtect.cacheConn then
        pcall(function() CardProtect.cacheConn:Disconnect() end)
        CardProtect.cacheConn = nil
    end
    CardProtect.cacheFrame = nil
    CardProtect.cacheLabels = nil
    CardProtect.cacheDirty = false
end

function CardProtect.loop()
    if not CardProtect.enabled then return end
    if not CardProtect.isActive() then return end
    local flashFrame = CardProtect.findFrame()
    if not flashFrame then
        if CardProtect.cacheFrame then CardProtect.dropCache() end
        return
    end
    if CardProtect.cacheFrame ~= flashFrame then
        CardProtect.dropCache()
        CardProtect.cacheFrame = flashFrame
        CardProtect.cacheDirty = true
        CardProtect.cacheConn = flashFrame.DescendantAdded:Connect(function()
            CardProtect.cacheDirty = true
        end)
    end
    -- Skip cedo: se a cache ja foi montada, nada mudou no frame, e nenhum label
    -- esta com o nome "errado", nao precisa re-varrer. Isso derruba o custo do
    -- loop de N * classify por tick para N = 0 na maioria dos ticks.
    if not CardProtect.cacheDirty and CardProtect.cacheLabels then
        local nameTag = NODT.NameTag
        local needsWork = false
        for _, label in ipairs(CardProtect.cacheLabels) do
            if label.Parent and label.Text ~= nameTag and CardProtect.classify(label) == true then
                needsWork = true
                break
            end
        end
        if not needsWork then return end
    end
    if CardProtect.cacheDirty then
        CardProtect.cacheDirty = false
        local list = {}
        for _, label in ipairs(flashFrame:GetDescendants()) do
            if label.Name == "Username" and label:IsA("TextLabel") then
                list[#list + 1] = label
            end
        end
        CardProtect.cacheLabels = list
    end
    local nameTag = NODT.NameTag
    for _, label in ipairs(CardProtect.cacheLabels) do
        if label.Parent and CardProtect.classify(label) == true and label.Text ~= nameTag then
            label.Text = nameTag
        end
    end
end

function CardProtect.stop()
    CardProtect.dropCache()
    if CardProtect.bound then
        CardProtect.bound = false
        pcall(RunService.UnbindFromRenderStep, RunService, CardProtect.bindName)
    end
    if CardProtect.heartbeatConn then
        pcall(function() CardProtect.heartbeatConn:Disconnect() end)
        CardProtect.heartbeatConn = nil
    end
end

function CardProtect.start()
    local HEARTBEAT_INTERVAL = 0.1
    if CardProtect.bound then return end
    -- Remove qualquer bind com o mesmo nome deixado por uma execucao anterior.
    pcall(RunService.UnbindFromRenderStep, RunService, CardProtect.bindName)
    -- Heartbeat com throttle de 0.1s: Card Protect nao precisa rodar 60fps.
    -- 10fps e suficiente pra pegar o FlashPlayerCardFrame aparecendo.
    local lastTick = 0
    CardProtect.heartbeatConn = RunService.Heartbeat:Connect(function()
        if Library.Unloaded or not CardProtect.enabled then
            CardProtect.stop()
            return
        end
        local now = os.clock()
        if now - lastTick < HEARTBEAT_INTERVAL then return end
        lastTick = now
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
function CardProtect.markNewFrame(previous, timeout)
    local deadline = os.clock() + (timeout or 0.6)
    repeat
        if Library.Unloaded then return nil end
        local frame = CardProtect.findFrame()
        if frame and frame ~= previous then
            CardProtect.ours[frame] = true
            return frame
        end
        task.wait(0.05)
    until os.clock() > deadline
    return nil
end

local function fireCardRemote()
    if CardState.hasFiredCard or CardState.isProcessing or Library.Unloaded then return end
    local PlayerCardService = getPackageService("PlayerCardService")
    local Remote = PlayerCardService and getServiceChild(PlayerCardService, "RE", "OnFlashCard")
    if not Remote then
        warn("[NodtHub] service not found")
        if not Core._fsWarned.cardRemoteMissing then
            Core._fsWarned.cardRemoteMissing = true
            Library:Notify({ Title = "Nodt Hub", Description = "PlayerCardService não encontrado — Player Card desabilitado" })
        end
        return
    end
    if Remote and firesignal then
        CardState.isProcessing = true
        CardState.hasFiredCard = true
        -- pcall garante que as flags sempre sao liberadas, mesmo se algo der erro no meio.
        pcall(function()
            local before = CardProtect.findFrame()
            -- Abre a janela em que o frame que aparecer e considerado o nosso.
            CardProtect.expectUntil = os.clock() + CardProtect.lateWindow
            local fsOk = pcall(firesignal, Remote.OnClientEvent, {
                ["PlayerCardItemId"] = State.selectedCard,
                ["Context"] = {
                    ["Custom"] = {},
                    ["PlacementId"] = "ScoredPoint",
                },
                ["Player"] = LocalPlayer,
            })
            if not fsOk and not Core._fsWarned.fireCardRemote then
                Core._fsWarned.fireCardRemote = true
                warn("[NodtHub] firesignal falhou em fireCardRemote")
            end
            local shown = CardProtect.markNewFrame(before, 0.6)
            CardProtect.expectUntil = 0
            task.wait(0.3)
        end)
        CardState.hasFiredCard = false
        CardState.isProcessing = false
    end
end

-- Chamada pelo toggle "Card Protect": aplica o card na hora, sem precisar do botao Apply.
-- Se ja houver um disparo em andamento, espera ele terminar (ate 3s) antes de disparar.
function CardProtect.forceApply()
    task.spawn(function()
        -- #3: se nao ha processing ativo, dispara imediato. Se ha, espera curto
        -- (0.8s) em vez de 3s. Em hit rapido com multi-hit, 3s travava a fila.
        local deadline = os.clock() + 0.8
        while (CardState.isProcessing or CardState.hasFiredCard) and os.clock() < deadline and not Library.Unloaded do
            task.wait(0.05)
        end
        if Library.Unloaded or not CardProtect.enabled then return end
        pcall(fireCardRemote)
    end)
end

-- Trata um frame novo do jogo. Nao descarta o evento: se outro disparo esta em
-- andamento, espera ele terminar e so depois decide.
local function changePlayerCard(frame)
    if Library.Unloaded or not CardState.playerCardEnabled then return end
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

    while (CardState.isProcessing or CardProtect.swapping) and frame.Parent do
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
    if CardState.cardConnection then
        pcall(function()
            CardState.cardConnection:Disconnect()
        end)
        CardState.cardConnection = nil
    end
    CardProtect.attachedTo = nil
    disconnectList(CardProtect.guiConns)
end

-- Conecta o ChildAdded em uma pasta Persistent e vigia se ela (ou a Interface) for destruida.
function CardProtect.attach(persistent)
    if Library.Unloaded or not CardProtect.listening or not persistent then return end
    if CardProtect.attachedTo == persistent and CardState.cardConnection and CardState.cardConnection.Connected then
        return
    end
    CardProtect.detach()
    CardProtect.attachedTo = persistent
    CardState.cardConnection = track(persistent.ChildAdded:Connect(CardProtect.onChild))

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
    if not CardState.playerCardEnabled then return end
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
    if CardState.cardConnection and CardState.cardConnection.Connected then return end
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
        -- Executado pelo session.unload para soltar todos os listeners do Player Card.
        CardProtect.stop()
        pcall(disablePlayerCard)
    end,
})

_G.NODT.PlayerCard = {
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
        if NODT.NotifConn then
            pcall(function() NODT.NotifConn:Disconnect() end)
            NODT.NotifConn = nil
        end
        if NODT.NotifConn2 then
            pcall(function() NODT.NotifConn2:Disconnect() end)
            NODT.NotifConn2 = nil
        end
        NODT.NotifPending = nil
        NODT.NotifPendingLabels = nil
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

local function getCharParts(character)
    if HitboxState.charPartsCacheDisabled then
        local parts = {}
        for _, piece in ipairs(character:GetChildren()) do
            if piece:IsA("BasePart") then parts[#parts + 1] = piece end
        end
        return parts
    end
    local now = os.clock()
    local cache = HitboxState.charPartsCache
    if not cache or cache.character ~= character then
        local parts = {}
        for _, piece in ipairs(character:GetChildren()) do
            if piece:IsA("BasePart") then parts[#parts + 1] = piece end
        end
        HitboxState.charPartsCache = { character = character, parts = parts, hits = 0, misses = 0, at = now }
        return parts
    end
    -- stale safety: se o character ainda e o mesmo mas os parts viraram orfaos (ex: destruicao
    -- massiva sem CharacterAdded), ou o cache ficou vazio, ou passou o TTL, refaz o scan.
    local alive = 0
    for i = 1, #cache.parts do
        if cache.parts[i].Parent then alive = alive + 1 end
    end
    -- TTL de 1s + scan vazio detectam cache podre (parts carregadas depois, accessory destruction)
    if alive == 0 or now - cache.at >= HitboxState.charPartsCacheTTL then
        local misses = cache.misses
        if alive == 0 and #cache.parts > 0 then
            -- tinha parts e todos morreram: cache podre. Conta o miss (carregado para o cache novo)
            misses = misses + 1
            if misses >= 3 then
                HitboxState.charPartsCacheDisabled = true
                if not Core._fsWarned.hitboxCharPartsCacheDisabled then
                    Core._fsWarned.hitboxCharPartsCacheDisabled = true
                    warn("[NodtHub] hitbox: cache de charParts desativado apos 3 scans podres")
                    if Library and Library.Notify then
                        Library:Notify({ Title = "Nodt Hub", Description = "Hitbox: cache degradado, performance reduzida" })
                    end
                end
                if not Core._fsWarned.hitboxCacheStale then
                    Core._fsWarned.hitboxCacheStale = true
                    warn("[NodtHub] hitboxCache degradou (comportamento volta ao original)")
                end
            end
        end
        local parts = {}
        for _, piece in ipairs(character:GetChildren()) do
            if piece:IsA("BasePart") then parts[#parts + 1] = piece end
        end
        HitboxState.charPartsCache = { character = character, parts = parts, hits = cache.hits, misses = misses, at = now }
        return parts
    end
    cache.hits = cache.hits + 1
    return cache.parts
end

local function reachableBall(params, character, reach)
    if not character then return nil end
    local closest, shortest = nil, reach or HitboxState.hitboxReach
    local charParts = getCharParts(character)
    for _, model in ipairs(params.FilterDescendantsInstances) do
        if model:IsA("Model") then
            local driver = model.PrimaryPart or findFirstPart(model)
            if driver then
                for i = 1, #charParts do
                    local piece = charParts[i]
                    if piece.Parent then
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
    if HitboxState.hitboxHooked then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("hitbox", function(callNext, self, method, ...)
        if self == Workspace and method == "GetPartsInPart" then
            local spiking = SpikeReach.expiry > os.clock()
            if HitboxState.hitboxEnabled or spiking then
                local probe, params = ...
                if typeof(probe) == "Instance" and typeof(params) == "OverlapParams"
                    and params.FilterType == Enum.RaycastFilterType.Include then
                    local results = callNext(self, method, probe, params)
                    if type(results) == "table" and not results[1] then
                        local driver = reachableBall(params, LocalPlayer.Character, HitboxState.hitboxEnabled and SpikeReach.reach or HitboxState.hitboxReach)
                        if not driver and spiking and not Core._fsWarned.hitboxReachable then
                            Core._fsWarned.hitboxReachable = true
                            warn("[NodtHub] hitbox: reachableBall retornou nil com spiking ativo")
                        end
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
        HitboxState.hitboxHooked = true
    elseif not Core._fsWarned.hitboxHookInstall then
        Core._fsWarned.hitboxHookInstall = true
        warn("[NodtHub] hitbox: hookNamecall retornou nil (executor sem getrawmetatable?)")
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
    if HitboxState.hitboxFollow then return end
    local missCount = 0
    HitboxState.hitboxFollow = track(RunService.RenderStepped:Connect(function()
        if next(HitboxState.hitboxBoxes) == nil then return end
        for driver, shell in pairs(HitboxState.hitboxBoxes) do
            if driver.Parent and shell.Parent then
                missCount = 0
                local cf = driver.CFrame
                if shell.CFrame ~= cf then
                    shell.CFrame = cf
                end
            else
                missCount = missCount + 1
                if missCount >= 5 and not Core._fsWarned.hitboxFollowMiss then
                    Core._fsWarned.hitboxFollowMiss = true
                    warn("[NodtHub] hitbox follow: 5+ shells órfãos detectados")
                end
            end
        end
    end))
end

local function updateHitboxes(scale)
    if not HitboxState.hitboxEnabled then return end
    HitboxState.hitboxReach = scale or HitboxState.hitboxReach
    installHitboxHook()
    installHitboxFollow()
    local folder = adornHolder()
    local live = {}
    for _, model in ipairs(ballModels()) do
        local driver = model.PrimaryPart or findFirstPart(model)
        if driver then
            live[driver] = true
            local shell = HitboxState.hitboxBoxes[driver]
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
                HitboxState.hitboxBoxes[driver] = shell
            end
            shell.Size = Vector3.new(2, 2, 2) * HitboxState.hitboxReach
            shell.CFrame = driver.CFrame
            shell.Color = HitboxState.hitboxColor
            shell.Transparency = HitboxState.hitboxTransparency
        end
    end
    for driver, shell in pairs(HitboxState.hitboxBoxes) do
        if not live[driver] then
            if shell.Parent then
                shell:Destroy()
            end
            HitboxState.hitboxBoxes[driver] = nil
        end
    end
    if next(HitboxState.hitboxBoxes) == nil and HitboxState.hitboxFollow then
        HitboxState.hitboxFollow:Disconnect()
        HitboxState.hitboxFollow = nil
    end
end

local function removeHitboxes()
    if HitboxState.hitboxFollow then
        HitboxState.hitboxFollow:Disconnect()
        HitboxState.hitboxFollow = nil
    end
    for driver, shell in pairs(HitboxState.hitboxBoxes) do
        if shell.Parent then
            shell:Destroy()
        end
        HitboxState.hitboxBoxes[driver] = nil
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
        if HitboxState.hitboxEnabled and child.Parent then
            updateHitboxes(HitboxState.hitboxScale)
        end
    end
end))

if HitboxState.hitboxEnabled then
    updateHitboxes(HitboxState.hitboxScale)
end

local function removeLine(player)
    local data = VisualState.lines[player]
    if data then
        pcall(function()
            if data.beam then data.beam:Destroy() end
        end)
        pcall(function()
            if data.target then data.target:Destroy() end
        end)
        pcall(function()
            if data.attachment then data.attachment:Destroy() end
        end)
        VisualState.lines[player] = nil
    end
end

local function updateLine(player, index)
    if not VisualState.linesEnabled then
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

    -- Se attachment/target morreram (respawn/morte), limpa e recria do zero
    local data = VisualState.lines[player]
    if data then
        local attOk = data.attachment and data.attachment.Parent and data.attachment:IsDescendantOf(Workspace)
        local tgtOk = data.target and data.target.Parent and data.target:IsDescendantOf(Workspace)
        if not attOk or not tgtOk then
            removeLine(player)
            data = nil
        end
    end

    if not VisualState.lines[player] then
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
        VisualState.lines[player] = { beam = beam, target = target, attachment = attachment }
    end
    data = VisualState.lines[player]
    local camera = Workspace.CurrentCamera
    local lookVector = State.lineAimMode and player == LocalPlayer and camera
        and camera.CFrame.LookVector or rootPart.CFrame.LookVector
    data.target.Position = head.Position + lookVector * State.lineDistance
end

local linesLastRun = 0
local function linesHeartbeatStep()
    if not VisualState.linesEnabled then
        if next(VisualState.lines) ~= nil then
            for player in pairs(VisualState.lines) do removeLine(player) end
        end
        return
    end
    local now = os.clock()
    if now - linesLastRun < 0.05 then return end
    linesLastRun = now
    if State.lineAimMode then
        updateLine(LocalPlayer, 1)
        for player in pairs(VisualState.lines) do
            if player ~= LocalPlayer then removeLine(player) end
        end
        return
    end
    for index, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Team ~= LocalPlayer.Team then
            updateLine(player, index)
        else
            removeLine(player)
        end
    end
end

track(Players.PlayerRemoving:Connect(removeLine))

-- Limpa beams fantasmas no respawn do LocalPlayer
track(LocalPlayer.CharacterAdded:Connect(function()
    for player in pairs(VisualState.lines) do
        removeLine(player)
    end
end))

_G.NODT.Lines = {
    SetEnabled = function(value)
        VisualState.linesEnabled = value
        if not value then
            if VisualState.linesConn then
                VisualState.linesConn:Disconnect()
                VisualState.linesConn = nil
            end
            for player in pairs(VisualState.lines) do
                removeLine(player)
            end
        elseif not VisualState.linesConn then
            VisualState.linesConn = track(RunService.Heartbeat:Connect(linesHeartbeatStep))
        end
    end,
    SetDistance = function(value)
        State.lineDistance = value
    end,
    IsEnabled = function()
        return VisualState.linesEnabled
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
    -- Cache orientado a eventos: modelos CLIENT_BALL_* entram/saem por ChildAdded/ChildRemoved
    -- e a 1a BasePart de cada um e resolvida uma vez. Um rescan lento (2s) cobre renomeacoes tardias.
    local _models = {}
    local _hooked = false
    local _rescanTime = 0

    local function consider(child)
        local name = child.Name
        if string.sub(name, 1, 12) == "CLIENT_BALL_" and child:IsA("Model") and string.match(name, "^CLIENT_BALL_%d+$") then
            if _models[child] == nil then
                _models[child] = false
            end
        end
    end

    local function hook()
        if _hooked then return end
        _hooked = true
        for _, child in ipairs(Workspace:GetChildren()) do
            consider(child)
        end
        track(Workspace.ChildAdded:Connect(consider))
        track(Workspace.ChildRemoved:Connect(function(child)
            _models[child] = nil
        end))
    end

    local _cache = { at = 0, ball = nil, dist = nil, rootPos = nil }
    getNearestBall = function()
        if Library.Unloaded then return nil, nil end
        local now = os.clock()
        local character = LocalPlayer.Character
        if not character then return nil, nil end
        local rootPart = character:FindFirstChild("HumanoidRootPart")
        if not rootPart then return nil, nil end
        if _cache.ball and _cache.rootPos == rootPart.Position
            and (now - _cache.at) < 0.016 and _cache.ball.Parent then
            return _cache.ball, _cache.dist
        end
        hook()
        if now - _rescanTime > 2 then
            _rescanTime = now
            -- remove órfãos: model renomeado ou destruído sem ChildRemoved
            for model in pairs(_models) do
                if not model.Parent or not string.match(model.Name, "^CLIENT_BALL_%d+$") then
                    _models[model] = nil
                end
            end
            for _, child in ipairs(Workspace:GetChildren()) do
                consider(child)
            end
        end
        local nearestBall = nil
        local nearestDistance = math.huge
        local rootPos = rootPart.Position
        for model, part in pairs(_models) do
            if model.Parent == nil then
                _models[model] = nil
            else
                if not part or not part.Parent then
                    part = false
                    for _, descendant in ipairs(model:GetDescendants()) do
                        if descendant:IsA("BasePart") then
                            part = descendant
                            break
                        end
                    end
                    _models[model] = part
                end
                if part then
                    local distance = (part.Position - rootPos).Magnitude
                    if distance < nearestDistance then
                        nearestDistance = distance
                        nearestBall = part
                    end
                end
            end
        end
        _cache.at, _cache.ball, _cache.dist, _cache.rootPos = now, nearestBall, nearestDistance, rootPos
        return nearestBall, nearestDistance
    end
end

local function ballDrift(part)
    getCachedServices()
    local controller = ServiceCache._BallController
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
    local dt = now - (when or 0)
    if same and spot and dt <= 0.001 then return Vector3.zero end
    if same and spot then
        return (part.Position - spot) / dt
    end
    return Vector3.zero
end

local getNearestTeammate

local function autoReceive()
    -- Limites (studs / segundos).
    local BASE_RADIUS = Receive.range or 5      -- raio minimo de pegada
    local SPEED_FACTOR = 0.18   -- raio = BASE_RADIUS + velocidade da bola * SPEED_FACTOR
    local MAX_RADIUS = 55      -- teto de seguranca para o raio dinamico
    local RELEASE_RANGE = 15   -- bola alem disso libera a trava
    local LOCK_TIME = 1.8        -- segundos maximos de trava apos o disparo

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

    if Receive.only_closest then
        local nearest = getNearestTeammate()
        if nearest and nearest.Character and nearest.Character:FindFirstChild("HumanoidRootPart") then
            local myDist = (ball.Position - rootPart.Position).Magnitude
            local allyDist = (ball.Position - nearest.Character.HumanoidRootPart.Position).Magnitude
            if allyDist < myDist then return end
        end
    end

    -- Raio dinamico (anti-tunneling): quanto mais rapida a bola, maior o raio.
    -- Usa o maior entre a velocidade fisica e a velocidade registrada pelo controller da bola.
    local speed = math.max(ball.AssemblyLinearVelocity.Magnitude, ballDrift(ball).Magnitude)
    local radius = math.min(BASE_RADIUS + speed * SPEED_FACTOR, MAX_RADIUS)

    -- Hitbox ativa: soma o alcance configurado no slider (hitboxReach) ao raio de recepcao.
    -- Somado DEPOIS do teto, para o teto de seguranca nao "comer" o valor da hitbox.
    -- Hitbox desligada: o raio fica exatamente como era.
    if HitboxState.hitboxEnabled then
        radius = radius + HitboxState.hitboxReach
    end

    local ballAhead = ball.Position + ball.AssemblyLinearVelocity * ((Receive.lead or 0) + (Receive.ping_comp or 0))
    local distance = (ballAhead - rootPart.Position).Magnitude
    if distance >= radius then return end

    getCachedServices()
    local handlers = ServiceCache._GameHandlers
    if type(handlers) == "table" and handlers.States then
        local states = handlers.States
        if states.IsBusy:get() or states.IsServing:get() or not states.IsPlaying:get() then
            return
        end
        Receive._handlersMiss = nil
    elseif not Receive._handlersMiss then
        Receive._handlersMiss = os.clock()
        return
    elseif os.clock() - Receive._handlersMiss < 0.5 then
        return
    end

    if firesignal then
        -- Trava ativada antes do disparo para impedir qualquer Set duplicado.
        Receive.locked = true
        Receive.stamp = now
        -- Com raio dinamico > 15, a trava so pode soltar por distancia depois que a bola passar do raio.
        Receive.releaseRange = math.max(RELEASE_RANGE, radius + 5)
        local setOk = pcall(function() firesignal(Remotes.doMove.OnClientEvent, "Set", false, false) end)
        if not setOk and not Core._fsWarned.autoReceiveSet then
            Core._fsWarned.autoReceiveSet = true
            warn("[NodtHub] firesignal falhou em autoReceive (Set)")
        end
    end
end

local autoReceiveLastRun = 0
local function autoReceiveHeartbeatStep()
    if not State.autoReceiveEnabled then return end
    local now = os.clock()
    if now - autoReceiveLastRun < 0.016 then return end
    autoReceiveLastRun = now
    autoReceive()
end

local enemyAim

local function autoSpikeStep()
    local MIN_HEIGHT_ABOVE_ROOT = 3  -- bola abaixo disso (relativo ao root) nao e spike
    local MAX_DISTANCE = 12          -- longe demais para spike
    local MIN_DISTANCE = 2           -- colada, provavelmente ja tocou
    local COOLDOWN = 0.5             -- segundos entre spikes automaticos
    if not State.autoSpikeEnabled then return end
    if Library.Unloaded then return end

    local now = os.clock()
    if now - (MovementState.autoSpikeLastStep or 0) < 0.016 then return end
    MovementState.autoSpikeLastStep = now

    -- cooldown 0.5s
    if now - MovementState.autoSpikeLastFire < COOLDOWN then return end

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not root or not humanoid or humanoid.Health <= 0 then return end

    -- jogador precisa estar no ar (spike acontece no ar)
    local humanoidState = humanoid:GetState()
    local inAir = humanoidState == Enum.HumanoidStateType.Jumping
        or humanoidState == Enum.HumanoidStateType.Freefall
    if not inAir then return end

    -- pegar bola e checar estados do jogo
    local ball = getNearestBall()
    if not ball or not ball.Parent then return end

    getCachedServices()
    local handlers = ServiceCache._GameHandlers
    if not handlers or type(handlers) ~= "table" or not handlers.States then return end
    local states = handlers.States
    if states.IsBusy:get() or states.IsServing:get() then return end
    if not states.IsPlaying:get() then return end

    -- janela de spike: bola acima de X studs de altura relativa ao root, e a uma distância jogável
    local height = ball.Position.Y - root.Position.Y
    local distance = (ball.Position - root.Position).Magnitude
    if height < MIN_HEIGHT_ABOVE_ROOT then return end          -- bola muito baixa, não é spike
    if distance > MAX_DISTANCE then return end       -- longe demais
    if distance < MIN_DISTANCE then return end        -- colada, provavelmente já tocou

    -- dispara o spike
    MovementState.autoSpikeLastFire = now
    if firesignal and Remotes.doMove then
        local dir = State.autoSpikeAim and (MovementState.cornerAim and MovementState.cornerAim() or Camera.CFrame.LookVector) or Camera.CFrame.LookVector
        local spikeOk = pcall(function() firesignal(Remotes.doMove.OnClientEvent, NET.K.SPIKE, false, false, dir) end)
        if not spikeOk and not Core._fsWarned.autoSpike then
            Core._fsWarned.autoSpike = true
            warn("[NodtHub] firesignal falhou em autoSpikeStep")
        end
    end
end

track(LocalPlayer.CharacterAdded:Connect(function()
    Receive.stamp = 0
    Receive.part = nil
end))


local function enableRedirectSpike()
    State.redirectSpikeEnabled = true
    if HookState.redirectSpikeInstalled then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("redirectSpike", function(callNext, self, method, ...)
        if not Remotes.BallService then return callNext(self, method, ...) end
        if self == Remotes.Interact and method == NET.K.INVOKE then
            NET.pace(self)
            local data = (...)
            if type(data) == "table" and data.Move == NET.K.SPIKE and State.redirectSpikeEnabled then
                local look = Camera.CFrame.LookVector
                local flat = Vector3.new(look.X, 0, look.Z)
                if flat.Magnitude > 0.01 then
                    local dir = flat.Unit
                    pcall(function()
                        data.LookVector = dir
                        data.Direction = dir
                    end)
                end
            end
            return NET.callCritical(callNext, self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        HookState.redirectSpikeInstalled = hooked
    end
end

local function disableRedirectSpike()
    State.redirectSpikeEnabled = false
    if HookState.redirectSpikeInstalled then pcall(HookState.redirectSpikeInstalled); HookState.redirectSpikeInstalled = false end
end

local function enableAutoRejoin()
    State.autoRejoinEnabled = true
    if not State.autoRejoinConnections then
        State.autoRejoinConnections = {}
        local function queueRejoin()
            if not State.autoRejoinEnabled or State.autoRejoinQueued then return end
            State.autoRejoinQueued = true
            task.spawn(function()
                task.wait(1)
                State.autoRejoinQueued = false
                if State.autoRejoinEnabled and not Library.Unloaded then
                    pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
                end
            end)
        end
        table.insert(State.autoRejoinConnections, TeleportService.TeleportInitFailed:Connect(function(player)
            if player == LocalPlayer then queueRejoin() end
        end))
        table.insert(State.autoRejoinConnections, LocalPlayer.OnTeleport:Connect(function(status)
            if status == Enum.TeleportState.Failed or status == Enum.TeleportState.Cancelled then queueRejoin() end
        end))
    end
    if HookState.autoRejoinInstalled then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end

    local hooked = hookNamecall("autoRejoin", function(callNext, self, method, ...)
        if self == LocalPlayer and method == NET.K.KICK then
            if State.autoRejoinEnabled then
                -- Intercepta o Kick e agenda o Teleport
                task.spawn(function()
                    -- Estabilidade: solta as conexoes ativas (session.links) antes da troca
                    -- de servidor, para nenhuma thread em background ficar rodando.
                    pcall(function()
                        local genv = (type(getgenv) == "function" and getgenv()) or _G
                        local session = (genv.NODT and genv.NODT.Session) or rawget(genv, "NODT_SESSION") or genv.NODT_SESSION
                        if type(session) == "table" and type(session.links) == "table" then
                            local links = session.links
                            for _, link in ipairs(links) do
                                pcall(function()
                                    link:Disconnect()
                                end)
                            end
                            for i = #links, 1, -1 do
                                links[i] = nil
                            end
                        end
                    end)
                    task.wait(1)
                    pcall(function()
                        game:GetService("TeleportService"):Teleport(game.PlaceId, LocalPlayer)
                    end)
                end)
                return true -- cancela o kick no cliente para evitar a tela de desconexão preta
            end
        end
        return callNext(self, method, ...)
    end)

    if hooked then
        HookState.autoRejoinInstalled = hooked
    end
end

local function disableAutoRejoin()
    State.autoRejoinEnabled = false
    for _, connection in ipairs(State.autoRejoinConnections or {}) do pcall(function() connection:Disconnect() end) end
    State.autoRejoinConnections = nil
    State.autoRejoinQueued = false
    if type(HookState.autoRejoinInstalled) == "function" then
        pcall(HookState.autoRejoinInstalled)
    end
    HookState.autoRejoinInstalled = false
end

local AutoCorner = {
    enabled = false,
    side = "Auto",
    reach = "All",
    depth = 1.0,
}

local function enableSanjuTilt()
    local TILT_BLEND_FACTOR = 0.3      -- mistura do bend na direcao do look
    local TILT_AMPLIFY_FACTOR = 1.35   -- amplificacao do tilt antes do clamp
    local TILT_CLAMP = 1.0             -- limite absoluto do tilt (-1..1)
    State.sanjuTiltEnabled = true
    if HookState.sanjuTiltInstalled then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("sanjuTilt", function(callNext, self, method, ...)
        if not Remotes.BallService then return callNext(self, method, ...) end
        if self == Remotes.Interact and method == NET.K.INVOKE then
            NET.pace(self)
            local data = (...)
            if type(data) == "table" and data.Move == NET.K.SPIKE and State.sanjuTiltEnabled then
                pcall(function()
                    if data.TiltDirection and data.LookVector then
                        local tiltDir = data.TiltDirection
                        if math.abs(tiltDir.X) > 0.01 or math.abs(tiltDir.Z) > 0.01 then
                            local lookVec = data.LookVector
                            local bend = Vector3.new(tiltDir.X, 0, tiltDir.Z)
                            -- Soma 30% do tilt na mira; evita .Unit em vetor zero (NaN)
                            local blended = Vector3.new(
                                lookVec.X + bend.X * TILT_BLEND_FACTOR,
                                lookVec.Y,
                                lookVec.Z + bend.Z * TILT_BLEND_FACTOR
                            )
                            if blended.Magnitude > 0.001 then
                                data.LookVector = blended.Unit
                            else
                                data.LookVector = lookVec
                            end
                            -- Aumenta tilt em 35%, mas limita X/Z a 1.0 (servidor rejeita > 1)
                            local tx = math.clamp(tiltDir.X * TILT_AMPLIFY_FACTOR, -TILT_CLAMP, TILT_CLAMP)
                            local tz = math.clamp(tiltDir.Z * TILT_AMPLIFY_FACTOR, -TILT_CLAMP, TILT_CLAMP)
                            data.TiltDirection = Vector3.new(tx, tiltDir.Y, tz)
                        end
                    end
                end)
            end
            return NET.callCritical(callNext, self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        HookState.sanjuTiltInstalled = hooked
    end
end

local function disableSanjuTilt()
    State.sanjuTiltEnabled = false
    if HookState.sanjuTiltInstalled then pcall(HookState.sanjuTiltInstalled); HookState.sanjuTiltInstalled = false end
end

AutoCorner.physics = function()
    if ServiceCache._Physics then return ServiceCache._Physics end
    local restore = safeGetIdentity()
    safeSetIdentity(2)
    local reached, module = pcall(require, ReplicatedStorage.Common.Physics)
    safeSetIdentity(restore)
    if reached and module then
        ServiceCache._Physics = module
        return module
    end
    return nil
end

AutoCorner.bounds = function()
    local BOUNDS_CACHE_TTL = 2
    local now = os.clock()
    if AutoCorner._boundsCache and now - (AutoCorner._boundsCacheAt or 0) < BOUNDS_CACHE_TTL then
        return table.unpack(AutoCorner._boundsCache)
    end
    local physics = AutoCorner.physics()
    if physics then
        local hasFn, fn = pcall(function()
            return physics._getCourtlines
        end)
        if hasFn and type(fn) == "function" then
            local found, lines = pcall(fn)
            if found and lines and typeof(lines) == "Instance" and lines:IsA("BasePart") then
                local result = { lines.Position, lines.Size * 0.5, lines.Position.Y }
                AutoCorner._boundsCache, AutoCorner._boundsCacheAt = result, now
                AutoCorner._courtlinesCache = lines
                AutoCorner._courtlinesCacheAt = now
                return table.unpack(result)
            end
        end
    end
    -- Fallback: tamanho da quadra via workspace.Map.Court
    local map = Workspace:FindFirstChild("Map")
    local court = map and map:FindFirstChild("Court")
    if court and court:IsA("BasePart") then
        local half = court.Size * 0.5
        half = Vector3.new(math.max(half.X - 1, 1), math.max(half.Y, 1), math.max(half.Z - 1, 1))
        local surfaceY = math.max(court.Position.Y + court.Size.Y * 0.5, court.Position.Y + 0.1)
        local result = { court.Position, half, surfaceY }
        AutoCorner._boundsCache, AutoCorner._boundsCacheAt = result, now
        AutoCorner._courtlinesCache = false
        AutoCorner._courtlinesCacheAt = now
        return table.unpack(result)
    end
    return nil
end

AutoCorner.courtlines = function()
    local now = os.clock()
    if AutoCorner._courtlinesCache ~= nil and now - (AutoCorner._courtlinesCacheAt or 0) < 2 then
        return AutoCorner._courtlinesCache or nil
    end
    local physics = AutoCorner.physics()
    if not physics then
        AutoCorner._courtlinesCache = false
        AutoCorner._courtlinesCacheAt = now
        return nil
    end
    local hasFn, fn = pcall(function()
        return physics._getCourtlines
    end)
    if not (hasFn and type(fn) == "function") then
        AutoCorner._courtlinesCache = false
        AutoCorner._courtlinesCacheAt = now
        return nil
    end
    local ok, lines = pcall(fn)
    if ok and typeof(lines) == "Instance" and lines:IsA("BasePart") then
        AutoCorner._courtlinesCache = lines
        AutoCorner._courtlinesCacheAt = now
        return lines
    end
    AutoCorner._courtlinesCache = false
    AutoCorner._courtlinesCacheAt = now
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
    local CORNER_EDGE_MARGIN = 2          -- folga do canto em X/Z (cornerPoint)
    local CORNER_SHORT_RATIO = 0.3        -- fracao da meia-quadra do canto curto (cornerPoint)
    local SHORT_REWARD_FACTOR = 0.45      -- peso do canto curto por hugging
    local DEFAULT_GUARD_DISTANCE = 60     -- distancia inicial do guarda mais proximo
    local MAX_GUARD_SCORE_DISTANCE = 45   -- teto de distancia usado no score do guarda
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local centre, half, surfaceY = AutoCorner.bounds()
    if not root or not centre then return nil end

    local halfX = math.max(half.X - CORNER_EDGE_MARGIN, 1)
    local halfZ = math.max(half.Z - CORNER_EDGE_MARGIN, 1)

    local map = Workspace:FindFirstChild("Map")
    local collide = map and map:FindFirstChild("BallCollideOnly")
    local net = collide and collide:FindFirstChild("Net")
    local netZ = net and net.Parent and net.Position.Z

    local index = LocalPlayer.Team and LocalPlayer.Team:GetAttribute("Index")
    local sign
    if index == 1 then
        sign = 1
    elseif index == 2 then
        sign = -1
    else
        -- Sem time e sem Net: não dá para inferir o lado da quadra com segurança
        if not net or not netZ then
            return nil
        end
        sign = (root.Position.Z < netZ) and 1 or -1
    end

    if not netZ then
        netZ = centre.Z
    end

    local deepZ = centre.Z + sign * halfZ * (AutoCorner.depth or 1.0)
    local leftX = centre.X + sign * halfX
    local rightX = centre.X - sign * halfX

    local pivot = AutoCorner.origin()
    local attackLine = half.Z / 3
    local standoff = math.abs(root.Position.Z - netZ)
    local hugging = 1 - math.clamp(standoff / attackLine, 0, 1)
    AutoCorner.lean = hugging

    local shortZ = centre.Z + sign * halfZ * CORNER_SHORT_RATIO
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
        corners[#corners + 1] = { at = Vector3.new(leftX, surfaceY, shortZ), reward = SHORT_REWARD_FACTOR * hugging }
        corners[#corners + 1] = { at = Vector3.new(rightX, surfaceY, shortZ), reward = SHORT_REWARD_FACTOR * hugging }
    end

    local eye = Workspace.CurrentCamera or Camera
    local heading = eye and eye.CFrame.LookVector or root.CFrame.LookVector
    heading = Vector3.new(heading.X, 0, heading.Z)
    if heading.Magnitude < 0.01 then
        return corners[1].at
    end
    heading = heading.Unit

    local physics = AutoCorner.physics()
    -- Cache de _getCourtlines (evita pcall por pulo). Passa por AutoCorner.courtlines.
    local bounds = AutoCorner.courtlines()

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
            local nearest = DEFAULT_GUARD_DISTANCE
            for _, guard in ipairs(guards) do
                local gap = (guard - entry.spot).Magnitude
                if gap < nearest then nearest = gap end
            end
            local score = math.min(nearest, MAX_GUARD_SCORE_DISTANCE) / MAX_GUARD_SCORE_DISTANCE + entry.reward
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
        local netZ = net and net.Parent and net.Position.Z
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

MovementState.cornerAim = function()
    local f = AutoCorner.facing()
    if not f then return nil end
    return (f - Vector3.new(0, 0.35, 0)).Unit
end

local Landing -- forward decl: tabela atribuida mais abaixo (Landing = { ... }); installAim/pickCorner usam em runtime

AutoCorner.installAim = function()
    if AutoCorner.aimed then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("autoCornerAim", function(callNext, self, method, ...)
        if not Remotes.BallService then return callNext(self, method, ...) end
        if self == Remotes.Interact and method == NET.K.INVOKE then
            local data = (...)
            if AutoCorner.enabled and type(data) == "table" and (data.Move == NET.K.SPIKE or data.Move == NET.K.SERVESPIKE) then
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

                -- Correcao de tilt: se a bola esta "saindo" pra fora (por tilt natural do personagem),
                -- empurra o TiltDirection pra dentro da linha. Isso acontece no MESMO doMove que ja ia
                -- ser disparado — sem rotacao de cliente, sem frame visivel pro inimigo.
                pcall(function()
                    local character = LocalPlayer.Character
                    local root = character and character:FindFirstChild("HumanoidRootPart")
                    if not root then return end

                    local ball = getNearestBall()
                    if not ball or not ball.Parent then return end

                    local map = Workspace:FindFirstChild("Map")
                    local collide = map and map:FindFirstChild("BallCollideOnly")
                    local net = collide and collide:FindFirstChild("Net")
                    if not net then return end

                    local court = map and map:FindFirstChild("Court")
                    if not court or not court:IsA("BasePart") then return end

                    local halfX = math.max(court.Size.X * 0.5 - 1, 1)
                    local halfZ = math.max(court.Size.Z * 0.5 - 1, 1)
                    local centre = court.Position

                    -- Projeta onde a bola vai cair, em XZ.
                    local ballPos = ball.Position
                    local ballVel = ball.AssemblyLinearVelocity
                    local fallPredict = Landing.predict and select(1, Landing.predict(ball, "landing")) or nil
                    local landingPos = fallPredict or ballPos

                    local outsideX = math.abs(landingPos.X - centre.X) > halfX
                    local outsideZ = math.abs(landingPos.Z - centre.Z) > halfZ

                    if not outsideX and not outsideZ then return end

                    -- Ponto onde ela caiu (ou vai cair), em XZ.
                    local correctedX = math.clamp(landingPos.X, centre.X - halfX, centre.X + halfX)
                    local correctedZ = math.clamp(landingPos.Z, centre.Z - halfZ, centre.Z + halfZ)

                    -- Diferença entre o ponto que ela cairia e o ponto corrigido, em XZ.
                    local deltaX = correctedX - landingPos.X
                    local deltaZ = correctedZ - landingPos.Z

                    -- Empurra o LookVector na direção da correção. Magnitude proporcional ao delta,
                    -- cap em 0.15 pra não "virar" a mira, só curvar.
                    local flatAim = Vector3.new(data.LookVector and data.LookVector.X or 0, 0, data.LookVector and data.LookVector.Z or 0)
                    if flatAim.Magnitude < 0.01 then return end
                    flatAim = flatAim.Unit

                    local correction = Vector3.new(deltaX, 0, deltaZ)
                    if correction.Magnitude < 0.01 then return end
                    local cap = math.min(correction.Magnitude, 0.15)
                    local push = correction.Unit * cap

                    local newFlat = flatAim + push
                    if newFlat.Magnitude < 0.01 then return end
                    newFlat = newFlat.Unit

                    local newAim = (newFlat - Vector3.new(0, 0.35, 0)).Unit
                    data.LookVector = newAim
                    data.Direction = newAim

                    -- TiltDirection: mesma direção mas em plano XZ com Y=1 (mesmo padrão do Aim original)
                    if typeof(data.TiltDirection) == "Vector3" then
                        local tiltXZ = Vector3.new(newFlat.X, 0, newFlat.Z)
                        if tiltXZ.Magnitude > 0.01 then
                            tiltXZ = tiltXZ.Unit
                            data.TiltDirection = Vector3.new(tiltXZ.X, 1, tiltXZ.Z)
                        end
                    end
                end)
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        AutoCorner.aimed = true
        AutoCorner.aimRelease = hooked
    end
end

AutoCorner.disableAim = function()
    if AutoCorner.aimRelease then pcall(AutoCorner.aimRelease); AutoCorner.aimRelease = nil end
    AutoCorner.aimed = false
end

Core.LineAim = {
    enabled = false,
    lastJump = 0,
    token = 0,
}

Core.LineAim.pickCorner = function(root, ball)
    local MIN_HALF_SIZE = 1          -- piso para meia-dimensao da quadra
    local COURT_EDGE_MARGIN = 1      -- folga do canto em Z (fundo/rede)
    local SIDE_EDGE_MARGIN = 1.5     -- folga do canto em X (lateral)
    local SHORT_ZONE_RATIO = 0.35    -- fracao da meia-quadra que define o canto curto
    local HUGGING_THRESHOLD = 0.5    -- acima disso o atacante esta colado na rede -> canto curto
    local centre, half, surfaceY = AutoCorner.bounds()
    if typeof(centre) ~= "Vector3" or typeof(half) ~= "Vector3" then return nil end

    local signZ = 1
    if root.Position.Z > centre.Z then signZ = -1 end

    local map = Workspace:FindFirstChild("Map")
    local collide = map and map:FindFirstChild("BallCollideOnly")
    local net = collide and collide:FindFirstChild("Net")
    local netZ = net and net.Position.Z or centre.Z

    local origin = root.Position
    if ball and ball.Parent then
        local okPredict, spot = pcall(function() return Landing.predict(ball, "landing") end)
        if okPredict and typeof(spot) == "Vector3" then
            origin = spot
        end
    end

    local standoff = math.abs(origin.Z - netZ)
    local halfZ = math.max(half.Z - COURT_EDGE_MARGIN, MIN_HALF_SIZE)
    local attackLine = halfZ / 3
    local hugging = 1 - math.clamp(standoff / attackLine, 0, 1)

    local limitX = math.max(half.X - SIDE_EDGE_MARGIN, MIN_HALF_SIZE)
    local deepZ = centre.Z + signZ * halfZ
    local shortZ = centre.Z + signZ * halfZ * SHORT_ZONE_RATIO
    local targetZ = hugging > HUGGING_THRESHOLD and shortZ or deepZ

    -- 4 cantos: front-left, front-right (perto do net), back-left, back-right (fundo da quadra).
    -- "front" e "back" em Z; "left" e "right" em X. Os 4 sempre entram na lista — o filtro
    -- de distância (MAX_SPIKE_REACH) e de court (isPositionInCourt) decide quais sobrevivem.
    local corners = {
        { pos = Vector3.new(centre.X - limitX, surfaceY, targetZ), side = "front-left" },
        { pos = Vector3.new(centre.X + limitX, surfaceY, targetZ), side = "front-right" },
        { pos = Vector3.new(centre.X - limitX, surfaceY, deepZ),   side = "back-left"  },
        { pos = Vector3.new(centre.X + limitX, surfaceY, deepZ),   side = "back-right" },
    }

    local physics = AutoCorner.physics()
    -- Cache de _getCourtlines: mesmo helper do cornerPoint, elimina pcall repetido
    -- enquanto o Auto Corner Linha recalcula o canto (RECALC_INTERVAL = 0.1s).
    local bounds = AutoCorner.courtlines()

    local valid = {}
    for _, corner in ipairs(corners) do
        local ok = true
        if physics and bounds and type(physics.isPositionInCourt) == "function" then
            local okCourt, inside = pcall(physics.isPositionInCourt, corner.pos, bounds, 0, nil)
            ok = okCourt and inside ~= false
        end
        if ok then
            table.insert(valid, corner)
        end
    end
    if #valid == 0 then
        valid = corners
    end

    local MAX_SPIKE_REACH = 28
    local reachable = {}
    for _, corner in ipairs(valid) do
        local gap = (corner.pos - origin).Magnitude
        corner.gap = gap
        if gap <= MAX_SPIKE_REACH then
            table.insert(reachable, corner)
        end
    end
    if #reachable == 0 then
        local closest = valid[1]
        for _, corner in ipairs(valid) do
            if corner.gap < closest.gap then closest = corner end
        end
        return closest.pos, closest.side
    end
    valid = reachable

    local guards = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and (not LocalPlayer.Team or player.Team ~= LocalPlayer.Team) then
            local enemyRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            if enemyRoot then
                table.insert(guards, enemyRoot.Position)
            end
        end
    end

    local best, bestScore
    for _, corner in ipairs(valid) do
        local nearestEnemy = 999
        for _, guard in ipairs(guards) do
            local gap = (Vector3.new(guard.X, surfaceY, guard.Z) - corner.pos).Magnitude
            if gap < nearestEnemy then nearestEnemy = gap end
        end
        if not bestScore or nearestEnemy > bestScore then
            bestScore = nearestEnemy
            best = corner
        end
    end

    if not best then best = valid[1] end
    return best.pos, best.side
end

Core.LineAim.faceToCorner = function(root, cornerPos)
    local delta = cornerPos - root.Position
    local flat = Vector3.new(delta.X, 0, delta.Z)
    if flat.Magnitude < 0.5 then return end
    local dir = flat.Unit
    root.CFrame = CFrame.lookAt(root.Position, root.Position + dir)
end

Core.LineAim.fireSpike = function()
    if firesignal and Remotes.doMove then
        local fsOk = pcall(function()
            firesignal(Remotes.doMove.OnClientEvent, NET.K.SPIKE, false, false)
        end)
        if not fsOk and not Core._fsWarned.lineAimFireSpike then
            Core._fsWarned.lineAimFireSpike = true
            warn("[NodtHub] firesignal falhou em Core.LineAim.fireSpike")
        end
    end
end

Core.LineAim.jump = function()
    local JUMP_DEBOUNCE = 0.15           -- intervalo minimo entre jumps
    local MAX_JUMP_DURATION = 2.5        -- tempo maximo do loop de jump
    local GROUND_CHECK_AFTER = 0.2       -- so checa chao depois desse tempo
    local RECALC_INTERVAL = 0.1          -- recalculo do canto alvo
    local FIRE_AFTER = 0.15              -- tempo ate disparar o spike
    local SPIKE_MAX_DISTANCE = 14        -- distancia maxima bola-jogador para spike
    local SPIKE_MIN_HEIGHT = 2           -- altura minima da bola para spike
    local LA = Core.LineAim
    if not LA.enabled or Library.Unloaded then return end
    local now = os.clock()
    if now - LA.lastJump < JUMP_DEBOUNCE then return end
    LA.lastJump = now

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not root or not humanoid or humanoid.Health <= 0 then return end

    LA.token = LA.token + 1
    local token = LA.token

    humanoid.AutoRotate = false

    task.spawn(function()
        local started = os.clock()
        local fired = false
        local targetCorner = nil
        local lastRecalc = 0

        while LA.enabled and LA.token == token and not Library.Unloaded do
            local elapsed = os.clock() - started
            if elapsed > MAX_JUMP_DURATION or not root.Parent or humanoid.Health <= 0 then break end
            if elapsed > GROUND_CHECK_AFTER and humanoid.FloorMaterial ~= Enum.Material.Air then break end

            if elapsed - lastRecalc > RECALC_INTERVAL or not targetCorner then
                lastRecalc = elapsed
                local ball = getNearestBall()
                local corner, side = LA.pickCorner(root, ball)
                if corner then
                    targetCorner = corner
                    LA.faceToCorner(root, corner)
                end
            elseif targetCorner then
                LA.faceToCorner(root, targetCorner)
            end

            if not fired and elapsed > FIRE_AFTER then
                local ball = getNearestBall()
                if ball and ball.Parent then
                    local distance = (ball.Position - root.Position).Magnitude
                    local height = ball.Position.Y - root.Position.Y
                    if distance < SPIKE_MAX_DISTANCE and height > SPIKE_MIN_HEIGHT then
                        fired = true
                        LA.fireSpike()
                        break
                    end
                end
            end

            RunService.Heartbeat:Wait()
        end

        if humanoid and humanoid.Parent and not State.autoShiftLockEnabled then
            humanoid.AutoRotate = true
        end
    end)
end

Core.LineAim.enable = function()
    Core.LineAim.enabled = true
    if not Core.LineAim.jumpLink then
        Core.LineAim.jumpLink = track(UserInputService.JumpRequest:Connect(Core.LineAim.jump))
    end
end

Core.LineAim.disable = function()
    Core.LineAim.enabled = false
    if Core.LineAim.jumpLink then
        Core.LineAim.jumpLink:Disconnect()
        Core.LineAim.jumpLink = nil
    end
end

Core.ToggleLineAim = function(value)
    if value then Core.LineAim.enable() else Core.LineAim.disable() end
end


local function enableMaxCharge()
    local MAX_CHARGE_VALUE = 1.0          -- valor forcado para Charge/SpecialCharge/Power/Force
    local CHARGE_TIME_MULTIPLIER = 3      -- ChargeTime = baseTime * 3
    local HOLD_TIME_MULTIPLIER = 2        -- HoldTime/HoldDuration = baseTime * 2
    State.maxChargeEnabled = true
    if HookState.maxChargeHookActive then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("maxCharge", function(callNext, self, method, ...)
        if not Remotes.BallService then return callNext(self, method, ...) end
        if self == Remotes.Interact and method == NET.K.INVOKE then
            NET.pace(self)
            local data = (...)
            if type(data) == "table" and data.Move == NET.K.SPIKE and State.maxChargeEnabled then
                pcall(function()
                    data.Charge = MAX_CHARGE_VALUE
                    data.SpecialCharge = MAX_CHARGE_VALUE
                    data.Power = MAX_CHARGE_VALUE
                    data.Force = MAX_CHARGE_VALUE
                    local baseTime = tonumber(data.ChargeTime) or 1.0
                    data.ChargeTime = baseTime * CHARGE_TIME_MULTIPLIER
                    if data.HoldTime ~= nil then data.HoldTime = baseTime * HOLD_TIME_MULTIPLIER end
                    if data.HoldDuration ~= nil then data.HoldDuration = baseTime * HOLD_TIME_MULTIPLIER end
                end)
            end
            return NET.callCritical(callNext, self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        HookState.maxChargeHookActive = hooked
    end
end

local function disableMaxCharge()
    State.maxChargeEnabled = false
    if HookState.maxChargeHookActive then pcall(HookState.maxChargeHookActive); HookState.maxChargeHookActive = false end
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

    Hush.gag(Remotes.EffectsRemote.OnClientEvent)
    Hush.gag(Remotes.GameEffectRemote.OnClientEvent)

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

-- Silent Spike: helpers pra garantir que a bola cai DENTRO da quadra.
-- O alvo eh sempre clampado com margem; o drop eh ajustado se a fisica
-- do jogo estiver disponivel (Landing.predict). Sem fisica, cai num drop
-- conservador que evita passar por cima da linha.
local SilentSpikeAim = {
    EDGE_MARGIN = 2,              -- studs de folga das linhas (alvo nunca na borda)
    GRID_STEPS = 5,               -- resolucao do grid de busca (5x5 = 25 pontos)
    DROP_MAX_HARD = 0.55,         -- drop maximo absoluto (evita queda vertical total)
    DROP_STEP = 0.05,             -- incremento de drop por iteracao
    DROP_ITERS = 6,               -- numero maximo de iteracoes de ajuste
}

-- Retorna true se spot esta dentro da quadra (com margem).
SilentSpikeAim.inside = function(spot, centre, half, margin)
    if typeof(spot) ~= "Vector3" then return false end
    local m = margin or SilentSpikeAim.EDGE_MARGIN
    local dx = math.abs(spot.X - centre.X)
    local dz = math.abs(spot.Z - centre.Z)
    return dx <= (half.X - m) and dz <= (half.Z - m)
end

-- Encontra o melhor alvo DENTRO da quadra, longe do guarda mais proximo.
-- Varre um grid 5x5 na metade inimiga, filtra por inside, escolhe o ponto
-- com a maior distancia ao guarda mais proximo. Sempre retorna um ponto
-- dentro da quadra (fallback: centro da metade inimiga).
SilentSpikeAim.pickTarget = function(origin, guards, centre, half, sign, surfaceY)
    local m = SilentSpikeAim.EDGE_MARGIN
    local halfX = math.max(half.X - m, 1)
    local halfZ = math.max(half.Z - m, 1)
    local steps = SilentSpikeAim.GRID_STEPS
    local best, bestScore
    for gx = -1, 1, (2 / steps) do
        for gz = 0, 1, (1 / steps) do
            -- Z vai de 0 (rede) ate 1 (fundo da quadra inimiga)
            local px = centre.X + gx * halfX * 0.85
            local pz = centre.Z + sign * (halfZ * (0.4 + gz * 0.5))
            local candidate = Vector3.new(px, surfaceY, pz)
            if SilentSpikeAim.inside(candidate, centre, half) then
                local nearest = math.huge
                for _, g in ipairs(guards) do
                    local d = (Vector3.new(g.X, surfaceY, g.Z) - candidate).Magnitude
                    if d < nearest then nearest = d end
                end
                if not bestScore or nearest > bestScore then
                    bestScore = nearest
                    best = candidate
                end
            end
        end
    end
    if best then return best end
    -- fallback seguro: centro da metade inimiga
    return Vector3.new(centre.X, surfaceY, centre.Z + sign * halfZ * 0.5)
end

-- Ajusta o drop ate a bola cair dentro. Usa Landing.predict se Physics
-- estiver carregado. Sem Physics, retorna o drop base + incremento unico
-- (conservador, garante caida antes da linha em quase todos os casos).
SilentSpikeAim.solve = function(origin, flatDir, baseDrop, centre, half, ball)
    local drop = baseDrop
    local physicsLoaded = pcall(getCachedServices) and ServiceCache._Physics ~= nil
    if physicsLoaded and ball and ball.Parent then
        for _ = 1, SilentSpikeAim.DROP_ITERS do
            local aim = (flatDir - Vector3.new(0, drop, 0)).Unit
            -- Simula a trajetoria usando a fisica do jogo se possivel.
            -- Landing.predict recebe a bola ja em voo; aqui simulamos com a
            -- direcao que vamos mandar. Reutilizamos o solver interno se
            -- existir, senao caímos no baseline.
            local okPredict, spot = pcall(function()
                local gravity = Landing.gravity()
                local speed = 80 -- estimativa conservadora (o jogo nao expoe a velocidade real do spike)
                local vel = aim * speed
                local flight = Landing.solve(origin, vel, gravity, centre.Y)
                if not flight then return nil end
                return Vector3.new(
                    origin.X + vel.X * flight,
                    centre.Y,
                    origin.Z + vel.Z * flight
                )
            end)
            if okPredict and spot and SilentSpikeAim.inside(spot, centre, half) then
                return aim
            end
            drop = math.min(drop + SilentSpikeAim.DROP_STEP, SilentSpikeAim.DROP_MAX_HARD)
        end
    end
    -- fallback: drop base + 1 incremento. Ainda dentro do limite superior.
    drop = math.min(baseDrop + SilentSpikeAim.DROP_STEP, SilentSpikeAim.DROP_MAX_HARD)
    return (flatDir - Vector3.new(0, drop, 0)).Unit
end

enemyAim = function()
    local MIN_STANDOFF = 2              -- distancia minima a rede para o calculo de standoff
    local HEADROOM_DROP_FACTOR = 0.45   -- queda proporcional ao headroom
    local DROP_MIN = -0.05              -- limite inferior da queda
    local DROP_MAX = 0.30               -- limite superior da queda (base; solve sobe se precisar)
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local centre, half, surfaceY = AutoCorner.bounds()
    if not centre then return nil end

    local map = Workspace:FindFirstChild("Map")
    local collide = map and map:FindFirstChild("BallCollideOnly")
    local net = collide and collide:FindFirstChild("Net")
    local netZ = net and net.Parent and net.Position.Z or centre.Z
    local netTop = net and net.Parent and (net.Position.Y + net.Size.Y * 0.5) or surfaceY

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
    local origin = ball and ball.Parent and ball.Position or (root.Position + Vector3.new(0, 6, 0))
    local headroom = origin.Y - netTop
    local standoff = math.max(math.abs(netZ - origin.Z), MIN_STANDOFF)
    local baseDrop = math.clamp(HEADROOM_DROP_FACTOR * headroom / standoff, DROP_MIN, DROP_MAX)

    -- Coleta guardas (inimigos) pra escolher alvo longe deles.
    local guards = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and (not LocalPlayer.Team or player.Team ~= LocalPlayer.Team) then
            local enemyRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            if enemyRoot then
                guards[#guards + 1] = enemyRoot.Position
            end
        end
    end

    local target = SilentSpikeAim.pickTarget(origin, guards, centre, half, sign, surfaceY)

    local flat = Vector3.new(target.X - origin.X, 0, target.Z - origin.Z)
    if flat.Magnitude < 0.01 then
        -- fallback: aponta pro centro da metade inimiga
        flat = Vector3.new(centre.X - origin.X, 0, (centre.Z + sign * half.Z * 0.5) - origin.Z)
    end
    if flat.Magnitude < 0.01 then return nil end
    flat = flat.Unit

    return SilentSpikeAim.solve(origin, flat, baseDrop, centre, half, ball)
end

local Silent = { steer = nil, expiry = 0, hooked = false, release = nil, hushToken = 0 }

Silent.install = function()
    if Silent.hooked then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("silentSpike", function(callNext, self, method, ...)
        if not Remotes.BallService then return callNext(self, method, ...) end
        if self == Remotes.Interact and method == NET.K.INVOKE then
            local data = (...)
            local steer = Silent.steer
            if steer ~= nil then
                if os.clock() >= Silent.expiry then
                    Silent.steer = nil
                    Silent.expiry = 0
                elseif type(data) == "table" and typeof(steer) == "Vector3" then
                    if data.Move == NET.K.SPIKE or data.Move == NET.K.SERVESPIKE then
                        pcall(function()
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
                        end)
                        -- one shot: o próximo spike normal não herda a direção
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
        Silent.release = hooked
    end
end

Silent.uninstall = function()
    Silent.steer = nil
    Silent.expiry = 0
    Silent.hushToken = (Silent.hushToken or 0) + 1
    if Silent.hushTask then
        pcall(task.cancel, Silent.hushTask)
        Silent.hushTask = nil
    end
    if type(Silent.release) == "function" then
        pcall(Silent.release)
    end
    Silent.release = nil
    Silent.hooked = false
    pcall(Hush.stop)
end

local function fireNewSpike()
    local HITBOX_WINDOW = 0.3           -- janela do hitbox apos o disparo
    local SILENT_STEER_WINDOW = 0.4     -- janela do steer silencioso
    local HUSH_RESTORE_DELAY = 0.15     -- delay antes de restaurar o hush
    if not State.newSilentSpikeEnabled then return end
    if not firesignal then return end
    local newRemote = Remotes.doMove
    if not newRemote then
        warn("[NodtHub] service not found")
        return
    end

    local dir = enemyAim() or Camera.CFrame.LookVector
    if typeof(dir) ~= "Vector3" or dir.Magnitude <= 0.01 then
        return
    end
    dir = dir.Unit

    Hush.start()
    installHitboxHook()
    SpikeReach.expiry = os.clock() + HITBOX_WINDOW

    -- Token: só o último silent spike pode chamar Hush.stop
    Silent.hushToken = (Silent.hushToken or 0) + 1
    local myHush = Silent.hushToken

    local expiry = os.clock() + SILENT_STEER_WINDOW
    Silent.steer = dir
    Silent.expiry = expiry
    Silent.install()
    local fsOk = pcall(firesignal, newRemote.OnClientEvent, NET.K.SPIKE, false, false, dir)
    if not fsOk and not Core._fsWarned.fireNewSpike then
        Core._fsWarned.fireNewSpike = true
        warn("[NodtHub] firesignal falhou em fireNewSpike")
    end

    if Silent.hushTask then
        pcall(task.cancel, Silent.hushTask)
        Silent.hushTask = nil
    end
    Silent.hushTask = task.delay(HUSH_RESTORE_DELAY, function()
        if Silent.hushToken == myHush then
            Hush.stop()
        end
    end)
    task.delay(0.4, function()
        if Silent.expiry == expiry then
            Silent.steer = nil
            Silent.expiry = 0
        end
    end)
end

-- Helper unico dos botoes flutuantes: ScreenGui + TextButton + UICorner + UIStroke + drag.
-- opts.name = chave em ButtonState; opts.onClick = callback do clique; opts.initialVisible = visibilidade inicial.
local function makeFloatButton(opts)
    local key = opts.name
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    screenGui.ResetOnSpawn = false
    ButtonState[key] = Instance.new("TextButton")
    ButtonState[key].Size = UDim2.new(0, 50, 0, 50)
    ButtonState[key].Position = opts.position
    ButtonState[key].BackgroundColor3 = Color3.fromRGB(9, 13, 16)
    ButtonState[key].Text = opts.text
    ButtonState[key].TextColor3 = Color3.fromRGB(255, 255, 255)
    ButtonState[key].TextScaled = true
    ButtonState[key].Font = Enum.Font.GothamBold
    ButtonState[key].Parent = screenGui
    ButtonState[key].BackgroundTransparency = 0.12
    ButtonState[key].BorderSizePixel = 0
    ButtonState[key].Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = ButtonState[key]
    local ring = Instance.new("UIStroke")
    ring.Color = opts.ringColor
    ring.Thickness = 2
    ring.Transparency = 0.1
    ring.Parent = ButtonState[key]
    local dragging = false
    local dragStart = nil
    local startPos = nil
    ButtonState[key].InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = ButtonState[key].Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    ButtonState[key].InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            ButtonState[key].Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    ButtonState[key].MouseButton1Click:Connect(opts.onClick)
    ButtonState[key].Visible = opts.initialVisible
    return ButtonState[key]
end

local function createNewSpikeButton()
    return makeFloatButton({
        name = "newSpikeButton", text = "Spike", position = UDim2.new(0.5, -25, 0.85, -25),
        ringColor = Color3.fromRGB(255, 76, 46), onClick = function() fireNewSpike() end, initialVisible = false,
    })
end

ButtonState.newSpikeButton = createNewSpikeButton()

local function enableDesync()
    if MovementState.desyncConnection then return end
    if not Remotes.doMove then
        warn("[NodtHub] service not found")
        return
    end
    MovementState.desyncConnection = UserInputService.JumpRequest:Connect(function()
        if State.desyncEnabled then
            task.wait(math.random(2, 5) / 100)
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
                if math.abs(vel.X) > 80 or math.abs(vel.Z) > 80 then
                    desyncRoot.AssemblyLinearVelocity = Vector3.new(math.clamp(vel.X, -80, 80), vel.Y, math.clamp(vel.Z, -80, 80))
                end
            end
            if firesignal then
                pcall(function() firesignal(Remotes.doMove.OnClientEvent, NET.K.SPIKE, false, false) end)
            end
        end
    end)
    State.desyncEnabled = true
end

local function disableDesync()
    if MovementState.desyncConnection then
        MovementState.desyncConnection:Disconnect()
        MovementState.desyncConnection = nil
    end
    State.desyncEnabled = false
end

local function enableAutoBlock()
    if MovementState.autoBlockConnection then return end
    if not Remotes.doMove then
        warn("[NodtHub] service not found")
        return
    end
    MovementState.autoBlockConnection = UserInputService.JumpRequest:Connect(function()
        if State.autoBlockEnabled then
            -- Clamp de seguranca (apenas horizontal X/Z; Y livre para dive)
            local character = LocalPlayer.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if root then
                local vel = root.AssemblyLinearVelocity
                if math.abs(vel.X) > 50 or math.abs(vel.Z) > 50 then
                    root.AssemblyLinearVelocity = Vector3.new(math.clamp(vel.X, -50, 50), vel.Y, math.clamp(vel.Z, -50, 50))
                end
            end
            if firesignal then
                pcall(function() firesignal(Remotes.doMove.OnClientEvent, NET.K.BLOCK, false, false) end)
            end
        end
    end)
end

local function disableAutoBlock()
    if MovementState.autoBlockConnection then
        MovementState.autoBlockConnection:Disconnect()
        MovementState.autoBlockConnection = nil
    end
end

function MovementState.kazanaConnect()
    if MovementState.kazanaLink or Library.Unloaded then return end
    if not (State.kazanaBlueEnabled or State.kazanaWhiteEnabled) then return end
    MovementState.kazanaLink = UserInputService.JumpRequest:Connect(function()
        if not State.kazanaBlueEnabled and not State.kazanaWhiteEnabled then
            return
        end
        local character = LocalPlayer.Character
        if not character or not character.PrimaryPart then
            return
        end
        if os.clock() - (VisualState.seen.__kazanaAt or 0) < 0.35 then
            return
        end
        VisualState.seen.__kazanaAt = os.clock()

        local white = State.kazanaWhiteEnabled
        local effectFolder = ReplicatedStorage.Assets:FindFirstChild("Effects")
        local module = effectFolder and effectFolder:FindFirstChild(white and "KazanaWhite" or "KazanaBlue")
        if not module then
            return
        end

        local restore = safeGetIdentity()
        safeSetIdentity(2)
        pcall(function()
            require(module)(character)
            require(ReplicatedStorage.Tools.Sound).fromName(white and "Kazana_White" or "Kazana_Blue")({})
        end)
        safeSetIdentity(restore)
    end)
end

function MovementState.kazanaDisconnect()
    if MovementState.kazanaLink then
        MovementState.kazanaLink:Disconnect()
        MovementState.kazanaLink = nil
    end
end

track({ Disconnect = MovementState.kazanaDisconnect })

local function playDashEffect(direction)
    local restore = safeGetIdentity()
    safeSetIdentity(2)
    pcall(function()
        local Effect = require(ReplicatedStorage.Content.Effect)
        Effect:Play("KuraiDashFX")({
            Player = LocalPlayer,
            Direction = direction,
        })
    end)
    safeSetIdentity(restore)
end

local function akariDash()
    local DASH_HITBOX_WINDOW = 0.3
    local DASH_TWEEN_TIME = 0.2
    local DASH_MAX_DISTANCE = 28
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
            distance = math.clamp(flat.Magnitude - 1, 0, DASH_MAX_DISTANCE) * (State.akariDashMultiplier or 1.0)
        end
    end
    if not direction then
        local forward = Camera.CFrame.LookVector
        direction = Vector3.new(forward.X, 0, forward.Z).Unit
    end
    playDashEffect(direction)
    SpikeReach.expiry = os.clock() + DASH_HITBOX_WINDOW
    local tween = game:GetService("TweenService"):Create(hrp, TweenInfo.new(DASH_TWEEN_TIME, Enum.EasingStyle.Linear), {
        CFrame = CFrame.new(hrp.Position + (direction * distance)) * CFrame.Angles(0, math.rad(hrp.Orientation.Y), 0)
    })
    tween:Play()
end

local function createDashButton()
    return makeFloatButton({
        name = "dashButton", text = "⚡", position = UDim2.new(0.15, -25, 0.8, -25),
        ringColor = Color3.fromRGB(255, 76, 46), onClick = akariDash, initialVisible = false,
    })
end

createDashButton()

local function stopBall()
    if not Remotes.BallService then return end
    local ballId = getBallId()
    if not ballId then return end
    local lookVector = Vector3.new(0, -1, 0)
    if Remotes.Interact then
        NET.pace(Remotes.Interact)
        Remotes.Interact:InvokeServer({
            ["Charge"] = 1,
            ["Move"] = NET.K.BLOCK,
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
    return makeFloatButton({
        name = "stopBallButton", text = "Stop", position = UDim2.new(0.35, -25, 0.8, -25),
        ringColor = Color3.fromRGB(255, 92, 110), onClick = function() stopBall() end, initialVisible = ButtonState.stopBallVisible,
    })
end

AutoCounter = (function()
    local ReplicatedFirst = game:GetService("ReplicatedFirst")

    local state = {
        enabled = false,
        move = "Auto",
        netRange = 9,
        lateral = 14,
        reach = 20,
        delay = 0.05,
        cooldown = 0.35,
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
    local api = { state = state }

    local function elevate(fn)
        local restore = safeGetIdentity()
        safeSetIdentity(2)
        local ok = pcall(fn)
        safeSetIdentity(restore)
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
            if not Knit then
                if not Core._fsWarned.autoCounterKnit then
                    Core._fsWarned.autoCounterKnit = true
                    Library:Notify({ Title = "Nodt Hub", Description = "Auto Counter: GameController não encontrado" })
                end
                return
            end
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

    local netCache = nil
    local function getNet()
        if netCache and netCache.Parent then
            return netCache
        end
        local tagged = CollectionService:GetTagged("Net")[1]
        if tagged and tagged:IsA("BasePart") then
            netCache = tagged
            return tagged
        end
        local map = Workspace:FindFirstChild("Map")
        local collide = map and map:FindFirstChild("BallCollideOnly")
        netCache = collide and collide:FindFirstChild("Net") or nil
        return netCache
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

        if not api._hostiles or api._hostilesDirty then
            api._hostilesDirty = false
            local list = {}
            local myTeam = LocalPlayer.Team
            for _, player in ipairs(Players:GetPlayers()) do
                if player ~= LocalPlayer and (myTeam == nil or player.Team ~= myTeam) then
                    list[#list + 1] = player
                end
            end
            api._hostiles = list
        end
        for _, player in ipairs(api._hostiles) do
            local character = player.Character
            local enemyRoot = character and character:FindFirstChild("HumanoidRootPart")
            if enemyRoot then
                local hum = character:FindFirstChildOfClass("Humanoid")
                local humState = hum and hum:GetState()
                local isAirborne = character:GetAttribute("Jumping")
                    or humState == Enum.HumanoidStateType.Jumping
                    or humState == Enum.HumanoidStateType.Freefall
                if isAirborne then
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
        if (ahead.Z - netZ) * side > 0 then return NET.K.SPIKE end
        return NET.K.BLOCK
    end

    local function fire(move)
        if not bind() then return false end
        if not handlers or not handlers.States then return false end
        local states = handlers.States
        if states.IsBusy:get() or states.IsStunned:get() or states.IsServing:get() then return false end
        if not states.IsPlaying:get() then return false end
        if ReplicatedStorage:GetAttribute("ServedByTeam") then return false end

        firing = true
        armed = false
        lastFire = os.clock() -- cooldown comeca na tentativa, nao so no fim
        task.spawn(function()
            -- Só tenta pular se estiver no chão (evita bug de física no ar)
            local canJump = state.autoJump and not states.IsJumping:get()
            if canJump then
                local onGround = true
                if type(isOnGround) == "function" then
                    local okGround, result = pcall(isOnGround)
                    onGround = okGround and result and true or false
                end
                if onGround and type(controller) == "table" then
                    elevate(function() controller:PerformJump() end)
                end
            end
            -- Delay configurável, mínimo 0.1s
            local waitTime = math.max(0.03, tonumber(state.delay) or 0.03)
            task.wait(waitTime)
            elevate(function()
                pcall(function()
                    controller:DoMove({
                        ActionName = move,
                        IsAerial = true,
                        InputState = Enum.UserInputState.Begin,
                        Metadata = {},
                    })
                end)
            end)
            lastFire = os.clock()
            firing = false
        end)
        return true
    end

    local lastStepRun = 0
    local function step()
        if Library.Unloaded or not state.enabled or firing then return end
        local now = os.clock()
        if now - lastStepRun < 0.03 then return end
        lastStepRun = now
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not root then return end
        local net = getNet()
        if not net then return end
        local ball, ahead, netZ, side = findThreat(root, net)
        if not ball then armed = true return end
        if now - lastFire < state.cooldown then return end
        if not armed then
            if now - lastFire < REARM_TIMEOUT then return end
            armed = true
        end
        fire(pickMove(ahead, netZ, side))
    end

    api.connect = function()
        if api.connection then return end
        api.connection = track(RunService.Heartbeat:Connect(step))
    end

    track(Players.PlayerAdded:Connect(function() api._hostilesDirty = true end))
    track(Players.PlayerRemoving:Connect(function() api._hostilesDirty = true end))
    track(Players.ChildAdded:Connect(function() api._hostilesDirty = true end))
    for _, p in ipairs(Players:GetPlayers()) do
        track(p.Changed:Connect(function(prop)
            if prop == "Team" then api._hostilesDirty = true end
        end))
    end

    api.reset = function()
        handlers = nil
        controller = nil
        lastBindAttempt = 0
    end

    return api
end)()

getNearestTeammate = function()
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
    if not Remotes.BallService then return end
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
    if Remotes.Interact then
        NET.pace(Remotes.Interact)
        Remotes.Interact:InvokeServer({
            ["Charge"] = 1,
            ["Move"] = NET.K.JUMPSET,
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


local function enableAutoSetAim()
    State.autoSetAimEnabled = true
    if HookState.autoSetAimInstalled then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end

    local hooked = hookNamecall("autoSetAim", function(callNext, self, method, ...)
        if not Remotes.BallService then return callNext(self, method, ...) end
        if self == Remotes.Interact and method == NET.K.INVOKE then
            NET.pace(self)
            local data = (...)
            if type(data) == "table" and data.Move == NET.K.JUMPSET and State.autoSetAimEnabled then
                local nearestTeammate = getNearestTeammate()
                local playerRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")

                if nearestTeammate and nearestTeammate.Character and playerRoot then
                    local targetRoot = nearestTeammate.Character:FindFirstChild("HumanoidRootPart")
                    if targetRoot then
                        local flatDirection = targetRoot.Position - playerRoot.Position
                        flatDirection = Vector3.new(flatDirection.X, 0, flatDirection.Z)

                        if flatDirection.Magnitude > 1 then
                            local dirUnit = flatDirection.Unit
                            data.TiltDirection = Vector3.new(dirUnit.X, 1, dirUnit.Z)
                            data.LookVector = dirUnit
                        else
                            local camLook = Camera.CFrame.LookVector
                            local flatCam = Vector3.new(camLook.X, 0, camLook.Z)
                            if flatCam.Magnitude > 0.01 then
                                flatCam = flatCam.Unit
                            else
                                flatCam = Vector3.new(0, 0, -1)
                            end
                            data.TiltDirection = Vector3.new(flatCam.X, 1, flatCam.Z)
                            data.LookVector = flatCam
                        end
                    end
                end
            end
            return NET.callCritical(callNext, self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        HookState.autoSetAimInstalled = hooked
    end
end

local function disableAutoSetAim()
    State.autoSetAimEnabled = false
    if HookState.autoSetAimInstalled then pcall(HookState.autoSetAimInstalled); HookState.autoSetAimInstalled = false end
end

local function createAimButton()
    return makeFloatButton({
        name = "aimButton", text = "Aim", position = UDim2.new(0.65, -25, 0.8, -25),
        ringColor = Color3.fromRGB(255, 76, 46), onClick = function() aim() end, initialVisible = ButtonState.aimVisible,
    })
end

MovementState.airStep = function()
    if not State.airMovement then
        if MovementState.bodyVelocity then
            MovementState.bodyVelocity:Destroy()
            MovementState.bodyVelocity = nil
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

    if not MovementState.bodyVelocity or MovementState.bodyVelocity.Parent ~= root then
        if MovementState.bodyVelocity then
            MovementState.bodyVelocity:Destroy()
        end
        MovementState.bodyVelocity = Instance.new("BodyVelocity")
        MovementState.bodyVelocity.Name = MARK
        MovementState.bodyVelocity.MaxForce = Vector3.zero
        MovementState.bodyVelocity.Velocity = Vector3.zero
        MovementState.bodyVelocity.P = 12500
        MovementState.bodyVelocity.Parent = root
    end

    local direction = humanoid.MoveDirection
    if direction.Magnitude == 0 then
        if VisualState.seen.__controls == nil then
            local reached, controls = pcall(function()
                return require(LocalPlayer.PlayerScripts.PlayerModule):GetControls()
            end)
            VisualState.seen.__controls = (reached and controls) or false
        end
        if VisualState.seen.__controls then
            local read, raw = pcall(VisualState.seen.__controls.GetMoveVector, VisualState.seen.__controls)
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
        MovementState.bodyVelocity.MaxForce = Vector3.new(math.huge, 0, math.huge)
        MovementState.bodyVelocity.Velocity = direction.Unit * State.airMovementSpeed
    else
        MovementState.bodyVelocity.MaxForce = Vector3.zero
        MovementState.bodyVelocity.Velocity = Vector3.zero
    end
end

function MovementState.airConnect()
    if MovementState.airLink or Library.Unloaded then return end
    MovementState.airLink = RunService.Heartbeat:Connect(MovementState.airStep)
end

function MovementState.airDisconnect()
    if MovementState.airLink then
        MovementState.airLink:Disconnect()
        MovementState.airLink = nil
    end
    if MovementState.bodyVelocity then
        MovementState.bodyVelocity:Destroy()
        MovementState.bodyVelocity = nil
    end
end

track({ Disconnect = MovementState.airDisconnect })

local function isEnemy(player)
    if player == LocalPlayer then return false end
    -- Sem times (lobby etc.): qualquer outro jogador é tratado como inimigo
    if not player.Team or not LocalPlayer.Team then return true end
    return player.Team ~= LocalPlayer.Team
end

local function applyESP(player)
    if not player.Character or VisualState.espHighlights[player] then return end
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
    VisualState.espHighlights[player] = highlight
end

local function removeESP(player)
    if VisualState.espHighlights[player] then
        VisualState.espHighlights[player]:Destroy()
        VisualState.espHighlights[player] = nil
    end
end

local function cleanupConnections(player)
    if VisualState.espConnections[player] then
        for _, connection in pairs(VisualState.espConnections[player]) do
            connection:Disconnect()
        end
        VisualState.espConnections[player] = nil
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
        VisualState.espConnections[player] = { track(stateConnection) }
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
track(Players.PlayerRemoving:Connect(function(player)
    cleanupConnections(player)
end))

local function enableMaxServe()
    State.maxServeEnabled = true
    if HookState.maxServeHookActive then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("maxServe", function(callNext, self, method, ...)
        if not Remotes.Serve then return callNext(self, method, ...) end
        if self == Remotes.Serve and method == NET.K.INVOKE and State.maxServeEnabled then
            local args = table.pack(...)
            args[2] = 5
            return callNext(self, method, table.unpack(args, 1, math.max(args.n, 2)))
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        HookState.maxServeHookActive = hooked
    end
end

local function disableMaxServe()
    State.maxServeEnabled = false
    if HookState.maxServeHookActive then pcall(HookState.maxServeHookActive); HookState.maxServeHookActive = false end
end

local function leadFeetSlam()
    if not State.leadFeetEnabled then return end
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not character or not root then return end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return end

    local tuning = { Acceleration = -10000, TerminalVelocity = -300, Duration = 2 }
    local controller = nil

    local restore = safeGetIdentity()
    safeSetIdentity(2)
    pcall(function()
        if not ServiceCache._LeadFeetAbility then
            ServiceCache._LeadFeetAbility = require(ReplicatedStorage.Content.Ability.LeadFeet)
        end
        local ability = ServiceCache._LeadFeetAbility
        if type(ability) == "table" and type(ability.Metadata) == "table" then
            tuning = ability.Metadata
        end
        local Knit = getKnitRoot()
        if not Knit then return end
        controller = Knit.GetController("GameController")
        if not controller and not Core._fsWarned.leadFeetController then
            Core._fsWarned.leadFeetController = true
            Library:Notify({ Title = "Nodt Hub", Description = "Lead Feet: GameController não encontrado" })
        end
        if controller then
            controller.IsBusy:set(false)
        end
        if not ServiceCache._EffectModule then
            ServiceCache._EffectModule = require(ReplicatedStorage.Content.Effect)
        end
        ServiceCache._EffectModule:Play("LeadFeetFX")({ Player = LocalPlayer })
        if not ServiceCache._JumpAction then
            ServiceCache._JumpAction = require(game:GetService("ReplicatedFirst").Controllers.GameController.Actions.Move.Jump)
        end
        ServiceCache._JumpAction.stop()
        if controller then
            controller.IsBusy:set(true)
        end
    end)
    safeSetIdentity(restore)

    if ButtonState.leadFeetLink then
        ButtonState.leadFeetLink:Disconnect()
        ButtonState.leadFeetLink = nil
    end

    local expiry = os.clock() + (tuning.Duration or 2)
    ButtonState.leadFeetLink = RunService.Heartbeat:Connect(function(delta)
        if not root.Parent or humanoid.FloorMaterial ~= Enum.Material.Air or os.clock() >= expiry or humanoid.Health <= 0 then
            if controller then
                controller.IsBusy:set(false)
            end
            if ButtonState.leadFeetLink then
                ButtonState.leadFeetLink:Disconnect()
                ButtonState.leadFeetLink = nil
            end
            return
        end
        local velocity = root.AssemblyLinearVelocity
        local drop = math.max(velocity.Y + (tuning.Acceleration or -10000) * delta, tuning.TerminalVelocity or -300)
        root.AssemblyLinearVelocity = Vector3.new(velocity.X, drop, velocity.Z)
    end)
end

local function createLeadFeetButton()
    return makeFloatButton({
        name = "leadFeetButton", text = "LF", position = UDim2.new(0.25, -25, 0.8, -25),
        ringColor = Color3.fromRGB(255, 76, 46), onClick = leadFeetSlam, initialVisible = false,
    })
end

createLeadFeetButton()

local function loadJerseys()
    CardState.jerseyList = {
        "BlueOnesieJersey", "ClassicJersey", "CursedTournamentTop100Jersey", "CursedTournamentTop1Jersey", "CursedTournamentTop1KJersey", "DragonTuxedoJersey", "NeonJersey", "PajamasJersey", "PastelJersey", "PinkOnesieJersey", "PirateJersey", "RainbowJersey", "RefJersey", "SkeletonJersey", "SkeletonJerseySeason19", "SparkleTimeJersey", "T1TournamentJersey", "TournamentJersey", "TournamentTop100BeachJersey", "TournamentTop10BeachJersey", "TournamentTop1BeachJersey", "TuxedoJersey", "VampireJersey"
    }
    return CardState.jerseyList
end

loadJerseys()

local function loadBallSkins()
    CardState.ballSkinList = {
        "2026ChocolateEggBall", "2026EasterEggBall", "AcornBall", "AlienBall", "AngelHeadBall", "AngelicBall", "AngryEmojiBall", "AnimeVolleyBall", "ArrowBall", "AuroraBall", "BananaBall", "Basketball", "BeachBall", "BeachGlobeBall", "BlackBall", "BlueAndYellowBall", "BooBall", "BrainBall", "BronzeCannonBall", "BronzeCloverBall", "BronzeCoconutBall", "BronzeEggBall", "BronzeFestivalBall", "BronzeHeartBall", "BronzeOrnamentBall", "BronzeRibcageBall", "BronzeSeashellBall", "BunnyBall", "BunnyEggBall", "CakeBall", "CameraBall", "CandleBall", "CauldronBall", "CelestialOrbBall", "ChocolateBunnyHeadBall", "ChocolateCoveredBall", "ChocolateCoveredNerdBall", "ChocolateEggBall", "ChocolateHeartBall", "ChristmasLightsBall", "ClassicBall", "CloverBall", "ClownBall", "CoalBall", "CoconutBall", "CoralReefBall", "CrabBall", "CrackedBall", "CrackedEasterEggBall", "CraftyBall", "CryoFlareBall", "CursedKrakenEyeBall", "CuteKittyBall", "DarkBatBall", "DecoratedEasterEggBall", "DemonBall", "DevilBall", "DevilHeadBall", "DiamondAcornBall", "DiamondBall", "DiamondCannonBall", "DiamondCloverBall", "DiamondCoconutBall", "DiamondEggBall", "DiamondEyeBall", "DiamondFestivalBall", "DiamondHeartBall", "DiamondRibcageBall", "DiamondSantaBall", "DiamondSeashellBall", "DiamondSnowGlobeBall", "DiamondSnowmanBall", "DiscoBall", "EasterEggBall", "ElectrifiedBall", "EvilEyeBall", "FestivalBall", "FlameBall", "FlowerBall", "FlowerBlossomBall", "FourLeafCloverBall", "Frostball", "GalaxyBall", "GamerBall", "GhostBall", "GiftBall", "GingerbreadBall", "GodBall", "GoldCannonBall", "GoldCoconutBall", "GoldCoinBall", "GoldFestivalBall", "GoldHeartBall", "GoldRibcageBall", "GoldSeashellBall", "GoldenBall", "GoldenClockBall", "GoldenCloverBall", "GoldenDiamondBall", "GoldenEggBall", "GoldenPearlBall", "GoldenSkullBall", "GoldenSnowmanBall", "GoldenStarBall", "GoldenSunEggBall", "GradientBall", "HackerBall", "HamburgerBall", "HauntedBall", "HeadBall", "HeartBall", "HologramBall", "HolyHellBall", "HorseshoeBall", "HourglassBall", "IceCreamBall", "JellyfishBall", "KarasunoBall", "KareemBall", "KoiBall", "Level150Ball", "Level50Ball", "LifebuoyBall", "MagicCrystalBall", "MangoBall", "MechBall", "MoneyBall", "MonkeyBall", "MoonBall", "MoonFireBall", "NebulaBall", "NerdBall", "NewYearsDragonBall", "NinjaBall", "OrnamentBall", "OvergrownCrystalBall", "PaintSplatterBall", "PartyHatBall", "PartySunglassesBall", "PastelSwirlEggBall", "PearlBall", "PhantomBall", "PhoenixBall", "PhonkBall", "PinataBall", "PineappleBall", "PinkBall", "PinkBlossomBall", "PinkFlamingoBall", "PinkSummerHatBall", "PirateHatBall", "PixelBall", "PolyhedralBall", "PotOfGoldBall", "PotionBall", "PumpkinBall", "PurplePhoenixBall", "RainbowBall", "RainbowPrismBall", "RattlingJawBall", "ReaperBall", "RedDragonBall", "RedEyeBall", "RedGreenAndWhiteBall", "ReindeerBall", "RigBall", "RippedBall", "RubberDuckyBall", "SaturnBall", "ScarecrowBall", "ShellBall", "ShinyBunnyEggBall", "ShinyChocolateEggBall", "SilverBall", "SilverCannonBall", "SilverCloverBall", "SilverCoconutBall", "SilverEggBall", "SilverFestivalBall", "SilverHeartBall", "SilverLanternBall", "SilverMikageHeadBall", "SilverRibbonBall", "SilverRibcageBall", "SilverSeashellBall", "SilverTurkeyBall", "SlimeBall", "SnowGlobeBall", "Snowball", "SnowmanBall", "SoccerBall", "SoulBall", "SpikyBall", "SpiritBall", "StainedGlassBall", "SubspaceBall", "SummerHatBall", "SunBall", "SunglassesBall", "SuperSunBall", "TennisBall", "TigerBall", "TimeBall", "TitaniumBall", "TranslucentTurkeyBall", "TrollFaceBall", "TurkeyBall", "TuxedoBall", "UltraFastModeBall", "VIPBall", "ValentineCardBall", "WaterBall", "WhiteEggBall", "WingedBall", "WizardHatBall"
    }
    return CardState.ballSkinList
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

    if not VisualState.seen.__jerseyHook then
        VisualState.seen.__jerseyChar = character
        VisualState.seen.__jerseyHook = track(LocalPlayer.CharacterAdded:Connect(function(character2)
            local oldChar = VisualState.seen.__jerseyChar
            if oldChar and oldChar ~= character2 then
                VisualState.originals[oldChar] = nil
            end
            VisualState.seen.__jerseyChar = character2
            CardState.pickedTeam = nil
            if State.autoApplyJersey then
                local deadline = os.clock() + 2
                while not character2:FindFirstChild("UpperTorso") and os.clock() < deadline do
                    task.wait(0.05)
                end
                if character2:FindFirstChild("UpperTorso") and State.autoApplyJersey then
                    task.wait(0.15)
                    applyJersey(State.selectedJersey)
                end
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
        local backup = VisualState.originals[character]
        if backup then
            clearWorn()
            for _, saved in ipairs(backup) do
                local restored = saved:Clone()
                if restored:IsA("SurfaceGui") then
                    restored.Adornee = character:FindFirstChild("UpperTorso")
                end
                restored.Parent = character
            end
            VisualState.originals[character] = nil
        end
        CardState.pickedTeam = nil
        return true
    end

    if not VisualState.originals[character] then
        local backup = {}
        for _, child in ipairs(character:GetChildren()) do
            if child.Name == "JerseyFront" or child.Name == "JerseyBack"
                or child:IsA("Clothing") or child:IsA("ShirtGraphic") then
                table.insert(backup, child:Clone())
            end
        end
        VisualState.originals[character] = backup
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

    local restore = safeGetIdentity()
    safeSetIdentity(2)
    local loaded, Jersey = pcall(require, ReplicatedStorage.Tools.Jersey)
    safeSetIdentity(restore)
    if not loaded or type(Jersey) ~= "table" or not Jersey.set then
        if not Core._fsWarned.jerseyModule then
            Core._fsWarned.jerseyModule = true
            Library:Notify({ Title = "Nodt Hub", Description = "Jersey: módulo Tools.Jersey não encontrado" })
        end
        return false
    end

    CardState.pickedTeam = CardState.pickedTeam or resolveTeam()

    local applied, err = pcall(Jersey.set, {
        Player = LocalPlayer,
        Character = character,
        Id = id or State.selectedJersey,
        TeamName = CardState.pickedTeam,
    })
    if not applied then
        warn("[NODTHUB] jersey apply failed: " .. tostring(err))
        if not Core._fsWarned.jerseyApply then
            Core._fsWarned.jerseyApply = true
            Library:Notify({ Title = "Nodt Hub", Description = "Jersey: falha ao aplicar (Tools.Jersey.set erro)" })
        end
        return false
    end

    CardState.pickedTeam = CardState.pickedTeam or resolveTeam()
    return true
end

local function sweep()
    local ballFolder = ReplicatedStorage:FindFirstChild("Assets")
    ballFolder = ballFolder and ballFolder:FindFirstChild("Ball")
    if not ballFolder then
        return
    end

    local function strip(model)
        local holder = VisualState.clones[model]
        if holder then
            holder:Destroy()
            VisualState.clones[model] = nil
        end
        local saved = VisualState.originals[model]
        if saved then
            for piece, record in pairs(saved) do
                if piece.Parent then
                    pcall(function()
                        piece[record.field] = record.value
                    end)
                end
            end
            VisualState.originals[model] = nil
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
        VisualState.originals[model] = saved

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

        VisualState.clones[model] = holder
    end

    local tracked = {}
    for model in pairs(VisualState.clones) do
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

    if not VisualState.seen.__ballHook then
        VisualState.seen.__ballHook = track(Workspace.ChildAdded:Connect(function(child)
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

local function safeSweep()
    if CardState.sweepBusy then return end
    CardState.sweepBusy = true
    task.spawn(function()
        local ok, err = pcall(sweep)
        if not ok then warn("[NodtHub] sweep falhou:", err) end
        task.wait(0.3)
        CardState.sweepBusy = false
    end)
end

Kisuki = { enabled = false, hooked = false, charge = 1 }

Kisuki.effect = function(strong)
    local character = LocalPlayer.Character
    if not character or not character.PrimaryPart then return end
    local assets = ReplicatedStorage:FindFirstChild("Assets")
    local effects = assets and assets:FindFirstChild("Effects")
    local module = effects and effects:FindFirstChild("SuperDive")
    if not module then return end

    local restore = safeGetIdentity()
    safeSetIdentity(2)
    pcall(function()
        task.spawn(require(module), character, { IsStrong = strong })
    end)
    safeSetIdentity(restore)
end

Kisuki.install = function()
    if Kisuki.hooked then return end
    local Knit = getKnitRoot()
    if not Knit then return end
    local found, controller = pcall(Knit.GetController, "GameController")
    if not found or type(controller) ~= "table" or type(controller.Dive) ~= "function" then
        if not Core._fsWarned.kisukiController then
            Core._fsWarned.kisukiController = true
            Library:Notify({ Title = "Nodt Hub", Description = "Kisuki Dive: GameController não encontrado" })
        end
        return
    end

    local passthrough = controller.Dive
    Kisuki.originalDive = passthrough
    Kisuki.controller = controller
    controller.Dive = function(self, params, ...)
        if not Kisuki.enabled then
            return passthrough(self, params, ...)
        end

        local blend = math.clamp(Kisuki.charge, 0, 1)
        local restore = safeGetIdentity()
        safeSetIdentity(2)
        local styled, special = pcall(require, ReplicatedStorage.Content.Style.Kimiro.Special)
        safeSetIdentity(restore)
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

Kisuki.uninstall = function()
    if Kisuki.controller and Kisuki.originalDive then
        pcall(function()
            Kisuki.controller.Dive = Kisuki.originalDive
        end)
    end
    Kisuki.controller = nil
    Kisuki.originalDive = nil
    Kisuki.hooked = false
end

Kisuki.reset = function()
    Kisuki.controller = nil
    Kisuki.originalDive = nil
    Kisuki.hooked = false
end

Vault = { real = nil, want = {}, worn = false, wornRelease = nil, _typeCache = {}, _typeCacheCount = 0, _applied = {} }

-- Espera inventory.Equipped existir (Option do Knit so fica pronta apos KnitStart).
-- Retorna table ou nil. maxWait em segundos. Sem yield bloqueante: sleep 0.1s por tentativa.
Vault._waitEquipped = function(inventory, maxWait)
    if not inventory then return nil end
    -- Z5: NAO early-return se inventory.Equipped for nil. O Option do Knit so
    -- fica pronta apos KnitStart; o loop abaixo lida com nil ate o deadline.
    -- Early return matava o retry do patch N2 em setSlot/currentSlot no boot.
    local deadline = os.clock() + (maxWait or 1)
    while os.clock() < deadline do
        local ok, worn = pcall(function()
            return inventory.Equipped:get()
        end)
        if ok and type(worn) == "table" then
            return worn
        end
        task.wait(0.1)
    end
    return nil
end

Vault.mark = function(kind, on)
    -- N7: snapshot primeiro, wear depois. O hook vaultEquip so deve instalar
    -- depois que Vault.real existe, senao intercepta Equip sem snapshot.
    Vault.want[kind] = on or nil
    if not on then
        -- N1: ao desligar um kind, remove da _applied os ids que esse kind aplicou.
        -- Sem isso _applied cresce indefinidamente e mark reproduz o bulk original.
        for id in pairs(Vault._applied) do
            local idKind = Vault.typeOf(id)
            if idKind == kind then
                Vault._applied[id] = nil
            end
        end
    end

    local Knit = getKnitRoot()
    if not Knit then
        if not Core._fsWarned.vaultKnit then
            Core._fsWarned.vaultKnit = true
            Library:Notify({ Title = "Nodt Hub", Description = "Vault: Knit não encontrado — cosmetics limitados" })
        end
        return
    end
    local found, inventory = pcall(Knit.GetController, "InventoryController")
    if not found or type(inventory) ~= "table" or not inventory.Inventory then return end

    local held, current = pcall(function()
        return inventory.Inventory:get()
    end)
    if not held or type(current) ~= "table" then return end

    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = (genv.NODT and genv.NODT.Session) or rawget(genv, "NODT_SESSION") or genv.NODT_SESSION
    if type(session) ~= "table" then session = nil end

    if not Vault.real then
        local carried = session and session.vault or nil
        if carried and carried.inventory then
            -- X3: re-snapshot do inventario atual. Carried e da execucao anterior;
            -- se o servidor mudou (item comprado/removido), usar carried direto deixa
            -- o hook vaultEquip interceptando item que agora o jogador TEM (absorve
            -- sem chegar no servidor). Re-snapshot resolve.
            local okSnap, snapshot = pcall(function()
                return inventory.Inventory:get()
            end)
            if okSnap and type(snapshot) == "table" then
                Vault.real = {}
                for id, count in pairs(snapshot) do
                    Vault.real[id] = count
                end
            else
                -- Z2: fallback copia, nao compartilha referencia. Carried.inventory
                -- aponta pra session.vault.inventory; compartilhar deixa mutacao
                -- no proximo mark(_, false) corromper os dois.
                Vault.real = {}
                for id, count in pairs(carried.inventory) do
                    Vault.real[id] = count
                end
            end
            Vault.realTitle = carried.title
            Vault.realEquipped = carried.equipped or {}
            -- Y1: session.vault pode ser nil se um mark(_, false) anterior falhou em
            -- restaurar e zerou session.vault. Sem guard, o index crasha mark inteiro
            -- e deixa Vault.real populado sem worn (o wear final nao roda).
            if session and session.vault then
                session.vault.inventory = Vault.real
            end
        else
            local snapshot = {}
            for id, count in pairs(current) do
                snapshot[id] = count
            end
            Vault.real = snapshot
            Vault.realTitle = LocalPlayer:GetAttribute("User_Title")
            -- Equipped e Option do Knit: fica nil ate KnitStart. Retry curto (max 1s)
            -- pra nao snapshotar {} vazio se mark rodar no boot.
            local worn = Vault._waitEquipped(inventory, 1)
            local realEquipped = {}
            if type(worn) == "table" then
                for slot, value in pairs(worn) do
                    realEquipped[slot] = value
                end
            end
            Vault.realEquipped = realEquipped
            if session then
                local previousVault = type(session.vault) == "table" and session.vault or nil
                session.vault = {
                    inventory = Vault.real,
                    title = Vault.realTitle,
                    equipped = Vault.realEquipped,
                    worn = previousVault and previousVault.worn or false,
                    wornRelease = previousVault and previousVault.wornRelease or nil,
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
        -- N3: libera o hook vaultEquip antes de restaurar o inventario real.
        -- Sem isso, o hook fica ativo sem snapshot correspondente e o proximo
        -- mark ve Vault.real populado e pula o snapshot (usa dados velhos).
        if Vault.worn and type(Vault.wornRelease) == "function" then
            pcall(Vault.wornRelease)
        end
        -- X2: apos rejoin, session.vault.wornRelease pode ser o release da
        -- execucao ANTERIOR (hook diferente). Chamar se nao for o mesmo que o atual.
        if session and session.vault and type(session.vault.wornRelease) == "function"
            and session.vault.wornRelease ~= Vault.wornRelease then
            pcall(session.vault.wornRelease)
        end
        Vault.worn = false
        Vault.wornRelease = nil
        if session and session.vault then
            session.vault.worn = false
            session.vault.wornRelease = nil
        end
        local restored = pcall(function()
            inventory.Inventory:set(Vault.real)
        end)
        if restored then
            Vault.real = nil
            Vault._applied = {}
            if session then session.vault = nil end
        end
        return
    end

    -- Nao replica mais o inventario inteiro. So adiciona os ids especificos
    -- que o Vault aplicou visualmente (rastreados em Vault._applied).
    -- Bulk loop poluia cache local e nao burlava IsEquipped (server-side).
    local stocked = {}
    for id, count in pairs(Vault.real) do
        stocked[id] = count
    end
    for id in pairs(Vault._applied or {}) do
        stocked[id] = 1
    end
    pcall(function()
        inventory.Inventory:set(stocked)
    end)
    -- Z4: mantem session.vault.inventory refletindo o Vault.real atual.
    -- Sem isso, session.vault.inventory fica no snapshot ORIGINAL mesmo se
    -- _applied mudou via setSlot/wear entre mark e unload. Restore do unload
    -- passa a usar o snapshot mais recente.
    if session and session.vault and Vault.real then
        local snapshotCopy = {}
        for id, count in pairs(Vault.real) do
            snapshotCopy[id] = count
        end
        session.vault.inventory = snapshotCopy
    end
    -- N7: instala o hook vaultEquip DEPOIS do snapshot existir.
    -- Antes disso o hook interceptava Equip com Vault.real == nil e passava direto.
    if on then
        Vault.wear()
    end
end

-- grava no cache de typeOf e conta entradas novas: > 200 indica leak lento (loga 1x por sessao)
Vault._cacheType = function(id, kind, entry)
    local cache = Vault._typeCache
    if cache[id] == nil then
        Vault._typeCacheCount = Vault._typeCacheCount + 1
        if Vault._typeCacheCount > 200 and not Core._fsWarned.vaultCacheStale then
            Core._fsWarned.vaultCacheStale = true
            warn("[NodtHub] vaultCache degradou (comportamento volta ao original)")
        end
    end
    cache[id] = { kind, entry, os.clock() }
end

Vault.typeOf = function(id)
    -- cache por ID: sucessos ficam na sessao (modulos de item nao mudam); falhas (modulo ausente /
    -- require falhou) ficam so 2s, pois o Content pode carregar depois e o cache revalida.
    local cached = Vault._typeCache[id]
    if cached then
        if cached[1] then return cached[1], cached[2] end
        if os.clock() - cached[3] < 2 then return nil end -- TTL de 2s pra falha
    end
    local ItemFolder = ReplicatedStorage:FindFirstChild("Content") and ReplicatedStorage.Content:FindFirstChild("Item")
    local module = ItemFolder and ItemFolder:FindFirstChild("Entities")
    module = module and module:FindFirstChild(id)
    if not module then
        Vault._cacheType(id, nil, nil)
        return nil
    end
    local restore = safeGetIdentity()
    safeSetIdentity(2)
    local read, entry = pcall(require, module)
    safeSetIdentity(restore)
    if read and type(entry) == "table" and entry.Type then
        Vault._cacheType(id, entry.Type, entry)
        return entry.Type, entry
    end
    Vault._cacheType(id, nil, nil)
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
        CardState.pickedTeam = nil
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

local effectList, VisualApply
Vault.setSlot = function(kind, id)
    local Knit = getKnitRoot()
    if not Knit then
        if not Core._fsWarned.vaultKnit then
            Core._fsWarned.vaultKnit = true
            Library:Notify({ Title = "Nodt Hub", Description = "Vault: Knit não encontrado — cosmetics limitados" })
        end
        return
    end
    local found, inventory = pcall(Knit.GetController, "InventoryController")
    if not found or type(inventory) ~= "table" then return end
    -- N2: sem guard em inventory.Equipped. _waitEquipped lida com nil ate KnitStart.
    -- Timeout 0.3s (fluxo rapido, chamado por VisualApply e fireCardRemote a 0.5s).
    local worn = Vault._waitEquipped(inventory, 0.3)
    if type(worn) ~= "table" then return end
    local dressed = {}
    for slot, value in pairs(worn) do
        dressed[slot] = value
    end
    if id ~= nil and type(VisualApply) == "table" and type(VisualApply.pick) == "function" then
        local list
        if kind == "ScoreEffect" then
            list = effectList
        elseif kind == "Jersey" then
            list = CardState.jerseyList
        elseif kind == "PlayerCard" then
            list = CardState.cardList
        elseif kind == "Ball" then
            list = CardState.ballSkinList
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
    if id ~= nil then
        Vault._applied[id] = true
    end
    pcall(function()
        inventory.Equipped:set(dressed)
    end)
end

Vault.currentSlot = function(kind)
    local Knit = getKnitRoot()
    if not Knit then return nil end
    local found, inventory = pcall(Knit.GetController, "InventoryController")
    if not found or type(inventory) ~= "table" then return nil end
    -- N2: sem guard em inventory.Equipped. _waitEquipped lida com nil ate KnitStart.
    local worn = Vault._waitEquipped(inventory, 0.3)
    if type(worn) == "table" then
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
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = type(genv) == "table" and ((genv.NODT and genv.NODT.Session) or rawget(genv, "NODT_SESSION") or genv.NODT_SESSION) or nil
    if type(session) ~= "table" then session = nil end
    if Vault.worn and session and session.isHookActive and session.isHookActive("vaultEquip") then return true end
    if Vault.worn then
        Vault.worn, Vault.wornRelease = false, nil
        if session then
            session.vault = session.vault or {}
            session.vault.worn, session.vault.wornRelease = false, nil
        end
    end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return false end
    local InventoryService = getPackageService("InventoryService")
    local remote = InventoryService and getServiceChild(InventoryService, "RF", "Equip")
    if not remote then
        warn("[NodtHub] service not found")
        if not Core._fsWarned.vaultWear then
            Core._fsWarned.vaultWear = true
            Library:Notify({ Title = "Nodt Hub", Description = "Vault: InventoryService.Equip não encontrado" })
        end
        return false
    end

    -- hook absorve equip de item nao-comprado; Vault.dress aplica item falso, servidor nunca ve
    local hooked = hookNamecall("vaultEquip", function(callNext, self, method, ...)
        if not remote then return callNext(self, method, ...) end
        if self == remote and method == NET.K.INVOKE then
            local id = (...)
            if type(id) == "string" and Vault.real then
                local kind, entry = Vault.typeOf(id)
                if not Vault.real[id] then
                    if kind and Vault.currentSlot(kind) == id then
                        Vault.revert(kind)
                        return true
                    end
                    Vault._applied[id] = true
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
        Vault.wornRelease = hooked
        if session then
            session.vault = session.vault or {}
            session.vault.worn = true
            session.vault.wornRelease = hooked
        end
    end
    return hooked and true or false
end

Landing = {
    enabled = false,
    marker = nil,
    label = nil,
    tracked = nil,
    last = nil,
    stamp = 0,
    drift = Vector3.zero,
    drifts = { landing = Vector3.zero, trajectory = Vector3.zero },
    trackers = { landing = { tracked = nil, last = nil, stamp = 0 }, trajectory = { tracked = nil, last = nil, stamp = 0 } },
    floorCache = {},
    floorCacheSweepTick = 0,
    floorCacheTTL = 1.5,           -- 1.5s reduz misses em ~70%; a posicao da bola manda, nao o floor
    floorCacheCellSize = 5,        -- 5 studs por celula (X, Y, Z)
    floorCacheDisabled = false,    -- set true se fallback disparar N vezes
    floorCacheMisses = 0,          -- contador de divergencias detectadas
}

Landing.clear = function()
    if Landing.marker then
        pcall(function() Landing.marker:Destroy() end)
    end
    Landing.marker = nil
    Landing.label = nil
    Landing.tracked = nil
    Landing.last = nil
    Landing.drift = Vector3.zero
    Landing.drifts.landing = Vector3.zero
    Landing.drifts.trajectory = Vector3.zero
    Landing.trackers.landing = { tracked = nil, last = nil, stamp = 0 }
    Landing.trackers.trajectory = { tracked = nil, last = nil, stamp = 0 }
    Landing.floorCache = {}
    Landing.floorCacheSweepTick = 0
    Landing.floorCacheMisses = 0
end

Landing.build = function()
    local disc = Instance.new("Part")
    disc.Name = MARK
    disc.Shape = Enum.PartType.Cylinder
    disc.Size = Vector3.new(0.1, 3, 3)
    disc.Anchored = true
    disc.CanCollide = false
    disc.CanQuery = false
    disc.CanTouch = false
    disc.Material = Enum.Material.Neon
    disc.Transparency = 0.5
    disc.CastShadow = false
    disc.Parent = Workspace

    local board = Instance.new("BillboardGui")
    board.Size = UDim2.new(0, 60, 0, 20)
    board.StudsOffset = Vector3.new(0, 2.5, 0)
    board.AlwaysOnTop = true
    board.Parent = disc

    local text = Instance.new("TextLabel")
    text.Size = UDim2.fromScale(1, 1)
    text.BackgroundTransparency = 1
    text.TextScaled = false
    text.TextSize = 14
    text.Font = Enum.Font.GothamBold
    text.TextStrokeTransparency = 0.3
    text.TextColor3 = Color3.new(1, 1, 1)
    text.Parent = board

    Landing.marker = disc
    Landing.label = text
end

Landing.gravity = function()
    getCachedServices()
    local pulled, value = pcall(function()
        if not ServiceCache._GameConfig or not ServiceCache._State then return nil end
        return ServiceCache._State.get(ReplicatedStorage, ServiceCache._State.Id.Modifier, "BallGravity", ServiceCache._GameConfig.Physics.Gravity)
    end)
    if pulled and type(value) == "number" and value > 0 then
        return value
    end
    return 17
end

Landing.velocity = function(part, driftSlot)
    if not part or not part.Parent then return Vector3.zero end
    getCachedServices()
    local controller = ServiceCache._BallController
    if type(controller) == "table" and type(controller.ActiveBalls) == "table" then
            for _, record in pairs(controller.ActiveBalls) do
                local model = record.Ball
                if model and model.Parent and model:IsAncestorOf(part) and typeof(record.Velocity) == "Vector3" then
                    return record.Velocity
                end
            end
    end
    return Landing.drifts[driftSlot or "landing"] or Vector3.zero
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

-- helper local para Landing.predict: cache 3D bucket + fallback
local function landingCachedFloor(pos)
    getCachedServices()
    local module = ServiceCache._Physics
    if not module then return nil end

    if Landing.floorCacheDisabled then
        local ok, y = pcall(module.calculateFloorHeight, pos, true)
        if ok and type(y) == "number" then return y end
        return nil
    end

    local cell = Landing.floorCacheCellSize
    local kx = math.floor(pos.X / cell)
    local ky = math.floor(pos.Y / cell)
    local kz = math.floor(pos.Z / cell)
    local key = kx .. "_" .. ky .. "_" .. kz
    local now = os.clock()
    local entry = Landing.floorCache[key]
    if entry and now - entry.at < Landing.floorCacheTTL then
        return entry.y
    end

    local ok, y = pcall(module.calculateFloorHeight, pos, true)
    if ok and type(y) == "number" then
        Landing.floorCache[key] = { y = y, at = now }
        Landing.floorCacheSweepTick = (Landing.floorCacheSweepTick or 0) + 1
        if Landing.floorCacheSweepTick >= 30 then
            Landing.floorCacheSweepTick = 0
            local cache = Landing.floorCache
            local expiredKeys = {}
            local cacheKey, cacheEntry = next(cache)
            while cacheKey do
                if now - cacheEntry.at >= Landing.floorCacheTTL then
                    table.insert(expiredKeys, cacheKey)
                end
                cacheKey, cacheEntry = next(cache, cacheKey)
            end
            for _, expiredKey in ipairs(expiredKeys) do
                cache[expiredKey] = nil
            end
        end
        return y
    end
    return nil
end

Landing.predict = function(ball, driftSlot)
    if not ball or not ball.Parent then return nil end
    getCachedServices()
    local module = ServiceCache._Physics
    if not module then return nil end

    local gravity = Landing.gravity()
    local vel = Landing.velocity(ball, driftSlot)
    if typeof(vel) ~= "Vector3" then return nil end
    if not ball.Parent then return nil end
    local pos = ball.Position

    local floorY = module.LastFloorHeight
    if not floorY then
        floorY = landingCachedFloor(pos)
    end
    if not floorY then return nil end

    local flight = Landing.solve(pos, vel, gravity, floorY)
    if not flight then return nil end

    local spot = Vector3.new(pos.X + vel.X * flight, floorY, pos.Z + vel.Z * flight)
    -- 3D bucket (X_Y_Z) evita cache hit cross-level; 2D introduziria bug em steps/plataformas
    local ground = landingCachedFloor(Vector3.new(spot.X, pos.Y, spot.Z))

    -- FALLBACK: se o cache devolveu valor muito diferente do esperado E o cache ja
    -- falhou antes, forca cache off e recalcula do zero sem cache
    if ground and math.abs(ground - floorY) > 50 then
        Landing.floorCacheMisses = Landing.floorCacheMisses + 1
        if Landing.floorCacheMisses >= 3 and not Landing.floorCacheDisabled then
            Landing.floorCacheDisabled = true
            if not Core._fsWarned.landingFloorCacheDisabled then
                Core._fsWarned.landingFloorCacheDisabled = true
                warn("[NodtHub] landing: floor cache desativado apos 3 divergencias > 50 studs")
                if Library and Library.Notify then
                    Library:Notify({ Title = "Nodt Hub", Description = "Landing: preditor lento (cache desativado)" })
                end
            end
            if not Core._fsWarned.landingCacheStale then
                Core._fsWarned.landingCacheStale = true
                warn("[NodtHub] landingCache degradou (comportamento volta ao original)")
            end
        end
        local ok, fresh = pcall(module.calculateFloorHeight, Vector3.new(spot.X, pos.Y, spot.Z), true)
        if ok and type(fresh) == "number" then
            ground = fresh
        end
    end

    if ground and type(ground) == "number" and math.abs(ground - floorY) > 0.05 then
        local refined = Landing.solve(pos, vel, gravity, ground)
        if refined then
            flight = refined
            spot = Vector3.new(pos.X + vel.X * flight, ground, pos.Z + vel.Z * flight)
        end
    end

    return spot, module, flight, Landing.netHit(pos, vel, gravity, flight)
end

local LandingThrottle = {
    lastPredict = 0,
    lastSpot = nil,
    lastFlight = nil,
    lastPhysics = nil,
    lastNetted = false,
    lastBallPos = nil,
    interval = 0.06,
}

Landing.step = function()
    if not Landing.enabled then
        if Landing.marker then Landing.clear() end
        return
    end

    local now = os.clock()

    if Landing.marker then
        Landing.marker.Transparency = Landing.markerTransparency or 0.5
    end

    if now - LandingThrottle.lastPredict < LandingThrottle.interval then
        return
    end
    LandingThrottle.lastPredict = now

    local ball = getNearestBall()
    if not ball then
        if Landing.marker then Landing.marker.Transparency = 1 end
        Landing.last = nil
        return
    end

    local tracker = Landing.trackers.landing
    if tracker.tracked == ball and tracker.last and now > tracker.stamp then
        Landing.drifts.landing = (ball.Position - tracker.last) / (now - tracker.stamp)
    end
    tracker.tracked, tracker.last, tracker.stamp = ball, ball.Position, now

    local ballMoved = not LandingThrottle.lastBallPos
        or (ball.Position - LandingThrottle.lastBallPos).Magnitude > 0.5

    if not ballMoved and LandingThrottle.lastSpot then
        local spot = LandingThrottle.lastSpot
        local physics = LandingThrottle.lastPhysics
        local flight = LandingThrottle.lastFlight
        local netted = LandingThrottle.lastNetted

        if not Landing.marker then Landing.build() end
        local bounds = physics and physics._getCourtlines and physics._getCourtlines()
        local inside = true
        if bounds and physics and physics.isPositionInCourt then
            local ok, verdict = pcall(physics.isPositionInCourt, spot, nil, ball.Size.X * 0.5, nil)
            inside = not ok or verdict
        end
        local tone
        if netted then
            tone = Color3.fromRGB(250, 180, 40)
        elseif inside then
            tone = Color3.fromRGB(60, 220, 90)
        else
            tone = Color3.fromRGB(235, 60, 60)
        end
        local urgency = math.clamp(1 - flight / 2, 0, 1)
        local span = 3 + urgency * 1.5
        Landing.marker.Size = Vector3.new(0.1, span, span)
        Landing.markerTransparency = 0.5 - urgency * 0.15
        Landing.marker.Transparency = Landing.markerTransparency
        Landing.marker.Color = tone
        Landing.marker.CFrame = CFrame.new(spot + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90))
        Landing.label.Text = string.format("%.1fs", flight)
        Landing.label.TextColor3 = tone
        return
    end

    LandingThrottle.lastBallPos = ball.Position

    local spot, physics, flight, netted = Landing.predict(ball, "landing")
    if not spot then
        if Landing.marker then Landing.marker.Transparency = 1 end
        LandingThrottle.lastSpot = nil
        return
    end

    LandingThrottle.lastSpot = spot
    LandingThrottle.lastPhysics = physics
    LandingThrottle.lastFlight = flight
    LandingThrottle.lastNetted = netted

    if not Landing.marker then Landing.build() end
    local bounds = physics._getCourtlines and physics._getCourtlines()
    local inside = true
    if bounds and physics.isPositionInCourt then
        local ok, verdict = pcall(physics.isPositionInCourt, spot, nil, ball.Size.X * 0.5, nil)
        inside = not ok or verdict
    end

    local tone
    if netted then
        tone = Color3.fromRGB(250, 180, 40)
    elseif inside then
        tone = Color3.fromRGB(60, 220, 90)
    else
        tone = Color3.fromRGB(235, 60, 60)
    end

    local urgency = math.clamp(1 - flight / 2, 0, 1)
    local span = 3 + urgency * 1.5
    Landing.marker.Size = Vector3.new(0.1, span, span)
    Landing.markerTransparency = 0.5 - urgency * 0.15
    Landing.marker.Transparency = Landing.markerTransparency
    Landing.marker.Color = tone
    Landing.marker.CFrame = CFrame.new(spot + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90))
    Landing.label.Text = string.format("%.1fs", flight)
    Landing.label.TextColor3 = tone
end

function Landing.connect()
    if Landing.link or Library.Unloaded then return end
    Landing.link = RunService.RenderStepped:Connect(Landing.step)
end

function Landing.disconnect()
    if Landing.link then
        Landing.link:Disconnect()
        Landing.link = nil
    end
end

track({ Disconnect = Landing.disconnect })

local function cleanupSpikeTrajectory()
    for _, key in ipairs({
        "trajectoryBeam",
        "trajectoryAttach0",
        "trajectoryAttach1",
        "trajectoryPart",
    }) do
        local instance = TrajectoryState[key]
        if instance then
            pcall(function() instance:Destroy() end)
            TrajectoryState[key] = nil
        end
    end
end

local TrajectoryThrottle = { lastPredict = 0, lastSpot = nil, lastBallPos = nil, interval = 0.05 }

local function updateSpikeTrajectory()
    if not State.spikeTrajectoryEnabled then
        cleanupSpikeTrajectory()
        return
    end

    local now = os.clock()
    if now - TrajectoryThrottle.lastPredict < TrajectoryThrottle.interval then
        return
    end
    TrajectoryThrottle.lastPredict = now

    local ball = getNearestBall()
    if not ball then return end

    local tracker = Landing.trackers.trajectory
    if tracker.tracked == ball and tracker.last and now > tracker.stamp then
        Landing.drifts.trajectory = (ball.Position - tracker.last) / (now - tracker.stamp)
    end
    tracker.tracked, tracker.last, tracker.stamp = ball, ball.Position, now

    local ballMoved = not TrajectoryThrottle.lastBallPos
        or (ball.Position - TrajectoryThrottle.lastBallPos).Magnitude > 0.5

    local spot
    if not ballMoved and TrajectoryThrottle.lastSpot then
        spot = TrajectoryThrottle.lastSpot
    else
        spot = Landing.predict(ball, "trajectory")
        TrajectoryThrottle.lastSpot = spot
        TrajectoryThrottle.lastBallPos = ball.Position
    end

    if not spot then return end

    if not TrajectoryState.trajectoryBeam then
        TrajectoryState.trajectoryPart = Instance.new("Part")
        TrajectoryState.trajectoryPart.Anchored = true
        TrajectoryState.trajectoryPart.CanCollide = false
        TrajectoryState.trajectoryPart.CanQuery = false
        TrajectoryState.trajectoryPart.Transparency = 1
        TrajectoryState.trajectoryPart.Size = Vector3.new(0.5, 0.5, 0.5)
        TrajectoryState.trajectoryPart.Parent = workspace

        TrajectoryState.trajectoryAttach0 = Instance.new("Attachment", ball)
        TrajectoryState.trajectoryAttach1 = Instance.new("Attachment", TrajectoryState.trajectoryPart)

        TrajectoryState.trajectoryBeam = Instance.new("Beam")
        TrajectoryState.trajectoryBeam.Attachment0 = TrajectoryState.trajectoryAttach0
        TrajectoryState.trajectoryBeam.Attachment1 = TrajectoryState.trajectoryAttach1
        TrajectoryState.trajectoryBeam.Width0 = 0.2
        TrajectoryState.trajectoryBeam.Width1 = 0.2
        TrajectoryState.trajectoryBeam.FaceCamera = true
        TrajectoryState.trajectoryBeam.Color = ColorSequence.new(Color3.fromRGB(255, 60, 60))
        TrajectoryState.trajectoryBeam.LightEmission = 1
        TrajectoryState.trajectoryBeam.Parent = ball
    end

    TrajectoryState.trajectoryAttach0.Parent = ball
    TrajectoryState.trajectoryPart.Position = spot
    TrajectoryState.trajectoryBeam.Enabled = true
end

function TrajectoryState.connect()
    if TrajectoryState.link or Library.Unloaded then return end
    TrajectoryState.link = RunService.RenderStepped:Connect(updateSpikeTrajectory)
end

function TrajectoryState.disconnect()
    if TrajectoryState.link then
        TrajectoryState.link:Disconnect()
        TrajectoryState.link = nil
    end
end

track({ Disconnect = TrajectoryState.disconnect })

local function loadEffects()
    effectList = {
        "2026ScoreEffect", "AtomicExplosionScoreEffect", "AuroraScoreEffect", "BallPortalScoreEffect", "BananaSlipScoreEffect", "BeachSpiralScoreEffect", "BeachSplashScoreEffect", "BeatOfMadnessScoreEffect", "BinaryScoreEffect", "BlackHoleScoreEffect", "BloodMoonScoreEffect", "BlueHeartScoreEffect", "BotFaceEmojiScoreEffect", "BubbleScoreEffect", "BunnyHopScoreEffect", "CandyCaneScoreEffect", "CandyCrunchScoreEffect", "CannonBallRainScoreEffect", "CauldronSplashScoreEffect", "ChickScoreEffect", "ChocolateBeamScoreEffect", "ChocolateEggHatchingScoreEffect", "ChocolateSpiralScoreEffect", "ChocolateSplashScoreEffect", "CloudburstScoreEffect", "ColonThreeScoreEffect", "ColorfulFireScoreEffect", "CombiningHeartsScoreEffect", "ConfettiBurstScoreEffect", "CookieSplashScoreEffect", "CoolBunnyScoreEffect", "CoralScoreEffect", "CosmicSpiralScoreEffect", "CrabBeamScoreEffect", "CrabScurryScoreEffect", "CryoFlareScoreEffect", "CursedCrateScoreEffect", "CursedScoreEffect", "CyberWaveScoreEffect", "DarkStarScoreEffect", "DiamondScoreEffect", "DivineStrikeScoreEffect", "DynamiteScoreEffect", "EasterBeamScoreEffect", "EasterEggBasketScoreEffect", "EasterSwirlScoreEffect", "EggHatchScoreEffect", "EggMeteorScoreEffect", "EggRainScoreEffect", "ElectricScoreEffect", "EverybodyDanceScoreEffect", "FallingAcornScoreEffect", "FallingAnchorScoreEffect", "FallingAnvilScoreEffect", "FallingPianoScoreEffect", "FishExplosionScoreEffect", "FistSlamScoreEffect", "FlameScoreEffect", "FlamethrowerScoreEffect", "FloppyFishScoreEffect", "FountainScoreEffect", "FourLeafCloverSpiralScoreEffect", "GenieLampScoreEffect", "GhostVortexScoreEffect", "GiantEggDropScoreEffect", "GiantPlayerScoreEffect", "GiantSoccerKickScoreEffect", "GiantTongueScoreEffect", "GlowStickDanceScoreEffect", "GobbleStormScoreEffect", "GoldCoinPopScoreEffect", "GoldScoreEffect", "GoldenConfettiBurstScoreEffect", "GoldenEggPopScoreEffect", "GoldenWaveScoreEffect", "GravyWaveScoreEffect", "GreenEnergyScoreEffect", "GroundCrackScoreEffect", "HakkaScoreEffect", "HeartBeamScoreEffect", "HeartBubbleScoreEffect", "HeartScoreEffect", "HoneyScoreEffect", "IceCreamScoreEffect", "IceScoreEffect", "JohnDoeScoreEffect", "KittySpiralScoreEffect", "KrakenPullScoreEffect", "LaughingScoreEffect", "LavaSplashScoreEffect", "LeafExplosionScoreEffect", "Level100ScoreEffect", "Level200ScoreEffect", "LightShowScoreEffect", "LightningStrikeScoreEffect", "LuckyCloverScoreEffect", "LuckyStrikeScoreEffect", "MagicBurstScoreEffect", "MegaSunbeamScoreEffect", "MetaBlastScoreEffect", "MeteorScoreEffect", "MoneyExplosionScoreEffect", "MoonlightBeamScoreEffect", "MusicNoteStormScoreEffect", "NewYearsWrathScoreEffect", "NinjaStarScoreEffect", "NorthStarScoreEffect", "NukeScoreEffect", "OceanicSpiralScoreEffect", "PalmTreeHammockScoreEffect", "PastelRainbowScoreEffect", "PastelSwirlScoreEffect", "PineappleScoreEffect", "PinkCosmicSpiralScoreEffect", "PinkHeartScoreEffect", "PixelExplosionScoreEffect", "PlayerBubbleScoreEffect", "PlushieScoreEffect", "PotExplosionScoreEffect", "PotionSplashScoreEffect", "PumpkinPieBurstScoreEffect", "PumpkinSmashScoreEffect", "RainbowScoreEffect", "RainbowStarScoreEffect", "RainbowStrikeScoreEffect", "RandomFavoriteScoreEffect", "RankedWinsScoreEffect", "RedDragonScoreEffect", "RosePetalScoreEffect", "SantasWrathScoreEffect", "SeaCreatureExplosionScoreEffect", "Season0ProScoreEffect", "Season10ProScoreEffect", "Season11ProScoreEffect", "Season12ProScoreEffect", "Season13ProScoreEffect", "Season14ProScoreEffect", "Season15ProScoreEffect", "Season16ProScoreEffect", "Season17ProScoreEffect", "Season18ProScoreEffect", "Season19ProScoreEffect", "Season1ProScoreEffect", "Season2ProScoreEffect", "Season3ProScoreEffect", "Season4ProScoreEffect", "Season5ProScoreEffect", "Season6ProScoreEffect", "Season7ProScoreEffect", "Season8ProScoreEffect", "Season9ProScoreEffect", "ShockwaveBlastScoreEffect", "SixSeven2ScoreEffect", "SixSevenScoreEffect", "SkeletonGrabScoreEffect", "SkullScoreEffect", "SlimeSplashScoreEffect", "SnowTornadoScoreEffect", "SpellCasterScoreEffect", "SpiderInfestationScoreEffect", "SpiritExplosionScoreEffect", "SpringSunScoreEffect", "StPatricksBurstScoreEffect", "StormyWaveScoreEffect", "StrobeLightScoreEffect", "SupernovaScoreEffect", "TapDancerScoreEffect", "ThunderstormScoreEffect", "TimeStopperEasterScoreEffect", "TimeStopperScoreEffect", "TongueScoreEffect", "TrampolineScoreEffect", "TreasureChestScoreEffect", "TsunamiScoreEffect", "VioletBeamScoreEffect", "WaterSplashScoreEffect", "WatermelonSmashScoreEffect", "WhirlpoolScoreEffect", "WindBurstScoreEffect", "WolfEmojiScoreEffect", "XDScoreEffect", "XylophoneScoreEffect"
    }
    table.sort(effectList)
    return effectList
end

effectList = loadEffects()

CardState.cardList = {}
local function loadCards()
    CardState.cardList = {}
    local ok, ItemEntities = pcall(function()
        return ReplicatedStorage.Content.Item.Entities
    end)
    if ok and ItemEntities then
        for _, child in ipairs(ItemEntities:GetChildren()) do
            if child:IsA("ModuleScript") then
                local name = child.Name
                if string.match(name, "PlayerCard") then
                    local restore = safeGetIdentity()
                    safeSetIdentity(2)
                    local loaded, entry = pcall(require, child)
                    safeSetIdentity(restore)
                    if loaded and type(entry) == "table" and entry.Type == "PlayerCard" then
                        table.insert(CardState.cardList, name)
                    end
                end
            end
        end
    end
    table.sort(CardState.cardList)
    if #CardState.cardList == 0 then
        table.insert(CardState.cardList, "ContentCreatorPlayerCard")
    end
    return CardState.cardList
end

CardState.cardList = loadCards()

local function enableHitEffect()
    if CardState.hitConnection then return end
    CardState.hasFired = false
    CardState.isLocalHit = false
    local lastHitTime = 0
    local lastVaultTime = 0
    local Remote = Remotes.HitGround
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
    local function releaseHitConnections()
        if CardState.hitRemovedConnection then CardState.hitRemovedConnection:Disconnect() end
        if CardState.hitConnection then CardState.hitConnection:Disconnect() end
        if Library.HitRemoteConn then Library.HitRemoteConn:Disconnect() end
        CardState.hitRemovedConnection = nil
        CardState.hitConnection = nil
        Library.HitRemoteConn = nil
    end
    Library.HitRemoteConn = track(Remote.OnClientEvent:Connect(function(...)
        local args = {...}
        local myName = LocalPlayer.Name
        for _, val in pairs(args) do
            if tostring(val) == myName then
                CardState.isLocalHit = true
                break
            end
        end
    end))
    if not Library.HitRemoteConn then
        releaseHitConnections()
        return false
    end
    local function fireHitRemote(hitPos)
        if CardState.hasFired then return end
        if not CardState.isLocalHit then return end
        if not CardState.hitEffectEnabled then return end
        -- Cooldown por tempo (sem travar a thread no final)
        if os.clock() - lastHitTime <= 0.3 then return end
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if root and root.AssemblyLinearVelocity.Magnitude > 50 then return end
        lastHitTime = os.clock()
        CardState.hasFired = true
        local myUsername = LocalPlayer.Name
        local targetObject = workspace:FindFirstChild(myUsername) or workspace:FindFirstChild("uwuwuwiiwuw6")
        local effectId = State.selectedEffect
        local hardHit = true
        if effectId == "GroundHit1" or effectId == "GroundHit2" then
            hardHit = effectId == "GroundHit2"
            effectId = nil
        end
        if firesignal then
            -- #2: sincroniza o slot do inventário em background pra nao segurar
            -- o frame do hit. Vault.setSlot pode levar ate 0.3s via _waitEquipped.
            -- Cooldown: evita flood de chamadas ao Vault (no maximo 1 a cada 0.5s).
            if os.clock() - lastVaultTime > 0.5 then
                lastVaultTime = os.clock()
                local spawnEffectId = State.selectedEffect
                task.spawn(function()
                    pcall(Vault.setSlot, "ScoreEffect", spawnEffectId)
                end)
            end
            -- [NOVO] delay antes do firesignal
            task.wait(math.random(9, 11) / 100)
            local fsOk = pcall(firesignal, Remote.OnClientEvent, table.unpack({
                hitPos,
                hardHit,
                false,
                5,
                effectId,
                targetObject,
                Vector3.new(-0.000002088591600113432, 1, -0.000004710930170404026)
            }, 1, 7))
            if not fsOk and not Core._fsWarned.fireHitRemote then
                Core._fsWarned.fireHitRemote = true
                warn("[NodtHub] firesignal falhou em fireHitRemote")
            end
        end
        CardState.hasFired = false
        CardState.isLocalHit = false
    end
    CardState.hitConnection = track(workspace.ChildAdded:Connect(function(child)
        if child.Name == "HitIndicator" then
            if child.Color == Color3.fromRGB(0, 255, 0) then
                -- Fire em background: fireHitRemote tem task.wait + Vault.setSlot +
                -- firesignal, todos sincronos. Rodar na thread do ChildAdded travava
                -- o frame do hit antes do efeito sair.
                local hitPos = child.Position
                task.spawn(function()
                    fireHitRemote(hitPos)
                end)
            end
        end
    end))
    if not CardState.hitConnection then
        releaseHitConnections()
        return false
    end
    CardState.hitRemovedConnection = track(workspace.DescendantRemoving:Connect(function(child)
        if child.Name == "HitIndicator" then
            CardState.hasFired = false
            CardState.isLocalHit = false
        end
    end))
    if not CardState.hitRemovedConnection then
        releaseHitConnections()
        return false
    end
    return true
end

local function setupCharacter(character)
    local humanoid = character:WaitForChild("Humanoid", 10)
    local rootPart = character:WaitForChild("HumanoidRootPart", 10)
    if not humanoid or not rootPart then return end
    
    if MovementState.shiftLockConnection then
        MovementState.shiftLockConnection:Disconnect()
        MovementState.shiftLockConnection = nil
    end
    if MovementState.floorMaterialConnection then
        MovementState.floorMaterialConnection:Disconnect()
        MovementState.floorMaterialConnection = nil
    end
    if MovementState.stateChangedConnection then
        MovementState.stateChangedConnection:Disconnect()
        MovementState.stateChangedConnection = nil
    end

    MovementState.shiftLockConnection = humanoid:GetPropertyChangedSignal("Jump"):Connect(function()
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

    MovementState.floorMaterialConnection = humanoid:GetPropertyChangedSignal("FloorMaterial"):Connect(function()
        if State.autoShiftLockEnabled or AutoCorner.enabled then
            return
        end
        if humanoid.FloorMaterial == Enum.Material.Air then
            humanoid.AutoRotate = false
        else
            humanoid.AutoRotate = true
        end
    end)

    -- Limpa mira antiga do AutoCorner ao aterrissar / voltar a correr
    MovementState.stateChangedConnection = humanoid.StateChanged:Connect(function(_, newState)
        if newState == Enum.HumanoidStateType.Landed or newState == Enum.HumanoidStateType.Running then
            AutoCorner.steer = nil
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

local function ensureAnimationController()
    if _AC and type(_AC.PlayAnimation) == "function" then
        return true
    end
    local ok, module = pcall(function()
        local controllers = game:GetService("ReplicatedFirst"):FindFirstChild("Controllers")
            or game:GetService("ReplicatedFirst"):WaitForChild("Controllers", 2)
        if not controllers then return nil end
        local anim = controllers:FindFirstChild("AnimationController")
            or controllers:WaitForChild("AnimationController", 2)
        if not anim then return nil end
        return require(anim)
    end)
    if ok and module and type(module.PlayAnimation) == "function" then
        _AC = module
        return true
    end
    return false
end

local function doFakeSpike()
    if not State.fakeSpikeEnabled then return end

    local character = LocalPlayer.Character
    if not character then return end

    local hum = character:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return end

    if not ensureAnimationController() then return end

    -- Pulo real da finta (mantido de propósito)
    hum.Jump = true

    pcall(function()
        _AC:PlayAnimation("SpikeJump")
    end)

    task.delay(0.28, function()
        -- Personagem ainda é o mesmo e está vivo?
        if LocalPlayer.Character ~= character then return end
        local currentHum = character:FindFirstChildOfClass("Humanoid")
        if not currentHum or currentHum.Health <= 0 then return end
        if not (_AC and type(_AC.PlayAnimation) == "function") then return end
        pcall(function()
            _AC:PlayAnimation("Spike")
        end)
    end)
end

function MovementState.fakeSpikeConnect()
    if MovementState.fakeSpikeLink or Library.Unloaded then return end
    MovementState.fakeSpikeLink = UserInputService.JumpRequest:Connect(function()
        if not State.fakeSpikeEnabled then return end
        pcall(doFakeSpike)
    end)
end

function MovementState.fakeSpikeDisconnect()
    if MovementState.fakeSpikeLink then
        MovementState.fakeSpikeLink:Disconnect()
        MovementState.fakeSpikeLink = nil
    end
end

track({ Disconnect = MovementState.fakeSpikeDisconnect })

local function startAutoSpin()
    State.autoSpinGen = (State.autoSpinGen or 0) + 1
    local gen = State.autoSpinGen
    task.spawn(function()
        local nameLabel, Roll
        local rolls = 0
        while State.autoSpin and State.autoSpinGen == gen and not Library.Unloaded do
            if #CardState.desiredStyles == 0 or rolls >= 5000 then State.autoSpin = false; return end
            if not nameLabel or not nameLabel.Parent then
                local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
                local interface = pg and pg:FindFirstChild("Interface")
                local lobby = interface and interface:FindFirstChild("Lobby")
                local sub = lobby and lobby:FindFirstChild("Styles")
                local topPanel = sub and sub:FindFirstChild("TopPanel")
                nameLabel = topPanel and topPanel:FindFirstChild("DisplayName")
                if not nameLabel then
                    task.wait(0.5)
                    continue
                end
            end
            local current = nameLabel.Text
            for _, wanted in ipairs(CardState.desiredStyles) do
                if current == wanted then
                    State.autoSpin = false
                    return
                end
            end
            if not Roll or not Roll.Parent then
                local Service = getPackageService("StyleService")
                Roll = Service and getServiceChild(Service, "RF", "Roll")
                if not Roll then
                    warn("[NodtHub] service not found")
                    return
                end
            end
            rolls = rolls + 1
            local ok = pcall(Roll.InvokeServer, Roll, State.spinType == "Lucky")
            task.wait(ok and 0.15 or 1)
        end
    end)
end

local function startAutoAbilitySpin()
    State.autoAbilitySpinGen = (State.autoAbilitySpinGen or 0) + 1
    local gen = State.autoAbilitySpinGen
    task.spawn(function()
        local nameLabel, Roll
        local rolls = 0
        while State.autoAbilitySpin and State.autoAbilitySpinGen == gen and not Library.Unloaded do
            if #CardState.desiredAbilities == 0 or rolls >= 5000 then State.autoAbilitySpin = false; return end
            if not nameLabel or not nameLabel.Parent then
                local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
                local interface = pg and pg:FindFirstChild("Interface")
                local lobby = interface and interface:FindFirstChild("Lobby")
                local sub = lobby and lobby:FindFirstChild("Abilities")
                local topPanel = sub and sub:FindFirstChild("TopPanel")
                nameLabel = topPanel and topPanel:FindFirstChild("DisplayName")
                if not nameLabel then
                    task.wait(0.5)
                    continue
                end
            end
            local current = nameLabel.Text
            for _, wanted in ipairs(CardState.desiredAbilities) do
                if current == wanted then
                    State.autoAbilitySpin = false
                    return
                end
            end
            if not Roll or not Roll.Parent then
                local Service = getPackageService("AbilityService")
                Roll = Service and getServiceChild(Service, "RF", "Roll")
                if not Roll then
                    warn("[NodtHub] service not found")
                    return
                end
            end
            rolls = rolls + 1
            local ok = pcall(Roll.InvokeServer, Roll, State.abilitySpinType == "Lucky")
            task.wait(ok and 0.15 or 1)
        end
    end)
end

local function enableAntiLag()
	if AntiLagState.enabled then return end
	AntiLagState.enabled = true
	AntiLagState.optimizedPlayers = setmetatable({}, { __mode = "k" })
	AntiLagState.playerConns = {}

	local function safeGet(instance, propertyName)
		local reached, value = pcall(function() return instance[propertyName] end)
		if reached then return value end
		return nil
	end
	local function safeSet(instance, propertyName, value)
		if not instance then return end
		pcall(function() instance[propertyName] = value end)
	end
	local function rememberProperty(instance, propertyName)
		if not instance then return end
		local data = AntiLagState.changedProperties[instance]
		if not data then
			data = {}
			AntiLagState.changedProperties[instance] = data
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
		if Library.Root and instance:IsDescendantOf(Library.Root) then
			return true
		end
		local name = instance.Name
		if name == MARK or name == MARK2 then return true end
		if name == "NodtHub_FloatBtn" or name == "NODT_Loader" or name == "KeyPanel" then return true end
		if name == "HitIndicator" then return true end
		local ancestor = instance.Parent
		local depth = 0
		while ancestor and depth < 10 do
			if ancestor.Name == MARK or ancestor.Name == MARK2 then return true end
			ancestor = ancestor.Parent
			depth = depth + 1
		end
		local char = LocalPlayer.Character
		if char and instance:IsDescendantOf(char) then return true end
		local model = instance:FindFirstAncestorOfClass("Model")
		if model and model.Parent == workspace and model:FindFirstChildOfClass("Humanoid") then
			return true
		end
		local parent = instance.Parent
		depth = 0
		while parent and depth < 5 do
			if parent.Name == "Notify" or parent.Name == "Keybinds" or parent.Name == "TipCard" then
				return true
			end
			parent = parent.Parent
			depth = depth + 1
		end
		return false
	end

	local function optimizeInstance(instance)
		if shouldSkip(instance) then return end
		-- pcall unico por instancia: rememberAndSet faz 2 pcalls por prop; envolver o bloco economiza ~60% de pcalls no batch inicial.
		if instance:IsA("BasePart") then
			pcall(function()
				rememberAndSet(instance, "Reflectance", 0)
				rememberAndSet(instance, "CastShadow", false)
				if instance:IsA("MeshPart") then
					rememberAndSet(instance, "RenderFidelity", Enum.RenderFidelity.Performance)
				end
			end)
		elseif instance:IsA("ParticleEmitter") or instance:IsA("Trail") or instance:IsA("Beam")
			or instance:IsA("Smoke") or instance:IsA("Fire") or instance:IsA("Sparkles") then
			pcall(function()
				rememberAndSet(instance, "Enabled", false)
			end)
		elseif instance:IsA("PointLight") or instance:IsA("SpotLight") or instance:IsA("SurfaceLight") then
			pcall(function()
				rememberAndSet(instance, "Enabled", false)
			end)
		end
	end

	local function optimizePlayer(player)
		if player == LocalPlayer then return end
		if AntiLagState.optimizedPlayers[player] then return end
		AntiLagState.optimizedPlayers[player] = true

		local function scanCharacter(character)
			if not character then return end
			for _, desc in ipairs(character:GetDescendants()) do
				if desc:IsA("BasePart") then
					rememberAndSet(desc, "Reflectance", 0)
					rememberAndSet(desc, "CastShadow", false)
					if desc:IsA("MeshPart") then
						rememberAndSet(desc, "RenderFidelity", Enum.RenderFidelity.Performance)
					end
				elseif desc:IsA("Decal") or desc:IsA("Texture") then
					rememberAndSet(desc, "Transparency", 1)
				elseif desc:IsA("BillboardGui") or desc:IsA("SurfaceGui") or desc:IsA("ScreenGui") then
					rememberAndSet(desc, "Enabled", false)
				elseif desc:IsA("ParticleEmitter") or desc:IsA("Trail") or desc:IsA("Beam")
					or desc:IsA("Smoke") or desc:IsA("Fire") or desc:IsA("Sparkles") then
					rememberAndSet(desc, "Enabled", false)
				end
			end
			local animator = character:FindFirstChildWhichIsA("Animator", true)
			if animator then
				pcall(function()
					for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
						pcall(track.Stop, track, 0)
					end
				end)
			end
		end

		scanCharacter(player.Character)
		table.insert(AntiLagState.playerConns, track(player.CharacterAdded:Connect(function(char)
			task.wait(0.5)
			if AntiLagState.enabled then scanCharacter(char) end
		end)))
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
		if AntiLagState.oldQualityLevel == nil then
			AntiLagState.oldQualityLevel = rendering.QualityLevel
		end
		rendering.QualityLevel = Enum.QualityLevel.Level01
		local userGameSettings = UserSettings():GetService("UserGameSettings")
		if AntiLagState.oldSavedQualityLevel == nil then
			AntiLagState.oldSavedQualityLevel = userGameSettings.SavedQualityLevel
		end
		userGameSettings.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1
	end

	setLowestQuality()
	optimizeLighting()
	optimizeTerrain()

	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LocalPlayer then optimizePlayer(p) end
	end
	table.insert(AntiLagState.playerConns, track(Players.PlayerAdded:Connect(function(p)
		if AntiLagState.enabled and p ~= LocalPlayer then optimizePlayer(p) end
	end)))

	local descendants = {}
	local descendantsReady = false
	task.spawn(function()
		for _, v in ipairs(workspace:GetDescendants()) do
			table.insert(descendants, v)
			if #descendants % 1000 == 0 then task.wait() end
		end
		descendantsReady = true
	end)
	local index = 1
	local batchSize = 300
	local batchConn
	batchConn = RunService.Heartbeat:Connect(function()
		if Library.Unloaded or not AntiLagState.enabled then
			if batchConn then batchConn:Disconnect() batchConn = nil end
			return
		end
		if not descendantsReady then return end
		local last = math.min(index + batchSize - 1, #descendants)
		-- Orcamento de ~2ms por frame: mesmo resultado, sem estourar o frame time.
		local budgetEnd = os.clock() + 0.002
		local i = index
		while i <= last do
			optimizeInstance(descendants[i])
			i = i + 1
			if os.clock() > budgetEnd then break end
		end
		last = i - 1
		index = last + 1
		if index > #descendants then
			if batchConn then batchConn:Disconnect() batchConn = nil end
		end
	end)
	table.insert(AntiLagState.antilagConnections, batchConn)

	local queue = {}
	local scheduled = false
	local function flushQueue()
		scheduled = false
		if Library.Unloaded or not AntiLagState.enabled then return end
		local snapshot = queue
		queue = {}
		for _, inst in ipairs(snapshot) do optimizeInstance(inst) end
	end
	table.insert(AntiLagState.antilagConnections, workspace.DescendantAdded:Connect(function(instance)
		if Library.Unloaded or not AntiLagState.enabled then return end
		table.insert(queue, instance)
		if not scheduled then
			scheduled = true
			task.delay(0.1, flushQueue)
		end
	end))
end

local function disableAntiLag()
	AntiLagState.enabled = false
	for instance, props in pairs(AntiLagState.changedProperties) do
		if instance and instance.Parent then
			for prop, value in pairs(props) do
				pcall(function() instance[prop] = value end)
			end
		end
	end
	AntiLagState.changedProperties = setmetatable({}, { __mode = "k" })
	if AntiLagState.oldQualityLevel ~= nil then
		pcall(function() settings().Rendering.QualityLevel = AntiLagState.oldQualityLevel end)
		AntiLagState.oldQualityLevel = nil
	end
	if AntiLagState.oldSavedQualityLevel ~= nil then
		pcall(function() UserSettings():GetService("UserGameSettings").SavedQualityLevel = AntiLagState.oldSavedQualityLevel end)
		AntiLagState.oldSavedQualityLevel = nil
	end
	for _, conn in ipairs(AntiLagState.antilagConnections) do
		pcall(function() conn:Disconnect() end)
	end
	AntiLagState.antilagConnections = {}
	for _, conn in ipairs(AntiLagState.playerConns or {}) do
		pcall(function() conn:Disconnect() end)
	end
	AntiLagState.playerConns = {}
	AntiLagState.optimizedPlayers = setmetatable({}, { __mode = "k" })
end
Library.RestoreAntiLag = disableAntiLag


-- ============================================================
-- [CORE] FACHADA PÚBLICA — expõe a lógica para a UI
-- ============================================================
-- Internamente o core continua usando locals (limite de 200 no chunk).
-- A UI deve chamar apenas os métodos abaixo.

Core.State = State

-- Spike / movement

-- Spike
Core.ToggleRedirectSpike = function(value)
	if value then enableRedirectSpike() else disableRedirectSpike() end
end
Core.ToggleAutoCorner = function(value)
	AutoCorner.enabled = value and true or false
	if value then
		AutoCorner.installAim()
	else
		AutoCorner.disableAim()
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
end
Core.SetAutoCornerSide = function(value)
	AutoCorner.side = value
end
Core.SetAutoCornerReach = function(value)
	AutoCorner.reach = value
end
Core.SetAutoCornerDepth = function(v) AutoCorner.depth = math.clamp(tonumber(v) or 1.0, 0.1, 1.0) end
Core.ToggleSilentSpike = function(value)
	State.newSilentSpikeEnabled = value and true or false
	if ButtonState.newSpikeButton then ButtonState.newSpikeButton.Visible = value end
	if not value and Silent and Silent.uninstall then
		Silent.uninstall()
	end
end
Core.FireSilentSpike = function()
	fireNewSpike()
end
Core.ToggleSanjuTilt = function(value)
	if value then enableSanjuTilt() else disableSanjuTilt() end
end
Core.ToggleMaxCharge = function(value)
	if value then enableMaxCharge() else disableMaxCharge() end
end
Core.ToggleFakeSpike = function(value)
	State.fakeSpikeEnabled = value and true or false
	if value then
		MovementState.fakeSpikeConnect()
	else
		MovementState.fakeSpikeDisconnect()
	end
end
Core.ToggleAutoCounter = function(value)
	AutoCounter.state.enabled = value and true or false
	if value then
		AutoCounter.connect()
	elseif AutoCounter.connection then
		pcall(function() AutoCounter.connection:Disconnect() end)
		AutoCounter.connection = nil
	end
end
Core.SetAutoCounterMove = function(value)
	AutoCounter.state.move = value
end
Core.SetAutoCounterNetRange = function(value)
	AutoCounter.state.netRange = value
end
Core.SetAutoCounterLateral = function(value)
	AutoCounter.state.lateral = value
end
Core.SetAutoCounterDelay = function(value)
	AutoCounter.state.delay = value
end
Core.SetAutoCounterJump = function(value)
	AutoCounter.state.autoJump = value and true or false
end

-- Hitbox
Core.ToggleHitbox = function(value)
	HitboxState.hitboxEnabled = value and true or false
	if value then updateHitboxes(HitboxState.hitboxScale) else removeHitboxes() end
end
Core.SetHitboxSize = function(value)
	HitboxState.hitboxScale = value
	if HitboxState.hitboxEnabled then updateHitboxes(value) end
end
Core.SetHitboxColor = function(value)
	local colors = {
		Invisible = Color3.fromRGB(255, 255, 255), White = Color3.fromRGB(255, 255, 255),
		Green = Color3.fromRGB(0, 255, 0), Blue = Color3.fromRGB(0, 0, 255),
		Red = Color3.fromRGB(255, 0, 0), Yellow = Color3.fromRGB(255, 255, 0),
		Purple = Color3.fromRGB(128, 0, 128), Orange = Color3.fromRGB(255, 165, 0),
		Pink = Color3.fromRGB(255, 105, 180),
	}
	local transparencies = {
		Invisible = 1, White = 0.3, Green = 0.3, Blue = 0.3, Red = 0.3,
		Yellow = 0.3, Purple = 0.3, Orange = 0.3, Pink = 0.3,
	}
	HitboxState.hitboxColor = colors[value] or Color3.fromRGB(0, 0, 255)
	HitboxState.hitboxTransparency = transparencies[value] or 0.3
	if HitboxState.hitboxEnabled then updateHitboxes(HitboxState.hitboxScale) end
end
Core.RemoveHitboxes = function()
	removeHitboxes()
end

-- Performance
Core.ToggleStopBallButton = function()
	ButtonState.stopBallVisible = not ButtonState.stopBallVisible
	if ButtonState.stopBallButton then
		ButtonState.stopBallButton.Visible = ButtonState.stopBallVisible
	else
		ButtonState.stopBallButton = createStopBallButton()
	end
end
Core.ToggleAimButton = function()
	ButtonState.aimVisible = not ButtonState.aimVisible
	if ButtonState.aimButton then
		ButtonState.aimButton.Visible = ButtonState.aimVisible
	else
		ButtonState.aimButton = createAimButton()
	end
end

-- Performance / movement
Core.ToggleAntiLag = function(value)
	if value then enableAntiLag() else disableAntiLag() end
end
Core.ToggleDesync = function(value)
	if value then enableDesync() else disableDesync() end
end
Core.ToggleAutoBlock = function(value)
    State.autoBlockEnabled = value and true or false
    if value then
        enableAutoBlock()
    else
        disableAutoBlock()
    end
end
Core.ToggleAutoRejoin = function(value)
    if value then enableAutoRejoin() else disableAutoRejoin() end
end
Core.ToggleAutoReady = function(value)
    State.autoReadyEnabled = value and true or false
    if value then
        if not MovementState.autoReadyThread then
            MovementState.autoReadyThread = task.spawn(function()
                local readyText = {
                    ["ready"] = true, ["accept"] = true, ["confirm"] = true,
                    ["play again"] = true, ["jogar novamente"] = true, ["aceitar"] = true,
                }
                local watched, buttons, links = nil, {}, {}
                local function unwatch()
                    for _, link in ipairs(links) do
                        pcall(function() link:Disconnect() end)
                    end
                    watched, buttons, links = nil, {}, {}
                end
                local function watch(gui)
                    unwatch()
                    watched = gui
                    for _, inst in ipairs(gui:GetDescendants()) do
                        if inst:IsA("TextButton") then buttons[inst] = true end
                    end
                    links[1] = gui.DescendantAdded:Connect(function(inst)
                        if inst:IsA("TextButton") then buttons[inst] = true end
                    end)
                    links[2] = gui.DescendantRemoving:Connect(function(inst)
                        buttons[inst] = nil
                    end)
                end
                while State.autoReadyEnabled and not Library.Unloaded do
                    task.wait(0.3)
                    pcall(function()
                        local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
                        if pg ~= watched then
                            if pg then watch(pg) else unwatch() end
                        end
                        if pg then
                            local clicked = false
                            for gui in pairs(buttons) do
                                if gui.Visible and readyText[string.lower(gui.Text or "")] then
                                    if firesignal then
                                        pcall(function()
                                            firesignal(gui.MouseButton1Click)
                                            firesignal(gui.Activated)
                                        end)
                                    end
                                    clicked = true
                                    break
                                end
                            end
                            if clicked then task.wait(0.5) end
                        end
                    end)
                end
                pcall(unwatch)
                MovementState.autoReadyThread = nil
            end)
        end
    end
end

-- Spike
Core.ToggleAutoSetAim = function(value)
    if value then enableAutoSetAim() else disableAutoSetAim() end
end
Core.ToggleAutoSpike = function(value)
    State.autoSpikeEnabled = value and true or false
    if value then
        if not MovementState.autoSpikeConn then
            MovementState.autoSpikeConn = track(RunService.Heartbeat:Connect(autoSpikeStep))
        end
    else
        if MovementState.autoSpikeConn then
            MovementState.autoSpikeConn:Disconnect()
            MovementState.autoSpikeConn = nil
        end
        MovementState.autoSpikeLastStep = 0
        MovementState.autoSpikeLastFire = 0
    end
end
Core.SetAutoSpikeAim = function(v) State.autoSpikeAim = v and true or false end

-- Performance
Core.ToggleAntiAFK = function(value)
	if not value then
		if MovementState.antiAfkConnection then
			MovementState.antiAfkConnection:Disconnect()
			MovementState.antiAfkConnection = nil
		end
		return
	end
	if MovementState.antiAfkConnection then return end
	MovementState.antiAfkConnection = LocalPlayer.Idled:Connect(function()
		pcall(function()
			LocalPlayer:SetAttribute("LastInput", tick())
		end)
		local VirtualUser = game:GetService("VirtualUser")
		if VirtualUser then
			local okCapture = pcall(VirtualUser.CaptureController, VirtualUser)
			local okClick = pcall(VirtualUser.ClickButton2, VirtualUser, Vector2.new())
			if okCapture and okClick then return end
		end
		pcall(function()
			if UserInputService and UserInputService.SendKeyEvent then
				UserInputService:SendKeyEvent(Enum.UserInputType.Keyboard, Enum.KeyCode.Space, true)
				UserInputService:SendKeyEvent(Enum.UserInputType.Keyboard, Enum.KeyCode.Space, false)
				return
			end
		end)
		local camera = Workspace.CurrentCamera or Camera
		if not camera then return end
		local nudge = CFrame.Angles(0, math.rad(0.1), 0)
		camera.CFrame = camera.CFrame * nudge
		local revert
		revert = RunService.RenderStepped:Connect(function()
			revert:Disconnect()
			camera.CFrame = camera.CFrame * nudge:Inverse()
		end)
	end)
end

-- Spike
Core.ToggleAutoReceive = function(value)
	State.autoReceiveEnabled = value and true or false
	if State.autoReceiveEnabled then
		if not MovementState.autoReceiveConn then
			MovementState.autoReceiveConn = track(RunService.Heartbeat:Connect(autoReceiveHeartbeatStep))
		end
	elseif MovementState.autoReceiveConn then
		MovementState.autoReceiveConn:Disconnect()
		MovementState.autoReceiveConn = nil
	end
end
Core.SetReceiveRange = function(value)
	Receive.range = value
end
Core.SetReceiveLead = function(value)
	Receive.lead = value
end
Core.SetReceiveOnlyClosest = function(v) Receive.only_closest = v and true or false end
Core.SetReceivePingComp = function(v) Receive.ping_comp = tonumber(v) or 0 end

-- Movement
Core.ToggleKisukiDive = function(value)
	Kisuki.enabled = value and true or false
	if value then Kisuki.install() end
end
Core.SetKisukiCharge = function(value)
	Kisuki.charge = value
end
Core.SetAkariDashMultiplier = function(v) State.akariDashMultiplier = math.clamp(tonumber(v) or 1.0, 0.1, 1.0) end
Core.ToggleAkariDash = function(value)
	State.akariDashEnabled = value and true or false
	if ButtonState.dashButton then ButtonState.dashButton.Visible = value end
end
Core.FireAkariDash = function()
	akariDash()
end
Core.ToggleLeadFeet = function(value)
	State.leadFeetEnabled = value and true or false
	if ButtonState.leadFeetButton then ButtonState.leadFeetButton.Visible = value end
end
Core.FireLeadFeet = function()
	leadFeetSlam()
end
Core.ToggleMaxServe = function(value)
	if value then enableMaxServe() else disableMaxServe() end
end
Core.ToggleJumpESP = function(value)
	State.espJumpEnabled = value and true or false
	if not value then
		for player in pairs(VisualState.espHighlights) do
			removeESP(player)
		end
	end
end

-- Character
Core.SetDiveSpeed = function(value)
	local num = tonumber(value)
	if num then LocalPlayer:SetAttribute("Multiplier_DiveSpeed", num) end
end
Core.SetJumpPower = function(value)
	local num = tonumber(value)
	if num then LocalPlayer:SetAttribute("Multiplier_JumpPower", num) end
end
Core.SetSpeed = function(value)
	local num = tonumber(value)
	if num then LocalPlayer:SetAttribute("Multiplier_Speed", num) end
end
Core.ToggleAirMovement = function(value)
	State.airMovement = value and true or false
	if State.airMovement then
		MovementState.airConnect()
	else
		MovementState.airDisconnect()
	end
end
Core.SetAirSpeed = function(value)
	State.airMovementSpeed = value
end
Core.ToggleAutoShiftLock = function(value)
	toggleShiftLock(value)
end

-- Visuals
Core.ToggleCharacterLines = function(value)
	VisualState.linesEnabled = value and true or false
	if VisualState.linesEnabled then
		if not VisualState.linesConn then
			VisualState.linesConn = track(RunService.Heartbeat:Connect(linesHeartbeatStep))
		end
	else
		if VisualState.linesConn then
			VisualState.linesConn:Disconnect()
			VisualState.linesConn = nil
		end
		for player in pairs(VisualState.lines) do removeLine(player) end
	end
end
Core.SetLineDistance = function(value)
	State.lineDistance = value
end
Core.ToggleLineAimMode = function(v) State.lineAimMode = v and true or false end

-- Visuals
Core.ToggleLandingMarker = function(value)
	Landing.enabled = value and true or false
	if Landing.enabled then
		Landing.connect()
	else
		Landing.disconnect()
		Landing.clear()
	end
end
Core.ToggleScoreEffect = function(value)
	CardState.hitEffectEnabled = value and true or false
	if value then
		local ok = pcall(enableHitEffect)
		if not ok or not CardState.hitConnection then
			CardState.hitEffectEnabled = false
			State.hitEffectEnabled = false
			if CardState.hitConnection then CardState.hitConnection:Disconnect() CardState.hitConnection = nil end
			if CardState.hitRemovedConnection then CardState.hitRemovedConnection:Disconnect() CardState.hitRemovedConnection = nil end
			if Library.HitRemoteConn then Library.HitRemoteConn:Disconnect() Library.HitRemoteConn = nil end
			Core.Notify("[NodtHub] Score effect failed to enable")
			return false
		end
		Vault.mark("ScoreEffect", true)
		Vault.setSlot("ScoreEffect", State.selectedEffect)
		return true
	else
		Vault.mark("ScoreEffect", false)
		CardState.hitEffectEnabled = false
		if CardState.hitConnection then CardState.hitConnection:Disconnect() CardState.hitConnection = nil end
		if CardState.hitRemovedConnection then CardState.hitRemovedConnection:Disconnect() CardState.hitRemovedConnection = nil end
		if Library.HitRemoteConn then Library.HitRemoteConn:Disconnect() Library.HitRemoteConn = nil end
		return true
	end
end
Core.ApplyScoreEffect = function()
	if VisualApply and VisualApply.score then VisualApply.score() end
end

-- Character
Core.ToggleProtect = function(value)
	toggleProtection(value)
end
Core.ToggleTshAnimation = function(value)
	State.tshAnimationEnabled = value and true or false
	if value then installSpikeEffectHook() end
end
Core.ToggleHidariAnimation = function(value)
	State.hidariAnimationEnabled = value and true or false
	if value then installSpikeEffectHook() end
end
Core.ToggleKazanaBlue = function(value)
	State.kazanaBlueEnabled = value and true or false
	if State.kazanaBlueEnabled or State.kazanaWhiteEnabled then
		MovementState.kazanaConnect()
	else
		MovementState.kazanaDisconnect()
	end
end
Core.ToggleKazanaWhite = function(value)
	State.kazanaWhiteEnabled = value and true or false
	if State.kazanaBlueEnabled or State.kazanaWhiteEnabled then
		MovementState.kazanaConnect()
	else
		MovementState.kazanaDisconnect()
	end
end
Core.ApplyPlayerCard = function()
	if VisualApply and VisualApply.card then VisualApply.card() end
end
Core.ToggleCardProtect = function(value)
	CardProtect.set(value)
	if value and not Library.Unloaded then
		CardProtect.forceApply()
	end
end
Core.ApplyBall = function()
	if VisualApply and VisualApply.ball then VisualApply.ball() end
end
Core.ApplyJersey = function()
	if VisualApply and VisualApply.jersey then VisualApply.jersey() end
end
Core.ToggleAutoApplyJersey = function(value)
	State.autoApplyJersey = value and true or false
	applyJersey(State.selectedJersey)
end
Core.SelectJersey = function(value)
	State.selectedJersey = value
	CardState.pickedTeam = nil
	if State.autoApplyJersey then
		task.spawn(function()
			pcall(applyJersey, State.selectedJersey)
		end)
	end
end
Core.ToggleTitleChanger = function(value)
	Vault.mark("Title", value and true or false)
end


-- Spike
Core.ToggleSpikeTrajectory = function(value)
    State.spikeTrajectoryEnabled = value and true or false
    if State.spikeTrajectoryEnabled then
        TrajectoryState.connect()
    else
        TrajectoryState.disconnect()
        cleanupSpikeTrajectory()
    end
end

-- Tables / refs úteis para a UI (somente leitura operacional)
Core.AutoCorner = AutoCorner
Core.AutoCounter = AutoCounter
Core.Vault = Vault
Core.CardProtect = CardProtect
Core.Landing = Landing
Core.Kisuki = Kisuki
Core.Receive = Receive
Core.VisualApply = VisualApply

-- ============================================================


-- Character

-- [UI] WINDOW + BINDINGS — só interface; ações passam pelo Core
-- ============================================================

-- [UI] escuta notificações emitidas pelo Core
Core.On("Notify", function(payload, seconds)
	if Library and Library.Notify then
		Library:Notify(payload, seconds)
	end
end)



local Window = Library:CreateWindow({
    Title = "Nodt Hub",
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
        Core.ToggleRedirectSpike(Value)
    end,
})

UI.LeftGroupBox:AddToggle("autocorner", {
    Text = "Auto Corner",
    Tooltip = "Aims to the corner sides of the enemy's goal",
    Default = false,
    Callback = function(Value)
        Core.ToggleAutoCorner(Value)
    end,
})

UI.LeftGroupBox:AddDropdown("autocornerside", {
    Values = {"Auto", "Left", "Right"},
    Default = "Auto",
    Text = "Corner Side",
    Callback = function(Value)
        Core.SetAutoCornerSide(Value)
    end,
})

UI.LeftGroupBox:AddSlider("autocornerdepth", {
    Text = "Corner Depth",
    Default = 1.0,
    Min = 0.1,
    Max = 1.0,
    Rounding = 2,
    Callback = function(Value)
        Core.SetAutoCornerDepth(Value)
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

UI.LeftGroupBox:AddToggle("lineaim", {
    Text = "Auto Corner Linha",
    Tooltip = "Gira o personagem para a linha inimiga ao pular. Use junto com o Auto Corner!",
    Default = false,
    Callback = function(Value)
        Core.ToggleLineAim(Value)
    end,
})

UI.LeftGroupBox:AddToggle("newspike", {
    Text = "Silent Spike",
    Tooltip = "Spike with no animation or sound",
    Default = false,
    Callback = function(Value)
        Core.ToggleSilentSpike(Value)
    end,
})

UI.LeftGroupBox:AddLabel("Silent Spike bind"):AddKeyPicker("newspikebind", {
    Default = "R",
    Mode = "Press",
    Text = "Silent Spike",
    Callback = function()
        Core.FireSilentSpike()
    end,
})

UI.LeftGroupBox:AddToggle("sanju", {
    Text = "Sanju Tilt",
    Tooltip = "Sanju tilt effect",
    Default = false,
    Callback = function(Value)
        Core.ToggleSanjuTilt(Value)
    end,
})

UI.LeftGroupBox:AddToggle("maxcharge", {
    Text = "Max Charge Special",
    Tooltip = "Max charge your special",
    Default = false,
    Callback = function(Value)
        Core.ToggleMaxCharge(Value)
    end,
})

UI.LeftGroupBox:AddToggle("fakespike", {
    Text = "Fake Spike",
    Tooltip = "Auto fake spike when jumping",
    Default = false,
    Callback = function(Value)
        Core.ToggleFakeSpike(Value)
    end,
})

UI.LeftGroupBox:AddToggle("autocounter", {
    Text = "Auto Counter",
    Tooltip = "Counters an enemy spike when both of you are at the net",
    Default = false,
    Callback = function(Value)
        Core.ToggleAutoCounter(Value)
    end,
})

UI.LeftGroupBox:AddDropdown("autocountermove", {
    Values = {"Auto", "Block", "Spike"},
    Default = "Auto",
    Text = "Counter Move",
    Tooltip = "Auto: block while the ball is still on their half, spike once it crosses",
    Callback = function(Value)
        Core.SetAutoCounterMove(Value)
    end,
})

UI.LeftGroupBox:AddSlider("autocounternetrange", {
    Text = "Counter Net Range",
    Default = 9,
    Min = 3,
    Max = 20,
    Rounding = 1,
    Callback = function(Value)
        Core.SetAutoCounterNetRange(Value)
    end,
})

UI.LeftGroupBox:AddSlider("autocounterlateral", {
    Text = "Counter Width",
    Default = 14,
    Min = 4,
    Max = 30,
    Rounding = 1,
    Callback = function(Value)
        Core.SetAutoCounterLateral(Value)
    end,
})

UI.LeftGroupBox:AddSlider("autocounterdelay", {
    Text = "Counter Delay",
    Default = 0.05,
    Min = 0,
    Max = 0.5,
    Rounding = 2,
    Callback = function(Value)
        Core.SetAutoCounterDelay(Value)
    end,
})

UI.LeftGroupBox:AddSlider("autocounterreach", {
    Text = "Counter Reach",
    Default = 20,
    Min = 10,
    Max = 20,
    Rounding = 1,
    Callback = function(Value)
        AutoCounter.state.reach = Value
    end,
})

UI.LeftGroupBox:AddToggle("autocounterjump", {
    Text = "Counter Auto Jump",
    Tooltip = "Jump before the counter, the block hitbox dies the moment you land",
    Default = true,
    Callback = function(Value)
        Core.SetAutoCounterJump(Value)
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
        Core.ToggleHitbox(Value)
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
        Core.SetHitboxSize(Value)
    end,
})

UI.HitboxGroup:AddDropdown("hitboxcolor", {
    Values = {"Invisible", "White", "Green", "Blue", "Red", "Yellow", "Purple", "Orange", "Pink"},
    Default = "Blue",
    Text = "Hitbox Color",
    Callback = function(Value)
        Core.SetHitboxColor(Value)
    end,
})

UI.HitboxGroup:AddButton({
    Text = "Remove Hitboxes",
    Func = function()
        Core.RemoveHitboxes()
    end,
})

UI.HitboxGroup:AddButton({
    Text = "Show Stop Ball",
    Func = function()
        Core.ToggleStopBallButton()
    end,
})

UI.HitboxGroup:AddButton({
    Text = "Show Aim",
    Func = function()
        Core.ToggleAimButton()
    end,
})

UI.PerfGroup = Tabs.Main:AddLeftGroupbox("Performance", "gauge")

UI.PerfGroup:AddToggle("antilag", {
    Text = "Anti-Lag",
    Tooltip = "Reduce graphics for better performance",
    Default = false,
    Callback = function(Value)
        Core.ToggleAntiLag(Value)
    end,
})



UI.MoveGroup = Tabs.Main:AddRightGroupbox("Movement", "move")

UI.MoveGroup:AddToggle("desync", {
    Text = "Desync",
    Tooltip = "Desync movement",
    Default = false,
    Callback = function(Value)
        Core.ToggleDesync(Value)
    end,
})

UI.MoveGroup:AddToggle("autoreceive", {
    Text = "Auto Receive",
    Tooltip = "Auto receive the ball",
    Default = false,
    Callback = function(Value)
        Core.ToggleAutoReceive(Value)
    end,
})

UI.MoveGroup:AddSlider("autoreceiverange", {
    Text = "Receive Range",
    Default = 10,
    Min = 3,
    Max = 20,
    Rounding = 1,
    Callback = function(Value)
        Core.SetReceiveRange(Value)
    end,
})

UI.MoveGroup:AddSlider("autoreceivelead", {
    Text = "Receive Lead",
    Default = 0.35,
    Min = 0,
    Max = 1,
    Rounding = 2,
    Callback = function(Value)
        Core.SetReceiveLead(Value)
    end,
})

UI.MoveGroup:AddToggle("ReceiveOnlyClosest", {
    Text = "Only If Closest",
    Default = false,
    Callback = function(Value)
        Core.SetReceiveOnlyClosest(Value)
    end,
})

UI.MoveGroup:AddSlider("ReceivePingComp", {
    Text = "Ping Compensator (s)",
    Default = 0,
    Min = 0,
    Max = 0.3,
    Rounding = 2,
    Callback = function(Value)
        Core.SetReceivePingComp(Value)
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

UI.MoveGroup:AddToggle("autoblock", {
    Text = "Auto Block",
    Tooltip = "Fires block instantly when you jump (no cooldown)",
    Default = false,
    Callback = function(Value)
        Core.ToggleAutoBlock(Value)
    end,
})

UI.MoveGroup:AddToggle("autospike", {
    Text = "Auto Spike",
    Tooltip = "Auto spikes when you jump near the ball in attack range",
    Default = false,
    Callback = function(Value)
        Core.ToggleAutoSpike(Value)
    end,
})

UI.MoveGroup:AddToggle("autospikeaim", {
    Text = "Auto Spike Corner",
    Default = false,
    Callback = function(Value)
        Core.SetAutoSpikeAim(Value)
    end,
})

UI.MoveGroup:AddToggle("autosetaim", {
    Text = "Auto Set Aim",
    Tooltip = "Força o JumpSet a mirar perfeitamente no amigo mais próximo",
    Default = false,
    Callback = function(Value)
        Core.ToggleAutoSetAim(Value)
    end,
})

UI.MoveGroup:AddToggle("kisukidive", {
    Text = "Kisuki Dive",
    Tooltip = "Kisuki super dive",
    Default = false,
    Callback = function(Value)
        Core.ToggleKisukiDive(Value)
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
        Core.SetKisukiCharge(Value)
    end,
})

UI.MoveGroup:AddToggle("akaridash", {
    Text = "Akari Dash",
    Tooltip = "Dash into the ball",
    Default = false,
    Callback = function(Value)
        Core.ToggleAkariDash(Value)
    end,
})

UI.MoveGroup:AddSlider("akaridashmult", {
    Text = "Dash Distance",
    Default = 1.0,
    Min = 0.1,
    Max = 1.0,
    Rounding = 2,
    Callback = function(Value)
        Core.SetAkariDashMultiplier(Value)
    end,
})

UI.MoveGroup:AddLabel("Akari Dash bind"):AddKeyPicker("akaridashbind", {
    Default = "F",
    Mode = "Press",
    Text = "Akari Dash",
    Callback = function()
        Core.FireAkariDash()
    end,
})

UI.MoveGroup:AddToggle("leadfeet", {
    Text = "Lead Feet",
    Tooltip = "Slams you down at the ability's own -10000 acceleration",
    Default = false,
    Callback = function(Value)
        Core.ToggleLeadFeet(Value)
    end,
})

UI.MoveGroup:AddLabel("Lead Feet bind"):AddKeyPicker("leadfeetbind", {
    Default = "G",
    Mode = "Press",
    Text = "Lead Feet",
    Callback = function()
        Core.FireLeadFeet()
    end,
})

UI.MaxServeGroup = Tabs.Main:AddLeftGroupbox("Max Serve", "server")

UI.MaxServeGroup:AddToggle("maxserve", {
    Text = "Max Serve",
    Tooltip = "Max serve power",
    Default = false,
    Callback = function(Value)
        Core.ToggleMaxServe(Value)
    end,
})

UI.MaxServeGroup:AddToggle("esp", {
    Text = "Jump ESP",
    Tooltip = "Highlight enemies while they are jumping",
    Default = false,
    Callback = function(Value)
        Core.ToggleJumpESP(Value)
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
        pcall(function()
            updateKeybind:InvokeServer("MouseButton1", true, "Spike\xE2\x80\x8B\x8F")
        end)
        task.wait(2)
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
        State.airMovement = Value and true or false
        if State.airMovement then
            MovementState.airConnect()
        else
            MovementState.airDisconnect()
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
        Core.ToggleAutoShiftLock(Value)
    end,
})

UI.CharMoveGroup:AddToggle("characterlines", {
    Text = "Character Enemy/Team Line",
    Tooltip = "Show colored beams to enemies",
    Default = false,
    Callback = function(Value)
        Core.ToggleCharacterLines(Value)
    end,
})

UI.CharMoveGroup:AddToggle("characteraimline", {
    Text = "Aim Line (Camera)",
    Default = false,
    Callback = function(Value)
        Core.ToggleLineAimMode(Value)
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

-- VISUAL APPLY (dropdown selects, button applies on demand)
VisualApply = {}

function VisualApply.pick(list, wanted)
    if table.find(list, wanted) then
        return wanted
    end
    return list[1]
end

State.selectedEffect = VisualApply.pick(effectList, State.selectedEffect)
State.selectedCard = VisualApply.pick(CardState.cardList, State.selectedCard)
State.selectedBallSkin = VisualApply.pick(CardState.ballSkinList, State.selectedBallSkin)

function VisualApply.score()
    -- o toggle "Score Effect ON" controla hitEffectEnabled (callback seta true)
    local toggle = UI.ScoreEffectToggle
    if toggle then
        toggle:SetValue(true)
    end
    local ok = pcall(enableHitEffect)
    if not ok or not CardState.hitConnection then
        CardState.hitEffectEnabled = false
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
    CardState.playerCardEnabled = true
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
    CardState.pickedTeam = nil
    task.spawn(function()
        pcall(applyJersey, State.selectedJersey)
    end)
    Library:Notify("Jersey applied: " .. State.selectedJersey)
end

-- [CORE] re-bind após VisualApply completo
Core.VisualApply = VisualApply


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
        CardState.hitEffectEnabled = Value
        if Value then
            local ok = pcall(enableHitEffect)
            if not ok or not CardState.hitConnection then
                CardState.hitEffectEnabled = false
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
            CardState.hitEffectEnabled = false
            -- solta os listeners do workspace/remote para nao ficarem ativos com o efeito off.
            if CardState.hitConnection then CardState.hitConnection:Disconnect() CardState.hitConnection = nil end
            if CardState.hitRemovedConnection then CardState.hitRemovedConnection:Disconnect() CardState.hitRemovedConnection = nil end
            if Library.HitRemoteConn then Library.HitRemoteConn:Disconnect() Library.HitRemoteConn = nil end
        end
    end,
})

UI.VisualScoreGroup:AddButton({
    Text = "Apply Score Effect",
    Func = function() Core.ApplyScoreEffect() end,
})

UI.VisualProtectGroup = Tabs.Visuals:AddRightGroupbox("Protection", "shield")

UI.VisualProtectGroup:AddToggle("protect", {
    Text = "Protect",
    Tooltip = "Enable/Disable all protection features",
    Default = false,
    Callback = function(Value)
        Core.ToggleProtect(Value)
    end,
})

UI.VisualProtectGroup:AddToggle("tshanimation", {
    Text = "TSH Animation",
    Tooltip = "PowerSpike + SpecialChargeSpikeVFX on spike",
    Default = false,
    Callback = function(Value)
        Core.ToggleTshAnimation(Value)
    end,
})

UI.VisualProtectGroup:AddToggle("hidarianimation", {
    Text = "Hidari Animation",
    Tooltip = "PowerSpike + HidariSpikeVFX on spike",
    Default = false,
    Callback = function(Value)
        Core.ToggleHidariAnimation(Value)
    end,
})

UI.VisualProtectGroup:AddToggle("kazanabluejump", {
    Text = "Kazana Blue Jump",
    Tooltip = "Fires KazanaBlue on jump",
    Default = false,
    Callback = function(Value)
        Core.ToggleKazanaBlue(Value)
    end,
})

UI.VisualProtectGroup:AddToggle("kazanawhitejump", {
    Text = "Kazana White Jump",
    Tooltip = "Fires KazanaWhite on jump",
    Default = false,
    Callback = function(Value)
        Core.ToggleKazanaWhite(Value)
    end,
})

UI.PlayerCardGroup = Tabs.Visuals:AddLeftGroupbox("Player Card", "id-card")

UI.PlayerCardGroup:AddDropdown("cardselect", {
    Values = CardState.cardList,
    Default = State.selectedCard,
    Text = "Select Player Card",
    Callback = function(Value)
        State.selectedCard = Value
    end,
})

UI.PlayerCardGroup:AddButton({
    Text = "Apply Player Card",
    Func = function() Core.ApplyPlayerCard() end,
})

UI.PlayerCardGroup:AddToggle("cardprotect", {
    Text = "Card Protect",
    Tooltip = "Hide your name on the Player Card",
    Default = false,
    Callback = function(Value)
        Core.ToggleCardProtect(Value)
    end,
})

UI.TitleGroup = Tabs.Visuals:AddRightGroupbox("Title Changer", "tag")

UI.TitleGroup:AddToggle("titleunlock", {
    Text = "Title Changer",
    Tooltip = "Change title",
    Default = false,
    Callback = function(Value)
        Core.ToggleTitleChanger(Value)
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


-- BALL SKIN UI
UI.BallSkinGroup = Tabs.Visuals:AddLeftGroupbox("Ball Changer", "circle")

UI.BallSkinGroup:AddDropdown("ballselect", {
    Values = CardState.ballSkinList,
    Default = State.selectedBallSkin,
    Text = "Select Ball",
    Callback = function(Value)
        State.selectedBallSkin = Value
    end,
})

UI.BallSkinGroup:AddButton({
    Text = "Apply Ball",
    Func = function() Core.ApplyBall() end,
})

-- JERSEY UI (FIXED - AUTO APPLY ENABLED BY DEFAULT)
UI.JerseyGroup = Tabs.Visuals:AddRightGroupbox("Jersey Changer", "shirt")

UI.JerseyGroup:AddToggle("autoapplyjersey", {
    Text = "Auto Apply Jersey",
    Tooltip = "Automatically apply selected jersey",
    Hidden = true,
    Default = false,
    Callback = function(Value)
        Core.ToggleAutoApplyJersey(Value)
    end,
})

UI.JerseyGroup:AddDropdown("jerseyselect", {
    Values = #CardState.jerseyList > 0 and CardState.jerseyList or {"No Jerseys Found"},
    Default = #CardState.jerseyList > 0 and CardState.jerseyList[1] or "No Jerseys Found",
    Text = "Select Jersey",
    Callback = function(Value)
        Core.SelectJersey(Value)
    end,
})

UI.JerseyGroup:AddButton({
    Text = "Apply Jersey",
    Func = function() Core.ApplyJersey() end,
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
        CardState.desiredStyles = {Value}
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
        CardState.desiredStyles = {Value}
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
        CardState.desiredAbilities = {Value}
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
        CardState.desiredAbilities = {Value}
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

local GameJoinUtils = Tabs.GameJoin:AddRightGroupbox("Utility", "shield-check")

GameJoinUtils:AddToggle("antiafk", {
    Text = "Anti-AFK",
    Tooltip = "Prevents the game from kicking you for inactivity",
    Default = true,
    Callback = function(Value)
        Core.ToggleAntiAFK(Value)
    end,
})

GameJoinUtils:AddToggle("autorejoin", {
    Text = "Auto Rejoin",
    Tooltip = "Rejoins the game automatically if you get kicked",
    Default = false,
    Callback = function(Value)
        Core.ToggleAutoRejoin(Value)
    end,
})

GameJoinUtils:AddToggle("autoready", {
    Text = "Auto Ready",
    Tooltip = "Clica automaticamente no botão de Ready/Aceitar entre as partidas",
    Default = false,
    Callback = function(Value)
        Core.ToggleAutoReady(Value)
    end,
})

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

Core.Cleanup = function()
    -- Hitboxes temporárias
    pcall(removeHitboxes)

    -- Marcador da Ball Prediction
    pcall(function()
        Landing.enabled = false
        Landing.disconnect()
        Landing.clear()
    end)

    -- Beam, attachments e Part da Spike Trajectory
    pcall(TrajectoryState.disconnect)
    pcall(cleanupSpikeTrajectory)

    -- Movimento aereo
    pcall(MovementState.airDisconnect)

    -- Linhas/Beams visuais rastreados
    if VisualState.linesConn then
        VisualState.linesConn:Disconnect()
        VisualState.linesConn = nil
    end
    for player in pairs(VisualState.lines) do
        pcall(removeLine, player)
    end
    VisualState.linesEnabled = false

    -- Remove referências restantes das hitboxes rastreadas
    for driver, shell in pairs(HitboxState.hitboxBoxes) do
        pcall(function()
            if shell then shell:Destroy() end
        end)
        HitboxState.hitboxBoxes[driver] = nil
    end
end

Library.CleanupExtras = function()
    pcall(Core.Cleanup)
    pcall(disableAutoBlock)
    if ButtonState.leadFeetLink then pcall(function() ButtonState.leadFeetLink:Disconnect() end) end
    -- autoApplyBallSkin off para o sweep so remover as skins (sem reaplicar).
    State.autoApplyBallSkin = false
    if CardState.sweepBusy == false then pcall(task.spawn, safeSweep) end
end

Core.ToggleAutoSave = function(value)
    State.autoSaveGen = (State.autoSaveGen or 0) + 1
    local gen = State.autoSaveGen
    State.autoSaveEnabled = value and true or false
    State.autoSaveRunning = false
    if value then
        State.autoSaveRunning = true
        task.spawn(function()
            while State.autoSaveEnabled and State.autoSaveGen == gen and not Library.Unloaded do
                task.wait(30) -- Aumentado de 8s para 30s para evitar hitch periodico.
                if Library.Unloaded or not State.autoSaveEnabled then break end

                local ok, currentJson = pcall(function()
                    local HttpService = game:GetService("HttpService")
                    return HttpService:JSONEncode(Library.CollectConfig())
                end)

                if ok and currentJson then
                    if State.lastSaveState ~= currentJson then
                        State.lastSaveState = currentJson

                        -- Salva no arquivo "autosave" (config separada das manuais)
                        local success = false
                        pcall(function()
                            success = Library:SaveConfig("autosave")
                            -- Define como autoload
                            local api = Library.FileApi()
                            if success and api and api.write then
                                api.write("NODT/autoload.txt", "autosave")
                            end
                        end)
                    end
                end
            end
            if State.autoSaveGen == gen then State.autoSaveRunning = false end
        end)
    end
end

MenuGroup:AddToggle("autosave", {
    Text = "Auto Save Config",
    Tooltip = "Salva e carrega automaticamente suas configurações ao reexecutar",
    Default = true, -- Já vem ligado
    Callback = function(Value)
        Core.ToggleAutoSave(Value)
    end,
})

MenuGroup:AddButton("Unload", function()
    Library:Unload()
end)

Library.ToggleKeybind = Options.MenuKeybind

Library:SetConfigFolder("NODT")
Library:BuildConfigSection(Tabs["UI Settings"])
Library:LoadAutoloadConfig()
-- Botão flutuante "N": criado automaticamente pelo Library:CreateWindow (ver NODT HUB UI LIBRARY no topo).

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
    if Landing and Landing.clear then pcall(Landing.clear) end
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

-- [A1] Boot assert suite: roda 1x depois de toda a inicializacao. So loga, nao bloqueia nada.
do
    local function verifyBoot()
        if Library.Unloaded then return end
        local nodt = _G.NODT or {}
        local netOk = type(NET.K) == "table" and NET.K.INVOKE == "InvokeServer"
        if netOk then
            for _, key in ipairs({ "INVOKE", "FIRE", "KICK", "INTERACT", "DOMOVE", "SPIKE", "SERVESPIKE", "BLOCK", "JUMPSET" }) do
                if type(NET.K[key]) ~= "string" then netOk = false break end
            end
        end
        local checks = {
            { "NODT.Core", type(rawget(nodt, "Core")) == "table" },
            { "NODT.Session", type(rawget(nodt, "Session")) == "table" },
            { "NODT.AuthPassed", rawget(nodt, "AuthPassed") == true },
            { "Library.Root", typeof(Library.Root) == "Instance" },
            { "Library.Window", Library.Window ~= nil },
            { "NET.K", netOk },
            { "Core.On", type(Core.On) == "function" },
            { "Core.Emit", type(Core.Emit) == "function" },
            { "Core.ToggleHitbox", type(Core.ToggleHitbox) == "function" },
            { "Core.ToggleSilentSpike", type(Core.ToggleSilentSpike) == "function" },
            { "Core.ToggleAutoCorner", type(Core.ToggleAutoCorner) == "function" },
        }
        for _, entry in ipairs(checks) do
            if not entry[2] then warn("[NODT boot] FALHOU: " .. entry[1]) end
        end
    end
    task.defer(verifyBoot)
end
