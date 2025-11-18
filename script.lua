local dfpwm = require("cc.audio.dfpwm")
local speakersTemp = { peripheral.find("speaker") }
local speakers = {}
local drive = peripheral.find("drive")
local decoder = dfpwm.make_decoder()
local time = os.epoch("utc")
local timeStorage = 0
local menu = require "menu"
local bigBuffer = {}
local bigChunk
local response
local chunk;
local uri = nil
local volume = settings.get("media_center.volume")
local selectedSong = nil

for i = 1, 10 do
    speakers[i] = {}
end

for i = 1, 20 do
    bigBuffer[i] = ""
end

for i = 1, #speakerstemp do
    local t = ((i - 1) % 10) + 1
    table.insert(speakers[t], speakerstemp[i])
end

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

function playChunk(chunk, batch)
	local returnValue = nil
	local callbacks = {}

	for i, speaker in pairs(speakers[batch]) do
		if i > 1 then
			table.insert(callbacks, function()
				speaker.playAudio(chunk, volume or 1.0)
			end)
		else
			table.insert(callbacks, function()
				returnValue = speaker.playAudio(chunk, volume or 1.0)
			end)
		end
	end

	parallel.waitForAll(table.unpack(callbacks))

	return returnValue
end

print("Playing '" .. "' at volume " .. (volume or 1.0))

local quit = false

function play()
	while true do
    if timeStorage ~= math.floor(time) then
        timeStorage = math.floor(time)
        if bigChunk ~= nil then
            playChunk(bigChunk, timeStorage%10+1)
        end
        getChunk()
        local t = {}
        for i = 1, 10 do
            t[i] = bigBuffer[i] or ""
        end
        bigChunk = table.concat(t)
	end
end

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

function getChunk() 
    if response == nil then
        response = http.get(uri, nil, true)
    end

	local chunkSize = 4800
    if chunk == nil then
	    chunk = response.read(chunkSize)
    end
	local buffer = decoder(chunk)
    for i = 20, 2, -1 do
        bigBuffer[i] = bigBuffer[i-1]
    end
    bigBuffer[20] = buffer
	chunk = response.read(chunkSize)

    if chunk == nil then
        response.close()
        response = http.get(uri, nil, true)
        chunk = response.read(chunkSize)
    end
end

function timekeep()
    while true do
        time = os.epoch("utc")/100
        sleep(0.01)
    end
end
parallel.waitForAny(play, readUserInput, waitForQuit, timekeep)
