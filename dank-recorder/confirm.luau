--!nonstrict
-- Dank Recorder - the canvas confirmation bar ([[layer]] "confirm").
--
-- Shown by the service while a recording is armed. It reports the canvas that will
-- be captured and offers the same five actions as the DMS bar: Full screen, Region,
-- Sound/Muted, Cancel and Start recording, plus Move.
--
-- The bar is a layer surface, so the plugin owns its geometry: the service places it
-- with noctalia.layer.configure() before it shows the bar, and the Move control swaps it
-- between the bottom and top edges. Noctalia gives a layer's script pointer events only
-- through its own controls, so the bar cannot be dragged by its background; Move is the
-- equivalent, and the edge it picks is remembered for the next recording.

local status = {}

local function tr(key)
    return noctalia.tr(key)
end

local function send(action)
    noctalia.state.set("command", { action = action })
end

local function isArmed()
    return (status.state or "idle") == "armed"
end

-- Named callbacks: every button names a global here, so a re-render never leaves a
-- stale closure behind a click.
function cmdFullScreen()
    send("fullscreen")
end

function cmdReselect()
    send("reselect")
end

function cmdCycleOutput()
    send("cycle-output")
end

function cmdMove()
    send("move-confirm")
end

function cmdAudio()
    send("toggle-audio")
end

function cmdCancel()
    send("cancel")
end

function cmdStart()
    send("confirm")
end

function onIpc(event)
    send(event)
end

local function render()
    if not isArmed() then
        -- The service hides the layer on confirm or cancel; an empty tree keeps a bar
        -- that outlived its armed state from showing a stale canvas.
        layer.render(ui.box({ width = 1, height = 1 }))
        return
    end

    local canvas = status.canvas or ""
    local target = status.target or tr("confirm.live-desktop")
    -- Move swaps the bar between the two edges, so the tooltip names where it goes.
    local moveTooltip = if (status.position or "bottom") == "top" then tr("confirm.move-down-tooltip") else tr("confirm.move-up-tooltip")
    local audioText = status.audioText or tr("audio.sound")
    local audioIcon = status.audioIcon or "volume"
    local audioOn = status.audioOn == true
    local isRegion = status.isRegion == true

    -- The layer gives the bar its exact size, so the card is drawn here: one row of
    -- controls, centred in a rounded surface.
    layer.render(ui.column({
        flexGrow = 1,
        fill = "surface_container",
        radius = 14,
        border = "outline",
        borderWidth = 1,
        paddingH = 14,
        paddingV = 7,
        justify = "center",
    }, {
        ui.row({ height = 42, gap = 8, align = "center" }, {
            ui.column({
                width = 34,
                height = 34,
                radius = 10,
                fill = "primary/0.14",
                align = "center",
                justify = "center",
            }, {
                ui.glyph({ name = "video", size = 18, color = "primary" }),
            }),
            ui.column({ gap = 0, align = "start", minWidth = 210 }, {
                ui.label({
                    text = canvas,
                    fontSize = 16,
                    fontWeight = "semibold",
                    color = "on_surface",
                }),
                ui.label({
                    text = target,
                    fontSize = 12,
                    color = "on_surface_variant",
                }),
            }),
            ui.spacer({ flexGrow = 1 }),
            ui.button({
                glyph = "arrows-move",
                variant = "ghost",
                controlSize = "md",
                tooltip = moveTooltip,
                onClick = "cmdMove",
            }),
            ui.button({
                glyph = "device-desktop",
                variant = "secondary",
                controlSize = "md",
                tooltip = tr("confirm.cycle-output-tooltip"),
                enabled = (tonumber(status.outputs) or 1) > 1,
                onClick = "cmdCycleOutput",
            }),
            ui.button({
                text = tr("confirm.full-screen"),
                glyph = "maximize",
                variant = "secondary",
                controlSize = "md",
                enabled = isRegion,
                tooltip = if isRegion then tr("confirm.full-screen-tooltip") else nil,
                onClick = "cmdFullScreen",
            }),
            ui.button({
                text = tr("confirm.region"),
                glyph = "crop",
                variant = "secondary",
                controlSize = "md",
                tooltip = tr("confirm.region-tooltip"),
                onClick = "cmdReselect",
            }),
            ui.button({
                text = audioText,
                glyph = audioIcon,
                variant = if audioOn then "secondary" else "outline",
                controlSize = "md",
                tooltip = tr("confirm.audio-tooltip"),
                onClick = "cmdAudio",
            }),
            ui.button({
                text = tr("confirm.cancel"),
                variant = "secondary",
                controlSize = "md",
                onClick = "cmdCancel",
            }),
            ui.button({
                text = tr("confirm.start"),
                glyph = "player-record",
                variant = "primary",
                controlSize = "md",
                onClick = "cmdStart",
            }),
        }),
    }))
end

status = noctalia.state.get("status") or {}
noctalia.state.watch("status", function(next)
    status = next or {}
    render()
end)
render()
