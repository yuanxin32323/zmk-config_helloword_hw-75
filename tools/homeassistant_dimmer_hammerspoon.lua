-- Hammerspoon bridge for the HW-75 Dynamic "dimmer" knob mode.
--
-- Firmware mapping:
--   F21: increase brightness value
--   F20: decrease brightness value
--
-- Usage:
--   1. Install Hammerspoon on macOS.
--   2. Copy or load this file from ~/.hammerspoon/init.lua.
--   3. Fill in HA_BASE_URL, HA_TOKEN, and LIGHT_ENTITY_ID.

local HA_BASE_URL = "http://homeassistant.local:8123"
local HA_TOKEN = "PUT_LONG_LIVED_ACCESS_TOKEN_HERE"
local LIGHT_ENTITY_ID = "light.your_light"
local DEFAULT_PCT = 50
local CHANGE_PER_NOTCH_PCT = 5
local SEND_DEBOUNCE_SECONDS = 0.12
local TRANSITION_SECONDS = 0.2

local currentPct = DEFAULT_PCT
local hasSynced = false
local pendingPct = nil
local sendTimer = nil

local function clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, value))
end

local function haUrl(path)
    return HA_BASE_URL:gsub("/+$", "") .. path
end

local function headers()
    return {
        ["Authorization"] = "Bearer " .. HA_TOKEN,
        ["Content-Type"] = "application/json",
    }
end

local function notifyFailure(status, body)
    hs.notify.new({
        title = "HW-75 dimmer",
        informativeText = string.format(
            "Home Assistant request failed: %s %s",
            tostring(status or "unknown"),
            body or ""
        ),
    }):send()
end

local function brightnessToPct(brightness)
    return clamp(math.floor((brightness * 100 / 255) + 0.5), 0, 100)
end

local function syncBrightnessFromHomeAssistant(callback)
    local url = haUrl("/api/states/" .. LIGHT_ENTITY_ID)

    hs.http.asyncGet(url, headers(), function(status, responseBody)
        if status and status >= 200 and status < 300 then
            local ok, decoded = pcall(hs.json.decode, responseBody)
            if ok and decoded then
                if decoded.state == "off" then
                    currentPct = 0
                elseif decoded.attributes and decoded.attributes.brightness then
                    currentPct = brightnessToPct(decoded.attributes.brightness)
                else
                    currentPct = DEFAULT_PCT
                end
                hasSynced = true
            end
        else
            notifyFailure(status, responseBody)
        end

        if callback then
            callback()
        end
    end)
end

local function callLightService(pct)
    local service = pct == 0 and "turn_off" or "turn_on"
    local payload = {
        entity_id = LIGHT_ENTITY_ID,
        transition = TRANSITION_SECONDS,
    }

    if pct > 0 then
        payload.brightness_pct = pct
    end

    local url = haUrl("/api/services/light/" .. service)
    local body = hs.json.encode(payload)

    hs.http.asyncPost(url, body, headers(), function(status, responseBody)
        if not status or status < 200 or status >= 300 then
            notifyFailure(status, responseBody)
        end
    end)
end

local function flushPendingBrightness()
    sendTimer = nil

    if pendingPct == nil then
        return
    end

    local pct = pendingPct
    pendingPct = nil
    callLightService(pct)
end

local function scheduleBrightnessSend(pct)
    pendingPct = pct

    if sendTimer then
        sendTimer:stop()
    end

    sendTimer = hs.timer.doAfter(SEND_DEBOUNCE_SECONDS, flushPendingBrightness)
end

local function setBrightnessPct(pct)
    currentPct = clamp(pct, 0, 100)
    scheduleBrightnessSend(currentPct)
end

local function changeBrightness(deltaPct)
    if not hasSynced then
        syncBrightnessFromHomeAssistant(function()
            setBrightnessPct(currentPct + deltaPct)
        end)
        return
    end

    setBrightnessPct(currentPct + deltaPct)
end

syncBrightnessFromHomeAssistant()

hs.hotkey.bind({}, "F21", function()
    changeBrightness(CHANGE_PER_NOTCH_PCT)
end)

hs.hotkey.bind({}, "F20", function()
    changeBrightness(-CHANGE_PER_NOTCH_PCT)
end)
