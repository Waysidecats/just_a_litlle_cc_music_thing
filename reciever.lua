-- receiver_startup.lua

local dfpwm = require("cc.audio.dfpwm")
local decoder = dfpwm.make_decoder()
local speakers = { peripheral.find("speaker") }

local volume = settings.get("media_center.volume") or 1.0
local modem = peripheral.find("modem")
rednet.open(peripheral.getName(modem))

local PROTOCOL = "monolith-local-radio"

local globalTick = 0
local buffer = {}

local function playChunk(chunk)
    local ok
    local tasks = {}

    for i, sp in ipairs(speakers) do
        if i == 1 then
            table.insert(tasks, function()
                ok = sp.playAudio(chunk, volume)
            end)
        else
            table.insert(tasks, function()
                sp.playAudio(chunk, volume)
            end)
        end
    end

    parallel.waitForAll(table.unpack(tasks))
    return ok
end

while true do
    local id, msg = rednet.receive(PROTOCOL, 0.05)

    -- clock ticks
    if msg and msg.type == "clock" then
        globalTick = msg.tick
    end

    -- audio chunks
    if msg and msg.type == "audio" then
        buffer[msg.play_at] = msg.chunk
    end

    -- If it's time to play
    local chunk = buffer[globalTick]
    if chunk then
        buffer[globalTick] = nil

        while not playChunk(chunk) do
            os.pullEvent("speaker_audio_empty")
        end
    end
end
