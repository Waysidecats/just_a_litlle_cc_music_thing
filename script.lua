-- Libraries
local basalt = require("lib/basalt")
if not basalt then error("Basalt wasn't found") end

local dfpwm = require("/lib/dfpwm")
if not dfpwm then error("dfpwm wasn't found") end

-- Options
local version = "1000.0.0"  -- prevents auto-update
local indexFile = "local_index.json"

-- Settings
local bufferLength = settings.get("bufferLength", 16)
local clientVolume = settings.get("clientVolume", 1)
local serverVolume = settings.get("serverVolume", 0)

-- Default Channels
local controlChannel = 2561
local bufferChannel = controlChannel + 1
local clientChannel = controlChannel + 2

-- Peripherals
local modem = peripheral.find("modem")
local speaker = peripheral.find("speaker")
local monitor = peripheral.find("monitor")

if not modem then error("There needs to be a modem attached") end
if not speaker then error("There needs to be a speaker attached") end

-- Load local index
local function loadIndex()
    if not fs.exists(indexFile) then
        local file = fs.open(indexFile, "w")
        local blankIndex = {
            latestVersion = "1000.0.0",
            indexName = "Local",
            songs = {}
        }
        file.write(textutils.serialiseJSON(blankIndex))
        file.close()
    end
    local file = fs.open(indexFile, "r")
    local content = file.readAll()
    file.close()
    local ok, data = pcall(textutils.unserialiseJSON, content)
    if not ok or not data then error("Malformed local index file") end
    return data
end

local index = loadIndex()

-- Helpers
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
    error("Invalid function arguments")
end

local playBuffer = function(buffer, volume)
    if not volume then volume = 1 end
    while not speaker.playAudio(buffer, volume) do os.pullEvent("speaker_audio_empty") end
end

-- musicme table
local musicme = {}
local args = { ... }

-- Client
musicme.client = function(arguments)
    local baseChannel = tonumber(arguments[1]) or 2561
    controlChannel = baseChannel
    bufferChannel = baseChannel + 1
    clientChannel = baseChannel + 2

    modem.open(bufferChannel)
    modem.open(clientChannel)

    local bufferPlayback = function()
        local msg
        while true do
            msg = awaitMessage(bufferChannel, controlChannel, "buffer")
            if msg.buffer then playBuffer(msg.buffer, clientVolume) end
        end
    end

    local receiveMessage = function()
        local msg
        while true do
            msg = awaitMessage(clientChannel, controlChannel, "any")
            if msg.command == "start" then
                os.sleep(2)
                shell.run("reboot")
            elseif msg.command == "pause" then
                if msg.pause then speaker.stop() end
                shell.run("reboot")
            elseif msg.command == "stop" then
                speaker.stop()
                shell.run("reboot")
            elseif msg.command == "volume" then
                clientVolume = msg.volume
            end
        end
    end

    parallel.waitForAll(bufferPlayback, receiveMessage)
end

-- Get song handle
local getSongHandle = function(songID)
    if type(songID) == "table" then
        songID.file = "https://cc.alexdevs.me/dfpwm?url=" .. textutils.urlEncode(songID.file)
    elseif type(songID) == "string" then
        local newSongID = {}
        newSongID.file = "https://cc.alexdevs.me/dfpwm?url=" .. textutils.urlEncode(songID)
        newSongID.name = songID
        newSongID.author = "URL"
        songID = newSongID
    end
    local h, err = http.get({ ["url"] = songID.file, ["binary"] = true, ["redirect"] = true })
    if not h then error("Failed to download song: " .. err) end
    return h
end

-- GUI server
musicme.gui = function(arguments)
    local baseChannel = tonumber(arguments[1]) or 2561
    controlChannel = baseChannel
    bufferChannel = baseChannel + 1
    clientChannel = baseChannel + 2

    if arguments[2] and tonumber(arguments[2]) then
        serverVolume = math.min(math.max(tonumber(arguments[2]), 0), 3)
    end

    modem.open(controlChannel)
    modem.open(clientChannel)

    local main = basalt.createFrame()
    if not main then error("Failed to create basalt frame") end

    local decoder = dfpwm.make_intdecoder()
    local pause, playback, shuffle = false, false, false
    local selectedSong, playingSong = nil, nil

    local list = main:addList()
        :setPosition(2, 2)
        :setSize("parent.w - 2", "parent.h - 6")
    for i, o in pairs(index.songs) do list:addItem(index.songs[i].author .. " - " .. index.songs[i].name) end

    main:onClick(function() selectedSong = index.songs[list:getItemIndex()] end)

    local currentlyPlaying = main:addLabel()
        :setPosition(29, "parent.h - 3")
        :setSize("parent.w - 42", 3)
        :setText("Now Playing: ")
    local updateTrack = function()
        if playingSong ~= nil and playback then
            local status = pause and "Paused: " or "Now Playing: "
            currentlyPlaying:setText(status .. playingSong.author .. " - " .. playingSong.name)
        else
            currentlyPlaying:setText("Now Playing: ")
        end
    end
    main:onEvent(updateTrack)

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
    end

    local startPlayback = function()
        local broadcastSong = function(song)
            playingSong = selectedSong
            local songHandle = getSongHandle(song)
            while true do
                while pause do os.pullEvent() end
                local chunk = songHandle.read(128 * bufferLength)
                if not chunk then break end
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
                    if #history > math.floor(#(index.songs)/2) then table.remove(history) end
                    local randomSong = math.random(1, #(index.songs))
                    while tableFind(history, randomSong) do randomSong = math.random(1, #(index.songs)) end
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
        parallel.waitForAny(function() broadcast() end)
    end

    -- Buttons
    local playButton = main:addButton():setPosition(2, "parent.h - 3"):setSize(6,3):setText("Play"):setBackground(colors.lime)
    local pauseButton = main:addButton():setPosition(10, "parent.h - 3"):setSize(9,3):setText("Pause"):setBackground(colors.orange)
    local stopButton = main:addButton():setPosition(21, "parent.h - 3"):setSize(6,3):setText("Stop"):setBackground(colors.red)
    local shuffleButton = main:addButton():setPosition("parent.w - 9", "parent.h - 2"):setSize(4,1):setText("=>"):setBackground(colors.red)
    local volumeUpButton = main:addButton():setPosition("parent.w - 3", "parent.h - 3"):setSize(3,1):setText("+")
    local volumeDownButton = main:addButton():setPosition("parent.w - 3", "parent.h - 1"):setSize(3,1):setText("-")

    playButton:onClick(function() startPlayback(); updateTrack() end)
    pauseButton:onClick(function() pausePlayback(); updateTrack() end)
    stopButton:onClick(function() stopPlayback(); pause=false; updateTrack() end)
    shuffleButton:onClick(function() shuffle = not shuffle; shuffleButton:setBackground(shuffle and colors.green or colors.red) end)
    volumeUpButton:onClick(function() clientVolume = math.min(clientVolume+0.1,3); setVolume() end)
    volumeDownButton:onClick(function() clientVolume = math.max(clientVolume-0.1,0); setVolume() end)

    basalt.autoUpdate()
end

-- Save function
musicme.save = function(arguments)
    local url = arguments[1]
    local author = arguments[2] or "URL"
    if not url then print("Usage: musicme save <url> [author]") return end

    local index = loadIndex()
    local song = {
        type="song",
        name=url:match("[^/]+$") or "Unknown Song",
        author=author,
        file=url
    }
    table.insert(index.songs, song)
    local file = fs.open(indexFile, "w")
    file.write(textutils.serialiseJSON(index))
    file.close()
    print("Saved song: " .. song.name .. " by " .. song.author)
end

-- Command handling
shell.run("clear")
local command = table.remove(args, 1)
if monitor and command == "gui" then
    musicme.gui(args)
elseif musicme[command] then
    musicme[command](args)
else
    print("Invalid command. Use 'musicme help'.")
end
