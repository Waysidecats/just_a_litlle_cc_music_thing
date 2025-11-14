-- broadcaster.lua
local dfpwm = require("cc.audio.dfpwm")
local decoder = dfpwm.make_decoder()
local speakers = { peripheral.find("speaker") }
local drive = peripheral.find("drive")
local menu = require "menu"

local rednetChannel = 16783

-- Detect modem
local modem = peripheral.find("modem")
if not modem then error("No modem found!") end
rednet.open(peripheral.getName(modem))

-- Tick counter
local currentTick = 0
local function tickCounter()
    while true do
        os.pullEvent("tick")
        currentTick = currentTick + 1
    end
end

-------------------------------------------------------
-- Song Selection Logic
-------------------------------------------------------

local uri = nil
local volume = settings.get("media_center.volume") or 1.0
local selectedSong = nil

if drive == nil or not drive.isDiskPresent() then
    local songs = fs.list("songs/")
    if #songs == 0 then error("No songs found.") end

    local entries = {
        { label = "[CANCEL]", callback = function() error() end }
    }

    for _, fp in ipairs(songs) do
        table.insert(entries, {
            label = fp:match("^(.*)%.") or fp,
            callback = function() selectedSong = fp; menu.exit() end
        })
    end

    menu.init({ main = { entries = entries } })
    menu.thread()

    if selectedSong then
        local file = fs.open("songs/" .. selectedSong, "r")
        uri = file.readAll()
        file.close()
    else
        error("No song selected.")
    end
else
    local f = fs.open("disk/song.txt", "r")
    uri = f.readAll()
    f.close()
end

if not uri or not uri:find("^https") then
    error("Invalid URI.")
end

-------------------------------------------------------
-- Audio playback helpers
-------------------------------------------------------

local function playChunk(chunk)
    local retval = nil
    local calls = {}

    for i, sp in ipairs(speakers) do
        if i == 1 then
            table.insert(calls, function() retval = sp.playAudio(chunk, volume) end)
        else
            table.insert(calls, function() sp.playAudio(chunk, volume) end)
        end
    end

    parallel.waitForAll(table.unpack(calls))
    return retval
end

-------------------------------------------------------
-- Playback / Broadcasting / Input
-------------------------------------------------------

local quit = false

local function inputThread()
    while true do
        local line = read()
        if string.lower(line) == "stop" then
            quit = true
            rednet.broadcast({ stop = true }, rednetChannel)
            print("Stopping... receivers notified.")
            return
        end
    end
end

local function healthThread(startTick)
    while not quit do
        rednet.broadcast({
            url = uri,
            startTick = startTick
        }, rednetChannel)
        sleep(2)
    end
end

local function playThread(startTick)
    while currentTick < startTick do
        os.pullEvent("tick")
    end

    print("Starting audio at tick:", startTick)

    local response = http.get(uri, nil, true)
    local chunkSize = 4 * 1024

    while not quit do
        local chunk = response.read(chunkSize)
        if not chunk then break end

        local buffer = decoder(chunk)

        while not playChunk(buffer) do
            os.pullEvent("speaker_audio_empty")
        end
    end
end

-------------------------------------------------------
-- Start main program
-------------------------------------------------------

parallel.waitForAny(tickCounter, function()
    local startTick = currentTick + 80 -- 4 second sync delay

    print("Synced start tick:", startTick)

    parallel.waitForAny(
        function() playThread(startTick) end,
        function() healthThread(startTick) end,
        inputThread
    )
end)

print("Broadcaster shut down.")
