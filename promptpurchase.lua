
local cloneref = cloneref or function(x) return x end

local Players            = game:GetService("Players")
local StarterGui         = game:GetService("StarterGui")
local MarketplaceService = game:GetService("MarketplaceService")
local HttpService        = game:GetService("HttpService")
local CoreGui            = cloneref(game:GetService("CoreGui"))
local GuiService         = cloneref(game:GetService("GuiService"))
local VirtualInputManager = cloneref(game:GetService("VirtualInputManager"))

local LocalPlayer = Players.LocalPlayer

if type(getgenv().AutoRefundRuntime) == "table" and type(getgenv().AutoRefundRuntime.Destroy) == "function" then
	pcall(getgenv().AutoRefundRuntime.Destroy)
end

local Runtime = { alive = true, connections = {}, library = nil, gui = nil }

function Runtime.Destroy()
	Runtime.alive = false
	for _, conn in ipairs(Runtime.connections) do
		pcall(function() conn:Disconnect() end)
	end
	Runtime.connections = {}
	if Runtime.library and type(Runtime.library.Destroy) == "function" then
		pcall(Runtime.library.Destroy, Runtime.library)
	elseif Runtime.gui then
		pcall(function() Runtime.gui:Destroy() end)
	end
	Runtime.library = nil
	Runtime.gui = nil
end

getgenv().AutoRefundRuntime = Runtime

local function default(key, value)
	if _G[key] == nil then _G[key] = value end
end

default("AutoPurchase",         false)
default("AutoPurchaseFilter",   false)
default("AutoPurchaseFreeOnly", false)
default("AutoPurchaseId",       0)
default("AutoPurchaseStealth",  false)
_G.AutoRefundV2 = false
default("Webhook",              "")

local URL_WALLYLIB     = "https://raw.githubusercontent.com/phngkhaniuem/my-Ui-Library/refs/heads/main/wallylib.lua"
local URL_NOTIFICATION = "https://raw.githubusercontent.com/phngkhaniuem/my-Ui-Library/refs/heads/main/Notification.lua"

local KIND_COLORS = {
	info    = Color3.fromRGB(0, 170, 255),
	success = Color3.fromRGB(83, 230, 50),
	error   = Color3.fromRGB(255, 84, 84),
}

local SKIP_MESSAGES = {
	{ "You already own this item. Your account has not been charged.", "You already own this item", "Already Owned" },
	{ "Your purchase of {ITEM_NAME} failed because something went wrong. Your account has not been charged. Please try again later.", "Purchase failed", "Failed" },
	{ "This item is not currently for sale. Your account has not been charged.", "Item is not for sale", "Not For Sale" },
	{ "You have successfully bought {ITEM_NAME}.", "Purchase completed", "Success" },
}

local currentPromptId = nil
local promptPrices    = {}
local lastActionAt    = 0
local preferredMethod = { buy = 1, close = 1 }
local lastReport      = { key = nil, at = 0 }

local okNotif, Notification = pcall(function()
	return loadstring(game:HttpGet(URL_NOTIFICATION, true))()
end)
if not okNotif or type(Notification) ~= "table" then
	Notification = nil
end

local function notify(title, text, kind, duration, icon)
	local ok = Notification and pcall(function()
		Notification:Notify(
			{ Title = title, Description = text },
			{
				Type         = icon and "image" or "default",
				Time         = duration or 3,
				OutlineColor = KIND_COLORS[kind or "info"] or KIND_COLORS.info,
			},
			icon and { Image = icon, ImageColor = Color3.new(1, 1, 1) } or nil
		)
	end)
	if not ok then
		pcall(function()
			StarterGui:SetCore("SendNotification", {
				Title = title, Text = text, Duration = duration or 3,
			})
		end)
	end
end

local function parseItemId(text)
	text = tostring(text or "")
	local id = text:match("/catalog/(%d+)")
		or text:match("/bundles/(%d+)")
		or text:match("/library/(%d+)")
		or text:match("/item/(%d+)")
		or text:match("[?&]id=(%d+)")
		or text:match("%d+")
	return tonumber(id) or 0
end

local function cleanRichText(text)
	text = tostring(text or "")
	text = text:gsub("<font[^>]*>.-</font>", "R$")
	text = text:gsub("<[^>]+>", "")
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

if type(_G.AutoPurchaseId) == "string" then
	_G.AutoPurchaseId = parseItemId(_G.AutoPurchaseId)
end

local function getOverlayItemInfo()
	local overlay = CoreGui:FindFirstChild("FoundationOverlay")
	local safe    = overlay and overlay:FindFirstChild("SafeAreaFrame")
	if not safe then return nil end

	local nameLabel = safe:FindFirstChild("ItemName", true)
	local costLabel = safe:FindFirstChild("ItemCost", true)
	if not nameLabel and not costLabel then return nil end

	return {
		Name          = nameLabel and nameLabel.Text or "Unknown",
		Price         = costLabel and cleanRichText(costLabel.Text) or "?",
		Remaining     = "N/A",
		CollectibleId = "N/A",
		TotalQuantity = "N/A",
		IsForSale     = "Unknown",
	}
end

local function clickByCoordinates(btn)

	local posX = btn.AbsolutePosition.X + btn.AbsoluteSize.X / 2
	local posY = btn.AbsolutePosition.Y + btn.AbsoluteSize.Y / 2

	local sg = btn:FindFirstAncestorWhichIsA("ScreenGui")
	if not (sg and sg.IgnoreGuiInset) then
		posY = posY + GuiService:GetGuiInset().Y
	end

	local offset = _G.AutoPurchaseOffset
	if typeof(offset) == "Vector2" then
		posX, posY = posX + offset.X, posY + offset.Y
	end

	VirtualInputManager:SendMouseButtonEvent(posX, posY, 0, true, game, 1)
	VirtualInputManager:SendMouseButtonEvent(posX, posY, 0, false, game, 1)
end

local function clickBySignal(btn)
	local fired = false
	for _, name in ipairs({ "Activated", "MouseButton1Click" }) do
		if getconnections then
			local okC, conns = pcall(getconnections, btn[name])
			if okC and type(conns) == "table" then
				for _, c in ipairs(conns) do
					pcall(function()
						if c.Fire then c:Fire() elseif c.Function then c.Function() end
					end)
					fired = true
				end
			end
		end
	end
	if not fired and firesignal then
		pcall(firesignal, btn.Activated)
		pcall(firesignal, btn.MouseButton1Click)
		fired = true
	end
	return fired
end

local function clickBySelection(btn)
	local previous = GuiService.SelectedObject
	GuiService.SelectedObject = btn
	task.wait()
	VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Return, false, game)
	VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Return, false, game)
	task.wait()
	GuiService.SelectedObject = previous
end

local CLICK_METHODS = { clickBySignal, clickBySelection, clickByCoordinates }

local function isStillOpen(btn)
	return btn ~= nil
		and btn.Parent ~= nil
		and btn:IsDescendantOf(CoreGui)
		and btn.Visible
		and btn.AbsoluteSize.X > 0
end

local function clickButton(btn, key)
	local start = preferredMethod[key]
	for i = 0, #CLICK_METHODS - 1 do
		local idx = (start - 1 + i) % #CLICK_METHODS + 1
		pcall(CLICK_METHODS[idx], btn)
		task.wait(0.25)
		if not isStillOpen(btn) then
			preferredMethod[key] = idx
			return true
		end
	end
	return false
end

local function installStealthHooks()
	if getgenv().AutoRefundStealthHooked then return end
	getgenv().AutoRefundStealthHooked = true

	pcall(function()
		local mt = getrawmetatable(game)
		setreadonly(mt, false)
		local oldIndex, oldNamecall, oldToString = mt.__index, mt.__namecall, mt.__tostring

		mt.__index = function(self, key)
			if self == game and key == "VirtualInputManager" and not checkcaller() then return nil end
			local value = oldIndex(self, key)
			if type(value) == "function" then
				return function(obj, ...)
					local args = {...}
					if (key == "WaitForChild" or key == "FindFirstChild" or key == "FindFirstChildRecursive" or key == "FindFirstChildOfClass" or key == "FindFirstChildWhichIsA") and args[1] == "VirtualInputManager" and not checkcaller() then return nil end
					if key == "GetChildren" or key == "GetDescendants" then
						local tbl = value(obj, ...)
						local out = {}
						for i = 1, #tbl do
							local v = tbl[i]
							if not (typeof(v) == "Instance" and v.Name == "VirtualInputManager") or checkcaller() then out[#out + 1] = v end
						end
						return out
					end
					local result = value(obj, ...)
					if typeof(result) == "Instance" and result.Name == "VirtualInputManager" and not checkcaller() then return nil end
					return result
				end
			end
			if typeof(value) == "Instance" and value.Name == "VirtualInputManager" and not checkcaller() then return nil end
			return value
		end

		mt.__namecall = function(self, ...)
			local method = getnamecallmethod()
			local args = {...}
			if not checkcaller() then
				if self == game and method == "GetService" and args[1] == "VirtualInputManager" then return nil end
				if (method == "WaitForChild" or method == "FindFirstChild" or method == "FindFirstChildRecursive") and args[1] == "VirtualInputManager" then return nil end
			end
			local result = oldNamecall(self, ...)
			if typeof(result) == "Instance" and result.Name == "VirtualInputManager" and not checkcaller() then return nil end
			return result
		end

		mt.__tostring = function(self)
			if typeof(self) == "Instance" and self.Name == "VirtualInputManager" and not checkcaller() then return "Instance" end
			return oldToString(self)
		end

		local oldRawget
		oldRawget = hookfunction(rawget, function(t, k)
			if t == game and k == "VirtualInputManager" and not checkcaller() then return nil end
			return oldRawget(t, k)
		end)

		local oldRawequal
		oldRawequal = hookfunction(rawequal, function(a, b)
			if not checkcaller() and ((typeof(a) == "Instance" and a.Name == "VirtualInputManager") or (typeof(b) == "Instance" and b.Name == "VirtualInputManager")) then return false end
			return oldRawequal(a, b)
		end)

		setreadonly(mt, true)
	end)
end

local function findCloseButton(overlay)
	for _, d in ipairs(overlay:GetDescendants()) do
		if d.Name == "CloseAffordance" and d:IsA("GuiButton") and d.Visible and d.AbsoluteSize.X > 0 then
			return d
		end
	end
	return nil
end

local function getPromptPrice(overlay)

	local id = currentPromptId
	if id then
		local t = os.clock()
		while promptPrices[id] == nil and os.clock() - t < 0.5 do
			task.wait()
		end
		local price = promptPrices[id]
		if type(price) == "number" then return price end
	end

	local cost = overlay:FindFirstChild("ItemCost", true) or overlay:FindFirstChild("RobuxPrice", true)
	if cost and cost:IsA("TextLabel") then
		local text = cleanRichText(cost.Text)
		if string.find(string.lower(text), "free", 1, true) then return 0 end
		local digits = text:gsub("[^%d]", "")
		if digits ~= "" then return tonumber(digits) end
	end
	return nil
end

local function shouldBuy(overlay)

	if _G.AutoPurchaseFilter then
		local target = tonumber(_G.AutoPurchaseId) or 0
		if target ~= 0 then
			local t = os.clock()
			while currentPromptId == nil and os.clock() - t < 0.3 do
				task.wait()
			end
			if currentPromptId ~= target then
				return false, "ID " .. tostring(currentPromptId or "?") .. " does not match"
			end
		end
	end

	if _G.AutoPurchaseFreeOnly then
		local price = getPromptPrice(overlay)
		if price == nil then
			return false, "could not determine the price"
		elseif price ~= 0 then
			return false, "price is " .. tostring(price) .. " Robux"
		end
	end

	return true
end

local function closePrompt(overlay, reason)
	local target = findCloseButton(overlay)
	if not target then return end

	lastActionAt = os.clock()
	notify("Auto Purchase", "Skipped: " .. tostring(reason or "conditions not met"), "info", 2)
	clickButton(target, "close")
	lastActionAt = os.clock()
end

local Request = request or http_request or (syn and syn.request)

local function isHttpOk(res)
	local code = res and (res.StatusCode or res.Status)
	return code == 200 or code == 204
end

local function getJson(url)
	if not Request then return nil end
	local ok, res = pcall(Request, { Url = url, Method = "GET" })
	if not ok or not isHttpOk(res) then return nil end

	local decoded, data = pcall(HttpService.JSONDecode, HttpService, res.Body)
	return decoded and data or nil
end

local function formatStock(item)
	local left  = tonumber(item.unitsAvailableForConsumption)
	local total = tonumber(item.totalQuantity)
	if left and total then
		return ("%d / %d"):format(left, total)
	end
	return item.totalQuantity == nil and "∞" or "Unknown"
end

local function sendReport(messageText, itemName)
	local webhook = _G.Webhook
	if type(webhook) ~= "string" or webhook == "" or not Request then return end

	local id = currentPromptId
	if not id then
		local typed = tonumber(_G.AutoPurchaseId) or 0
		if typed ~= 0 then id = typed end
	end
	if not id then return end

	local statusText = (cleanRichText(messageText):gsub("%s+", " "))
	if statusText == "" then statusText = "Unknown" end

	local key = statusText .. ":" .. tostring(id)
	if lastReport.key == key and os.clock() - lastReport.at < 5 then return end
	lastReport.key, lastReport.at = key, os.clock()

	task.spawn(function()
		local item = getJson(("https://catalog.roblox.com/v1/catalog/items/%d/details?itemType=Asset"):format(id)) or {}
		local profile = getJson("https://users.roblox.com/v1/users/" .. LocalPlayer.UserId)
		local displayName = profile and profile.displayName or LocalPlayer.Name

		local thumb = getJson(
			("https://thumbnails.roblox.com/v1/assets?assetIds=%d&size=420x420&format=Png&isCircular=false"):format(id)
		)
		local imageUrl = thumb and thumb.data and thumb.data[1] and thumb.data[1].imageUrl

		local now = os.time()
		local embed = {
			title = "Report UGC Notification",
			description = ("||script make by pnka.309||"),
			color = 0xFFFFFF,
			fields = {
				{ name = "Account", value = ("||%s (@%s) | %d||"):format(displayName, LocalPlayer.Name, LocalPlayer.UserId) },
				{ name = "Item", value = ("[%s](https://www.roblox.com/catalog/%d)"):format((tostring(itemName or item.name or "Unknown"):gsub("[%[%]]", "")), id) },
				{ name = "Id",      value = tostring(id) },
				{ name = "Price",   value = (item.price and tostring(item.price) or "Unknown") .. " Robux" },
				{ name = "Status",  value = "||" .. statusText .. "||" },
				{ name = "Stock",   value = formatStock(item) },
				{ name = "Onsale",  value = item.isPurchasable == true and "Yes" or "No" },
				{ name = "\u{200B}", value = "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬" },
				{ name = "\u{200B}", value = ("<t:%d:D> | <t:%d:T>"):format(now, now) },
			},
			thumbnail = imageUrl and { url = imageUrl } or nil,
		}

		local ok, res = pcall(Request, {
			Url     = webhook,
			Method  = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body    = HttpService:JSONEncode({ username = "UGC Report", embeds = { embed } }),
		})

		local sent = ok and isHttpOk(res)
		notify("Webhook", sent and "Sent successfully" or "Sent failed", sent and "success" or "error", 2)
	end)
end

local function collapseSpaces(text)
	text = tostring(text or ""):gsub("%s+", " ")
	return (text:gsub("^ ", ""):gsub(" $", ""))
end

local function normalizeMessage(text)
	return string.lower(collapseSpaces(text))
end

local function compileMessage(sentence)
	local pattern = normalizeMessage(sentence)
	pattern = pattern:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
	pattern = pattern:gsub("{item_name}", "().+()")
	return "^" .. pattern .. "$"
end

for _, entry in ipairs(SKIP_MESSAGES) do
	entry.pattern = compileMessage(entry[1])
	entry.hasName = string.find(string.lower(entry[1]), "{item_name}", 1, true) ~= nil
end

local function matchSkipMessage(text)
	local collapsed = collapseSpaces(text)
	local lowered   = string.lower(collapsed)

	for _, entry in ipairs(SKIP_MESSAGES) do
		if entry.hasName then
			local from, to = string.match(lowered, entry.pattern)
			if from then
				return entry[2], entry[3], collapsed:sub(from, to - 1)
			end
		elseif string.find(lowered, entry.pattern) then
			return entry[2], entry[3], nil
		end
	end
	return nil
end

local function findSkipMessage(overlay)
	local msg = overlay:FindFirstChild("Message", true)
	if msg and msg:IsA("TextLabel") then
		local label, status, itemName = matchSkipMessage(msg.Text)
		if label then return label, status, msg.Text, itemName end
	end

	for _, d in ipairs(overlay:GetDescendants()) do
		if d:IsA("TextLabel") and d.Text ~= "" then
			local label, status, itemName = matchSkipMessage(d.Text)
			if label then return label, status, d.Text, itemName end
		end
	end
	return nil
end

local function handleSkipMessage(overlay)
	if os.clock() - lastActionAt < 0.5 then return false end

	local label, status, rawText, itemName = findSkipMessage(overlay)
	if not label then
		return false
	end

	local target = findCloseButton(overlay)
	if not target then
		for _, d in ipairs(overlay:GetDescendants()) do
			if d.Name == "1" and d.Parent and d.Parent.Name == "Actions" and d:IsA("GuiButton") then
				target = d
				break
			end
		end
	end

	if target then
		lastActionAt = os.clock()
		if status == "Success" then
			notify("Auto Purchase", label, "success", 2)
		else
			notify("Auto Purchase", "Skipped: " .. label, "info", 2)
		end
		sendReport(rawText, itemName)
		clickButton(target, "close")
		lastActionAt = os.clock()
	end
	return true
end

local function scanOverlay(overlay)
	if handleSkipMessage(overlay) then return end

	local elements = overlay:GetDescendants()
	for i = 1, #elements do
		if not Runtime.alive then return end
		local v = elements[i]
		if v.Parent then
			if v.Parent.Name == "1" and string.find(v.Name, "Buy") then

				if os.clock() - lastActionAt >= 0.5 then
					local lastPos = v.AbsolutePosition
					task.wait(0.05)
					if v.AbsolutePosition == lastPos and _G.AutoPurchase then
						local okBuy, reason = shouldBuy(overlay)
						if okBuy then
							clickButton(v, "buy")
						else
							closePrompt(overlay, reason)
						end
					end
				end

			elseif v.Parent.Name == "Actions" and v.Name == "1" then

				local isBuyBtn = false
				local children = v.Parent:GetDescendants()
				for j = 1, #children do
					local child = children[j]
					if child:IsA("TextLabel") and (string.find(child.Text, "Buy") or string.find(child.Text, "Price") or string.find(child.Text, "Robux")) then
						isBuyBtn = true
						break
					end
				end

				if not isBuyBtn then
					local lastPos = v.AbsolutePosition
					task.wait()
					if v.AbsolutePosition == lastPos and _G.AutoPurchase then
						clickButton(v, "buy")
					end
				end
			end
		end
	end
end

table.insert(Runtime.connections, MarketplaceService.PromptPurchaseRequestedV2:Connect(function(_, assetId)
	if not assetId or assetId == 0 then return end

	currentPromptId = assetId
	promptPrices[assetId] = nil

	local autoDecline = _G.AutoRefundV2 and not _G.AutoPurchase

	local okInfo, product = pcall(function()
		return MarketplaceService:GetProductInfo(assetId)
	end)

	promptPrices[assetId] = (okInfo and product and product.PriceInRobux) or false

	local info
	if okInfo and product then
		local details = product.CollectibleItemDetails
		local status
		if product.IsForSale == nil then
			status = "N/A"
		elseif product.IsForSale then
			status = "On Sale"
		else
			status = "Off Sale"
		end

		info = {
			Name          = product.Name or "Unknown",
			Price         = tostring(product.PriceInRobux or 0) .. " Robux",
			Remaining     = product.Remaining ~= nil and tostring(product.Remaining) or "N/A",
			TotalQuantity = details and details.TotalQuantity and tostring(details.TotalQuantity) or "N/A",
			IsForSale     = status,
		}
	else
		info = getOverlayItemInfo() or {
			Name          = "Unknown Item",
			Price         = "?",
			Remaining     = "?",
			TotalQuantity = "?",
			IsForSale     = "Unknown",
		}
	end

	notify(
		"Item Profile",
		string.format(
			"%s\n%s | %s\nLeft: %s / %s",
			info.Name, info.Price, info.IsForSale, info.Remaining, info.TotalQuantity
		),
		"info",
		10,
		"rbxthumb://type=Asset&id=" .. tostring(assetId) .. "&w=420&h=420"
	)

	if autoDecline then
		pcall(function()
			MarketplaceService:SignalPromptPurchaseFinished(LocalPlayer, assetId, false)
		end)
	end
end))

task.spawn(function()
	local lastState = _G.AutoPurchase and true or false

	while Runtime.alive do
		local state = _G.AutoPurchase and true or false

		if state ~= lastState then
			notify("Auto Purchase", state and "Enabled" or "Disabled", state and "success" or "info", 3)
			lastState = state
		end

		if state then
			if _G.AutoPurchaseStealth then installStealthHooks() end
			local overlay = CoreGui:FindFirstChild("FoundationOverlay")
			if overlay then
				pcall(scanOverlay, overlay)
			end
		end

		task.wait()
	end
end)

local function buildUI()
	local okLib, Library = pcall(function()
		return loadstring(game:HttpGet(URL_WALLYLIB, true))()
	end)
	if not okLib or type(Library) ~= "table" then
		notify("Load Error", "Failed to load UI library.", "error", 8)
		return
	end

	local win = Library:CreateWindow("universal v1")
	Runtime.library = Library
	Runtime.gui = win.object and win.object:FindFirstAncestorWhichIsA("ScreenGui") or nil

	local itemLabel
	local idBox

	local function setItemLabel(name, id, forSale, price, remaining, total)
		local saleText = "nil"
		if forSale == true then
			saleText = "Yes"
		elseif forSale == false then
			saleText = "No"
		end

		local nameText  = name  ~= nil and tostring(name)  or "nil"
		local idText    = id    ~= nil and tostring(id)    or "nil"
		local priceText = price ~= nil and tostring(price) or "nil"
		local stockText = "nil"
		if remaining ~= nil or total ~= nil then
			stockText = tostring(remaining ~= nil and remaining or "?") .. " / " .. tostring(total ~= nil and total or "?")
		end

		local text = "Name: " .. nameText
			.. "\nID: " .. idText
			.. "\nSale: " .. saleText
			.. "\nRobux: " .. priceText
			.. "\nStock: " .. stockText

		itemLabel:Set(text)

		task.delay(0.15, function() itemLabel:Set(text) end)
	end

	local function refreshItem()
		local id = tonumber(_G.AutoPurchaseId) or 0
		if id == 0 then
			setItemLabel(nil, nil, nil, nil, nil, nil)
			return
		end

		task.spawn(function()
			local okInfo, product = pcall(function()
				return MarketplaceService:GetProductInfo(id)
			end)

			if (tonumber(_G.AutoPurchaseId) or 0) ~= id then return end

			if okInfo and product then
				local details = product.CollectibleItemDetails
				setItemLabel(product.Name, id, product.IsForSale, product.PriceInRobux, product.Remaining, details and details.TotalQuantity)
			else
				setItemLabel(nil, nil, nil, nil, nil, nil)
			end
		end)
	end

	win:Section("Main")

	win:Toggle("Auto Refund", { default = false, flag = "AutoRefund" }, function(state)
		_G.AutoRefundV2 = state
		notify("Auto Refund", state and "Enabled - prompts will be declined" or "Disabled", state and "success" or "info", 3)
	end)

	win:Toggle("Auto Purchase", { default = _G.AutoPurchase == true, flag = "AutoPurchase" }, function(state)
		_G.AutoPurchase = state
	end)

	idBox = win:Box("Item ID", { flag = "AutoPurchaseIdBox" }, function(value)
		local id = parseItemId(value)
		_G.AutoPurchaseId = id
		idBox.Text = id ~= 0 and tostring(id) or ""
		refreshItem()
	end)
	if (tonumber(_G.AutoPurchaseId) or 0) ~= 0 then
		idBox.Text = tostring(_G.AutoPurchaseId)
	end

	itemLabel = win:Label("Name: nil\nID: nil\nSale: nil\nRobux: nil\nStock: nil", { wrap = true })
	refreshItem()

	win:Toggle("Only buy matching ID", { default = _G.AutoPurchaseFilter == true, flag = "AutoPurchaseFilter" }, function(state)
		_G.AutoPurchaseFilter = state
	end)

	win:Toggle("Only buy if price is 0 Robux", { default = _G.AutoPurchaseFreeOnly == true, flag = "AutoPurchaseFreeOnly" }, function(state)
		_G.AutoPurchaseFreeOnly = state
	end)

	win:Button("Destroy", function()
		_G.AutoPurchase = false
		_G.AutoRefundV2 = false
		notify("pnka", "Destroyed", "info", 2)
		Runtime.Destroy()
	end)

	win:Label("Credit: skid by pnka.309")
end

buildUI()

notify("universal v1", "script successfully loaded\nenjoy!", "info", 5)
