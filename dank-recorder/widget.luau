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

-- Two lines for a vertical bar: minutes on top, seconds below, the way the built-in
-- clock stacks its hour and minute under a vertical bar.
local function timerLines(seconds)
    local total = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(total / 3600)
    local minutes = math.floor((total % 3600) / 60)
    local rest = total % 60
    local top = if hours > 0 then string.format("%d:%02d", hours, minutes) else tostring(minutes)
    return top, string.format("%02d", rest)
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
        -- Keep the camera; the accent colour is what says "armed".
        return "video"
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
    if isConfirmingStop() then
        rows[#rows + 1] = { key = tr("widget.stop-question"), value = tr("widget.stop-hint") }
    end
    if lastError ~= "" and state == "idle" then
        rows[#rows + 1] = { key = tr("panel.error"), value = lastError }
    end
    return rows
end

-- barWidget.isVertical() answers false for a side bar in Noctalia 5.3.0, so ask the
-- shell config when it does. Resolved once per load: moving a bar reloads the widget.
local function detectVerticalBar()
    local ok, vertical = pcall(function()
        return barWidget.isVertical()
    end)
    if ok and vertical == true then
        return true
    end
    local names = noctalia.getSetting("bar.order")
    if type(names) == "table" then
        local name = names[1]
        if type(name) == "string" then
            local position = noctalia.getSetting("bar." .. name .. ".position")
            if type(position) == "string" then
                return position == "left" or position == "right"
            end
        end
    end
    return false
end

local stackedTimer = detectVerticalBar()

local function glyphNode()
    return ui.glyph({
        name = glyphForState(),
        size = if stackedTimer then 17 else 18,
        color = colorForState(),
    })
end

-- barWidget.render replaces the built-in glyph/text row, so every state is built as a
-- tree: a column on a vertical bar (glyph above the timer), a row on a horizontal one.
local function render()
    local vertical = stackedTimer
    local children = { glyphNode() }
    local caption = textForState()

    if vertical then
        -- A vertical capsule only has room for numbers: the timer while recording, no
        -- wording otherwise. The glyph colour and the tooltip carry the state, which is
        -- what the DMS vertical pill did.
        if state == "recording" or state == "paused" then
            local top, bottom = timerLines(elapsed)
            children[#children + 1] = ui.label({
                text = top,
                fontSize = 13,
                fontWeight = "semibold",
                color = "on_surface",
                textAlign = "center",
            })
            children[#children + 1] = ui.label({
                text = bottom,
                fontSize = 12,
                color = "on_surface_variant",
                textAlign = "center",
            })
        end
        barWidget.render(ui.column({ gap = 0, align = "center" }, children))
    else
        if caption ~= "" then
            children[#children + 1] = ui.label({
                text = caption,
                fontSize = 13,
                fontWeight = "bold",
                color = "on_surface",
            })
        end
        barWidget.render(ui.row({ gap = 4, align = "center" }, children))
    end

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
