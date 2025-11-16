-- Libraries
local basalt = require("lib/basalt")
local dfpwm = require("/lib/dfpwm")
local v = require("/lib/semver")

-- Settings
local volume = settings.get("clientVolume", 1)
local bufferLength = settings.get("bufferLength", 16)

-- Channels (for networking)
local controlChannel = settings.get("controlChannel", 2561)
local bufferChannel = settings.get("bufferChannel", controlChannel + 1)
local clientChannel = settings.get("clientChannel", controlChannel + 2)

-- Peripherals
local modem = peripheral.find("modem")
local speaker = peripheral.find("speaker")
local monitor = peripheral.find("monitor")

if not modem then error("A modem is required") end
if not speaker then error("A speaker is required") end

-- Utility: play buffer on all speakers
local function playBuffer(buffer, vol)
    vol = vol or 1
    local callbacks = {}
    for i, sp in pairs({speaker}) do
        table.insert(callbacks, function()
            while not sp.playAudio(buffer, vol) do
                os.pullEvent("speaker_audio_empty")
            end
        end)
    end
    parallel.waitForAll(table.unpack(callbacks))
end

-- Save a song URL
local function saveSong(name, url)
    if not name or not url then
        print("Usage: musicme save <name> <url>")
        return
    end
    if not fs.exists("songs") then fs.makeDir("songs") end
    local file = fs.open("songs/" .. name .. ".txt", "w")
    file.write(url)
    file.close()
    print("Saved song '" .. name .. "' successfully!")
end

-- Load a song URL
local function loadSong(name)
    local path = "songs/" .. name .. ".txt"
    if not fs.exists(path) then
        error("Song '" .. name .. "' not found")
    end
    local file = fs.open(path, "r")
    local uri = file.readAll()
    file.close()
    return uri
end

-- Play a song from URL
local function playSong(uri)
    if not uri:find("^https?://") then error("Invalid URL") end

    local response = http.get(uri, nil, true)
    if not response then error("Failed to fetch song") end

    local decoder = dfpwm.make_decoder()
    local chunkSize = 4 * 1024
    local chunk = response.read(chunkSize)

    while chunk do
        local buffer = decoder(chunk)
        playBuffer(buffer, volume)
        chunk = response.read(chunkSize)
    end
    print("Finished playing song.")
end

-- List all saved songs
local function listSongs()
    if not fs.exists("songs") then return {} end
    return fs.list("songs")
end

-- Simple CLI
local args = { ... }
local command = table.remove(args, 1)

if command == "save" then
    local name, url = table.unpack(args)
    saveSong(name, url)

elseif command == "play" then
    local name = table.unpack(args)
    local uri = loadSong(name)
    playSong(uri)

elseif command == "list" then
    local songs = listSongs()
    print("Saved Songs:")
    for i, song in ipairs(songs) do
        print("-", song:match("^(.*)%.txt$"))
    end

else
    print([[Usage:
musicme save <name> <url>  -- Save a song URL to device
musicme play <name>        -- Play a saved song
musicme list               -- List saved songs]])
end
