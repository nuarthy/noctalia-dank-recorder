--!nonstrict
-- Dank Recorder - popout panel ([[panel]] "popout"), opened by right-clicking the bar
-- pill. Mirrors the DMS popout: idle offers Full screen and Region tiles, an active
-- recording offers Stop and Pause/Resume, and the footer opens the output folder or
-- the last file.

local status = {}

local function tr(key)
    return noctalia.tr(key)
end

local function send(action, closeAfter)
    noctalia.state.set("command", { action = action })
    if closeAfter then
        panel.close()
    end
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

local function currentState()
    return status.state or "idle"
end

local function isActive()
    return currentState() ~= "idle"
end

-- Named callbacks for the panel's own buttons.
function cmdStartFullscreen()
    send("start-fullscreen", true)
end

function cmdStartRegion()
    send("start-region", true)
end

function cmdConfirm()
    send("confirm", true)
end

function cmdStop()
    send("stop")
end

function cmdPause()
    send("pause")
end

function cmdOpenFolder()
    send("open-folder")
end

function cmdOpenLatest()
    send("open-last")
end

function cmdClose()
    panel.close()
end

local function titleText()
    local state = currentState()
    if state == "resolving" then
        return tr("widget.resolving")
    elseif state == "armed" then
        return tr("panel.armed")
    elseif state == "starting" then
        return tr("panel.starting")
    elseif state == "recording" then
        return `{tr("panel.recording")} · {formatTime(status.elapsed)}`
    elseif state == "paused" then
        return `{tr("panel.paused")} · {formatTime(status.elapsed)}`
    elseif state == "stopping" then
        return tr("panel.saving")
    end
    return tr("panel.title")
end

local function subtitleText()
    if isActive() then
        local parts = {}
        if type(status.backend) == "string" and status.backend ~= "" then
            parts[#parts + 1] = status.backend
        end
        if type(status.canvas) == "string" and status.canvas ~= "" then
            parts[#parts + 1] = status.canvas
        end
        if #parts == 0 then
            parts[#parts + 1] = tr("panel.in-progress")
        end
        return table.concat(parts, " · ")
    end
    return tr("panel.choose")
end

local function tile(glyph, title, subtitle, primary, onClick)
    return ui.column({
        flexGrow = 1,
        height = 104,
        radius = 14,
        gap = 4,
        align = "center",
        justify = "center",
        fill = if primary then "primary" else "surface_variant",
        border = if primary then nil else "outline/0.4",
        borderWidth = if primary then 0 else 1,
        onClick = onClick,
    }, {
        ui.glyph({
            name = glyph,
            size = 26,
            color = if primary then "on_primary" else "on_surface",
        }),
        ui.label({
            text = title,
            fontSize = 15,
            fontWeight = "semibold",
            color = if primary then "on_primary" else "on_surface",
        }),
        ui.label({
            text = subtitle,
            fontSize = 12,
            color = if primary then "on_primary" else "on_surface_variant",
        }),
    })
end

local function idleControls()
    return ui.row({ gap = 10, width = "100%" }, {
        tile("device-desktop", tr("popout.full-screen"), tr("popout.full-screen-hint"), true, "cmdStartFullscreen"),
        tile("crop", tr("popout.region"), tr("popout.region-hint"), false, "cmdStartRegion"),
    })
end

local function activeControls()
    local state = currentState()
    local busy = state == "starting" or state == "stopping"

    local primaryText = if state == "armed"
        then tr("popout.start-recording")
        elseif state == "resolving"
        then tr("popout.cancel")
        else tr("popout.stop-recording")

    local primaryGlyph = if state == "armed"
        then "player-record"
        elseif state == "resolving"
        then "x"
        else "player-stop"

    return ui.row({ gap = 10, width = "100%" }, {
        ui.button({
            text = primaryText,
            glyph = primaryGlyph,
            variant = if state == "armed" then "primary" else "destructive",
            controlSize = "md",
            flexGrow = 1,
            enabled = not busy,
            onClick = if state == "armed" then "cmdConfirm" else "cmdStop",
        }),
        ui.button({
            text = if state == "paused" then tr("popout.resume") else tr("popout.pause"),
            glyph = if state == "paused" then "player-play" else "player-pause",
            variant = "secondary",
            controlSize = "md",
            flexGrow = 1,
            enabled = state == "recording" or state == "paused",
            onClick = "cmdPause",
        }),
    })
end

local function footerControls()
    local hasLast = type(status.lastFile) == "string" and status.lastFile ~= ""
    return ui.row({ gap = 10, width = "100%" }, {
        ui.button({
            text = tr("popout.recordings"),
            glyph = "folder",
            variant = "ghost",
            controlSize = "md",
            flexGrow = 1,
            tooltip = tr("popout.recordings-tooltip"),
            onClick = "cmdOpenFolder",
        }),
        ui.button({
            text = tr("popout.open-latest"),
            glyph = "external-link",
            variant = "ghost",
            controlSize = "md",
            flexGrow = 1,
            visible = hasLast,
            onClick = "cmdOpenLatest",
        }),
    })
end

local function render()
    local rows = {
        ui.row({ gap = 8, align = "center", width = "100%" }, {
            ui.column({ gap = 2, flexGrow = 1 }, {
                ui.label({
                    text = titleText(),
                    fontSize = 17,
                    fontWeight = "bold",
                    color = if currentState() == "recording" then "error" else "on_surface",
                }),
                ui.label({
                    text = subtitleText(),
                    fontSize = 12,
                    color = "on_surface_variant",
                    maxLines = 2,
                }),
            }),
            ui.button({
                glyph = "x",
                variant = "ghost",
                controlSize = "sm",
                tooltip = tr("popout.close"),
                onClick = "cmdClose",
            }),
        }),
    }

    if isActive() then
        rows[#rows + 1] = activeControls()
    else
        rows[#rows + 1] = idleControls()
    end

    rows[#rows + 1] = footerControls()

    local errorText = if type(status.error) == "string" then status.error else ""
    if errorText ~= "" then
        rows[#rows + 1] = ui.label({
            text = errorText,
            fontSize = 11,
            color = "error",
            maxLines = 3,
        })
    end

    local info = {}
    if type(status.gpus) == "string" and status.gpus ~= "" then
        info[#info + 1] = `{tr("popout.gpus")}: {status.gpus}`
    end
    if type(status.caps) == "string" and status.caps ~= "" then
        info[#info + 1] = `{tr("popout.encoders")}: {status.caps}`
    end
    if #info > 0 then
        rows[#rows + 1] = ui.separator({ spacing = 4 })
        rows[#rows + 1] = ui.label({
            text = table.concat(info, "\n"),
            fontSize = 10,
            color = "on_surface_variant",
            maxLines = 4,
        })
    end

    panel.render(ui.column({
        padding = 16,
        gap = 14,
        align = "stretch",
        width = "100%",
    }, rows))
end

function onOpen()
    render()
end

function onIpc(event)
    send(event)
end

status = noctalia.state.get("status") or {}
noctalia.state.watch("status", function(next)
    status = next or {}
    render()
end)
render()
