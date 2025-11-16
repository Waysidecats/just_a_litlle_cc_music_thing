-- ==========================
-- Libraries
-- ==========================
local basalt = require("lib/basalt")
if not basalt then error("Basalt wasn't found") end

local v = require("/lib/semver")
if not v then error("semver wasn't found") end

local dfpwm = require("/lib/dfpwm")
if not dfpwm then error("dfpwm wasn't found") end

-- ==========================
-- Settings
-- ==========================
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
local monitor = peripheral.find("monitor")

if not modem then error("There needs to be a modem attached") end
if not speaker then error("There needs to be a speaker attached") end

-- ==========================
-- Local Index Builder (from saved songs)
-- ==========================
local function buildLocalIndex()
    local songs = {}
    if not fs.exists("songs") then
        fs.makeDir("songs")
    end

    for _, fileName in ipairs(fs.list("songs")) do
        if string.sub(fileName, -4) == ".txt" then
            local f = fs.open("songs/" .. fileName, "r")
            local url = f.readAll()
            f.close()

            table.insert(songs, {
                type = "song",
                name = string.sub(fileName, 1, -5), -- remove ".txt"
                author = "", -- author always empty
                file = url
            })
        end
    end

    -- Always add an empty placeholder for new songs
    table.insert(songs, { type="song", name="", author="", file="" })

    return {
        latestVersion = "1.0.0",
        indexName = "Local Library",
        songs = songs
    }
end

local index = buildLocalIndex()

-- ==========================
-- musicme core
-- ==========================
local musicme = {}
local args = { ... }

-- Table search helper
local tableFind = function(tbl, value)
    local s = {}
    for _, v in pairs(tbl) do s[v] = true end
    return s[value]
end

-- Await message on channels
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
    error("Invalid arguments to awaitMessage")
end

-- Play dfpwm buffer
local playBuffer = function(buffer, volume)
    if not volume then volume = 1 end
    while not speaker.playAudio(buffer, volume) do os.pullEvent("speaker_audio_empty") end
end

-- ==========================
-- Client
-- ==========================
musicme.client = function(arguments)
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
            if msg.command == "start" then shell.run("reboot") end
            if msg.command == "pause" then
                if msg.pause then speaker.stop() end
                shell.run("reboot")
            end
            if msg.command == "stop" then
                speaker.stop()
                shell.run("reboot")
            end
            if msg.command == "volume" then
                clientVolume = msg.volume
            end
        end
    end

    parallel.waitForAll(bufferPlayback, receiveMessage)
end

-- ==========================
-- Get song handle
-- ==========================
local getSongHandle = function(songID)
    if not songID then error("songID is nil") end
    local h, err = http.get({["url"] = songID.file, ["binary"] = true, ["redirect"] = true})
    if not h then error("Failed to open song file: " .. err) end
    return h
end

-- ==========================
-- GUI Server
-- ==========================
musicme.gui = function(arguments)
    if arguments[2] and tonumber(arguments[2]) then
        serverVolume = math.min(math.max(tonumber(arguments[2]), 0), 3)
    end

    modem.open(controlChannel)
    modem.open(clientChannel)

    local main = basalt.createFrame()
    if not main then error("Failed to create basalt frame") end

    local playbackThread = main:addThread()
    local decoder = dfpwm.make_intdecoder()

    local pause = false
    local playback = false
    local shuffle = false
    local selectedSong = nil
    local playingSong = nil

    local list = main:addList()
        :setPosition(2, 2)
        :setSize("parent.w - 2", "parent.h - 6")

    for i, o in pairs(index.songs) do
        list:addItem(index.songs[i].name)
    end

    main:onClick(function() selectedSong = index.songs[list:getItemIndex()] end)

    local currentlyPlaying = main:addLabel()
        :setPosition(29, "parent.h - 3")
        :setSize("parent.w - 42", 3)
        :setText("Now Playing: ")

    local updateTrack = function()
        if playingSong and playback then
            local status = pause and "Paused: " or "Now Playing: "
            currentlyPlaying:setText(status .. playingSong.name)
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
        playbackThread:stop()
    end

    local broadcastSong = function(song)
        if not song or song.file == "" then return end
        playingSong = song
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

    local startPlayback = function()
        playback = true
        setVolume()
        modem.transmit(clientChannel, controlChannel, {command="start", start=true})

        local broadcast = function()
            if not shuffle then broadcastSong(selectedSong) end
            if shuffle then
                local history = {}
                while shuffle do
                    if #history > math.floor(#(index.songs)/2) then table.remove(history) end
                    local rand = math.random(1, #(index.songs))
                    while tableFind(history, rand) do rand = math.random(1, #(index.songs)) end
                    table.insert(history, 1, rand)
                    list:selectItem(rand)
                    selectedSong = index.songs[rand]
                    broadcastSong(selectedSong)
                end
            end
        end

        playbackThread:start(broadcast)
    end

    -- Buttons
    local playButton = main:addButton():setPosition(2, "parent.h - 3"):setSize(6,3):setText("Play"):setBackground(colors.lime)
    local pauseButton = main:addButton():setPosition(10,"parent.h-3"):setSize(9,3):setText("Pause"):setBackground(colors.orange)
    local stopButton = main:addButton():setPosition(21,"parent.h-3"):setSize(6,3):setText("Stop"):setBackground(colors.red)
    local shuffleButton = main:addButton():setPosition("parent.w-9","parent.h-2"):setSize(4,1):setText("=>"):setBackground(colors.red)
    local volumeUpButton = main:addButton():setPosition("parent.w-3","parent.h-3"):setSize(3,1):setText("+")
    local volumeDownButton = main:addButton():setPosition("parent.w-3","parent.h-1"):setSize(3,1):setText("-")

    playButton:onClick(function() startPlayback(); updateTrack() end)
    pauseButton:onClick(function()
        pausePlayback()
        if pause then pauseButton:setText("Unpause"):setBackground(colors.green)
        else pauseButton:setText("Pause"):setBackground(colors.orange) end
        updateTrack()
    end)
    stopButton:onClick(function()
        stopPlayback()
        pause = false
        pauseButton:setText("Pause"):setBackground(colors.orange)
        selectedSong = nil
        updateTrack()
    end)
    volumeUpButton:onClick(function() clientVolume = math.min(clientVolume+0.1,3); setVolume() end)
    volumeDownButton:onClick(function() clientVolume = math.max(clientVolume-0.1,0); setVolume() end)
    shuffleButton:onClick(function()
        shuffle = not shuffle
        shuffleButton:setBackground(shuffle and colors.green or colors.red)
    end)

    basalt.autoUpdate()
end

-- ==========================
-- Help
-- ==========================
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
    startup <arg>       -- Creates a startup file. Specify whether it is for 'client' or for 'gui'
]])
end

-- ==========================
-- Startup
-- ==========================
musicme.startup = function(arguments)
    local mode = table.remove(arguments,1)
    if mode ~= "client" and mode ~= "gui" then
        print("Must indicate whether startup file is for GUI or client")
        return
    end
    if fs.exists("startup.lua") then fs.move("startup.lua","/old.musicme/startup.lua") end
    if mode == "client" then fs.copy("/lib/clientStartup.lua","startup.lua") end
    if mode == "gui" then fs.copy("/lib/guiStartup.lua","startup.lua") end
    print("startup.lua created successfully")
end

-- ==========================
-- Execute command
-- ==========================
shell.run("clear")
local command = table.remove(args,1)
if monitor and command=="gui" and args[1]~="monitor" then
    musicme.monitor(args)
elseif musicme[command] then
    musicme[command](args)
else
    print("Please provide a valid command. For usage, use `musicme help`.")
end
