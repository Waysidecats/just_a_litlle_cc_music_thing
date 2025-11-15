local dfpwm = require("cc.audio.dfpwm")
local speakers = { peripheral.find("speaker") }
local drive = peripheral.find("drive")
local decoder = dfpwm.make_decoder()

local menu = require "menu"

local uri = nil
local volume = settings.get("media_center.volume")
local selectedSong = nil

if drive == nil or not drive.isDiskPresent() then
	local savedSongs = fs.list("songs/")

	if #savedSongs == 0 then
		error("ERR - No disk was found in the drive, or no drive was found. No sound files were found saved to device.")
	else
		local entries = {
			[1] = {
				label = "[CANCEL]",
				callback = function()
					error()
				end
			}
		}

		for i, fp in ipairs(savedSongs) do
			table.insert(entries, {
				label = fp:match("^([^.]+)"),
				callback = function()
					selectedSong = fp
					menu.exit()
				end
			})
		end

		menu.init({
			main = {
				entries = entries
			}
		})

		menu.thread()

		if selectedSong ~= nil then
			local fp = "songs/" .. selectedSong

			if fs.exists(fp) then
				local file = fs.open(fp, "r")
				uri = file.readAll()
				file.close()
			else
				print("Song was not found on device!")
				return
			end
		else error() end
	end
else
	local songFile = fs.open("disk/song.txt", "r")
	uri = songFile.readAll()
	songFile.close()
end

if uri == nil or not uri:find("^https") then
	print("ERR - Invalid URI!")
	return
end

-- ===== STAGGERED PLAYBACK SETTINGS =====
local STAGGER_COUNT = 20
local staggerDelay = 1 / STAGGER_COUNT -- 20 phases per second
local speakersPerPhase = math.ceil(#speakers / STAGGER_COUNT)
local bufferQueue = {} -- triple buffer

-- staggered playChunk function
function playChunk(chunk)
	-- enqueue for triple buffering
	table.insert(bufferQueue, chunk)
	if #bufferQueue > 3 then
		table.remove(bufferQueue, 1)
	end

	local oldestChunk = bufferQueue[1]
	if not oldestChunk then return end

	local callbacks = {}

	for phase = 1, STAGGER_COUNT do
		local startIndex = (phase-1)*speakersPerPhase + 1
		local endIndex = math.min(phase*speakersPerPhase, #speakers)
		local phaseSpeakers = {}
		for i = startIndex, endIndex do
			table.insert(phaseSpeakers, speakers[i])
		end

		table.insert(callbacks, function()
			for _, speaker in ipairs(phaseSpeakers) do
				while not speaker.playAudio(oldestChunk, volume or 1.0) do
					os.pullEvent("speaker_audio_empty")
				end
			end
		end)

		-- stagger delay between phases
		table.insert(callbacks, function() sleep(staggerDelay) end)
	end

	parallel.waitForAll(table.unpack(callbacks))
	table.remove(bufferQueue, 1)
	return true
end

print("Playing '" .. (drive and drive.getDiskLabel() or selectedSong) .. "' at volume " .. (volume or 1.0))

local quit = false

-- modified play function to keep original behavior
function play()
	while true do
		local response = http.get(uri, nil, true)
		if not response then
			print("ERR - Failed to fetch URI")
			return
		end

		local chunkSize = 4 * 1024
		local chunk = response.read(chunkSize)
		while chunk ~= nil do
			local buffer = decoder(chunk)

			while not playChunk(buffer) do
				os.pullEvent("speaker_audio_empty")
			end

			chunk = response.read(chunkSize)
		end
	end
end

-- user input remains unchanged
function readUserInput()
	local commands = {
		["stop"] = function()
			quit = true
		end
	}

	while true do
		local input = string.lower(read())
		local commandName = ""
		local cmdargs = {}

		local i = 1
		for word in input:gmatch("%w+") do
			if i > 1 then
				table.insert(cmdargs, word)
			else
				commandName = word
			end
		end

		local command = commands[commandName]

		if command ~= nil then
			command(table.unpack(cmdargs))
		else print('"' .. cmdargs[1] .. '" is not a valid command!') end
	end
end

function waitForQuit()
	while not quit do
		sleep(0.1)
	end
end

parallel.waitForAny(play, readUserInput, waitForQuit)
