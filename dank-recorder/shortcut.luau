--!nonstrict
-- Dank Recorder - control-center quick tile ([[shortcut]]).
--
-- Holds no recorder logic: it mirrors the service's "status" and writes a command to
-- the shared channel, so a recording can be started with no bar pill placed.

local state = "idle"
local elapsed = 0
local recording = false
local active = false

local RECORDING_STATES = { recording = true, paused = true, starting = true }
local ACTIVE_STATES = { recording = true, paused = true, starting = true, armed = true, resolving = true, stopping = true }

local function tr(key)
    return noctalia.tr(key)
end

local function formatTime(seconds)
    local total = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(total / 3600)
    local minutes = math.floor((total % 3600) / 60)
    local rest = total % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, rest)
    end
    return string.format("%d:%02d", minutes, rest)
end

-- The tile has one label, so a running recording shows its timer: the same
-- "it is recording, for this long" read the DMS tile gave with icon plus timer.
local function label()
    if state == "recording" then
        return formatTime(elapsed)
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
        elapsed = tonumber(status.elapsed) or 0
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
