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

_G.NODT_CORE = Core

-- ============================================================
-- [UI] LIBRARY — Clean / Minimal (sem lógica de jogo)
-- ============================================================
local Library = (function()
--[[
	NODT HUB — UI Library (Luau / Roblox)
	Clean / Minimal — vinho escuro
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

--// ───────────────────────── TEMA PREMIUM ─────────────────────────
local Theme = {
	Shell     = Color3.fromRGB(21, 11, 15),   -- vinho quase preto
	Panel     = Color3.fromRGB(30, 16, 22),
	Raised    = Color3.fromRGB(46, 25, 33),
	Sunken    = Color3.fromRGB(14, 7, 10),
	Card      = Color3.fromRGB(26, 14, 19),
	Line      = Color3.fromRGB(72, 38, 50),
	LineSoft  = Color3.fromRGB(50, 27, 36),
	Accent    = Color3.fromRGB(143, 29, 62),  -- vinho
	Accent2   = Color3.fromRGB(232, 84, 96),  -- vermelho suave (fechar / erro)
	Accent3   = Color3.fromRGB(190, 62, 100), -- vinho claro (degrade sutil)
	AccentHover = Color3.fromRGB(166, 38, 76),
	AccentText = Color3.fromRGB(228, 122, 152), -- vinho claro p/ textos (boa leitura)
	Text      = Color3.fromRGB(244, 236, 238),
	SubText   = Color3.fromRGB(168, 142, 151),
	Faint     = Color3.fromRGB(112, 88, 97),
	OnAccent  = Color3.fromRGB(255, 238, 243), -- texto claro sobre o vinho
	Error     = Color3.fromRGB(240, 98, 98),
	Glow      = Color3.fromRGB(143, 29, 62),
}

-- Compat
Theme.Wine = Color3.fromRGB(110, 20, 46)
Theme.WineHi = Theme.Accent
Theme.WineDeep = Color3.fromRGB(42, 10, 21)
Theme.ShellTop = Theme.Shell
Theme.PanelLow = Theme.Panel
Theme.AccentSoft = Color3.fromRGB(64, 22, 37)

local WIN_W, WIN_H = 700, 480
local HEAD_H = 54
local TABS_H = 44
local PILL = UDim.new(1, 0)
local FONT = Enum.Font.GothamMedium
local FONT_B = Enum.Font.GothamBold
local FONT_MONO = Enum.Font.Code
local TWEEN_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TWEEN_FAST = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_SQUISH_DOWN = TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TWEEN_SQUISH_UP = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local Lib = {
	Options = {},
	Toggles = {},
	Theme = Theme,
	CornerRadius = 14,
	ForceCheckbox = false,
	ShowToggleFrameInKeybinds = true,
	NotifySide = "Right",
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

local function glide(inst, props, seconds)
	local info = seconds and TweenInfo.new(seconds, Enum.EasingStyle.Quint, Enum.EasingDirection.Out) or TWEEN_INFO
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
		Rotation = rotation or 45,
		Color = ColorSequence.new(Theme.Accent, Theme.Accent3),
	}, inst)
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
	return LocalPlayer:WaitForChild("PlayerGui")
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

--// ───────────────────────── ROOT / TOOLTIP / NOTIFY ─────────────────────────
local Root = new("ScreenGui", {
	Name = tag(),
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 99998,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
mountGui(Root)
Lib.Root = Root

-- Tooltip
local TipCard = new("Frame", {
	Visible = false,
	AutomaticSize = Enum.AutomaticSize.XY,
	Size = UDim2.fromOffset(0, 0),
	BackgroundColor3 = Theme.Raised,
	BorderSizePixel = 0,
	ZIndex = 300,
}, Root)
corner(TipCard, 8)
stroke(TipCard, Theme.Accent, 1, 0.55)
pad(TipCard, 10, 10, 6, 6)
local TipText = label(TipCard, {
	AutomaticSize = Enum.AutomaticSize.XY,
	Size = UDim2.fromOffset(0, 0),
	Font = Enum.Font.Gotham,
	TextSize = 12,
	TextWrapped = true,
	ZIndex = 301,
})
new("UISizeConstraint", { MaxSize = Vector2.new(230, 400) }, TipText)

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

-- Notificações
local NotifyHolder = new("Frame", {
	Name = "Notify",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -18, 0, 18),
	Size = UDim2.new(0, 280, 1, -36),
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
	notifyCount = notifyCount + 1

	local card = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = notifyCount,
	}, NotifyHolder)
	corner(card, 12)
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

	local content = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, card)
	new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, content)

	local texts = {}
	if title then
		table.insert(texts, label(content, {
			Size = UDim2.new(1, 0, 0, 16),
			Font = FONT_B,
			TextSize = 13,
			Text = tostring(title),
			TextTransparency = 1,
			LayoutOrder = 1,
		}))
	end
	table.insert(texts, label(content, {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = FONT,
		TextSize = 12,
		TextColor3 = title and Theme.SubText or Theme.Text,
		TextWrapped = true,
		Text = tostring(text),
		TextTransparency = 1,
		LayoutOrder = 2,
	}))

	glide(card, { BackgroundTransparency = 0.02 })
	glide(edge, { Transparency = 0.45 })
	glide(bar, { BackgroundTransparency = 0 })
	for _, t in ipairs(texts) do glide(t, { TextTransparency = 0 }) end

	task.delay(seconds or 4, function()
		if not card.Parent then return end
		glide(card, { BackgroundTransparency = 1 })
		glide(edge, { Transparency = 1 })
		glide(bar, { BackgroundTransparency = 1 })
		for _, t in ipairs(texts) do glide(t, { TextTransparency = 1 }) end
		task.wait(0.25)
		card:Destroy()
	end)
end

function Lib:SetNotifySide(side)
	Lib.NotifySide = side
	if side == "Left" then
		NotifyHolder.AnchorPoint = Vector2.new(0, 0)
		NotifyHolder.Position = UDim2.new(0, 18, 0, 18)
		NotifyHolder:FindFirstChildOfClass("UIListLayout").HorizontalAlignment = Enum.HorizontalAlignment.Left
	else
		NotifyHolder.AnchorPoint = Vector2.new(1, 0)
		NotifyHolder.Position = UDim2.new(1, -18, 0, 18)
		NotifyHolder:FindFirstChildOfClass("UIListLayout").HorizontalAlignment = Enum.HorizontalAlignment.Right
	end
end

-- Keybind list
local KeybindFrame = new("Frame", {
	Name = "Keybinds",
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 16, 0.5, 0),
	Size = UDim2.fromOffset(180, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = Theme.Panel,
	BorderSizePixel = 0,
	Visible = false,
	ZIndex = 150,
}, Root)
corner(KeybindFrame, 12)
stroke(KeybindFrame, Theme.LineSoft, 1, 0.15)
pad(KeybindFrame, 12, 12, 10, 10)
new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, KeybindFrame)
do
	local head = new("Frame", { Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1, LayoutOrder = 0 }, KeybindFrame)
	local headBar = new("Frame", {
		Position = UDim2.fromOffset(0, 2), Size = UDim2.fromOffset(3, 14),
		BackgroundColor3 = Theme.Accent3, BorderSizePixel = 0,
	}, head)
	corner(headBar, PILL)
	neonGradient(headBar, 90)
	label(head, { Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -10, 1, 0), Font = FONT_B, Text = "Keybinds" })
end
Lib.KeybindFrame = KeybindFrame

local function refreshKeybinds()
	for _, child in ipairs(KeybindFrame:GetChildren()) do
		if child:IsA("Frame") and child.Name == "Row" then child:Destroy() end
	end
	local order = 0
	for _, picker in ipairs(pickers) do
		if not picker.NoUI and picker.Value ~= "" then
			order = order + 1
			local row = new("Frame", {
				Name = "Row", Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1, LayoutOrder = order,
			}, KeybindFrame)
			label(row, {
				Size = UDim2.new(1, -52, 1, 0), TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = picker.Active and Theme.Text or Theme.SubText, Text = picker.Label,
			})
			label(row, {
				AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0, 48, 1, 0),
				Font = FONT_MONO, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Right,
				TextColor3 = picker.Active and Theme.AccentText or Theme.Faint, Text = "[" .. keyText(picker.Value) .. "]",
			})
		end
	end
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
	corner(Card, 12, true)
	local cardStroke = stroke(Card, Theme.LineSoft, 1, 0.25)
	pad(Card, 16, 16, 16, 16)
	new("UIListLayout", { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, Card)

	-- Título
	local titleRow = new("Frame", { Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, LayoutOrder = 1 }, Card)
	local titleBar = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(4, 18),
		BackgroundColor3 = Theme.Accent, BorderSizePixel = 0,
	}, titleRow)
	corner(titleBar, PILL)
	neonGradient(titleBar, 90)
	label(titleRow, {
		Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -12, 1, 0), Font = FONT_B, TextSize = 14,
		TextTruncate = Enum.TextTruncate.AtEnd, Text = tostring(title or ""),
	})

	local divider = new("Frame", {
		Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, LayoutOrder = 2,
	}, Card)
	gradient(divider, 0, Theme.Accent, Theme.LineSoft, NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 0.95),
	}))

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
			Size = UDim2.new(1, 0, 0, 14), Font = Enum.Font.Gotham, TextSize = 12,
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
		return line
	end

	--// TOGGLE (pílula neon)
	function Group:AddToggle(index, opts)
		opts = opts or {}
		local hasDesc = (opts.Description or opts.Desc) ~= nil
		local row = slot(hasDesc and 52 or 40)
		if opts.Hidden then row.Visible = false end

		local hoverBg = new("Frame", {
			Position = UDim2.fromOffset(-8, 0), Size = UDim2.new(1, 16, 1, 0),
			BackgroundColor3 = Theme.Raised, BackgroundTransparency = 1, BorderSizePixel = 0,
		}, row)
		corner(hoverBg, 8)

		local hit = new("TextButton", {
			Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, ZIndex = 5,
		}, row)
		attachTip(hit, opts.Tooltip)

		local text = label(row, {
			Position = UDim2.fromOffset(0, hasDesc and 8 or 0), Size = UDim2.new(1, -62, 0, hasDesc and 18 or 40),
			TextTruncate = Enum.TextTruncate.AtEnd, Text = opts.Text or index, Active = false,
		})
		if hasDesc then
			label(row, {
				Position = UDim2.fromOffset(0, 27), Size = UDim2.new(1, -62, 0, 16), Font = Enum.Font.Gotham,
				TextSize = 11, TextColor3 = Theme.Faint, TextTruncate = Enum.TextTruncate.AtEnd,
				Text = opts.Description or opts.Desc,
			})
		end

		local track = new("Frame", {
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(46, 26),
			BackgroundColor3 = Theme.Sunken, BorderSizePixel = 0,
		}, row)
		corner(track, PILL)
		local trackEdge = stroke(track, Theme.Line, 1, 0.3)
		local knob = new("Frame", {
			AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), Size = UDim2.fromOffset(20, 20),
			BackgroundColor3 = Theme.SubText, BorderSizePixel = 0,
		}, track)
		corner(knob, PILL)
		local knobGlow = stroke(knob, Theme.Accent, 0, 1)

		local Toggle = { Value = false, Type = "Toggle", Index = index, Callbacks = {} }
		local hovering = false

		local function paint()
			if Toggle.Value then
				glide(track, { BackgroundColor3 = Theme.Accent })
				glide(trackEdge, { Color = Theme.AccentHover, Transparency = 0.15 })
				glide(knob, { Position = UDim2.new(0, 23, 0.5, 0), BackgroundColor3 = Color3.new(1, 1, 1) })
				glide(knobGlow, { Thickness = 2.5, Transparency = 0.35, Color = Theme.Accent3 })
			else
				glide(track, { BackgroundColor3 = Theme.Sunken })
				glide(trackEdge, { Color = hovering and Theme.Accent or Theme.Line, Transparency = 0.3 })
				glide(knob, { Position = UDim2.new(0, 3, 0.5, 0), BackgroundColor3 = Theme.SubText })
				glide(knobGlow, { Thickness = 0, Transparency = 1 })
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
			glide(hoverBg, { BackgroundTransparency = 0.7 })
			if not Toggle.Value then glide(trackEdge, { Color = Theme.Accent }) end
		end)
		local pressed = false
		local function releaseKnob()
			if not pressed then return end
			pressed = false
			TweenService:Create(knob, TWEEN_SQUISH_UP, {
				Size = UDim2.fromOffset(20, 20),
				Position = UDim2.new(0, Toggle.Value and 23 or 3, 0.5, 0),
			}):Play()
		end
		bind(hit.MouseLeave, function()
			hovering = false
			glide(hoverBg, { BackgroundTransparency = 1 })
			if not Toggle.Value then glide(trackEdge, { Color = Theme.Line }) end
			releaseKnob()
		end)
		bind(hit.MouseButton1Down, function()
			pressed = true
			-- esmaga o knob (24x20); quando ligado, mantém a borda direita dentro do track
			local goal = { Size = UDim2.fromOffset(24, 20) }
			if Toggle.Value then goal.Position = UDim2.new(0, 19, 0.5, 0) end
			TweenService:Create(knob, TWEEN_SQUISH_DOWN, goal):Play()
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

	--// SLIDER (neon fill + glowing knob)
	function Group:AddSlider(index, opts)
		opts = opts or {}
		local minimum = opts.Min or 0
		local maximum = opts.Max or 100
		local step = 10 ^ (opts.Rounding or 0)
		local row = slot(60)
		attachTip(row, opts.Tooltip)

		label(row, {
			Size = UDim2.new(1, -56, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd, Text = opts.Text or index,
		})
		local readout = label(row, {
			AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(60, 18),
			Font = FONT_MONO, TextSize = 12, TextColor3 = Theme.AccentText, TextXAlignment = Enum.TextXAlignment.Right,
		})

		local bar = new("TextButton", {
			Position = UDim2.fromOffset(0, 30), Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1,
			Text = "", AutoButtonColor = false,
		}, row)
		local track = new("Frame", {
			AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 9, 0.5, 0), Size = UDim2.new(1, -18, 0, 8),
			BackgroundColor3 = Theme.Sunken, BorderSizePixel = 0,
		}, bar)
		corner(track, PILL)
		stroke(track, Theme.Line, 1, 0.45)
		local fill = new("Frame", {
			Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = Theme.Accent, BorderSizePixel = 0,
		}, track)
		corner(fill, PILL)
		neonGradient(fill, 0)
		local knob = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(18, 18),
			BackgroundColor3 = Theme.Text, BorderSizePixel = 0, ZIndex = 2,
		}, track)
		corner(knob, PILL)
		local knobStroke = stroke(knob, Theme.Accent, 2, 0.2)

		local Slider = { Value = minimum, Type = "Slider", Index = index, Callbacks = {}, Min = minimum, Max = maximum }
		local sliding = false

		local function paint()
			local span = maximum - minimum
			local ratio = span > 0 and math.clamp((Slider.Value - minimum) / span, 0, 1) or 0
			glide(fill, { Size = UDim2.new(ratio, 0, 1, 0) }, 0.12)
			glide(knob, { Position = UDim2.new(ratio, 0, 0.5, 0) }, 0.12)
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

		bind(bar.InputBegan, function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				sliding = true
				glide(knob, { Size = UDim2.fromOffset(22, 22) }, 0.1)
				glide(knobStroke, { Thickness = 3, Transparency = 0.05, Color = Theme.Accent3 })
				seek(input.Position.X)
			end
		end)
		bind(UserInputService.InputEnded, function(input)
			if sliding and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
				sliding = false
				glide(knob, { Size = UDim2.fromOffset(18, 18) }, 0.12)
				glide(knobStroke, { Thickness = 2, Transparency = 0.2, Color = Theme.Accent })
			end
		end)
		bind(UserInputService.InputChanged, function(input)
			if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				seek(input.Position.X)
			end
		end)
		bind(bar.MouseEnter, function()
			if not sliding then glide(knob, { Size = UDim2.fromOffset(20, 20) }, 0.1) end
		end)
		bind(bar.MouseLeave, function()
			if not sliding then glide(knob, { Size = UDim2.fromOffset(18, 18) }, 0.1) end
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
		local wrap = autoSlot(5)
		attachTip(wrap, opts.Tooltip)
		caption(wrap, opts.Text or index)

		local button = new("TextButton", {
			Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = Theme.Sunken, BorderSizePixel = 0,
			Text = "", AutoButtonColor = false, LayoutOrder = 1,
		}, wrap)
		corner(button, 10)
		local edge = stroke(button, Theme.Line, 1, 0.25)
		local valueText = label(button, {
			Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -42, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd,
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

		local popup = new("Frame", {
			Visible = false, BackgroundColor3 = Theme.Panel, BorderSizePixel = 0, ClipsDescendants = true, ZIndex = 62,
		}, Overlay)
		corner(popup, 12)
		stroke(popup, Theme.Accent, 1, 0.4)
		local scroll = new("ScrollingFrame", {
			Position = UDim2.fromOffset(4, 4), Size = UDim2.new(1, -8, 1, -8), BackgroundTransparency = 1, BorderSizePixel = 0,
			ScrollBarThickness = 3, ScrollBarImageColor3 = Theme.Accent, CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
		}, popup)
		new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, scroll)

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
				if isSelected(value) then
					glide(r.Frame, { BackgroundColor3 = Theme.Accent, BackgroundTransparency = 0.78 })
					glide(r.Label, { TextColor3 = Theme.AccentText })
				else
					glide(r.Frame, { BackgroundColor3 = Theme.Raised, BackgroundTransparency = 1 })
					glide(r.Label, { TextColor3 = Theme.Text })
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
			popup.Visible = false
			Overlay.Visible = false
			activeClose = nil
			glide(arrow, { Rotation = 0 })
			glide(edge, { Color = Theme.Line })
			glide(button, { BackgroundColor3 = Theme.Sunken })
		end

		local function build()
			for _, child in ipairs(scroll:GetChildren()) do
				if child:IsA("TextButton") then child:Destroy() end
			end
			rows = {}
			for order, value in ipairs(Dropdown.Values) do
				local entry = new("TextButton", {
					Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = Theme.Raised, BackgroundTransparency = 1,
					BorderSizePixel = 0, Text = "", AutoButtonColor = false, LayoutOrder = order,
				}, scroll)
				corner(entry, 8)
				local entryLabel = label(entry, {
					Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -24, 1, 0),
					TextTruncate = Enum.TextTruncate.AtEnd, Text = tostring(value),
				})
				rows[value] = { Frame = entry, Label = entryLabel }
				bind(entry.MouseEnter, function()
					if not isSelected(value) then glide(entry, { BackgroundTransparency = 0.55 }) end
				end)
				bind(entry.MouseLeave, function()
					if not isSelected(value) then glide(entry, { BackgroundTransparency = 1 }) end
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
			paint()
		end

		function Dropdown:SetValues(values)
			Dropdown.Values = values or {}
			build()
		end

		local function open()
			if activeClose then activeClose() end
			Dropdown.Open = true
			activeClose = close
			Overlay.Visible = true

			local sc = math.max(Scale.Scale, 0.01)
			local sAbs, sSize = Shell.AbsolutePosition, Shell.AbsoluteSize
			local bAbs, bSize = button.AbsolutePosition, button.AbsoluteSize
			local x = (bAbs.X - sAbs.X) / sc
			local top = (bAbs.Y - sAbs.Y) / sc
			local bh = bSize.Y / sc
			local w = bSize.X / sc
			local shellH = sSize.Y / sc
			local want = math.min(#Dropdown.Values * 30 + 8, 184)
			local below = shellH - (top + bh) - 10
			local above = top - HEAD_H - 6
			local h, y
			if want <= below or below >= above then
				h = math.min(want, math.max(below, 60))
				y = top + bh + 4
			else
				h = math.min(want, math.max(above, 60))
				y = top - h - 4
			end
			popup.Position = UDim2.fromOffset(x, y)
			popup.Size = UDim2.fromOffset(w, 0)
			popup.Visible = true
			glide(popup, { Size = UDim2.fromOffset(w, h) })
			glide(arrow, { Rotation = 180 })
			glide(edge, { Color = Theme.Accent })
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

		build()
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
		local wrap = autoSlot(5)
		attachTip(wrap, opts.Tooltip)
		caption(wrap, opts.Text or index)

		local field = new("TextBox", {
			Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = Theme.Sunken, BorderSizePixel = 0, Font = FONT,
			TextSize = 13, TextColor3 = Theme.Text, PlaceholderColor3 = Theme.Faint, PlaceholderText = opts.Placeholder or "",
			TextXAlignment = Enum.TextXAlignment.Left, ClearTextOnFocus = false, Text = opts.Default or "", LayoutOrder = 1,
		}, wrap)
		corner(field, 10)
		local edge = stroke(field, Theme.Line, 1, 0.25)
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

		bind(field.Focused, function() glide(edge, { Color = Theme.Accent }) end)
		bind(field.FocusLost, function()
			glide(edge, { Color = Theme.Line })
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
			if not field:IsFocused() then glide(edge, { Color = Theme.Faint }) end
		end)
		bind(field.MouseLeave, function()
			if not field:IsFocused() then glide(edge, { Color = Theme.Line }) end
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

		local row = slot(42)
		local button = new("TextButton", {
			Size = UDim2.fromScale(1, 1), BackgroundColor3 = Theme.Sunken, BorderSizePixel = 0, Font = FONT_B,
			TextSize = 13, TextColor3 = Theme.Text, Text = tostring(text or "Button"), AutoButtonColor = false,
		}, row)
		corner(button, 10)
		local edge = stroke(button, Theme.Line, 1, 0.25)
		attachTip(button, tooltip)

		bind(button.MouseEnter, function()
			glide(button, { BackgroundColor3 = Theme.Panel })
			-- hover glow: o contorno engrossa e acende suavemente
			glide(edge, { Color = Theme.Accent, Thickness = 2, Transparency = 0.05 })
		end)
		bind(button.MouseLeave, function()
			glide(button, { BackgroundColor3 = Theme.Sunken, TextColor3 = Theme.Text })
			glide(edge, { Color = Theme.Line, Thickness = 1, Transparency = 0.25 })
		end)
		bind(button.MouseButton1Down, function()
			-- clique discreto: escurece de leve, sem preencher com cor sólida
			glide(button, { BackgroundColor3 = Theme.Sunken }, 0.08)
		end)
		bind(button.MouseButton1Up, function()
			glide(button, { BackgroundColor3 = Theme.Panel }, 0.12)
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
			row.Size = UDim2.new(1, 0, 0, 30)
			textLabel.AutomaticSize = Enum.AutomaticSize.None
			textLabel.Size = UDim2.new(1, -70, 1, 0)
			textLabel.TextYAlignment = Enum.TextYAlignment.Center
			textLabel.TextTruncate = Enum.TextTruncate.AtEnd

			local chip = new("TextButton", {
				AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(0, 24),
				AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = Theme.Sunken, BorderSizePixel = 0, Font = FONT_B,
				TextSize = 12, TextColor3 = Theme.AccentText, Text = "", AutoButtonColor = false,
			}, row)
			corner(chip, PILL)
			local edge = stroke(chip, Theme.Line, 1, 0.25)
			pad(chip, 12, 12, 0, 0)
			new("UISizeConstraint", { MinSize = Vector2.new(44, 24) }, chip)

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
				if not Picker.Listening then glide(edge, { Color = Theme.Faint }) end
			end)
			bind(chip.MouseLeave, function()
				if not Picker.Listening then glide(edge, { Color = Theme.Line }) end
			end)
			bind(chip.MouseButton1Click, function()
				Picker.Listening = true
				paint()
			end)

			bind(UserInputService.InputBegan, function(input, processed)
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
			end)

			bind(UserInputService.InputEnded, function(input)
				if Picker.Mode ~= "Toggle" and Picker.Active and input.UserInputType == Enum.UserInputType.Keyboard
					and input.KeyCode.Name == Picker.Value then
					Picker.Active = false
					refreshKeybinds()
					if Picker.Mode == "Hold" and opts.Callback then
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

--// ───────────────────────── ORB FLUTUANTE (Premium) ─────────────────────────
function Lib:CreateFloatButton()
	if Lib.FloatButton and Lib.FloatButton.Parent then
		return Lib.FloatButton
	end
	assert(Shell, "[NodtHub] Crie a janela (CreateWindow) antes da bolinha flutuante.")

	local SIZE = 52

	-- "ball" e so a area de toque/arraste (invisivel). O visual vive em "body",
	-- que flutua sozinho sem interferir na posicao do arraste.
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
	local bodyStroke = stroke(body, Theme.Line, 1.4, 0)

	-- Onda suave que se expande e some
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

	-- Pontinho que orbita a borda
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
		BackgroundColor3 = Theme.Accent,
		BorderSizePixel = 0,
		ZIndex = 1001,
	}, orbit)
	corner(dot, PILL)
	new("UIStroke", {
		Color = Theme.Accent,
		Thickness = 3,
		Transparency = 0.7,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, dot)

	-- Letra N com brilho que passa por cima e "respiracao"
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

	-- Animacoes em loop (TweenService: leve, sem RenderStepped)
	local anims = {
		-- flutua pra cima e pra baixo
		TweenService:Create(body, TweenInfo.new(1.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
			Position = UDim2.fromScale(0, -0.06),
		}),
		-- N respira
		TweenService:Create(logoScale, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
			Scale = 1.12,
		}),
		-- brilho atravessa o N
		TweenService:Create(shimmer, TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, false, 0.6), {
			Offset = Vector2.new(1, 0),
		}),
		-- pontinho gira em volta
		TweenService:Create(orbit, TweenInfo.new(3.2, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1, false), {
			Rotation = 360,
		}),
		-- onda expande e some
		TweenService:Create(rippleScale, TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1, false, 0.3), {
			Scale = 1.6,
		}),
		TweenService:Create(rippleStroke, TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1, false, 0.3), {
			Transparency = 1,
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
			-- "pop" ao reaparecer
			pressScale.Scale = 0.7
			glide(pressScale, { Scale = 1 }, 0.3)
		end
	end)
	setAnimating(ball.Visible)

	-- Drag
	local dragging, dragStart, startPos, dragInput = false, nil, nil, nil
	local moved = false
	bind(ball.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, moved = true, false
			dragStart, startPos = input.Position, ball.Position
			glide(pressScale, { Scale = 0.88 }, 0.1)
			local c
			c = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					glide(pressScale, { Scale = 1 }, 0.12)
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

	-- Hover: cresce levemente e a borda acende
	bind(ball.MouseEnter, function()
		glide(pressScale, { Scale = 1.1 }, 0.18)
		glide(bodyStroke, { Color = Theme.Accent })
	end)
	bind(ball.MouseLeave, function()
		if not dragging then
			glide(pressScale, { Scale = 1 }, 0.18)
		end
		glide(bodyStroke, { Color = Theme.Line })
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
	local titleText = string.upper(tostring(config.Title or "NODT HUB"))
	local footerText = config.Footer or "Volleyball Legends"
	if config.NotifySide then Lib:SetNotifySide(config.NotifySide) end

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
	stroke(Shell, Theme.Line, 1.2, 0.25)
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
		local tween = glide(Scale, { Scale = targetScale() })
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

	-- Logo igual ao da bolinha flutuante: fundo escuro + "N" na cor do tema
	local logo = new("Frame", {
		Position = UDim2.fromOffset(16, 12), Size = UDim2.fromOffset(30, 30), BackgroundColor3 = Theme.Shell,
		BorderSizePixel = 0,
	}, Header)
	corner(logo, 9)
	stroke(logo, Theme.Line, 1.4, 0)
	label(logo, {
		Size = UDim2.fromScale(1, 1), Font = Enum.Font.GothamBlack, TextSize = 16, TextColor3 = Theme.Accent,
		TextXAlignment = Enum.TextXAlignment.Center, Text = "N",
	})
	label(Header, {
		Position = UDim2.fromOffset(56, 10), Size = UDim2.new(0.55, 0, 0, 18), Font = FONT_B, TextSize = 15, Text = titleText,
	})
	label(Header, {
		Position = UDim2.fromOffset(56, 28), Size = UDim2.new(0.55, 0, 0, 15), Font = Enum.Font.Gotham, TextSize = 11,
		TextColor3 = Theme.SubText, Text = footerText,
	})

	local function headerButton(text, rightOffset, hoverColor, hoverText)
		local btn = new("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, rightOffset, 0.5, 0), Size = UDim2.fromOffset(30, 30),
			BackgroundColor3 = Theme.Panel, BorderSizePixel = 0, Font = FONT_B, TextSize = 14, TextColor3 = Theme.SubText,
			Text = text, AutoButtonColor = false,
		}, Header)
		corner(btn, PILL)
		local edge = stroke(btn, Theme.LineSoft, 1, 0.15)
		bind(btn.MouseEnter, function()
			glide(btn, { BackgroundColor3 = hoverColor, TextColor3 = hoverText })
			glide(edge, { Color = hoverColor })
		end)
		bind(btn.MouseLeave, function()
			glide(btn, { BackgroundColor3 = Theme.Panel, TextColor3 = Theme.SubText })
			glide(edge, { Color = Theme.LineSoft })
		end)
		return btn
	end
	local closeBtn = headerButton("X", -14, Theme.Accent2, Color3.new(1, 1, 1))
	local minBtn = headerButton("-", -52, Theme.Raised, Theme.Text)

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

	-- MAIN
	local Main = new("Frame", {
		Name = "Main", Position = UDim2.fromOffset(0, HEAD_H), Size = UDim2.new(1, 0, 1, -HEAD_H), BackgroundTransparency = 1,
	}, Shell)

	local TabStrip = new("ScrollingFrame", {
		Name = "Tabs", Position = UDim2.fromOffset(14, 8), Size = UDim2.new(1, -28, 0, TABS_H), BackgroundTransparency = 1,
		BorderSizePixel = 0, ScrollBarThickness = 0, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
	}, Main)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Center,
	}, TabStrip)

	local Body = new("Frame", {
		Name = "Body", Position = UDim2.fromOffset(12, 8 + TABS_H + 8), Size = UDim2.new(1, -24, 1, -(8 + TABS_H + 8 + 12)),
		BackgroundColor3 = Theme.Shell, BorderSizePixel = 0,
	}, Main)
	corner(Body, 12, true)
	stroke(Body, Theme.LineSoft, 1, 0.2)
	pad(Body, 10, 10, 10, 10)

	Window = { Instance = Shell, TabList = {}, Tabs = {}, ActiveTab = nil, Minimized = false }
	Lib.Window = Window

	local function relayoutTabs()
		local n = #Window.TabList
		if n == 0 then return end
		local avail = WIN_W - 28
		local width = math.max(78, math.floor((avail - 8 * (n - 1)) / n))
		for _, tab in ipairs(Window.TabList) do
			tab.Button.Size = UDim2.fromOffset(width, 34)
		end
	end

	function Window:AddTab(name, icon, accent, subtitle)
		local Tab = { Name = name, Icon = icon, Accent = accent, Subtitle = subtitle }

		local btn = new("TextButton", {
			Size = UDim2.fromOffset(100, 34), BackgroundColor3 = Theme.Panel, BackgroundTransparency = 1, BorderSizePixel = 0,
			Font = FONT, TextSize = 13, TextColor3 = Theme.SubText, Text = tostring(name), AutoButtonColor = false,
			LayoutOrder = #Window.TabList + 1,
		}, TabStrip)
		corner(btn, 8, true)
		Tab.Button = btn

		local page = new("Frame", { Name = "Page", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, Body)
		Tab.Page = page

		local function scroller(position, size)
			local sf = new("ScrollingFrame", {
				Position = position, Size = size, BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 4,
				ScrollBarImageColor3 = Theme.Accent, ScrollBarImageTransparency = 0.2, CanvasSize = UDim2.new(),
				AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
			}, page)
			new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, sf)
			pad(sf, 0, 8, 0, 4)
			return sf
		end
		local left = scroller(UDim2.fromOffset(0, 0), UDim2.new(0.5, -6, 1, 0))
		local right = scroller(UDim2.new(0.5, 6, 0, 0), UDim2.new(0.5, -6, 1, 0))

		local function paint(active)
			if active then
				glide(btn, { BackgroundColor3 = Theme.Raised, BackgroundTransparency = 0, TextColor3 = Theme.AccentText })
			else
				glide(btn, { BackgroundTransparency = 1, TextColor3 = Theme.SubText })
			end
		end

		function Tab:Select()
			if activeClose then activeClose() end
			for _, other in ipairs(Window.TabList) do
				if other ~= Tab then
					other.Page.Visible = false
					other.Active = false
					other:Paint(false)
				end
			end
			Tab.Active = true
			page.Visible = true
			Window.ActiveTab = Tab
			paint(true)
		end

		function Tab:Paint(active)
			paint(active)
		end

		bind(btn.MouseEnter, function()
			if not Tab.Active then
				glide(btn, { BackgroundColor3 = Theme.Panel, BackgroundTransparency = 0, TextColor3 = Theme.Text })
			end
		end)
		bind(btn.MouseLeave, function()
			if not Tab.Active then
				glide(btn, { BackgroundTransparency = 1, TextColor3 = Theme.SubText })
			end
		end)
		bind(btn.MouseButton1Click, function()
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
		relayoutTabs()
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
				local tween = glide(Scale, { Scale = targetScale() })
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
	bind(minBtn.MouseButton1Click, function()
		Window:SetMinimized(not Window.Minimized)
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
	local session = rawget(genv, "NODT_SESSION")
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
	-- toda chamada real vai em pcall: erro vira false/nil e nunca propaga
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

local function restore(dump)
	for index, value in pairs(dump.toggles or {}) do
		local toggle = Lib.Toggles[index]
		if toggle then toggle:SetValue(value) end
	end
	for index, value in pairs(dump.options or {}) do
		local option = Lib.Options[index]
		if option and option.SetValue then option:SetValue(value) end
	end
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
		Size = UDim2.fromOffset(290, 178),
		BackgroundColor3 = Theme.Shell,
		BorderSizePixel = 0,
	}, gui)
	corner(frame, 14)
	local frameEdge = stroke(frame, Theme.Line, 1, 0.1)
	local frameScale = new("UIScale", { Scale = 0.92 }, frame)

	-- Marcador minimalista no topo
	local topMark = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.fromOffset(36, 3),
		BackgroundColor3 = Theme.Accent,
		BorderSizePixel = 0,
	}, frame)
	corner(topMark, PILL)

	local function fitScale()
		local view = gui.AbsoluteSize
		if view.X < 1 then return 1 end
		return math.clamp((view.X - 20) / 290, 0.5, 1)
	end

	label(frame, {
		Position = UDim2.fromOffset(20, 16), Size = UDim2.new(1, -40, 0, 20), Font = FONT_B, TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Center, Text = config.Title or "NODT HUB — KEY",
	})
	label(frame, {
		Position = UDim2.fromOffset(20, 38), Size = UDim2.new(1, -40, 0, 14), Font = Enum.Font.Gotham, TextSize = 11,
		TextColor3 = Theme.SubText, TextXAlignment = Enum.TextXAlignment.Center,
		Text = config.Subtitle or "HWID vinculado na 1ª ativação",
	})

	local box = new("TextBox", {
		Position = UDim2.fromOffset(20, 62), Size = UDim2.new(1, -40, 0, 34), BackgroundColor3 = Theme.Sunken,
		BorderSizePixel = 0, ClearTextOnFocus = false, Font = FONT, TextSize = 13, TextColor3 = Theme.Text,
		PlaceholderText = config.Placeholder or "Cole sua key aqui", PlaceholderColor3 = Theme.Faint, Text = "",
		TextXAlignment = Enum.TextXAlignment.Center,
	}, frame)
	corner(box, 10)
	local boxEdge = stroke(box, Theme.LineSoft, 1, 0.1)
	pad(box, 12, 12, 0, 0)

	local errorText = label(frame, {
		Position = UDim2.fromOffset(20, 100), Size = UDim2.new(1, -40, 0, 14), Font = Enum.Font.Gotham, TextSize = 11,
		TextColor3 = Theme.Error, TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "",
	})

	local submit = new("TextButton", {
		Position = UDim2.fromOffset(20, 122), Size = UDim2.new(1, -40, 0, 34), BackgroundColor3 = Theme.Accent,
		BorderSizePixel = 0, AutoButtonColor = false, Font = FONT_B, TextSize = 13, TextColor3 = Theme.OnAccent,
		Text = config.ButtonText or "ATIVAR",
	}, frame)
	corner(submit, 10)
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
		glide(submit, { BackgroundColor3 = Theme.AccentHover }, 0.12)
		if not busy then glide(submitScale, { Scale = 1.02 }, 0.12) end
	end)
	bind(submit.MouseLeave, function()
		glide(submit, { BackgroundColor3 = Theme.Accent }, 0.12)
		if not busy then glide(submitScale, { Scale = 1 }, 0.12) end
	end)
	bind(submit.MouseButton1Down, function()
		glide(submitScale, { Scale = 0.96 }, 0.08)
	end)
	bind(submit.MouseButton1Up, function()
		glide(submitScale, { Scale = 1 }, 0.1)
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
				if frame.Parent then glide(frameEdge, { Color = Theme.Line }) end
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
		if box.Parent then box:CaptureFocus() end
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
_G.__NODT_AUTH_PASSED = false

do
    local API_URL = "https://nodt-jz6jdzp7.manus.space"
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

        local ok, response
        for attempt = 1, 3 do
            ok, response = pcall(req, {
                Url = API_URL .. endpoint,
                Method = method,
                Headers = headers,
                Body = payload
            })

            if ok and response and response.Body and response.StatusCode < 500 then
                break
            end

            warn("[NodtHub] Servidor acordando (tentativa " .. attempt .. "/3)...")
            if attempt < 3 then
                task.wait(2)
            end
        end

        if not ok or not response or not response.Body then return nil, "Network error" end
        local decoded = jsonDecode(response.Body)
        if not decoded then 
            warn("[NodtHub] Resposta invalida do servidor: " .. tostring(response.Body))
            return nil, "Invalid JSON from server" 
        end
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
        local mkdirFn = rawget(_G, "makefolder") or genv.makefolder or makefolder
        local isFolderFn = rawget(_G, "isfolder") or genv.isfolder or isfolder

        if type(writeFn) ~= "function" then return false end

        local ok = pcall(function()
            if type(mkdirFn) == "function" and type(isFolderFn) == "function" then
                local probed, hasDir = pcall(isFolderFn, "NODT")
                if not (probed and hasDir) then
                    pcall(mkdirFn, "NODT")
                end
            end
            writeFn("NODT/token.json", data)
        end)
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
            _G.__NODT_AUTH_PASSED = true
            return true
        end

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
                local resp, status = apiRequest("POST", "/api/nodt/verify", { key = key, hwid = hwid })

                if status == 200 and resp and resp.valid == true then
                    State.SessionToken = resp.token or "token_ok"
                    State.KeyExpiresAt = resp.expires_at or (os.time() + 86400)

                    if saveToken(State.SessionToken, State.KeyExpiresAt) then
                        warn("[NodtHub] Key válida! Token salvo com sucesso.")
                    else
                        warn("[NodtHub] Key válida, mas não foi possível salvar o cache.")
                    end

                    prompt:Destroy()
                    _G.__NODT_AUTH_PASSED = true
                    return true
                else
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

if not _G.__NODT_AUTH_PASSED then
    pcall(function() Library:Unload() end)
    return
end
-- ============================================================


-- [CORE] Knit root resolver
local function getKnitRoot()
    local ReplicatedStorage = game:GetService("ReplicatedStorage")

    local okId, restore = pcall(getthreadidentity or function() end)
    if not okId then restore = nil end
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    local ok, knit = pcall(function()
        return require(ReplicatedStorage.Packages.Knit)
    end)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end
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
                    local okId, restore = pcall(getthreadidentity or function() end)
                    if not okId then restore = nil end
                    if setthreadidentity then
                        pcall(setthreadidentity, 2)
                    end
                    local loaded, result = pcall(require, module)
                    if setthreadidentity and restore then
                        pcall(setthreadidentity, restore)
                    end
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

-- [CORE] Compatibilidade de executor
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
        local okId, restore = pcall(readIdentity or function() end)
        if not okId then restore = nil end
        pcall(setIdentity, 2)
        local fired, firedErr = pcall(fire, signal, ...)
        if restore then
            pcall(setIdentity, restore)
        end
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
        if type(checkcaller) == "function" and checkcaller() then
            return hub.original(self, ...)
        end
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
do
    local okId, restore = pcall(getthreadidentity or function() end)
    if not okId then restore = nil end
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    pcall(function()
        local controllers = game:GetService("ReplicatedFirst"):WaitForChild("Controllers", 10)
        local module = controllers and controllers:WaitForChild("AnimationController", 10)
        if module then
            _AC = require(module)
        end
    end)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end
end

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
    UI_PingLabel = nil,
}

-- Conexoes, threads e movimento
local MovementState = {
    desyncConnection = nil,
    autoBlockConnection = nil,
    bodyVelocity = nil,
    shiftLockConnection = nil,
    autoSpikeConn = nil,
    autoSpikeLastFire = 0,
    antiAfkConnection = nil,
    pingFpsThread = nil,
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
    espHighlights = {},
    espConnections = {},
    originals = {},
    clones = {},
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
    changedProperties = {},
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
State.pingFpsEnabled = false
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
State.autoReceiveEnabled = false
local Receive = { range = 10, lead = 0.35, stamp = 0, gap = 0.2 }

-- Servicos/modulos usados em callbacks de frame: carregar uma vez e tentar novamente no maximo a cada segundo.

local function getCachedServices()
    if ServiceCache._BallController and ServiceCache._Physics and ServiceCache._GameHandlers and ServiceCache._GameConfig and ServiceCache._State then
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
        local okId, restore = pcall(getthreadidentity or function() end)
        if not okId then restore = nil end
        if setthreadidentity then
            pcall(setthreadidentity, 2)
        end
        pcall(function()
            ServiceCache._GameHandlers = require(game:GetService("ReplicatedFirst").Controllers.GameController.Handlers)
        end)
        if setthreadidentity and restore then
            pcall(setthreadidentity, restore)
        end
    end
    if not ServiceCache._Physics then
        local okId, restore = pcall(getthreadidentity or function() end)
        if not okId then restore = nil end
        if setthreadidentity then
            pcall(setthreadidentity, 2)
        end
        pcall(function()
            ServiceCache._Physics = require(ReplicatedStorage.Common.Physics)
        end)
        if setthreadidentity and restore then
            pcall(setthreadidentity, restore)
        end
    end
    if not ServiceCache._GameConfig then
        local okId, restore = pcall(getthreadidentity or function() end)
        if not okId then restore = nil end
        if setthreadidentity then
            pcall(setthreadidentity, 2)
        end
        pcall(function()
            ServiceCache._GameConfig = require(ReplicatedStorage.Configuration.Game)
        end)
        if setthreadidentity and restore then
            pcall(setthreadidentity, restore)
        end
    end
    if not ServiceCache._State then
        local okId, restore = pcall(getthreadidentity or function() end)
        if not okId then restore = nil end
        if setthreadidentity then
            pcall(setthreadidentity, 2)
        end
        pcall(function()
            ServiceCache._State = require(ReplicatedStorage.Common.State)
        end)
        if setthreadidentity and restore then
            pcall(setthreadidentity, restore)
        end
    end
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
    VisualState.clones = {}
    for player, highlight in pairs(VisualState.espHighlights) do
        if highlight and highlight.Destroy then pcall(highlight.Destroy, highlight) end
        VisualState.espHighlights[player] = nil
    end
    VisualState.espHighlights = {}
end

track(LocalPlayer.CharacterAdded:Connect(function()
    clearCharacterVisuals()
end))

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
    Remotes.doMove = BallServiceNode and BallServiceNode:FindFirstChild("RE") and BallServiceNode.RE:FindFirstChild("DoMove")
    Remotes.Interact = BallServiceNode and BallServiceNode:FindFirstChild("RF") and BallServiceNode.RF:FindFirstChild("Interact")
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
        if self == Remotes.Interact and method == "InvokeServer" then
            local data = (...)
            if type(data) == "table" and data.Move == "Spike" then
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
    if CardState.hasFiredCard or CardState.isProcessing or Library.Unloaded then return end
    local PlayerCardService = getPackageService("PlayerCardService")
    local Remote = PlayerCardService and getServiceChild(PlayerCardService, "RE", "OnFlashCard")
    if not Remote then
        warn("[NodtHub] service not found")
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
        CardState.hasFiredCard = false
        CardState.isProcessing = false
    end
end

-- Chamada pelo toggle "Card Protect": aplica o card na hora, sem precisar do botao Apply.
-- Se ja houver um disparo em andamento, espera ele terminar (ate 3s) antes de disparar.
function CardProtect.forceApply()
    task.spawn(function()
        local deadline = os.clock() + 3
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
    local closest, shortest = nil, reach or HitboxState.hitboxReach
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
                        local driver = reachableBall(params, LocalPlayer.Character, spiking and SpikeReach.reach or HitboxState.hitboxReach)
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
    HitboxState.hitboxFollow = track(RunService.RenderStepped:Connect(function()
        for driver, shell in pairs(HitboxState.hitboxBoxes) do
            if driver.Parent and shell.Parent then
                shell.CFrame = driver.CFrame
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
    data.target.Position = head.Position + rootPart.CFrame.LookVector * State.lineDistance
end

track(RunService.RenderStepped:Connect(function()
    if VisualState.linesEnabled then
        for index, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Team ~= LocalPlayer.Team then
                updateLine(player, index)
            else
                removeLine(player)
            end
        end
    else
        for player in pairs(VisualState.lines) do
            removeLine(player)
        end
    end
end))

track(Players.PlayerRemoving:Connect(removeLine))

-- Limpa beams fantasmas no respawn do LocalPlayer
track(LocalPlayer.CharacterAdded:Connect(function()
    for player in pairs(VisualState.lines) do
        removeLine(player)
    end
end))

_G.Lines = {
    SetEnabled = function(value)
        VisualState.linesEnabled = value
        if not value then
            for player in pairs(VisualState.lines) do
                removeLine(player)
            end
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
    if HitboxState.hitboxEnabled then
        radius = radius + HitboxState.hitboxReach
    end

    local ballAhead = ball.Position + ball.AssemblyLinearVelocity * (Receive.lead or 0)
    local distance = (ballAhead - rootPart.Position).Magnitude
    if distance >= radius then return end

    getCachedServices()
    local handlers = ServiceCache._GameHandlers
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
        pcall(function() firesignal(Remotes.doMove.OnClientEvent, "Set", false, false) end)
    end
end

track(RunService.RenderStepped:Connect(autoReceive))

local function autoSpikeStep()
    if not State.autoSpikeEnabled then return end
    if Library.Unloaded then return end

    -- cooldown 0.5s
    local now = os.clock()
    if now - MovementState.autoSpikeLastFire < 0.5 then return end

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
    if height < 3 then return end          -- bola muito baixa, não é spike
    if distance > 12 then return end       -- longe demais
    if distance < 2 then return end        -- colada, provavelmente já tocou

    -- dispara o spike
    MovementState.autoSpikeLastFire = now
    if firesignal and Remotes.doMove then
        pcall(function() firesignal(Remotes.doMove.OnClientEvent, "Spike", false, false) end)
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
        if self == Remotes.Interact and method == "InvokeServer" then
            local data = (...)
            if type(data) == "table" and data.Move == "Spike" and State.redirectSpikeEnabled then
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
            return callNext(self, method, data)
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
    if HookState.autoRejoinInstalled then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end

    local hooked = hookNamecall("autoRejoin", function(callNext, self, method, ...)
        if self == LocalPlayer and method == "Kick" then
            if State.autoRejoinEnabled then
                -- Intercepta o Kick e agenda o Teleport
                task.spawn(function()
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
    if HookState.autoRejoinInstalled then pcall(HookState.autoRejoinInstalled); HookState.autoRejoinInstalled = false end
end

local AutoCorner = {
    enabled = false,
    side = "Auto",
    reach = "All",
}

local function enableSanjuTilt()
    State.sanjuTiltEnabled = true
    if HookState.sanjuTiltInstalled then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("sanjuTilt", function(callNext, self, method, ...)
        if not Remotes.BallService then return callNext(self, method, ...) end
        if self == Remotes.Interact and method == "InvokeServer" then
            local data = (...)
            if type(data) == "table" and data.Move == "Spike" and State.sanjuTiltEnabled then
                pcall(function()
                    if data.TiltDirection and data.LookVector then
                        local tiltDir = data.TiltDirection
                        if math.abs(tiltDir.X) > 0.01 or math.abs(tiltDir.Z) > 0.01 then
                            local lookVec = data.LookVector
                            local bend = Vector3.new(tiltDir.X, 0, tiltDir.Z)
                            -- Soma 30% do tilt na mira; evita .Unit em vetor zero (NaN)
                            local blended = Vector3.new(
                                lookVec.X + bend.X * 0.3,
                                lookVec.Y,
                                lookVec.Z + bend.Z * 0.3
                            )
                            if blended.Magnitude > 0.001 then
                                data.LookVector = blended.Unit
                            else
                                data.LookVector = lookVec
                            end
                            -- Aumenta tilt em 35%, mas limita X/Z a 1.0 (servidor rejeita > 1)
                            local tx = math.clamp(tiltDir.X * 1.35, -1.0, 1.0)
                            local tz = math.clamp(tiltDir.Z * 1.35, -1.0, 1.0)
                            data.TiltDirection = Vector3.new(tx, tiltDir.Y, tz)
                        end
                    end
                end)
            end
            return callNext(self, method, data)
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
    local okId, restore = pcall(getthreadidentity or function() end)
    if not okId then restore = nil end
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    local reached, module = pcall(require, ReplicatedStorage.Common.Physics)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end
    return reached and module or nil
end

AutoCorner.bounds = function()
    local physics = AutoCorner.physics()
    if physics then
        local hasFn, fn = pcall(function()
            return physics._getCourtlines
        end)
        if hasFn and type(fn) == "function" then
            local found, lines = pcall(fn)
            if found and lines and typeof(lines) == "Instance" and lines:IsA("BasePart") then
                return lines.Position, lines.Size * 0.5, lines.Position.Y
            end
        end
    end
    -- Fallback: tamanho da quadra via workspace.Map.Court
    local map = Workspace:FindFirstChild("Map")
    local court = map and map:FindFirstChild("Court")
    if court and court:IsA("BasePart") then
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
    local netZ = net and net.Position.Z

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
    local bounds = nil
    if physics then
        local hasFn, fn = pcall(function()
            return physics._getCourtlines
        end)
        if hasFn and type(fn) == "function" then
            local okLines, lines = pcall(fn)
            if okLines then
                bounds = lines
            end
        end
    end

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
        if not Remotes.BallService then return callNext(self, method, ...) end
        if self == Remotes.Interact and method == "InvokeServer" then
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
        AutoCorner.aimRelease = hooked
    end
end

AutoCorner.disableAim = function()
    if AutoCorner.aimRelease then pcall(AutoCorner.aimRelease); AutoCorner.aimRelease = nil end
    AutoCorner.aimed = false
end

local function enableMaxCharge()
    State.maxChargeEnabled = true
    if HookState.maxChargeHookActive then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("maxCharge", function(callNext, self, method, ...)
        if not Remotes.BallService then return callNext(self, method, ...) end
        if self == Remotes.Interact and method == "InvokeServer" then
            local data = (...)
            if type(data) == "table" and data.Move == "Spike" and State.maxChargeEnabled then
                pcall(function()
                    data.Charge = 1.0
                    data.SpecialCharge = 1.0
                    data.Power = 1.0
                    data.Force = 1.0
                    data.ChargeTime = 10.0
                    if data.HoldTime ~= nil then data.HoldTime = 2.0 end
                    if data.HoldDuration ~= nil then data.HoldDuration = 2.0 end
                end)
            end
            return callNext(self, method, data)
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

local Silent = { steer = nil, expiry = 0, hooked = false, release = nil, hushToken = 0 }

Silent.install = function()
    if Silent.hooked then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("silentSpike", function(callNext, self, method, ...)
        if not Remotes.BallService then return callNext(self, method, ...) end
        if self == Remotes.Interact and method == "InvokeServer" then
            local data = (...)
            local steer = Silent.steer
            if steer ~= nil then
                if os.clock() >= Silent.expiry then
                    Silent.steer = nil
                    Silent.expiry = 0
                elseif type(data) == "table" and typeof(steer) == "Vector3" then
                    if data.Move == "Spike" or data.Move == "ServeSpike" then
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
    if type(Silent.release) == "function" then
        pcall(Silent.release)
    end
    Silent.release = nil
    Silent.hooked = false
    pcall(Hush.stop)
end

local function fireNewSpike()
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
    SpikeReach.expiry = os.clock() + 0.3

    -- Token: só o último silent spike pode chamar Hush.stop
    Silent.hushToken = (Silent.hushToken or 0) + 1
    local myHush = Silent.hushToken

    local expiry = os.clock() + 0.5
    Silent.steer = dir
    Silent.expiry = expiry
    Silent.install()
    local fsOk = pcall(firesignal, newRemote.OnClientEvent, "Spike", false, false, dir)
    if not fsOk and not Core._fsWarned.fireNewSpike then
        Core._fsWarned.fireNewSpike = true
        warn("[NodtHub] firesignal falhou em fireNewSpike")
    end

    task.spawn(function()
        task.wait(0.3)
        if Silent.hushToken == myHush then
            Hush.stop()
        end
    end)
    task.delay(0.5, function()
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
    ButtonState.newSpikeButton = Instance.new("TextButton")
    ButtonState.newSpikeButton.Size = UDim2.new(0, 50, 0, 50)
    ButtonState.newSpikeButton.Position = UDim2.new(0.5, -25, 0.85, -25)
    ButtonState.newSpikeButton.BackgroundColor3 = Color3.fromRGB(9, 13, 16)
    ButtonState.newSpikeButton.Text = "Spike"
    ButtonState.newSpikeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    ButtonState.newSpikeButton.TextScaled = true
    ButtonState.newSpikeButton.Font = Enum.Font.GothamBold
    ButtonState.newSpikeButton.Parent = screenGui
    ButtonState.newSpikeButton.BackgroundTransparency = 0.12
    ButtonState.newSpikeButton.BorderSizePixel = 0
    ButtonState.newSpikeButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = ButtonState.newSpikeButton
    local ring = Instance.new("UIStroke")
    ring.Color = Color3.fromRGB(255, 76, 46)
    ring.Thickness = 2
    ring.Transparency = 0.1
    ring.Parent = ButtonState.newSpikeButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    ButtonState.newSpikeButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = ButtonState.newSpikeButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    ButtonState.newSpikeButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            ButtonState.newSpikeButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    ButtonState.newSpikeButton.MouseButton1Click:Connect(function()
        fireNewSpike()
    end)
    ButtonState.newSpikeButton.Visible = false
    return ButtonState.newSpikeButton
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
                pcall(function() firesignal(Remotes.doMove.OnClientEvent, "Spike", false, false) end)
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
                pcall(function() firesignal(Remotes.doMove.OnClientEvent, "Block", false, false) end)
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

track(UserInputService.JumpRequest:Connect(function()
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

    local okId, restore = pcall(getthreadidentity or function() end)
    if not okId then restore = nil end
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
    local okId, restore = pcall(getthreadidentity or function() end)
    if not okId then restore = nil end
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
    ButtonState.dashButton = Instance.new("TextButton")
    ButtonState.dashButton.Size = UDim2.new(0, 50, 0, 50)
    ButtonState.dashButton.Position = UDim2.new(0.15, -25, 0.8, -25)
    ButtonState.dashButton.BackgroundColor3 = Color3.fromRGB(9, 13, 16)
    ButtonState.dashButton.Text = "⚡"
    ButtonState.dashButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    ButtonState.dashButton.TextScaled = true
    ButtonState.dashButton.Font = Enum.Font.GothamBold
    ButtonState.dashButton.Parent = screenGui
    ButtonState.dashButton.BackgroundTransparency = 0.12
    ButtonState.dashButton.BorderSizePixel = 0
    ButtonState.dashButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = ButtonState.dashButton
    local ring = Instance.new("UIStroke")
    ring.Color = Color3.fromRGB(255, 76, 46)
    ring.Thickness = 2
    ring.Transparency = 0.1
    ring.Parent = ButtonState.dashButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    ButtonState.dashButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = ButtonState.dashButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    ButtonState.dashButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            ButtonState.dashButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    ButtonState.dashButton.MouseButton1Click:Connect(akariDash)
    ButtonState.dashButton.Visible = false
    return ButtonState.dashButton
end

createDashButton()

local function stopBall()
    if not Remotes.BallService then return end
    local ballId = getBallId()
    if not ballId then return end
    local lookVector = Vector3.new(0, -1, 0)
    if Remotes.Interact then
        Remotes.Interact:InvokeServer({
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
    ButtonState.stopBallButton = Instance.new("TextButton")
    ButtonState.stopBallButton.Size = UDim2.new(0, 50, 0, 50)
    ButtonState.stopBallButton.Position = UDim2.new(0.35, -25, 0.8, -25)
    ButtonState.stopBallButton.BackgroundColor3 = Color3.fromRGB(9, 13, 16)
    ButtonState.stopBallButton.Text = "Stop"
    ButtonState.stopBallButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    ButtonState.stopBallButton.TextScaled = true
    ButtonState.stopBallButton.Font = Enum.Font.GothamBold
    ButtonState.stopBallButton.Parent = screenGui
    ButtonState.stopBallButton.BackgroundTransparency = 0.12
    ButtonState.stopBallButton.BorderSizePixel = 0
    ButtonState.stopBallButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = ButtonState.stopBallButton
    local ring = Instance.new("UIStroke")
    ring.Color = Color3.fromRGB(255, 92, 110)
    ring.Thickness = 2
    ring.Transparency = 0.1
    ring.Parent = ButtonState.stopBallButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    ButtonState.stopBallButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = ButtonState.stopBallButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    ButtonState.stopBallButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            ButtonState.stopBallButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    ButtonState.stopBallButton.MouseButton1Click:Connect(function()
        stopBall()
    end)
    ButtonState.stopBallButton.Visible = ButtonState.stopBallVisible
    return ButtonState.stopBallButton
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
        local okId, restore = pcall(getthreadidentity or function() end)
        if not okId then restore = nil end
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
            local waitTime = math.max(0.1, tonumber(state.delay) or 0.1)
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

    local api = { state = state }

    api.connect = function()
        if api.connection then return end
        api.connection = track(RunService.Heartbeat:Connect(step))
    end

    return api
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
        Remotes.Interact:InvokeServer({
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


local function enableAutoSetAim()
    State.autoSetAimEnabled = true
    if HookState.autoSetAimInstalled then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end

    local hooked = hookNamecall("autoSetAim", function(callNext, self, method, ...)
        if not Remotes.BallService then return callNext(self, method, ...) end
        if self == Remotes.Interact and method == "InvokeServer" then
            local data = (...)
            if type(data) == "table" and data.Move == "JumpSet" and State.autoSetAimEnabled then
                -- Pega o amigo mais próximo
                local nearestTeammate = getNearestTeammate()
                local playerRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")

                if nearestTeammate and nearestTeammate.Character and playerRoot then
                    local targetRoot = nearestTeammate.Character:FindFirstChild("HumanoidRootPart")
                    if targetRoot then
                        -- Calcula a direção perfeita e aplica
                        local direction = (targetRoot.Position - playerRoot.Position).Unit

                        -- Aplica os vetores que o jogo usa pro JumpSet
                        data.TiltDirection = Vector3.new(direction.X, 1, direction.Z)
                        local flatLook = Vector3.new(direction.X, 0, direction.Z)
                        if flatLook.Magnitude > 0.01 then
                            data.LookVector = flatLook.Unit
                        end
                    end
                end
            end
            return callNext(self, method, data)
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
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    screenGui.ResetOnSpawn = false
    ButtonState.aimButton = Instance.new("TextButton")
    ButtonState.aimButton.Size = UDim2.new(0, 50, 0, 50)
    ButtonState.aimButton.Position = UDim2.new(0.65, -25, 0.8, -25)
    ButtonState.aimButton.BackgroundColor3 = Color3.fromRGB(9, 13, 16)
    ButtonState.aimButton.Text = "Aim"
    ButtonState.aimButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    ButtonState.aimButton.TextScaled = true
    ButtonState.aimButton.Font = Enum.Font.GothamBold
    ButtonState.aimButton.Parent = screenGui
    ButtonState.aimButton.BackgroundTransparency = 0.12
    ButtonState.aimButton.BorderSizePixel = 0
    ButtonState.aimButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = ButtonState.aimButton
    local ring = Instance.new("UIStroke")
    ring.Color = Color3.fromRGB(255, 76, 46)
    ring.Thickness = 2
    ring.Transparency = 0.1
    ring.Parent = ButtonState.aimButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    ButtonState.aimButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = ButtonState.aimButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    ButtonState.aimButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            ButtonState.aimButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    ButtonState.aimButton.MouseButton1Click:Connect(function()
        aim()
    end)
    ButtonState.aimButton.Visible = ButtonState.aimVisible
    return ButtonState.aimButton
end

track(RunService.RenderStepped:Connect(function()
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
end))
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
        if self == Remotes.Serve and method == "InvokeServer" and State.maxServeEnabled then
            local args = {...}
            args[2] = 5
            return callNext(self, method, unpack(args))
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

-- Cache dos módulos do Lead Feet (evita require a cada uso)

local function leadFeetSlam()
    if not State.leadFeetEnabled then return end
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not character or not root then return end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return end

    local tuning = { Acceleration = -10000, TerminalVelocity = -300, Duration = 2 }
    local controller = nil

    local okId, restore = pcall(getthreadidentity or function() end)
    if not okId then restore = nil end
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
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
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end

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
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    screenGui.ResetOnSpawn = false
    ButtonState.leadFeetButton = Instance.new("TextButton")
    ButtonState.leadFeetButton.Size = UDim2.new(0, 50, 0, 50)
    ButtonState.leadFeetButton.Position = UDim2.new(0.25, -25, 0.8, -25)
    ButtonState.leadFeetButton.BackgroundColor3 = Color3.fromRGB(9, 13, 16)
    ButtonState.leadFeetButton.Text = "LF"
    ButtonState.leadFeetButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    ButtonState.leadFeetButton.TextScaled = true
    ButtonState.leadFeetButton.Font = Enum.Font.GothamBold
    ButtonState.leadFeetButton.Parent = screenGui
    ButtonState.leadFeetButton.BackgroundTransparency = 0.12
    ButtonState.leadFeetButton.BorderSizePixel = 0
    ButtonState.leadFeetButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = ButtonState.leadFeetButton
    local ring = Instance.new("UIStroke")
    ring.Color = Color3.fromRGB(255, 76, 46)
    ring.Thickness = 2
    ring.Transparency = 0.1
    ring.Parent = ButtonState.leadFeetButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    ButtonState.leadFeetButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = ButtonState.leadFeetButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    ButtonState.leadFeetButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            ButtonState.leadFeetButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    ButtonState.leadFeetButton.MouseButton1Click:Connect(leadFeetSlam)
    ButtonState.leadFeetButton.Visible = false
    return ButtonState.leadFeetButton
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

    local okId, restore = pcall(getthreadidentity or function() end)
    if not okId then restore = nil end
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    local loaded, Jersey = pcall(require, ReplicatedStorage.Tools.Jersey)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end
    if not loaded or type(Jersey) ~= "table" or not Jersey.set then
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

local Kisuki = { enabled = false, hooked = false, charge = 1 }

Kisuki.effect = function(strong)
    local character = LocalPlayer.Character
    if not character or not character.PrimaryPart then return end
    local assets = ReplicatedStorage:FindFirstChild("Assets")
    local effects = assets and assets:FindFirstChild("Effects")
    local module = effects and effects:FindFirstChild("SuperDive")
    if not module then return end

    local okId, restore = pcall(getthreadidentity or function() end)
    if not okId then restore = nil end
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
        local okId, restore = pcall(getthreadidentity or function() end)
        if not okId then restore = nil end
        if setthreadidentity then
            pcall(setthreadidentity, 2)
        end
        local styled, special = pcall(require, ReplicatedStorage.Content.Style.Kimiro.Special)
        if setthreadidentity and restore then
            pcall(setthreadidentity, restore)
        end
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
        local restored = pcall(function()
            inventory.Inventory:set(Vault.real)
        end)
        if restored then
            Vault.real = nil
            if session then session.vault = nil end
        end
        return
    end

    local okId, restore = pcall(getthreadidentity or function() end)
    if not okId then restore = nil end
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    local catalogued, Item = pcall(require, ReplicatedStorage.Content.Item)
    local ItemFolder = ReplicatedStorage:FindFirstChild("Content") and ReplicatedStorage.Content:FindFirstChild("Item")
    local entities = ItemFolder and ItemFolder:FindFirstChild("Entities")
    if not catalogued or not entities then
        if setthreadidentity and restore then
            pcall(setthreadidentity, restore)
        end
        return
    end

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
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end
    pcall(function()
        inventory.Inventory:set(stocked)
    end)
end

Vault.typeOf = function(id)
    local ItemFolder = ReplicatedStorage:FindFirstChild("Content") and ReplicatedStorage.Content:FindFirstChild("Item")
    local module = ItemFolder and ItemFolder:FindFirstChild("Entities")
    module = module and module:FindFirstChild(id)
    if not module then return nil end
    local okId, restore = pcall(getthreadidentity or function() end)
    if not okId then restore = nil end
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    local read, entry = pcall(require, module)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end
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
        if not ServiceCache._GameConfig or not ServiceCache._State then return nil end
        return ServiceCache._State.get(ReplicatedStorage, ServiceCache._State.Id.Modifier, "BallGravity", ServiceCache._GameConfig.Physics.Gravity)
    end)
    if pulled and type(value) == "number" and value > 0 then
        return value
    end
    return 17
end

Landing.velocity = function(part)
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
    local module = ServiceCache._Physics
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


local function updateSpikeTrajectory()
    if not State.spikeTrajectoryEnabled then
        if TrajectoryState.trajectoryBeam then TrajectoryState.trajectoryBeam.Enabled = false end
        if TrajectoryState.trajectoryPart then TrajectoryState.trajectoryPart.Transparency = 1 end
        return
    end

    local ball = getNearestBall()
    if not ball then return end

    -- Tracking próprio do drift (independente do Landing Marker)
    local now = os.clock()
    if Landing.tracked == ball and Landing.last and now > Landing.stamp then
        Landing.drift = (ball.Position - Landing.last) / (now - Landing.stamp)
    end
    Landing.tracked = ball
    Landing.last = ball.Position
    Landing.stamp = now

    local spot = Landing.predict(ball)
    if not spot then return end

    -- Cria a linha se não existir
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
        TrajectoryState.trajectoryBeam.Color = ColorSequence.new(Color3.fromRGB(255, 60, 60)) -- Vermelho neon
        TrajectoryState.trajectoryBeam.LightEmission = 1
        TrajectoryState.trajectoryBeam.Parent = ball
    end

    -- Atualiza a posição do ponto final e ativa a linha
    TrajectoryState.trajectoryAttach0.Parent = ball
    TrajectoryState.trajectoryPart.Position = spot
    TrajectoryState.trajectoryBeam.Enabled = true
end

track(RunService.RenderStepped:Connect(updateSpikeTrajectory))

effectList = {}
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
                if string.match(name, "Card") or string.match(name, "PlayerCard") then
                    table.insert(CardState.cardList, name)
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
            -- [NOVO] sincroniza o slot do inventário antes do disparo
            -- Cooldown: evita flood de chamadas ao Vault (no maximo 1 a cada 0.5s).
            if os.clock() - lastVaultTime > 0.5 then
                lastVaultTime = os.clock()
                Vault.setSlot("ScoreEffect", State.selectedEffect)
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
                fireHitRemote(child.Position)
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
    local humanoid = character:WaitForChild("Humanoid")
    local rootPart = character:WaitForChild("HumanoidRootPart")
    
    if MovementState.shiftLockConnection then
        MovementState.shiftLockConnection:Disconnect()
        MovementState.shiftLockConnection = nil
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

    -- Limpa mira antiga do AutoCorner ao aterrissar / voltar a correr
    track(humanoid.StateChanged:Connect(function(_, newState)
        if newState == Enum.HumanoidStateType.Landed or newState == Enum.HumanoidStateType.Running then
            AutoCorner.steer = nil
        end
    end))
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

track(UserInputService.JumpRequest:Connect(function()
    if not State.fakeSpikeEnabled then return end
    pcall(doFakeSpike)
end))

local function startAutoSpin()
    coroutine.wrap(function()
        while State.autoSpin do
            local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
            local interface = pg and pg:FindFirstChild("Interface")
            local lobby = interface and interface:FindFirstChild("Lobby")
            local sub = lobby and lobby:FindFirstChild("Styles")
            local topPanel = sub and sub:FindFirstChild("TopPanel")
            local nameLabel = topPanel and topPanel:FindFirstChild("DisplayName")
            if not nameLabel then
                task.wait(0.5)
                continue
            end
            local currentStyle = nameLabel.Text
            for _, style in ipairs(CardState.desiredStyles) do
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
            local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
            local interface = pg and pg:FindFirstChild("Interface")
            local lobby = interface and interface:FindFirstChild("Lobby")
            local sub = lobby and lobby:FindFirstChild("Abilities")
            local topPanel = sub and sub:FindFirstChild("TopPanel")
            local nameLabel = topPanel and topPanel:FindFirstChild("DisplayName")
            if not nameLabel then
                task.wait(0.5)
                continue
            end
            local currentAbility = nameLabel.Text
            for _, ability in ipairs(CardState.desiredAbilities) do
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
        if not instance then return end
        pcall(function()
            instance[propertyName] = value
        end)
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
        -- Nunca otimiza personagens de jogadores (local, inimigos, aliados)
        local model = instance:FindFirstAncestorOfClass("Model")
        if model and model.Parent == workspace then
            if model:FindFirstChildOfClass("Humanoid") then
                return true
            end
        end
        -- Fallback: qualquer Character sob Players
        for _, player in ipairs(Players:GetPlayers()) do
            local character = player.Character
            if character and instance:IsDescendantOf(character) then
                return true
            end
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

    -- Processa descendentes em lotes no Heartbeat (evita micro-stutters)
    local descendants = workspace:GetDescendants()
    local index = 1
    local batchSize = 150
    local batchConn
    batchConn = RunService.Heartbeat:Connect(function()
        if Library.Unloaded then
            if batchConn then
                batchConn:Disconnect()
                batchConn = nil
            end
            return
        end
        local last = math.min(index + batchSize - 1, #descendants)
        for i = index, last do
            optimizeInstance(descendants[i])
        end
        index = last + 1
        if index > #descendants then
            if batchConn then
                batchConn:Disconnect()
                batchConn = nil
            end
        end
    end)
    table.insert(AntiLagState.antilagConnections, batchConn)

    local conn = workspace.DescendantAdded:Connect(function(instance)
        if Library.Unloaded then return end
        optimizeInstance(instance)
    end)
    table.insert(AntiLagState.antilagConnections, conn)
end

local function disableAntiLag()
    for instance, props in pairs(AntiLagState.changedProperties) do
        if instance and instance.Parent then
            for prop, value in pairs(props) do
                pcall(function()
                    instance[prop] = value
                end)
            end
        end
    end
    AntiLagState.changedProperties = {}
    
    if AntiLagState.oldQualityLevel ~= nil then
        pcall(function()
            settings().Rendering.QualityLevel = AntiLagState.oldQualityLevel
        end)
        AntiLagState.oldQualityLevel = nil
    end
    
    if AntiLagState.oldSavedQualityLevel ~= nil then
        pcall(function()
            UserSettings():GetService("UserGameSettings").SavedQualityLevel = AntiLagState.oldSavedQualityLevel
        end)
        AntiLagState.oldSavedQualityLevel = nil
    end
    
    for _, conn in ipairs(AntiLagState.antilagConnections) do
        pcall(function()
            conn:Disconnect()
        end)
    end
    AntiLagState.antilagConnections = {}
end
Library.RestoreAntiLag = disableAntiLag


-- Custom Crosshair (GUI) — em do-block para nao consumir locals do chunk (limite de 200)
do
    local crosshairGui = Instance.new("ScreenGui")
    crosshairGui.Name = "NODT_Crosshair"
    crosshairGui.ResetOnSpawn = false
    crosshairGui.IgnoreGuiInset = true
    crosshairGui.DisplayOrder = 999999
    -- Tenta parentar no CoreGui ou no PlayerGui
    pcall(function() crosshairGui.Parent = game:GetService("CoreGui") end)
    if not crosshairGui.Parent then
        crosshairGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    end

    local crosshairFrame = Instance.new("Frame")
    crosshairFrame.Name = "Crosshair"
    crosshairFrame.AnchorPoint = Vector2.new(0.5, 0.5)
    crosshairFrame.Position = UDim2.fromScale(0.5, 0.5)
    crosshairFrame.BackgroundTransparency = 1
    crosshairFrame.Visible = false
    crosshairFrame.Parent = crosshairGui

    -- Cruz Horizontal
    local crossX = Instance.new("Frame")
    crossX.Name = "CrossX"
    crossX.AnchorPoint = Vector2.new(0.5, 0.5)
    crossX.Position = UDim2.fromScale(0.5, 0.5)
    crossX.BackgroundColor3 = State.crosshairColor
    crossX.BorderSizePixel = 0
    crossX.Parent = crosshairFrame

    -- Cruz Vertical
    local crossY = Instance.new("Frame")
    crossY.Name = "CrossY"
    crossY.AnchorPoint = Vector2.new(0.5, 0.5)
    crossY.Position = UDim2.fromScale(0.5, 0.5)
    crossY.BackgroundColor3 = State.crosshairColor
    crossY.BorderSizePixel = 0
    crossY.Parent = crosshairFrame

    -- Função para atualizar o tamanho e cor
    local function updateCrosshairVisual()
        local size = State.crosshairSize
        crossX.Size = UDim2.fromOffset(size * 2, 2) -- 2 de espessura
        crossY.Size = UDim2.fromOffset(2, size * 2)
        crossX.BackgroundColor3 = State.crosshairColor
        crossY.BackgroundColor3 = State.crosshairColor
    end
    updateCrosshairVisual()

    Core.Crosshair = { Gui = crosshairGui, Frame = crosshairFrame, Update = updateCrosshairVisual }
end

-- ============================================================
-- [CORE] FACHADA PÚBLICA — expõe a lógica para a UI
-- ============================================================
-- Internamente o core continua usando locals (limite de 200 no chunk).
-- A UI deve chamar apenas os métodos abaixo.

Core.State = State

-- Spike / movement
function Core.ToggleRedirectSpike(value)
	if value then enableRedirectSpike() else disableRedirectSpike() end
end
function Core.ToggleAutoCorner(value)
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
function Core.SetAutoCornerSide(value)
	AutoCorner.side = value
end
function Core.SetAutoCornerReach(value)
	AutoCorner.reach = value
end
function Core.ToggleSilentSpike(value)
	State.newSilentSpikeEnabled = value and true or false
	if ButtonState.newSpikeButton then ButtonState.newSpikeButton.Visible = value end
	if not value and Silent and Silent.uninstall then
		Silent.uninstall()
	end
end
function Core.FireSilentSpike()
	fireNewSpike()
end
function Core.ToggleSanjuTilt(value)
	if value then enableSanjuTilt() else disableSanjuTilt() end
end
function Core.ToggleMaxCharge(value)
	if value then enableMaxCharge() else disableMaxCharge() end
end
function Core.ToggleFakeSpike(value)
	State.fakeSpikeEnabled = value and true or false
end
function Core.ToggleAutoCounter(value)
	AutoCounter.state.enabled = value and true or false
	if value then
		AutoCounter.connect()
	elseif AutoCounter.connection then
		pcall(function() AutoCounter.connection:Disconnect() end)
		AutoCounter.connection = nil
	end
end
function Core.SetAutoCounterMove(value)
	AutoCounter.state.move = value
end
function Core.SetAutoCounterNetRange(value)
	AutoCounter.state.netRange = value
end
function Core.SetAutoCounterLateral(value)
	AutoCounter.state.lateral = value
end
function Core.SetAutoCounterDelay(value)
	AutoCounter.state.delay = value
end
function Core.SetAutoCounterJump(value)
	AutoCounter.state.autoJump = value and true or false
end

-- Hitbox
function Core.ToggleHitbox(value)
	HitboxState.hitboxEnabled = value and true or false
	if value then updateHitboxes(HitboxState.hitboxScale) else removeHitboxes() end
end
function Core.SetHitboxSize(value)
	HitboxState.hitboxScale = value
	if HitboxState.hitboxEnabled then updateHitboxes(value) end
end
function Core.SetHitboxColor(value)
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
function Core.RemoveHitboxes()
	removeHitboxes()
end
function Core.ToggleStopBallButton()
	ButtonState.stopBallVisible = not ButtonState.stopBallVisible
	if ButtonState.stopBallButton then
		ButtonState.stopBallButton.Visible = ButtonState.stopBallVisible
	else
		ButtonState.stopBallButton = createStopBallButton()
	end
end
function Core.ToggleAimButton()
	ButtonState.aimVisible = not ButtonState.aimVisible
	if ButtonState.aimButton then
		ButtonState.aimButton.Visible = ButtonState.aimVisible
	else
		ButtonState.aimButton = createAimButton()
	end
end

-- Performance / movement
function Core.ToggleAntiLag(value)
	if value then enableAntiLag() else disableAntiLag() end
end
function Core.ToggleFPSUnlock(value)
    State.fpsUnlockEnabled = value and true or false
    if State.fpsUnlockEnabled then
        -- Tenta desbloquear para 120 FPS (padrão para mobile)
        pcall(function()
            if type(setfpscap) == "function" then
                setfpscap(120)
            elseif type(sethiddenproperty) == "function" then
                sethiddenproperty(game:GetService("RunService"), "MaxFPS", 120)
            end
        end)
    else
        pcall(function()
            if type(setfpscap) == "function" then
                setfpscap(0)  -- 0 = sem cap, deixa o executor/jogo aplicar o padrão
            elseif type(sethiddenproperty) == "function" then
                sethiddenproperty(game:GetService("RunService"), "MaxFPS", 60)
            end
        end)
    end
end
function Core.ToggleDesync(value)
	if value then enableDesync() else disableDesync() end
end
function Core.ToggleAutoBlock(value)
    State.autoBlockEnabled = value and true or false
    if value then
        enableAutoBlock()
    else
        disableAutoBlock()
    end
end
function Core.ToggleAutoRejoin(value)
    if value then enableAutoRejoin() else disableAutoRejoin() end
end
function Core.ToggleAutoReady(value)
    State.autoReadyEnabled = value and true or false
    if value then
        if not MovementState.autoReadyThread then
            MovementState.autoReadyThread = task.spawn(function()
                while State.autoReadyEnabled and not Library.Unloaded do
                    task.wait(1)
                    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
                    if pg then
                        local clicked = false
                        for _, gui in ipairs(pg:GetDescendants()) do
                            if gui:IsA("TextButton") and gui.Visible then
                                local txt = string.lower(gui.Text or "")
                                if txt == "ready" or txt == "accept" or txt == "confirm"
                                or txt == "play again" or txt == "jogar novamente" or txt == "aceitar" then
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
                        end
                        if clicked then task.wait(0.5) end
                    end
                end
                MovementState.autoReadyThread = nil
            end)
        end
    end
end
function Core.ToggleAutoSetAim(value)
    if value then enableAutoSetAim() else disableAutoSetAim() end
end
function Core.ToggleAutoSpike(value)
    State.autoSpikeEnabled = value and true or false
    if value then
        if not MovementState.autoSpikeConn then
            MovementState.autoSpikeConn = track(RunService.RenderStepped:Connect(autoSpikeStep))
        end
    else
        if MovementState.autoSpikeConn then
            MovementState.autoSpikeConn:Disconnect()
            MovementState.autoSpikeConn = nil
        end
    end
end
function Core.ToggleAntiAFK(value)
	if not value then
		if MovementState.antiAfkConnection then
			MovementState.antiAfkConnection:Disconnect()
			MovementState.antiAfkConnection = nil
		end
		return
	end
	if MovementState.antiAfkConnection then return end
	MovementState.antiAfkConnection = LocalPlayer.Idled:Connect(function()
		local VirtualUser = game:GetService("VirtualUser")
		if VirtualUser then
			local okCapture = pcall(VirtualUser.CaptureController, VirtualUser)
			local okClick = pcall(VirtualUser.ClickButton2, VirtualUser, Vector2.new())
			if okCapture and okClick then return end
		end
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
function Core.TogglePingFPS(value)
    State.pingFpsEnabled = value and true or false
    if value then
        if not MovementState.pingFpsThread then
            MovementState.pingFpsThread = task.spawn(function()
                -- Espera 1 segundo antes do primeiro tick
                task.wait(1)
                while State.pingFpsEnabled and not Library.Unloaded do
                    if ButtonState.UI_PingLabel then
                        local pingStr = "?"
                        pcall(function()
                            local stats = game:GetService("Stats")
                            pingStr = math.floor(stats.Network.ServerStatsItem["Data Ping"]:GetValue())
                        end)

                        local fpsStr = "?"
                        pcall(function()
                            fpsStr = math.floor(workspace:GetRealPhysicsFPS())
                        end)

                        pcall(function()
                            ButtonState.UI_PingLabel:SetText("Ping: " .. pingStr .. "ms | FPS: " .. fpsStr)
                        end)
                    end
                    task.wait(1) -- Atualiza apenas 1 vez por segundo (zero lag)
                end
                MovementState.pingFpsThread = nil
                if ButtonState.UI_PingLabel and not Library.Unloaded then
                    ButtonState.UI_PingLabel:SetText("Ping: -- | FPS: --")
                end
            end)
        end
    else
        -- O while vai quebrar sozinho na próxima iteração
    end
end
function Core.ToggleAutoReceive(value)
	State.autoReceiveEnabled = value and true or false
end
function Core.SetReceiveRange(value)
	Receive.range = value
end
function Core.SetReceiveLead(value)
	Receive.lead = value
end
function Core.ToggleKisukiDive(value)
	Kisuki.enabled = value and true or false
	if value then Kisuki.install() end
end
function Core.SetKisukiCharge(value)
	Kisuki.charge = value
end
function Core.ToggleAkariDash(value)
	State.akariDashEnabled = value and true or false
	if ButtonState.dashButton then ButtonState.dashButton.Visible = value end
end
function Core.FireAkariDash()
	akariDash()
end
function Core.ToggleLeadFeet(value)
	State.leadFeetEnabled = value and true or false
	if ButtonState.leadFeetButton then ButtonState.leadFeetButton.Visible = value end
end
function Core.FireLeadFeet()
	leadFeetSlam()
end
function Core.ToggleMaxServe(value)
	if value then enableMaxServe() else disableMaxServe() end
end
function Core.ToggleJumpESP(value)
	State.espJumpEnabled = value and true or false
	if not value then
		for player in pairs(VisualState.espHighlights) do
			removeESP(player)
		end
	end
end

-- Character
function Core.SetDiveSpeed(value)
	local num = tonumber(value)
	if num then LocalPlayer:SetAttribute("Multiplier_DiveSpeed", num) end
end
function Core.SetJumpPower(value)
	local num = tonumber(value)
	if num then LocalPlayer:SetAttribute("Multiplier_JumpPower", num) end
end
function Core.SetSpeed(value)
	local num = tonumber(value)
	if num then LocalPlayer:SetAttribute("Multiplier_Speed", num) end
end
function Core.ToggleAirMovement(value)
	State.airMovement = value and true or false
	if not value and MovementState.bodyVelocity then
		MovementState.bodyVelocity:Destroy()
		MovementState.bodyVelocity = nil
	end
end
function Core.SetAirSpeed(value)
	State.airMovementSpeed = value
end
function Core.ToggleAutoShiftLock(value)
	toggleShiftLock(value)
end
function Core.ToggleCharacterLines(value)
	VisualState.linesEnabled = value and true or false
	if not value then
		for player in pairs(VisualState.lines) do removeLine(player) end
	end
end
function Core.SetLineDistance(value)
	State.lineDistance = value
end

-- Visuals
function Core.ToggleLandingMarker(value)
	Landing.enabled = value and true or false
	if not value then Landing.clear() end
end
function Core.ToggleScoreEffect(value)
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
function Core.ApplyScoreEffect()
	if VisualApply and VisualApply.score then VisualApply.score() end
end
function Core.ToggleProtect(value)
	toggleProtection(value)
end
function Core.ToggleTshAnimation(value)
	State.tshAnimationEnabled = value and true or false
end
function Core.ToggleHidariAnimation(value)
	State.hidariAnimationEnabled = value and true or false
end
function Core.ToggleKazanaBlue(value)
	State.kazanaBlueEnabled = value and true or false
end
function Core.ToggleKazanaWhite(value)
	State.kazanaWhiteEnabled = value and true or false
end
function Core.ApplyPlayerCard()
	if VisualApply and VisualApply.card then VisualApply.card() end
end
function Core.ResetPlayerCard()
	CardState.playerCardEnabled = false
	Vault.mark("PlayerCard", false)
	if Vault.realEquipped and Vault.realEquipped.PlayerCard then
		Vault.setSlot("PlayerCard", Vault.realEquipped.PlayerCard)
	end
	Core.Notify("Player card reset")
end
function Core.ToggleCardProtect(value)
	CardProtect.set(value)
	if value and not Library.Unloaded then
		CardProtect.forceApply()
	end
end
function Core.ApplyBall()
	if VisualApply and VisualApply.ball then VisualApply.ball() end
end
function Core.RemoveBallSkin()
	State.autoApplyBallSkin = false
	Vault.mark("Ball", false)
	task.spawn(safeSweep)
	Core.Notify("Ball skin removed")
end
function Core.ApplyJersey()
	if VisualApply and VisualApply.jersey then VisualApply.jersey() end
end
function Core.ToggleAutoApplyJersey(value)
	State.autoApplyJersey = value and true or false
	applyJersey(State.selectedJersey)
end
function Core.ToggleTitleChanger(value)
	Vault.mark("Title", value and true or false)
end

function Core.ToggleCrosshair(value)
    State.crosshairEnabled = value and true or false
    Core.Crosshair.Frame.Visible = State.crosshairEnabled
end

function Core.ToggleSpikeTrajectory(value)
    State.spikeTrajectoryEnabled = value and true or false
    if not value and TrajectoryState.trajectoryBeam then
        TrajectoryState.trajectoryBeam.Enabled = false
        if TrajectoryState.trajectoryPart then TrajectoryState.trajectoryPart.Transparency = 1 end
    end
end

function Core.SetCrosshairSize(value)
    State.crosshairSize = value
    Core.Crosshair.Update()
end

function Core.SetCrosshairColor(value)
    local colors = {
        White = Color3.fromRGB(255, 255, 255),
        Red = Color3.fromRGB(255, 60, 60),
        Green = Color3.fromRGB(60, 255, 60),
        Blue = Color3.fromRGB(60, 150, 255),
        Pink = Color3.fromRGB(255, 105, 180),
        Yellow = Color3.fromRGB(255, 255, 0),
        Purple = Color3.fromRGB(180, 60, 255)
    }
    State.crosshairColor = colors[value] or Color3.fromRGB(255, 255, 255)
    Core.Crosshair.Update()
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

function Core.SelectJersey(value)
	State.selectedJersey = value
	CardState.pickedTeam = nil
	if State.autoApplyJersey then
		applyJersey(State.selectedJersey)
	end
end

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

UI.LeftGroupBox:AddDropdown("autocornerreach", {
    Values = {"All", "Back", "Nearest"},
    Default = "All",
    Text = "Corner Depth",
    Callback = function(Value)
        Core.SetAutoCornerReach(Value)
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
        HitboxState.hitboxColor = colors[Value] or Color3.fromRGB(0, 0, 255)
        HitboxState.hitboxTransparency = transparencies[Value] or 0.3
        if HitboxState.hitboxEnabled then
            updateHitboxes(HitboxState.hitboxScale)
        end
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

UI.PerfGroup:AddToggle("fpsunlock", {
    Text = "FPS Unlocker",
    Tooltip = "Desbloqueia o limite de FPS do jogo para 120",
    Default = false,
    Callback = function(Value)
        Core.ToggleFPSUnlock(Value)
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
        State.airMovement = Value
        if not Value and MovementState.bodyVelocity then
            MovementState.bodyVelocity:Destroy()
            MovementState.bodyVelocity = nil
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
        VisualState.linesEnabled = Value
        if not Value then
            for player in pairs(VisualState.lines) do
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
        Core.ToggleLandingMarker(Value)
    end,
})

Tabs.Visuals:AddRightGroupbox("Ball Prediction", "target"):AddToggle("spiketrajectory", {
    Text = "Spike Trajectory",
    Tooltip = "Mostra uma linha vermelha da bola até o ponto de queda",
    Default = false,
    Callback = function(Value)
        Core.ToggleSpikeTrajectory(Value)
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
            -- Fix 6: solta os listeners do workspace/remote para nao ficarem ativos com o efeito off.
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

UI.PlayerCardGroup:AddButton({
    Text = "Reset Card",
    Func = function()
        CardState.playerCardEnabled = false
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
        Core.ToggleCardProtect(Value)
    end,
})

UI.CrosshairGroup = Tabs.Visuals:AddRightGroupbox("Crosshair", "crosshair")

UI.CrosshairGroup:AddToggle("crosshairtoggle", {
    Text = "Enable Crosshair",
    Tooltip = "Mostra uma mira no centro da tela",
    Default = false,
    Callback = function(Value)
        Core.ToggleCrosshair(Value)
    end,
})

UI.CrosshairGroup:AddSlider("crosshairsize", {
    Text = "Crosshair Size",
    Default = 6,
    Min = 2,
    Max = 20,
    Rounding = 0,
    Callback = function(Value)
        Core.SetCrosshairSize(Value)
    end,
})

UI.CrosshairGroup:AddDropdown("crosshaircolor", {
    Values = {"White", "Red", "Green", "Blue", "Pink", "Yellow", "Purple"},
    Default = "White",
    Text = "Color",
    Callback = function(Value)
        Core.SetCrosshairColor(Value)
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
    if Inj.stateCon then
        pcall(function()
            Inj.stateCon:Disconnect()
        end)
        Inj.stateCon = nil
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

    if Inj.stateCon then
        pcall(function() Inj.stateCon:Disconnect() end)
        Inj.stateCon = nil
    end
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

    if hum and hum.FloorMaterial == Enum.Material.Air then
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

    local humState = (hum and hum.Parent == char) and hum or (char and char:FindFirstChildOfClass("Humanoid"))
    if humState then
        if Inj.stateCon then pcall(function() Inj.stateCon:Disconnect() end) end
        Inj.stateCon = humState.StateChanged:Connect(function(_, newState)
            if newState == Enum.HumanoidStateType.Jumping
                or newState == Enum.HumanoidStateType.Freefall then
                pcall(function() trackObj:Stop(0.1) end)
                if Inj.playing == trackObj then
                    Inj.playing = nil
                    Inj.clearProp()
                end
            end
        end)
    end

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

UI.UtilityGroup = Tabs.Misc:AddLeftGroupbox("Utility", "shield-check")

UI.UtilityGroup:AddToggle("antiafk", {
    Text = "Anti-AFK",
    Tooltip = "Prevents the game from kicking you for inactivity",
    Default = true,
    Callback = function(Value)
        Core.ToggleAntiAFK(Value)
    end,
})

UI.UtilityGroup:AddToggle("autorejoin", {
    Text = "Auto Rejoin",
    Tooltip = "Rejoins the game automatically if you get kicked",
    Default = false,
    Callback = function(Value)
        Core.ToggleAutoRejoin(Value)
    end,
})

UI.UtilityGroup:AddToggle("autoready", {
    Text = "Auto Ready",
    Tooltip = "Clica automaticamente no botão de Ready/Aceitar entre as partidas",
    Default = false,
    Callback = function(Value)
        Core.ToggleAutoReady(Value)
    end,
})

local infoGroup = Tabs.Misc:AddRightGroupbox("Info", "activity")

ButtonState.UI_PingLabel = infoGroup:AddLabel("Ping: -- | FPS: --", true)

infoGroup:AddToggle("pingfps", {
    Text = "Show Ping / FPS",
    Tooltip = "Displays network ping and FPS (updates 1s)",
    Default = false,
    Callback = function(Value)
        Core.TogglePingFPS(Value)
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
    pcall(disableAutoBlock)
    pcall(function() Core.Crosshair.Gui:Destroy() end)
    if TrajectoryState.trajectoryBeam then TrajectoryState.trajectoryBeam:Destroy() end
    if TrajectoryState.trajectoryPart then TrajectoryState.trajectoryPart:Destroy() end
    pcall(UI.EmoteInject.clearProp)
    if ButtonState.leadFeetLink then pcall(function() ButtonState.leadFeetLink:Disconnect() end) end
    -- autoApplyBallSkin off para o sweep so remover as skins (sem reaplicar).
    State.autoApplyBallSkin = false
    if CardState.sweepBusy == false then pcall(task.spawn, safeSweep) end
end

function Core.ToggleAutoSave(value)
    State.autoSaveEnabled = value and true or false
    if value and not State.autoSaveRunning then
        State.autoSaveRunning = true
        task.spawn(function()
            while State.autoSaveEnabled and not Library.Unloaded do
                task.wait(3) -- Checa a cada 3 segundos
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
            State.autoSaveRunning = false
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
