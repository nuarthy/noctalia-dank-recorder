--!nonstrict
-- Dank Recorder - control-center quick tile ([[shortcut]]).
--
-- Holds no recorder logic: it mirrors the service's "status" and writes a command to
-- the shared channel, so a recording can be started with no bar pill placed.

local state = "idle"
local recording = false
local active = false

local RECORDING_STATES = { recording = true, paused = true, starting = true }
local ACTIVE_STATES = { recording = true, paused = true, starting = true, armed = true, resolving = true, stopping = true }

local function tr(key)
    return noctalia.tr(key)
end

local function label()
    if state == "recording" then
        return tr("shortcut.recording")
    elseif state == "paused" then
        return tr("shortcut.paused")
    elseif state == "armed" then
        return tr("shortcut.armed")
    elseif state == "resolving" or state == "starting" then
        return tr("shortcut.starting")
    elseif state == "stopping" then
        return tr("shortcut.saving")
    end
    return tr("shortcut.record-screen")
end

local function render()
    shortcut.setLabel(label())
    shortcut.setIcon("player-stop", "video")
    shortcut.setActive(active)
    shortcut.setEnabled(true)
end

local function applyStatus(status)
    if type(status) == "table" then
        state = status.state or "idle"
    end
    recording = RECORDING_STATES[state] == true
    active = ACTIVE_STATES[state] == true
    render()
end

function onClick()
    noctalia.state.set("command", { action = "toggle" })
end

function onRightClick()
    noctalia.state.set("command", { action = if recording then "pause" else "start" })
end

applyStatus(noctalia.state.get("status"))
noctalia.state.watch("status", applyStatus)
