--!nonstrict
-- Dank Recorder - the canvas confirmation bar ([[panel]] "confirm").
--
-- Shown by the service while a recording is armed. It reports the canvas that will
-- be captured and offers the same five actions as the DMS bar: Full screen, Region,
-- Sound/Muted, Cancel and Start recording.
--
-- Noctalia 5.3 supports plugin API 34, so this is a persistent floating panel
-- pinned to the bottom centre rather than a layer surface: the plugin cannot drag
-- it, but it exists only while armed, sits in the overlay layer, and takes keyboard
-- focus only when clicked - the same on-demand focus the DMS bar used.

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
        -- The service closes the bar on confirm or cancel; closing here as well keeps a
        -- panel that outlived its armed state from staying on screen.
        panel.close()
        return
    end

    local canvas = status.canvas or ""
    local target = status.target or tr("confirm.live-desktop")
    local audioText = status.audioText or tr("audio.sound")
    local audioIcon = status.audioIcon or "volume"
    local audioOn = status.audioOn == true
    local isRegion = status.isRegion == true

    -- The shell's panel supplies its own inset; the plugin adds none, and the flexible
    -- centred root keeps the gaps above and below the controls equal.
    panel.render(ui.column({
        flexGrow = 1,
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

function onOpen()
    render()
end

status = noctalia.state.get("status") or {}
noctalia.state.watch("status", function(next)
    status = next or {}
    render()
end)
render()
