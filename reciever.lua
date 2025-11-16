-- Libraries
local basalt = require("lib/basalt")
if not basalt then error("Basalt wasn't found") end

local v = require("/lib/semver")
if not v then error("semver wasn't found") end

local dfpwm = require("/lib/dfpwm")
if not dfpwm then error("dfpwm wasn't found") end

-- Options
local version = "1.0.0"
local repo = "https://raw.githubusercontent.com/JaredWogan/musicme/master/index.json"
local indexURL = repo .. "?cb=" .. os.epoch("utc")

-- Settings
local autoUpdates = settings.get("autoUpdates", true)
local bufferLength = settings.get("bufferLength", 16)
local clientVolume = settings.get("clientVolume", 1)
local serverVolume = settings.get("serverVolume", 0)

-- Channels
local controlChannel = settings.get("controlChannel", 2561)
local bufferChannel = settings.get("bufferChannel", controlChannel + 1)
local clientChannel = settings.get("clientChannel", controlChannel + 2)

-- Peripherals
local modem = peripheral.find("modem")
local speaker = peripheral.find("speaker")
local speakers = {peripheral.find("speaker")}
local monitor = peripheral.find("monitor")

-- Ensure there is a modem and speaker
if not modem then error("There needs to be a modem attached") end
if not speaker then error("There needs to be a speaker attached") end

-- HTTP Handle (Loads song library)
local handle, msgError = http.get(indexURL)
if not handle then error(msgError) end

local indexJSON = handle.readAll()
handle.close()

local index = textutils.unserialiseJSON(indexJSON)
if not index then error("The index is malformed.", 0) end


-- Check for updates
local function update()
    shell.run("wget run https://raw.githubusercontent.com/JaredWogan/musicme/master/install.lua")
end
if v(version) < v(index.latestVersion) and autoUpdates then
    error("Client outdated... Running Updates", 0)
    update()
end

-- musicme
local musicme = {}
local args = { ... }

local tableFind = function(table, value)
    local set = function(list)
        local s = {}
        for _, l in pairs(list) do s[l] = true end
        return s
    end
    return set(table)[value]
end

local awaitMessage = function(channel, replyChannel, command)
    local e, s, c, rc, msg, d = os.pullEvent("modem_message")
    if command == "any" then
        while c ~= channel and rc ~= replyChannel do
            e, s, c, rc, msg, d = os.pullEvent("modem_message")
        end
        return msg
    end
    if command and command ~= "any" then
        while c ~= channel and rc ~= replyChannel and msg.command ~= command do
            e, s, c, rc, msg, d = os.pullEvent("modem_message")
        end
        return msg
    end
    error("Invalid function arguments: <" .. tostring(channel) .. ", " .. tostring(replyChannel) .. ", " .. command .. ">")
end

function playBuffer(chunk, volume)
	local returnValue = nil
	local callbacks = {}

	for i, speak in pairs(speakers) do
		if i > 1 then
			table.insert(callbacks, function()
				speak.playAudio(chunk, volume or 1.0)
			end)
		else
			table.insert(callbacks, function()
				returnValue = speak.playAudio(chunk, volume or 1.0)
			end)
		end
	end

	parallel.waitForAll(table.unpack(callbacks))

	return returnValue
end

-- Run the speaker client
-- Run the speaker client
musicme.client = function(arguments)
    modem.open(bufferChannel)
    modem.open(clientChannel)

    -- Play buffer with proper sync for all speakers
    local function playBuffer(chunk, volume)
        local callbacks = {}
        for i, speak in ipairs(speakers) do
            table.insert(callbacks, function()
                while not speak.playAudio(chunk, volume or 1.0) do
                    os.pullEvent("speaker_audio_empty")
                end
            end)
        end
        parallel.waitForAll(table.unpack(callbacks))
    end

    -- Buffer playback loop
    local bufferPlayback = function()
        while true do
            local msg = awaitMessage(bufferChannel, controlChannel, "buffer")
            if msg.buffer then
                playBuffer(msg.buffer, 3000)
            end
        end
    end

    -- Receive other client messages
    local receiveMessage = function()
        while true do
            local msg = awaitMessage(clientChannel, controlChannel, "any")
            
            if msg.command == "start" then
                print("Starting playback...")
                os.sleep(2)
                shell.run("reboot")
            elseif msg.command == "buffer" then
                print("Received song buffer... playing")
            elseif msg.command == "pause" then
                if msg.pause then speaker.stop() end
                shell.run("reboot")
            elseif msg.command == "stop" then
                speaker.stop()
                shell.run("reboot")
            elseif msg.command == "volume" then
                print("Received volume command. Volume = " .. tostring(clientVolume) .. " -> " .. tostring(msg.volume))
                clientVolume = msg.volume
            end
        end
    end

    parallel.waitForAll(bufferPlayback, receiveMessage)
end

local getSongHandle = function(songID)
    if songID == nil then
        error("songID is nil")
    end
    if type(songID) == "table" then
        if string.find(songID.file, "flac") or string.find(songID.file, "wav") or string.find(songID.file, "mp3") or string.find(songID.file, "aac") or string.find(songID.file, "opus") or string.find(songID.file, "ogg") then
            songID.file = "https://cc.alexdevs.me/dfpwm?url=" .. textutils.urlEncode(songID.file)
        end
    end

    if type(songID) == "string" then
        local newSongID = {}
        newSongID.file = songID
        newSongID.name = songID
        if string.find(songID, "flac") or string.find(songID, "wav") or string.find(songID, "mp3") or string.find(songID, "aac") or string.find(songID, "opus") or string.find(songID, "ogg") then
            newSongID.file = "https://cc.alexdevs.me/dfpwm?url=" .. textutils.urlEncode(songID)
            newSongID.author = "URL (converting)"
        else
            newSongID.author = "URL"
        end
        songID = newSongID
    end

    local h, err = http.get({ ["url"] = songID.file, ["binary"] = true, ["redirect"] = true }) -- write in binary mode
    if not h then error("Failed to download song: " .. err) end

    return h
end

-- Control Server
musicme.gui = function(arguments)
    -- Set serverVolume if found
    if arguments[2] and tonumber(arguments[2]) then serverVolume = math.min(math.max(tonumber(arguments[2]), 0), 3) end

    -- Open modems
    modem.open(controlChannel)
    modem.open(clientChannel)
    -- Create GUI and decoder
    local main = basalt.createFrame()
    if not main then error("Failed to create basalt frame") end

    local playbackThread = main:addThread()
    local decoder = dfpwm.make_intdecoder()

    -- Variables
    local pause = false
    local playback = false
    local shuffle = false
    local selectedSong = nil
    local playingSong = nil

    -- Song list
    local list = main:addList()
        :setPosition(2, 2)
        :setSize("parent.w - 2", "parent.h - 6")
    for i, o in pairs(index.songs) do list:addItem(index.songs[i].author .. " - " .. index.songs[i].name) end

    -- Automatically update selectedSong song whenever screen is clicked
    main:onClick(function() selectedSong = index.songs[list:getItemIndex()] end)

    -- Current Track
    local currentlyPlaying = main:addLabel()
        :setPosition(29, "parent.h - 3")
        :setSize("parent.w - 42", 3)
        :setText("Now Playing: ")
    local updateTrack = function()
        if playingSong ~= nil and playback then
            local status = "Now Playing: "
            if pause then status = "Paused: " end
            currentlyPlaying:setText(status .. playingSong.author .. " - " .. playingSong.name)
        end
        if playingSong == nil or not playback then
            currentlyPlaying:setText("Now Playing: ")
        end
    end
    main:onEvent(updateTrack)

    -- Functions
    local setVolume = function()
        modem.transmit(clientChannel, controlChannel, {command="volume", volume=clientVolume})
    end
    local pausePlayback = function()
        pause = not pause
        modem.transmit(clientChannel, controlChannel, {command="pause", pause=pause})
    end
    local stopPlayback = function()
        modem.transmit(clientChannel, controlChannel, {command="stop", stop=true})
        playback = false
        playbackThread:stop()
    end
    local startPlayback = function()
        local broadcastSong = function(song)
            playingSong = selectedSong
            local songHandle = getSongHandle(song)
            while true do
                while pause do os.pullEvent() end

                -- Read next section of the song
                local chunk = songHandle.read(128 * bufferLength)

                -- If chunk is nil then song is finished
                if not chunk then break end

                -- Decode the chunk and play it
                local buffer = decoder(chunk)
                modem.transmit(bufferChannel, controlChannel, {command="buffer", buffer=buffer})
                playBuffer(buffer, serverVolume)
            end
            songHandle.close()
        end

        local broadcast = function()
            if not shuffle then broadcastSong(selectedSong) end
            if shuffle then
                local history = {}
                while shuffle do
                    if #history > math.floor(#(index.songs) / 2) then table.remove(history) end

                    local randomSong = math.random(1, #(index.songs))
                    while tableFind(history, randomSong) do
                        randomSong = math.random(1, #(index.songs))
                    end
                    table.insert(history, 1, randomSong)

                    list:selectItem(randomSong)
                    selectedSong = index.songs[randomSong]
                    broadcastSong(selectedSong)
                end
            end
        end

        playback = true
        setVolume()
        modem.transmit(clientChannel, controlChannel, {command="start", start=true})
        playbackThread:start(broadcast)
    end

    -- Play Button
    local playButton = main:addButton()
        :setPosition(2, "parent.h - 3")
        :setSize(6, 3)
        :setText("Play")
        :setHorizontalAlign("center")
        :setVerticalAlign("center")
        :setBackground(colors.lime)

    -- Pause Button
    local pauseButton = main:addButton()
        :setPosition(10, "parent.h - 3")
        :setSize(9, 3)
        :setText("Pause")
        :setHorizontalAlign("center")
        :setVerticalAlign("center")
        :setBackground(colors.orange)

    -- Stop Button
    local stopButton = main:addButton()
        :setPosition(21, "parent.h - 3")
        :setSize(6, 3)
        :setText("Stop")
        :setHorizontalAlign("center")
        :setVerticalAlign("center")
        :setBackground(colors.red)

    -- Shuffle Button
    local shuffleButton = main:addButton()
        :setPosition("parent.w - 9", "parent.h - 2")
        :setSize(4, 1)
        :setText("=>")
        :setHorizontalAlign("center")
        :setVerticalAlign("center")
        :setBackground(colors.red)

    -- Volume Up Button
    local volumeUpButton = main:addButton()
        :setPosition("parent.w - 3", "parent.h - 3")
        :setSize(3, 1)
        :setText("+")
        :setHorizontalAlign("center")
        :setVerticalAlign("center")

    -- Volume Down Button
    local volumeDownButton = main:addButton()
        :setPosition("parent.w - 3", "parent.h - 1")
        :setSize(3, 1)
        :setText("-")
        :setHorizontalAlign("center")
        :setVerticalAlign("center")

    local playOnClick = function()
        startPlayback()
        updateTrack()
        pauseButton:setText("Pause")
        pauseButton:setBackground(colors.orange)
    end
    playButton:onClick(playOnClick)

    local pauseOnClick = function()
        pausePlayback()
        if pause then
            pauseButton:setText("Unpause")
            pauseButton:setBackground(colors.green)
            updateTrack()
        end
        if not pause then
            pauseButton:setText("Pause")
            pauseButton:setBackground(colors.orange)
            updateTrack()
        end
    end
    pauseButton:onClick(pauseOnClick)

    local stopOnClick = function()
        stopPlayback()
        pause = false
        pauseButton:setText("Pause")
        pauseButton:setBackground(colors.orange)
        selectedSong = nil
        updateTrack()
    end
    stopButton:onClick(stopOnClick)

    local volumeUpOnClick = function()
        clientVolume = math.min(clientVolume + 0.1, 3)
        setVolume()
    end
    volumeUpButton:onClick(volumeUpOnClick)

    local volumeDownOnClick = function()
        clientVolume = math.max(clientVolume - 0.1, 0)
        setVolume()
    end
    volumeDownButton:onClick(volumeDownOnClick)

    local shuffleOnClick = function()
        shuffle = not shuffle
        if shuffle then
            shuffleButton:setBackground(colors.green)
        end
        if not shuffle then
            shuffleButton:setBackground(colors.red)
        end
    end
    shuffleButton:onClick(shuffleOnClick)

    basalt.autoUpdate()
end

musicme.help = function(arguments)
print([[
All computers running musicme must have a modem and speaker attached.
The GUI server computer defaults to being muted.
Currently the clients will reboot whenever the pause or stop buttons are hit.
Configuring auto startup is highly encouraged using 'musicme startup'.

Usage: <action> [arguments]
Actions:
musicme
    help                -- Displays this message
    gui <serverVolume>  -- Starts the GUI. Will automatically detect monitors.
    client              -- Runs the client.
    update              -- Updates musicme
    startup <arg>       -- Creates a startup file. Specify whether it is for 'client' or for 'gui'
]])
end

musicme.update = function(arguments)
    print("Updating Musicify, please hold on.")
    update()
end

musicme.monitor = function(arguments)
    if not monitor then print("A monitor must be attached") return end

    local scale = 0.5
    if arguments[1] then scale = arguments[1] end
    if not ((2 * scale) % 1) then scale = 0.5 end
    monitor.setTextScale(scale)

    if arguments[2] then serverVolume = arguments[2] end

    shell.run("monitor " .. peripheral.getName(monitor) .. " musicme gui monitor " .. tostring(serverVolume))
end

musicme.startup = function(arguments)
    local mode = table.remove(arguments, 1)
    print(mode)
    if mode ~= "client" and mode ~= "gui" then
        print("Must indicate whether startup file is for GUI or for client.")
        print("Use 'musicme help' for help")
        return
    end
    if fs.exists("startup.lua") then
        fs.move("startup.lua", "/old.musicme/startup.lua")
    end
    if mode == "client" then
        fs.copy("/lib/clientStartup.lua", "startup.lua")
    end
    if mode == "gui" then
        fs.copy("/lib/guiStartup.lua", "startup.lua")
    end
    print("startup.lua created successfully")
end

shell.run("clear")
local command = table.remove(args, 1)
if monitor and command == "gui" and args[1] ~= "monitor" then
    musicme["monitor"](args)
elseif musicme[command] then
    musicme[command](args)
else
    print("Please provide a valid command. For usage, use `musicime help`.")
end
