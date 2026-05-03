-- Hammerspoon bridge for HW-75 Dynamic Home Assistant controls.
--
-- Firmware mapping:
--   Scene mode:
--     F19: activate next scene
--     F18: activate previous scene
--   Dimmer mode:
--     F21: increase brightness value
--     F20: decrease brightness value
--
-- Usage:
--   1. Install Hammerspoon on macOS.
--   2. Load this file from ~/.hammerspoon/init.lua with dofile(...).
--   3. Fill in HA_BASE_URL, HA_TOKEN, LIGHT_ENTITY_ID, and SCENES.

local HA_BASE_URL = "http://homeassistant.local:8123"
local HA_TOKEN = "PUT_LONG_LIVED_ACCESS_TOKEN_HERE"

local LIGHT_ENTITY_ID = "light.your_light"
local DEFAULT_PCT = 50
local CHANGE_PER_NOTCH_PCT = 5
local SEND_DEBOUNCE_SECONDS = 0.12
local TRANSITION_SECONDS = 0.2

local SCENES = {
    { name = "工作", entity_id = "scene.work" },
    { name = "观影", entity_id = "scene.movie" },
    { name = "睡前", entity_id = "scene.bedtime" },
}
local SCENE_DEBOUNCE_SECONDS = 0.15

local currentPct = DEFAULT_PCT
local hasSynced = false
local pendingPct = nil
local sendTimer = nil

local currentSceneIndex = 1
local pendingSceneIndex = nil
local sceneTimer = nil

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

local function showStatus(message)
    if hs.alert then
        hs.alert.show(message, 0.8)
    end
end

local function notifyFailure(status, body)
    hs.notify.new({
        title = "HW-75 Home Assistant",
        informativeText = string.format(
            "Request failed: %s %s",
            tostring(status or "unknown"),
            body or ""
        ),
    }):send()
end

local function postService(domain, service, payload, callback)
    local url = haUrl("/api/services/" .. domain .. "/" .. service)
    local body = hs.json.encode(payload)

    hs.http.asyncPost(url, body, headers(), function(status, responseBody)
        if not status or status < 200 or status >= 300 then
            notifyFailure(status, responseBody)
            return
        end

        if callback then
            callback(status, responseBody)
        end
    end)
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

    postService("light", service, payload, function()
        showStatus("调光 " .. tostring(pct) .. "%")
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

local function sceneAt(index)
    return SCENES[index]
end

local function sceneEntityId(scene)
    if type(scene) == "string" then
        return scene
    end

    return scene.entity_id
end

local function sceneName(scene)
    if type(scene) == "string" then
        return scene
    end

    return scene.name or scene.entity_id
end

local function activateScene(index)
    local scene = sceneAt(index)
    if not scene then
        showStatus("未配置场景")
        return
    end

    local entityId = sceneEntityId(scene)
    if not entityId or entityId == "" then
        showStatus("场景缺少 entity_id")
        return
    end

    postService("scene", "turn_on", { entity_id = entityId }, function()
        showStatus("场景 " .. sceneName(scene))
    end)
end

local function flushPendingScene()
    sceneTimer = nil

    if pendingSceneIndex == nil then
        return
    end

    local index = pendingSceneIndex
    pendingSceneIndex = nil
    activateScene(index)
end

local function scheduleSceneActivation(index)
    pendingSceneIndex = index

    if sceneTimer then
        sceneTimer:stop()
    end

    sceneTimer = hs.timer.doAfter(SCENE_DEBOUNCE_SECONDS, flushPendingScene)
end

local function changeScene(delta)
    if #SCENES == 0 then
        showStatus("未配置场景")
        return
    end

    currentSceneIndex = ((currentSceneIndex - 1 + delta) % #SCENES) + 1
    scheduleSceneActivation(currentSceneIndex)
end

syncBrightnessFromHomeAssistant()

hs.hotkey.bind({}, "F19", function()
    changeScene(1)
end)

hs.hotkey.bind({}, "F18", function()
    changeScene(-1)
end)

hs.hotkey.bind({}, "F21", function()
    changeBrightness(CHANGE_PER_NOTCH_PCT)
end)

hs.hotkey.bind({}, "F20", function()
    changeBrightness(-CHANGE_PER_NOTCH_PCT)
end)
