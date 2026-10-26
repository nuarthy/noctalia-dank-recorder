--!nonstrict
-- Dank Recorder - bar pill ([[widget]]).
--
-- Mirrors the service's "status" and drives it through the "command" channel.
-- Behaviour kept from the DMS plugin:
--   left click   idle -> start, armed -> confirm, resolving -> cancel,
--                recording/paused -> "Stop?" for 3 s, then stop on the next click
--   right click  open the popout panel
-- The glyph and its colour follow the recorder state; the elapsed time is shown
-- while a recording runs.

local state = "idle"
local elapsed = 0
local lastError = ""
local confirmStopUntil = 0
local stopConfirmWindowMs = 3000

local function tr(key)
    return noctalia.tr(key)
end

-- The command carries the display this pill sits on, so a recording started from a
-- bar on a second monitor captures that monitor even when keyboard focus is elsewhere.
local function send(action)
    noctalia.state.set("command", { action = action, output = barWidget.outputName() })
end

local function formatTime(seconds)
    local total = math.max(0, math.floor(seconds))
    local hours = math.floor(total / 3600)
    local minutes = math.floor((total % 3600) / 60)
    local rest = total % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, rest)
    end
    return string.format("%d:%02d", minutes, rest)
end

local function isConfirmingStop()
    return confirmStopUntil > 0 and noctalia.nowMs() < confirmStopUntil
end

local function glyphForState()
    if isConfirmingStop() then
        return "player-stop"
    end
    if state == "resolving" then
        return "loader-2"
    elseif state == "armed" then
        return "circle-check"
    elseif state == "starting" then
        return "loader-2"
    elseif state == "recording" then
        return "player-stop"
    elseif state == "paused" then
        return "player-pause"
    elseif state == "stopping" then
        return "loader-2"
    end
    return "video"
end

local function colorForState()
    if isConfirmingStop() then
        return "tertiary"
    end
    if state == "recording" then
        return "error"
    elseif state == "paused" then
        return "tertiary"
    elseif state == "idle" then
        return "on_surface"
    end
    return "primary"
end

local function textForState()
    if isConfirmingStop() then
        return tr("widget.stop-question")
    end
    if state == "resolving" then
        return tr("widget.choosing")
    elseif state == "armed" then
        return tr("widget.start-question")
    elseif state == "recording" or state == "paused" then
        return formatTime(elapsed)
    end
    return ""
end

local function tooltipRows()
    local rows = {}
    if state == "recording" then
        rows[#rows + 1] = { key = tr("panel.recording"), value = formatTime(elapsed) }
    elseif state == "paused" then
        rows[#rows + 1] = { key = tr("panel.paused"), value = formatTime(elapsed) }
    elseif state == "armed" then
        rows[#rows + 1] = { key = tr("panel.title"), value = tr("widget.start-question") }
    elseif state == "idle" then
        rows[#rows + 1] = { key = tr("panel.title"), value = tr("widget.tap-to-record") }
    else
        rows[#rows + 1] = { key = tr("panel.title"), value = tr("widget.working") }
    end
    if lastError ~= "" and state == "idle" then
        rows[#rows + 1] = { key = tr("panel.error"), value = lastError }
    end
    return rows
end

local function render()
    barWidget.setGlyph(glyphForState())
    barWidget.setGlyphColor(colorForState())
    barWidget.setText(textForState())
    barWidget.setColor("on_surface")
    barWidget.setTooltip(tooltipRows())
end

local function applyStatus(status)
    if type(status) == "table" then
        state = status.state or "idle"
        elapsed = tonumber(status.elapsed) or 0
        lastError = status.error or ""
    end
    if not isConfirmingStop() then
        confirmStopUntil = 0
    end
    render()
end

function onClick()
    if state == "resolving" then
        send("stop")
        return
    end
    if state == "starting" or state == "stopping" then
        return
    end
    if state == "armed" then
        send("confirm")
        return
    end
    if state == "idle" then
        send("start")
        return
    end
    -- recording or paused: the first click arms the 3 s confirmation window.
    if isConfirmingStop() then
        confirmStopUntil = 0
        render()
        send("stop")
        return
    end
    confirmStopUntil = noctalia.nowMs() + stopConfirmWindowMs
    render()
end

function onRightClick()
    noctalia.togglePanel("nuarthy/dank-recorder:popout")
end

-- IPC reaches the pill too, so `noctalia msg plugin ...:recorder focused toggle`
-- runs the same path as a left click (including the 3 s "Stop?" window).
function onIpc(event)
    if event == "toggle" then
        onClick()
    elseif type(event) == "string" and event ~= "" then
        send(event)
    end
end

function update()
    -- The "Stop?" label has to disappear on its own, so the pill ticks. Everything
    -- else is driven by the service's "status" publishes.
    if confirmStopUntil > 0 and noctalia.nowMs() >= confirmStopUntil then
        confirmStopUntil = 0
        render()
    end
end

noctalia.setUpdateInterval(250)
applyStatus(noctalia.state.get("status"))
noctalia.state.watch("status", applyStatus)
