local dfpwm = require("cc.audio.dfpwm")
local decoder = dfpwm.make_decoder()

local modem = peripheral.find("modem")
rednet.open(peripheral.getName(modem))

local PROTOCOL = "monolith-local-radio"

local speakers = { peripheral.find("speaker") } -- not used for network streaming, but kept for reference

-- --- SONG SELECTION LOGIC ---
local fs = fs
local menu = require "menu"
local uri = nil

local drive = peripheral.find("drive")
local selectedSong = nil

-- choose song from local files if no disk is present
if drive == nil or not drive.isDiskPresent() then
    local savedSongs = fs.list("songs/")

    if #savedSongs == 0 then
        error("ERR - No disk found and no local songs available.")
    else
        local entries = {
            [1] = { label = "[CANCEL]", callback = function() error() end }
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

        menu.init({ main = { entries = entries } })
        menu.thread()

        if selectedSong then
            local fp = "songs/" .. selectedSong
            if fs.exists(fp) then
                local file = fs.open(fp, "r")
                uri = file.readAll()
                file.close()
            else
                error("Song file not found on device!")
            end
        else
            error("No song selected!")
        end
    end
else
    -- disk present, read song.txt
    local songFile = fs.open("disk/song.txt", "r")
    uri = songFile.readAll()
    songFile.close()
end

-- sanity check
if not uri or not uri:find("^https") then
    error("ERR - Invalid URI! Must be an https URL.")
end

-- --- NETWORK CLOCK ---
local globalTick = 0
local function clock()
    while true do
        globalTick = globalTick + 1
        rednet.broadcast({ type = "clock", tick = globalTick }, PROTOCOL)
        sleep(0)
    end
end

-- --- SEND AUDIO ---
local function sendAudio()
    while true do
        local res = http.get(uri, nil, true)
        if not res then error("Failed to fetch stream!") end

        local chunkSize = 4 * 1024
        local raw = res.read(chunkSize)

        while raw do
            local pcm = decoder(raw)
            local play_at_tick = globalTick + 8  -- jitter buffer

            rednet.broadcast({
                type = "audio",
                play_at = play_at_tick,
                chunk = pcm
            }, PROTOCOL)

            raw = res.read(chunkSize)
        end
    end
end

parallel.waitForAll(clock, sendAudio)
