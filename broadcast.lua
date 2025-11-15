-- stream_sync_host.lua

local dfpwm = require("cc.audio.dfpwm")
local decoder = dfpwm.make_decoder()

local modem = peripheral.find("modem")
rednet.open(peripheral.getName(modem))

local PROTOCOL = "monolith-local-radio"

local uri = "<YOUR STREAM URL HERE>"

local globalTick = 0
local function clock()
    while true do
        globalTick = globalTick + 1
        rednet.broadcast({
            type = "clock",
            tick = globalTick
        }, PROTOCOL)
        sleep(0)
    end
end

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
