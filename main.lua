PD2MusicImporter = PD2MusicImporter or {}

local Mod = PD2MusicImporter
local MENU_ID = "pd2_music_importer_menu"
local MOD_TAG = "PD2MusicImporter"
local IPC_ROOT = ModPath .. "ipc/"
local REQUEST_DIR = IPC_ROOT .. "requests/"
local STATUS_DIR = IPC_ROOT .. "status/"
local LATEST_STATUS = STATUS_DIR .. "latest.json"
local HELPER_STATUS = STATUS_DIR .. "helper.json"

local function read_json(path)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end

	local contents = file:read("*a")
	file:close()

	if not contents or contents == "" then
		return nil
	end

	local ok, decoded = pcall(json.decode, contents)
	if ok and type(decoded) == "table" then
		return decoded
	end

	return nil
end

local function write_json_atomic(path, value)
	local ok, encoded = pcall(json.encode, value)
	if not ok or type(encoded) ~= "string" then
		return false
	end

	local suffix = tostring(os.time()) .. tostring(math.random(100000, 999999))
	local temporary_path = path .. "." .. suffix .. ".tmp"
	local file = io.open(temporary_path, "wb")
	if not file then
		return false
	end

	local write_ok = file:write(encoded)
	file:flush()
	file:close()
	if not write_ok then
		os.remove(temporary_path)
		return false
	end

	-- Lua's Windows os.rename does not consistently replace an existing file.
	os.remove(path)
	local renamed = os.rename(temporary_path, path)
	if not renamed then
		os.remove(temporary_path)
		return false
	end

	return true
end

local function show_message(title, message)
	if QuickMenu and QuickMenu.new then
		QuickMenu:new(title, message, {
			{
				text = managers.localization:text("menu_ok"),
				is_cancel_button = true
			}
		}, MOD_TAG):Show()
		return
	end

	log("[" .. MOD_TAG .. "] " .. tostring(title) .. ": " .. tostring(message))
end

local function trim(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local sequence = 0
local function make_request_id()
	sequence = sequence + 1
	return string.format("%d_%d_%06x", os.time(), sequence, math.random(0, 0xFFFFFF))
end

local function queue_request(url, name)
	url = trim(url)
	name = trim(name)

	if url == "" or not url:match("^https?://") then
		show_message("Invalid YouTube link", "Paste a full YouTube URL, then choose Queue download.")
		return
	end

	if name == "" then
		show_message("Track name needed", "Enter a name for this menu music track first.")
		return
	end

	if #name > 100 then
		show_message("Track name too long", "Keep the track name to 100 characters or fewer.")
		return
	end

	local id = make_request_id()
	local request = {
		id = id,
		url = url,
		name = name,
		createdEpoch = os.time()
	}
	local request_path = REQUEST_DIR .. id .. ".json"

	if not write_json_atomic(request_path, request) then
		show_message("Could not queue download", "The mod could not write its request file. Check that the mod folder is writable.")
		return
	end

	write_json_atomic(LATEST_STATUS, {
		id = id,
		name = name,
		state = "queued",
		percent = 0,
		message = "Queued. Start the PowerShell helper if it is not already running.",
		updatedEpoch = os.time()
	})

	show_message("Download queued", "The PowerShell helper will download and install this track. Use Importer status to check progress.")
end

local function open_youtube_picker()
	local id = make_request_id()
	local request = {
		id = id,
		action = "open_picker",
		name = "YouTube picker",
		createdEpoch = os.time()
	}

	if not write_json_atomic(REQUEST_DIR .. id .. ".json", request) then
		show_message("Could not open YouTube picker", "The mod could not write its request file. Check that the mod folder is writable.")
		return
	end

	write_json_atomic(LATEST_STATUS, {
		id = id,
		name = request.name,
		state = "queued",
		percent = 0,
		message = "The PowerShell helper will open standalone Chromium on YouTube.",
		updatedEpoch = os.time()
	})
	show_message("Opening YouTube picker", "Choose a video in Chromium. The importer will download it, then return YouTube to its home page.")
end

local function request_game_restart()
	local id = make_request_id()
	local request = {
		id = id,
		action = "restart_game",
		name = "Restart PAYDAY 2",
		createdEpoch = os.time()
	}

	if not write_json_atomic(REQUEST_DIR .. id .. ".json", request) then
		show_message("Could not restart PAYDAY 2", "The mod could not write its request file. Check that the mod folder is writable and the PowerShell helper is running.")
		return
	end

	write_json_atomic(LATEST_STATUS, {
		id = id,
		name = request.name,
		state = "queued",
		percent = 0,
		message = "The helper will close the game, wait 5 seconds, then relaunch it through Steam.",
		updatedEpoch = os.time()
	})
	show_message("Restart requested", "The PowerShell helper will close PAYDAY 2, wait 5 seconds, then relaunch it through Steam. Save any active progress first.")
end

local function status_text()
	local status = read_json(LATEST_STATUS)
	local helper = read_json(HELPER_STATUS)
	local picker = read_json(STATUS_DIR .. "picker.json")
	local now = os.time()
	local helper_is_running = helper and tonumber(helper.updatedEpoch) and (now - tonumber(helper.updatedEpoch) <= 300)
	local lines = {}

	if helper_is_running then
		table.insert(lines, "PowerShell helper: running")
	else
		table.insert(lines, "PowerShell helper: not detected")
	end
	if helper and helper.state == "error" then
		table.insert(lines, "Helper message: " .. tostring(helper.message or "unknown error"))
	end
	if picker and picker.state == "error" then
		table.insert(lines, "Chromium extension: " .. tostring(picker.message or "error"))
	elseif picker and picker.state == "ready" then
		table.insert(lines, "Chromium extension: ready")
	end

	if status then
		table.insert(lines, "")
		table.insert(lines, "Track: " .. tostring(status.name or status.id or "(unknown)"))
		table.insert(lines, "Status: " .. tostring(status.state or "unknown"))
		if tonumber(status.percent) then
			table.insert(lines, "Progress: " .. tostring(status.percent) .. "%")
		end
		table.insert(lines, tostring(status.message or ""))
	else
		table.insert(lines, "")
		table.insert(lines, "No download status is available yet.")
	end

	return table.concat(lines, "\n")
end

local function load_inline_input()
	local ok, input = pcall(dofile, ModPath .. "lib/InlineInput/require.lua")
	if not ok or type(input) ~= "table" then
		input = rawget(_G, "InlineInput")
	end

	if type(input) == "table" and type(input.RegisterInput) == "function" then
		return input
	end

	local load_ok, loaded = pcall(dofile, ModPath .. "lib/InlineInput/inlineinput.lua")
	if load_ok and type(loaded) == "table" then
		input = loaded
	else
		input = rawget(_G, "InlineInput")
	end

	if type(input) == "table" and type(input.RegisterInput) == "function" then
		return input
	end

	local reason = not ok and input or (not load_ok and loaded) or "InlineInput.RegisterInput is unavailable"
	log("[" .. MOD_TAG .. "] Could not load bundled InlineInput: " .. tostring(reason))
	return nil
end

local InlineInput = load_inline_input()
if not InlineInput then
	return
end

local saved_values = read_json(IPC_ROOT .. "inputs.json") or {}
Mod.url = tostring(saved_values.url or "")
Mod.track_name = tostring(saved_values.trackName or "")

local function save_inputs()
	write_json_atomic(IPC_ROOT .. "inputs.json", {
		url = Mod.url,
		trackName = Mod.track_name
	})
end

local url_input = InlineInput:RegisterInput({
	id = "pd2_music_importer:url",
	menu_id = MENU_ID,
	item_id = "pd2_music_importer_url",
	title = "YouTube URL (click and Ctrl+V to paste)",
	desc = "Paste a public YouTube video link.",
	localized = false,
	priority = 10,
	placeholder = "https://www.youtube.com/watch?v=...",
	max_length = 512,
	get_value = function()
		return Mod.url
	end,
	set_value = function(value)
		Mod.url = value
	end,
	on_submit = function(value)
		Mod.url = value
		save_inputs()
	end
})

local name_input = InlineInput:RegisterInput({
	id = "pd2_music_importer:name",
	menu_id = MENU_ID,
	item_id = "pd2_music_importer_name",
	title = "Track name (click to edit)",
	desc = "This name appears in the music list.",
	localized = false,
	priority = 20,
	placeholder = "My Menu Track",
	max_length = 100,
	get_value = function()
		return Mod.track_name
	end,
	set_value = function(value)
		Mod.track_name = value
	end,
	on_submit = function(value)
		Mod.track_name = value
		save_inputs()
	end
})

Hooks:Add("MenuManagerSetupCustomMenus", MOD_TAG .. "_setup_menu", function()
	MenuHelper:NewMenu(MENU_ID)
end)

Hooks:Add("MenuManagerPopulateCustomMenus", MOD_TAG .. "_populate_menu", function()
	url_input:add_menu_item(MenuHelper, { priority = 10 })
	name_input:add_menu_item(MenuHelper, { priority = 20 })

	MenuHelper:AddButton({
		id = "pd2_music_importer_picker",
		title = "Open YouTube picker",
		desc = "Open standalone Chromium with the bundled picker extension to import YouTube videos automatically.",
		callback = "pd2_music_importer_picker",
		menu_id = MENU_ID,
		localized = false
	})

	MenuHelper:AddButton({
		id = "pd2_music_importer_queue",
		title = "Queue download",
		desc = "Download this YouTube track and create a menu music mod.",
		callback = "pd2_music_importer_queue",
		menu_id = MENU_ID,
		localized = false
	})

	MenuHelper:AddButton({
		id = "pd2_music_importer_status",
		title = "Importer status",
		desc = "Show helper and most recent request status.",
		callback = "pd2_music_importer_status",
		menu_id = MENU_ID,
		localized = false
	})

	MenuHelper:AddButton({
		id = "pd2_music_importer_restart",
		title = "Restart PAYDAY 2",
		desc = "Close the game, wait 5 seconds, then relaunch it through Steam. Save any active progress first.",
		callback = "pd2_music_importer_restart",
		menu_id = MENU_ID,
		localized = false
	})

	MenuCallbackHandler.pd2_music_importer_queue = function()
		queue_request(url_input:value(), name_input:value())
	end

	MenuCallbackHandler.pd2_music_importer_picker = function()
		open_youtube_picker()
	end

	MenuCallbackHandler.pd2_music_importer_status = function()
		show_message("Music importer status", status_text())
	end

	MenuCallbackHandler.pd2_music_importer_restart = function()
		request_game_restart()
	end
end)

Hooks:Add("MenuManagerBuildCustomMenus", MOD_TAG .. "_build_menu", function(_, nodes)
	nodes[MENU_ID] = MenuHelper:BuildMenu(MENU_ID)
	MenuHelper:AddMenuItem(nodes.options, MENU_ID, "PAYDAY 2 Music Importer", "Paste a YouTube link and create menu music.")
end)

log("[" .. MOD_TAG .. "] Loaded. Run Start-Helper.cmd before importing music.")
