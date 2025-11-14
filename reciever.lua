-- startup.lua (receiver)

local dfpwm = require("cc.audio.dfpwm")
local decoder = dfpwm.make_decoder()
local speakers = { peripheral.find("speaker") }
local rednetChannel = 16783

-- Find modem the clean way
local modem = peripheral.find("modem")
if not modem then error("Receiver requires a modem!") end
rednet.open(peripheral.getName(modem))

-- Tick counter
local currentTick = 0
local function tickCounter()
    while true do
        os.pullEvent("tick")
        currentTick = currentTick + 1
    end
end

local function playChunk(chunk)
    local retval = nil
    local calls = {}

    for i, sp in ipairs(speakers) do
        if i == 1 then
            table.insert(calls, function() retval = sp.playAudio(chunk, 1.0) end)
        else
            table.insert(calls, function() sp.playAudio(chunk, 1.0) end)
        end
    end

    parallel.waitForAll(table.unpack(calls))
    return retval
end

print("Receiver online. Waiting for broadcast...")

while true do
    local id, msg = rednet.receive(rednetChannel)

    if msg.stop then
        print("Received STOP command. Rebooting.")
        sleep(0.5)
        os.reboot()
    end

    if msg.url and msg.startTick then
        local uri = msg.url
        local startTick = msg.startTick

        print("Received sync start:", uri, startTick)

        parallel.waitForAny(
            tickCounter,
            function()
                while currentTick < startTick do
                    os.pullEvent("tick")
                end

                print("Starting audio at:", currentTick)

                local response = http.get(uri, nil, true)
                local chunkSize = 4 * 1024

                while true do
                    local chunk = response.read(chunkSize)
                    if not chunk then break end

                    local buffer = decoder(chunk)

                    while not playChunk(buffer) do
                        os.pullEvent("speaker_audio_empty")
                    end
                end

                print("Stream ended. Waiting for next broadcast.")
            end
        )
    end
end
