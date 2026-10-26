--!nonstrict
-- Dank Recorder - headless service ([[service]]).
--
-- Owns the gpu-screen-recorder process and the state machine, and publishes the
-- result on the plugin's shared "status" channel. The bar pill, the control-center
-- tile, the popout panel and the confirmation bar are thin clients: they mirror
-- "status" and drive the recorder by writing to the "command" channel.
--
-- States, as in the DMS plugin:
--   idle       nothing running
--   resolving  choosing the capture source (focused output, monitor list, slurp)
--   armed      waiting for Start / Cancel on the confirmation bar
--   starting   a candidate command is running, inside its 2.5 s probe window
--   recording  the probe passed
--   paused     SIGUSR2 sent, elapsed time frozen
--   stopping   SIGINT sent, waiting for the process to flush and exit

noctalia.setUpdateInterval(250)

local PROBE_TICKS = 10 -- 2.5 s: a candidate that cannot capture dies inside this
local CHECK_TICKS = 4 -- 1 s liveness and elapsed refresh
local LOG_TAIL_BYTES = 1500

local PLUGIN_ID = "nuarthy/dank-recorder"
local CONFIRM_PANEL = PLUGIN_ID .. ":confirm"

-- ── Small helpers ──────────────────────────────────────────────────────────

local function log(message)
    noctalia.log(`dank-recorder: {message}`)
end

local function tr(key)
    return noctalia.tr(key)
end

local function cfg(key)
    return noctalia.getConfig(key)
end

local function confString(key, fallback)
    local value = cfg(key)
    if type(value) == "string" then
        return value
    end
    return fallback
end

local function confBool(key, fallback)
    local value = cfg(key)
    if type(value) == "boolean" then
        return value
    end
    return fallback
end

-- Single-quote a value for /bin/sh.
local function shq(value)
    return "'" .. tostring(value):gsub("'", [['\'']]) .. "'"
end

local function joinArgs(argv)
    local parts = {}
    for _, value in ipairs(argv) do
        parts[#parts + 1] = shq(value)
    end
    return table.concat(parts, " ")
end

local function push(argv, extra)
    for _, value in ipairs(extra) do
        argv[#argv + 1] = value
    end
    return argv
end

-- ── Paths and settings ─────────────────────────────────────────────────────

local function runtimeDir()
    local dir = noctalia.pluginDataDir()
    if dir == nil or dir == "" then
        dir = noctalia.expandPath("~/.cache/noctalia/dank-recorder")
    end
    noctalia.mkdirAll(dir)
    return dir
end

local pidFile = runtimeDir() .. "/recorder.pid"
local logFile = runtimeDir() .. "/gpu-screen-recorder.log"

local function outputDirectory()
    local configured = noctalia.string.trim(confString("output_dir", ""))
    if configured ~= "" then
        return noctalia.expandPath(configured)
    end
    local videos = noctalia.getenv("XDG_VIDEOS_DIR")
    if videos ~= nil and videos ~= "" then
        return videos .. "/Screencasts"
    end
    return noctalia.expandPath("~/Videos/Screencasts")
end

local function frameRate()
    local value = tonumber(confString("frame_rate", "60"))
    if value == 30 or value == 60 or value == 120 then
        return value
    end
    return 60
end

local function codecName()
    local value = confString("codec", "h264")
    if value == "h264" or value == "hevc" or value == "av1" then
        return value
    end
    return "h264"
end

local function containerName()
    return if confString("container", "mp4") == "mkv" then "mkv" else "mp4"
end

local function qualityName()
    local value = confString("quality", "very_high")
    if value == "medium" or value == "high" or value == "very_high" or value == "ultra" then
        return value
    end
    return "very_high"
end

local function encoderMode()
    return if confString("encoder_mode", "auto") == "cpu" then "cpu" else "auto"
end

-- Runtime audio override. Noctalia plugins cannot write their own settings, so the
-- bar's Sound button mutes for this session instead of editing `audio_source`.
local audioOverride = nil
local audioLastSource = nil

local function configuredAudioSource()
    local value = confString("audio_source", "output")
    if value == "none" or value == "output" or value == "input" or value == "both" then
        return value
    end
    return "output"
end

local function audioSource()
    if audioOverride ~= nil then
        return audioOverride
    end
    return configuredAudioSource()
end

local function audioArgument()
    local source = audioSource()
    if source == "output" then
        return "default_output"
    elseif source == "input" then
        return "default_input"
    elseif source == "both" then
        return "default_output|default_input"
    end
    return ""
end

local function audioText()
    local source = audioSource()
    if source == "none" then
        return tr("audio.muted")
    elseif source == "both" then
        return tr("audio.both")
    elseif source == "input" then
        return tr("audio.microphone")
    end
    return tr("audio.sound")
end

local function audioIcon()
    local source = audioSource()
    if source == "none" then
        return "volume-off"
    elseif source == "input" then
        return "microphone"
    elseif source == "both" then
        return "headphones"
    end
    return "volume"
end

-- ── State ──────────────────────────────────────────────────────────────────

local recState = "idle"
local elapsedSeconds = 0
local backend = ""
local canvasLabel = ""
local lastFile = ""
local lastError = ""
local tick = 0

local armed = { source = "", region = "", isRegion = false, origin = "" }
local requestId = 0
local pid = 0
local pendingFile = ""
local candidates = {}
local candidateIndex = 1
local startTick = 0
local startedAtMs = 0
local baseElapsedMs = 0

local gpus = {}
local gpuSummary = ""
local infoVendor = ""
local hardwareCodecs = {}
local capsSummary = ""

local function nextRequest()
    requestId += 1
    return requestId
end

local function publish()
    noctalia.state.set("status", {
        state = recState,
        elapsed = elapsedSeconds,
        backend = backend,
        canvas = canvasLabel,
        lastFile = lastFile,
        error = lastError,
        audioOn = audioSource() ~= "none",
        audioText = audioText(),
        audioIcon = audioIcon(),
        audioSource = audioSource(),
        target = if armed.isRegion then tr("confirm.selected-region") else tr("confirm.live-desktop"),
        isRegion = armed.isRegion,
        outputs = #noctalia.outputs(),
        gpus = gpuSummary,
        caps = capsSummary,
        outputDir = outputDirectory(),
    })
end

local function setState(next)
    if recState == next then
        return
    end
    recState = next
    log(`state -> {next}`)
    publish()
end

local function notifyInfo(key, detail)
    if confBool("notify", true) then
        noctalia.notify(tr(key), detail)
    end
end

local function notifyError(key, detail)
    if confBool("notify", true) then
        noctalia.notifyError(tr(key), detail)
    end
end

-- ── GPU inventory and encoder capabilities ─────────────────────────────────

local GPU_PROBE = table.concat({
    'for node in /dev/dri/by-path/pci-*-render; do',
    '  [ -e "$node" ] || continue;',
    '  base=$(basename "$node"); pci=${base#pci-}; pci=${pci%-render};',
    '  vendor=$(cat "/sys/bus/pci/devices/$pci/vendor" 2>/dev/null);',
    '  device=$(cat "/sys/bus/pci/devices/$pci/device" 2>/dev/null);',
    '  echo "$base|${vendor#0x}:${device#0x}|$(basename "$(readlink -f "$node")")";',
    'done',
}, " ")

local function vendorLabel(vendorId)
    local id = tostring(vendorId):lower()
    if id == "1002" then
        return "AMD"
    elseif id == "10de" then
        return "NVIDIA"
    elseif id == "8086" then
        return "Intel"
    end
    return "GPU " .. id
end

local function detectGpus()
    noctalia.runAsync({ "sh", "-c", GPU_PROBE }, function(result)
        local found = {}
        for line in (result.stdout or ""):gmatch("[^\n]+") do
            local node, ids, renderNode = line:match("^([^|]+)|([^|]*)|(.*)$")
            if node ~= nil and ids ~= nil and ids ~= "" then
                local vendor, device = ids:match("^([^:]*):?(.*)$")
                found[#found + 1] = {
                    node = node,
                    vendor = vendor,
                    device = device,
                    renderNode = renderNode,
                    label = vendorLabel(vendor),
                }
            end
        end
        gpus = found
        local summary = {}
        for _, gpu in ipairs(found) do
            summary[#summary + 1] = `{gpu.label} ({gpu.vendor}:{gpu.device})`
        end
        gpuSummary = if #summary > 0 then table.concat(summary, ", ") else tr("gpu.none")
        log(`GPUs: {gpuSummary}`)
        publish()
    end, 5000)
end

local function vendorName(vendor)
    if vendor == "nvidia" then
        return "NVIDIA"
    elseif vendor == "intel" then
        return "Intel"
    elseif vendor == "amd" then
        return "AMD"
    end
    return "GPU"
end

local function encoderKind(vendor)
    if vendor == "nvidia" then
        return "NVENC"
    elseif vendor == "intel" then
        return "Quick Sync"
    end
    return "VAAPI"
end

local function hasHardwareCodec(codec)
    for _, entry in ipairs(hardwareCodecs) do
        if entry == codec then
            return true
        end
    end
    return false
end

local function detectCapabilities()
    noctalia.runAsync({ "gpu-screen-recorder", "--info" }, function(result)
        local codecs = {}
        local vendor = ""
        local section = ""
        for raw in (result.stdout or ""):gmatch("[^\n]+") do
            local line = noctalia.string.trim(raw)
            if line ~= "" then
                if line:match("^section=") then
                    section = line:sub(9)
                elseif section == "gpu_info" and line:match("^vendor|") then
                    vendor = line:sub(8)
                elseif section == "video_codecs" and line:find("|", 1, true) == nil then
                    if not line:match("_software$") then
                        codecs[#codecs + 1] = line
                    end
                end
            end
        end
        hardwareCodecs = codecs
        infoVendor = vendor
        capsSummary = if #codecs > 0
            then vendorName(vendor) .. " · " .. table.concat(codecs, ", ")
            else tr("gpu.cpu-only")
        log(`hardware encoders: {capsSummary}`)
        publish()
    end, 5000)
end

local function preferredGpu()
    local wanted = ({ amd = "1002", nvidia = "10de", intel = "8086" })[confString("gpu_preference", "auto")]
    if wanted == nil then
        return nil
    end
    for _, gpu in ipairs(gpus) do
        if gpu.vendor == wanted then
            return gpu
        end
    end
    return nil
end

local function expectedBackend()
    if encoderMode() == "cpu" then
        return "CPU (x264)"
    end
    local codec = codecName()
    if not hasHardwareCodec(codec) then
        return `CPU (no {codec} GPU encoder)`
    end
    return `{vendorName(infoVendor)} GPU ({encoderKind(infoVendor)}, {codec})`
end

-- ── Outputs and labels ─────────────────────────────────────────────────────

local function outputByConnector(name)
    for _, output in ipairs(noctalia.outputs()) do
        if output.name == name then
            return output
        end
    end
    return nil
end

local function focusedOutput()
    local name = noctalia.focusedOutputName()
    local byName = if name ~= nil and name ~= "" then outputByConnector(name) else nil
    if byName ~= nil then
        return byName
    end
    for _, output in ipairs(noctalia.outputs()) do
        if output.focused then
            return output
        end
    end
    return nil
end

-- The connector of the display that currently has focus, or nil when the shell
-- cannot name one.
local function focusedConnector()
    local name = noctalia.focusedOutputName()
    if type(name) == "string" and name ~= "" then
        return name
    end
    local output = focusedOutput()
    if output ~= nil then
        return output.name
    end
    return nil
end

-- gpu-screen-recorder's own first monitor. `-w screen` is not "the whole desktop":
-- the man page defines it as "record the first monitor found", which is the main
-- display even when another one is focused.
local firstMonitor = ""

local function detectFirstMonitor()
    noctalia.runAsync({ "gpu-screen-recorder", "--list-monitors" }, function(result)
        local line = (result.stdout or ""):match("^[^\n]+")
        if line ~= nil then
            local name = noctalia.string.trim(line:match("^[^|]+") or "")
            if name ~= "" then
                firstMonitor = name
                log(`first monitor: {firstMonitor}`)
            end
        end
    end, 5000)
end

local function firstMonitorConnector()
    if firstMonitor ~= "" then
        return firstMonitor
    end
    local outputs = noctalia.outputs()
    if #outputs > 0 then
        return outputs[1].name
    end
    return "screen"
end

local function canvasText(source, region)
    if region ~= nil and region ~= "" then
        local width, height, x, y = region:match("^(%d+)x(%d+)%+(-?%d+)%+(-?%d+)$")
        if width ~= nil then
            return `{width} × {height}  at {x}, {y}`
        end
        return region
    end
    if source == "portal" then
        -- The portal picks the source itself; claiming a size here would be a guess.
        return "Full screen"
    end
    local output = if source == "focused" then focusedOutput() else outputByConnector(source)
    local size = if output ~= nil then `  {output.width} × {output.height}` else ""
    local label = if source == "focused" then "Full screen" else source
    return label .. size
end

local function timestamp()
    return noctalia.formatTime("%Y-%m-%d_%H-%M-%S")
end

-- ── Process control ────────────────────────────────────────────────────────

local function readPid()
    local raw = noctalia.readFile(pidFile)
    if raw == nil then
        return 0
    end
    return tonumber(noctalia.string.trim(raw)) or 0
end

local function isAlive(targetPid)
    if targetPid == nil or targetPid <= 0 then
        return false
    end
    local stat = noctalia.readFile(`/proc/{targetPid}/stat`)
    if stat == nil then
        return false
    end
    local close = stat:find(")", 1, true)
    if close == nil then
        return false
    end
    local stateChar = stat:sub(close + 2, close + 2)
    return stateChar ~= "Z" and stateChar ~= "X"
end

local function signal(targetPid, name)
    if targetPid ~= nil and targetPid > 0 then
        noctalia.runAsync({ "kill", "-" .. name, tostring(targetPid) })
    end
end

-- SIGINT first, then SIGTERM after 8 s and SIGKILL 2 s later, matching the DMS
-- timers. It runs detached so it still completes if the runtime is reloaded.
local function escalation(targetPid)
    local p = tostring(targetPid)
    local cmd = `kill -INT {p} 2>/dev/null`
        .. `; n=0; while [ $n -lt 80 ]; do [ -d /proc/{p} ] || exit 0; sleep 0.1; n=$((n+1)); done`
        .. `; kill -TERM {p} 2>/dev/null; sleep 2; kill -KILL {p} 2>/dev/null; exit 0`
    noctalia.runAsync(cmd)
end

local function logTail()
    local contents = noctalia.readFile(logFile)
    if contents == nil or contents == "" then
        return ""
    end
    if #contents > LOG_TAIL_BYTES then
        contents = contents:sub(-LOG_TAIL_BYTES)
    end
    local lines = {}
    for line in contents:gmatch("[^\n]+") do
        if noctalia.string.trim(line) ~= "" then
            lines[#lines + 1] = noctalia.string.trim(line)
        end
    end
    local tail = {}
    for index = math.max(1, #lines - 2), #lines do
        tail[#tail + 1] = lines[index]
    end
    return table.concat(tail, "\n")
end

local function currentElapsedMs()
    if recState == "recording" then
        return baseElapsedMs + (noctalia.nowMs() - startedAtMs)
    end
    return baseElapsedMs
end

-- ── Command candidates ─────────────────────────────────────────────────────

local function baseArguments(source, region, file)
    local argv = { "gpu-screen-recorder", "-w", source }
    if region ~= "" then
        push(argv, { "-region", region })
    end
    push(argv, {
        "-f", tostring(frameRate()),
        "-k", codecName(),
        "-c", containerName(),
        "-cr", "limited",
        "-cursor", if confBool("record_cursor", true) then "yes" else "no",
        "-q", qualityName(),
        "-v", "no",
    })
    local audio = audioArgument()
    if audio ~= "" then
        push(argv, { "-a", audio })
    end
    if confBool("low_power", false) then
        push(argv, { "-low-power", "yes" })
    end
    push(argv, { "-o", file })
    return argv
end

local function buildCandidates(source, region, file)
    local argv = baseArguments(source, region, file)

    if encoderMode() == "cpu" then
        -- The software encoder is h264-only; honouring a configured hevc/av1 here
        -- would make every candidate die inside the probe window.
        if codecName() ~= "h264" then
            log(`cpu encoder forces h264 (configured {codecName()})`)
        end
        local cpuArgv = baseArguments(source, region, file)
        cpuArgv[#cpuArgv + 1] = "-encoder"
        cpuArgv[#cpuArgv + 1] = "cpu"
        return { { argv = cpuArgv, env = "", file = file } }
    end

    local list = {}
    local gpu = preferredGpu()
    if gpu ~= nil then
        list[#list + 1] = {
            argv = push({ table.unpack(argv) }, { "-fallback-cpu-encoding", "yes" }),
            env = `DRI_PRIME={gpu.vendor}:{gpu.device}`,
            file = file,
        }
    end
    -- Always present: let gpu-screen-recorder pick the GPU that drives the monitor,
    -- then drop to the CPU encoder when no GPU encoder works.
    list[#list + 1] = {
        argv = push({ table.unpack(argv) }, { "-fallback-cpu-encoding", "yes" }),
        env = "",
        file = file,
    }
    return list
end

-- ── Capture flow ───────────────────────────────────────────────────────────

-- Declared ahead of their callers: the candidate chain recurses, and the arming
-- helpers below are reached from the asynchronous source resolution.
local launchCandidate, advanceCandidate, arm

local function finishStop()
    pid = 0
    setState("idle")
    elapsedSeconds = 0
    baseElapsedMs = 0
    startedAtMs = 0
    local file = pendingFile
    if file == "" then
        notifyInfo("notify.stopped", tr("notify.no-file"))
        return
    end
    -- The process can exit before writing anything when it fails during startup,
    -- so confirm the file exists before claiming it was saved.
    local info = noctalia.fileInfo(file)
    if info ~= nil and info.isDir == false and info.size > 0 then
        lastFile = file
        log(`recording saved: {file}`)
        notifyInfo("notify.saved", file)
    else
        log(`recording stopped with no output file: {file}`)
        notifyInfo("notify.stopped", tr("notify.no-file"))
    end
    publish()
end

local function handleUnexpectedExit()
    local detail = logTail()
    log(`recorder exited on its own; tail: {detail}`)
    elapsedSeconds = 0
    baseElapsedMs = 0
    startedAtMs = 0
    lastError = if detail ~= "" then detail else tr("notify.exited")
    setState("idle")
    notifyError("notify.stopped-unexpectedly", lastError)
end

local function refineBackend()
    local text = (noctalia.readFile(logFile) or ""):lower()
    if text:find("trying cpu encoding", 1, true) or text:find("cpu encoding instead", 1, true)
        or text:find("libx264", 1, true) then
        backend = "CPU (fallback)"
    elseif text:find("nvenc", 1, true) then
        backend = "NVIDIA GPU (NVENC)"
    elseif text:find("vaapi", 1, true) then
        backend = `{vendorName(infoVendor)} GPU ({encoderKind(infoVendor)})`
    else
        backend = expectedBackend()
    end
end

local function beginRecording()
    startedAtMs = noctalia.nowMs()
    baseElapsedMs = 0
    elapsedSeconds = 0
    backend = expectedBackend()
    setState("recording")
    notifyInfo("notify.started", pendingFile)
end

local function failStart()
    local detail = logTail()
    if detail == "" then
        detail = tr("notify.exited")
    end
    lastError = detail
    pid = 0
    setState("idle")
    notifyError("notify.start-failed", detail)
end

function launchCandidate()
    local candidate = candidates[candidateIndex]
    if candidate == nil then
        failStart()
        return
    end
    pendingFile = candidate.file
    pid = 0
    startTick = tick
    setState("starting")
    local prefix = if candidate.env ~= "" then candidate.env .. " " else ""
    local cmd = `echo $$ > {shq(pidFile)}; {prefix}exec {joinArgs(candidate.argv)} >> {shq(logFile)} 2>&1`
    log(`launching candidate {candidateIndex}/{#candidates}: {cmd}`)
    if not noctalia.runAsync(cmd) then
        log("runAsync refused the recorder command")
        advanceCandidate()
    end
end

function advanceCandidate()
    candidateIndex += 1
    if candidateIndex <= #candidates then
        log(`candidate failed to start, trying {candidateIndex}/{#candidates}`)
        launchCandidate()
    else
        failStart()
    end
end

local function launch(source, region)
    local launchedAt = nextRequest()
    local dir = outputDirectory()
    local file = `{dir}/{timestamp()}.{containerName()}`
    local ok, err = noctalia.mkdirAll(dir)
    if not ok then
        log(`cannot create the recording folder {dir}: {err}`)
        setState("idle")
        notifyError("notify.mkdir-failed", dir)
        return false
    end
    if launchedAt ~= requestId then
        return false
    end
    noctalia.removeFile(pidFile)
    pendingFile = file
    candidates = buildCandidates(source, region or "", file)
    candidateIndex = 1
    launchCandidate()
    return true
end

local function resolveFocusedOutput(id)
    local name = noctalia.focusedOutputName()
    if name ~= nil and name ~= "" then
        if id == requestId then
            arm(name, "")
        end
        return
    end
    noctalia.runAsync({ "gpu-screen-recorder", "--list-monitors" }, function(result)
        if id ~= requestId or recState ~= "resolving" then
            return
        end
        local first = ""
        for line in (result.stdout or ""):gmatch("[^\n]+") do
            local name = noctalia.string.trim(line:match("^[^|]+") or "")
            if name ~= "" then
                first = name
                break
            end
        end
        arm(if first ~= "" then first else "focused", "")
    end, 5000)
end

local function selectRegion(id, cancelKey)
    -- Region geometry is WxH+X+Y, which is slurp's -f format. slurp reads stdin;
    -- point it at /dev/null so it does not block before drawing its overlay.
    noctalia.runAsync("slurp -f '%wx%h+%x+%y' </dev/null", function(result)
        if id ~= requestId then
            return
        end
        local region = noctalia.string.trim(result.stdout or "")
        if result.exitCode ~= 0 or not region:match("^%d+x%d+%+%-?%d+%+%-?%d+$") then
            if recState == "resolving" then
                setState("idle")
            end
            notifyInfo(cancelKey)
            return
        end
        log(`region selected: {region}`)
        arm("region", region)
    end, 60000)
end

-- ── Confirmation bar ───────────────────────────────────────────────────────

-- Open and close are separate commands rather than a toggle: the service cannot see
-- the host's panel state, and a toggle would close the bar whenever it was already up
-- (a service restart while armed, for example). `panel-open` and `panel-close` are
-- idempotent, so the state machine stays the only source of truth.
local function showConfirmPanel()
    noctalia.runAsync({ "noctalia", "msg", "panel-open", CONFIRM_PANEL })
end

local function hideConfirmPanel()
    noctalia.runAsync({ "noctalia", "msg", "panel-close", CONFIRM_PANEL })
end

local function clearArmed()
    armed.origin = ""
    armed.source = ""
    armed.region = ""
    armed.isRegion = false
    canvasLabel = ""
end

-- Arm the recorder and show the confirmation bar. With confirmation off, start now.
function arm(source, region, origin)
    if not confBool("confirm_before_recording", true) then
        return if launch(source, region) then "started" else "failed"
    end
    armed.source = source
    armed.region = region or ""
    armed.isRegion = armed.region ~= ""
    armed.origin = origin or ""
    canvasLabel = canvasText(source, armed.region)
    setState("armed")
    publish()
    showConfirmPanel()
    return "armed"
end

local function confirmStart()
    if recState ~= "armed" then
        return "not-armed"
    end
    local source = armed.source
    local region = armed.region
    clearArmed()
    hideConfirmPanel()
    launch(source, region)
    return "started"
end

local function cancelArmed()
    if recState ~= "armed" then
        return "not-armed"
    end
    nextRequest()
    clearArmed()
    hideConfirmPanel()
    setState("idle")
    notifyInfo("notify.cancelled")
    return "cancelled"
end

local function reselectRegion()
    if recState ~= "armed" then
        return "not-armed"
    end
    selectRegion(nextRequest(), "notify.region-cancelled")
    return "selecting"
end

-- Step the armed target to the next connected display. The canvas bar exposes this
-- because the focused output is not always the display the user is working on, and
-- gsr's own keywords cannot express "the other monitor".
local function cycleOutput()
    if recState ~= "armed" then
        return "not-armed"
    end
    local names = {}
    for _, output in ipairs(noctalia.outputs()) do
        names[#names + 1] = output.name
    end
    if #names == 0 then
        return "no-outputs"
    end
    local nextName = names[1]
    for index, name in ipairs(names) do
        if name == armed.source then
            nextName = names[(index % #names) + 1]
            break
        end
    end
    nextRequest()
    return arm(nextName, "", armed.origin)
end

local function useFullScreen()
    if recState ~= "armed" then
        return "not-armed"
    end
    nextRequest()
    local target = if armed.origin ~= "" then armed.origin else focusedConnector()
    return arm(if target ~= nil then target else "focused", "", armed.origin)
end

-- ── Public actions ─────────────────────────────────────────────────────────

-- "fullscreen" is the focused display: what the canvas bar's Full screen button and
-- the popout's Full screen tile mean. "primary" stays the first monitor.
local CAPTURE_MODES = { focused = true, fullscreen = true, primary = true, monitor = true, region = true, portal = true }

local function begin(modeOverride)
    if recState == "armed" then
        notifyInfo("notify.confirm-first")
        return "armed"
    end
    if recState ~= "idle" then
        notifyInfo("notify.busy")
        return "busy"
    end
    lastError = ""
    if type(modeOverride) == "string" and not CAPTURE_MODES[modeOverride]
        and outputByConnector(modeOverride) ~= nil then
        -- `start HDMI-A-1`: an explicit connector from IPC or a keybind.
        local id = nextRequest()
        setState("resolving")
        if id == requestId then
            return arm(modeOverride, "", nil)
        end
    end

    local mode = if type(modeOverride) == "string" and CAPTURE_MODES[modeOverride] then modeOverride else nil
    if mode == nil then
        local configured = confString("capture_target", "focused")
        mode = if CAPTURE_MODES[configured] then configured else "focused"
    end

    if mode == "fullscreen" then
        mode = "focused"
    end

    local origin = pendingOrigin
    pendingOrigin = nil
    local id = nextRequest()
    setState("resolving")

    if mode == "region" then
        selectRegion(id, "notify.region-cancelled")
        return "selecting"
    end
    if origin ~= nil and (mode == "focused") then
        return arm(origin, "", origin)
    end
    if mode == "portal" then
        return arm("portal", "")
    end
    if mode == "primary" then
        return arm(firstMonitorConnector(), "")
    end
    if mode == "monitor" then
        local monitor = noctalia.string.trim(confString("monitor", ""))
        if monitor ~= "" then
            return arm(monitor, "")
        end
    end
    resolveFocusedOutput(id)
    return "started"
end

local function requestStop()
    if recState == "armed" then
        return cancelArmed()
    end
    if recState == "idle" then
        return "not-recording"
    end
    if recState == "resolving" then
        nextRequest()
        setState("idle")
        notifyInfo("notify.cancelled")
        return "cancelled"
    end
    if recState == "stopping" then
        return "stopping"
    end
    if recState == "recording" then
        baseElapsedMs = currentElapsedMs()
    end
    if pid <= 0 then
        pid = readPid()
    end
    setState("stopping")
    log(`stopping recording (pid {pid})`)
    escalation(pid)
    return "stopping"
end

local function toggleRecording()
    if recState == "idle" then
        return begin(nil)
    end
    return requestStop()
end

local function togglePause()
    if recState == "recording" then
        if pid <= 0 then
            pid = readPid()
        end
        signal(pid, "USR2")
        baseElapsedMs = currentElapsedMs()
        setState("paused")
        notifyInfo("notify.paused")
        return "paused"
    end
    if recState == "paused" then
        if pid <= 0 then
            pid = readPid()
        end
        signal(pid, "USR2")
        startedAtMs = noctalia.nowMs()
        setState("recording")
        notifyInfo("notify.resumed")
        return "recording"
    end
    return "not-recording"
end

local function toggleAudio()
    if audioSource() ~= "none" then
        audioLastSource = audioSource()
        audioOverride = "none"
        publish()
        return "muted"
    end
    audioOverride = if audioLastSource ~= nil and audioLastSource ~= "none" then audioLastSource else "output"
    publish()
    return "sound"
end

local function openFolder()
    noctalia.runAsync({ "xdg-open", outputDirectory() })
    return "opened"
end

local function openLast()
    if lastFile == "" then
        return "empty"
    end
    noctalia.runAsync({ "xdg-open", lastFile })
    return "opened"
end

local function statusJson()
    return noctalia.json.encode({
        state = recState,
        elapsed = elapsedSeconds,
        backend = backend,
        canvas = canvasLabel,
        lastFile = lastFile,
        error = lastError,
        audioSource = audioSource(),
        gpus = gpuSummary,
        caps = capsSummary,
        outputDir = outputDirectory(),
        pid = pid,
    })
end

local function formatElapsed(seconds)
    local total = math.max(0, math.floor(seconds))
    local hours = math.floor(total / 3600)
    local minutes = math.floor((total % 3600) / 60)
    local rest = total % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, rest)
    end
    return string.format("%d:%02d", minutes, rest)
end

-- ── Command dispatch ───────────────────────────────────────────────────────

local START_ACTIONS = {
    ["start"] = true,
    ["start-capture"] = true,
    ["start-fullscreen"] = true,
    ["start-region"] = true,
    ["start-portal"] = true,
    ["start-focused"] = true,
}

local function handleAction(action, payload)
    if type(action) ~= "string" then
        return
    end
    local modeOverride = if type(payload) == "string" and payload ~= "" then payload else nil

    if action == "start" or action == "start-capture" then
        return begin(modeOverride)
    elseif action == "start-region" then
        return begin("region")
    elseif action == "start-portal" then
        return begin("portal")
    elseif action == "start-fullscreen" then
        return begin("fullscreen")
    elseif action == "start-focused" then
        return begin("focused")
    elseif action == "confirm" then
        return confirmStart()
    elseif action == "cancel" then
        return cancelArmed()
    elseif action == "reselect" then
        return reselectRegion()
    elseif action == "fullscreen" then
        return useFullScreen()
    elseif action == "cycle-output" or action == "next-output" then
        return cycleOutput()
    elseif action == "stop" then
        return requestStop()
    elseif action == "toggle" then
        return toggleRecording()
    elseif action == "pause" then
        return togglePause()
    elseif action == "toggle-audio" then
        return toggleAudio()
    elseif action == "open-folder" then
        return openFolder()
    elseif action == "open-last" then
        return openLast()
    elseif action == "status" then
        local json = statusJson()
        log(`status: {json}`)
        if recState == "recording" or recState == "paused" then
            local summary = `{tr("panel.recording")} {formatElapsed(elapsedSeconds)}`
            if backend ~= "" then
                summary = summary .. " · " .. backend
            end
            noctalia.notify(tr("panel.title"), summary)
        else
            noctalia.notify(tr("panel.title"), tr("widget.tap-to-record"))
        end
        return json
    end
    log(`unknown command '{action}'`)
end

local function normalizeEvent(event)
    local text = tostring(event or "")
    return (text:gsub("(%u)", function(char)
        return "-" .. char:lower()
    end))
end

-- ── Timers ─────────────────────────────────────────────────────────────────

function update()
    tick += 1

    if recState == "starting" then
        if tick - startTick >= PROBE_TICKS then
            if pid <= 0 then
                pid = readPid()
            end
            if isAlive(pid) then
                beginRecording()
            else
                advanceCandidate()
            end
        end
    elseif recState == "recording" or recState == "paused" then
        if tick % CHECK_TICKS == 0 then
            if pid <= 0 then
                pid = readPid()
            end
            if isAlive(pid) then
                local seconds = math.floor(currentElapsedMs() / 1000)
                if seconds ~= elapsedSeconds then
                    elapsedSeconds = seconds
                    publish()
                end
            else
                handleUnexpectedExit()
            end
        end
    elseif recState == "stopping" then
        if pid <= 0 then
            pid = readPid()
        end
        if not isAlive(pid) then
            refineBackend()
            finishStop()
        end
    end
end

-- ── Lifecycle ──────────────────────────────────────────────────────────────

function onIpc(event, payload)
    handleAction(normalizeEvent(event), payload)
end

function onConfigChanged()
    log("settings changed")
    audioOverride = nil
    detectGpus()
    detectCapabilities()
    publish()
end

function onExit(_signal, reason)
    if recState == "idle" or recState == "armed" then
        return
    end
    log(`stopping capture on service exit ({tostring(reason)})`)
    if pid <= 0 then
        pid = readPid()
    end
    escalation(pid)
end

-- The pill, the tile and both panels drive the recorder through this channel.
noctalia.state.watch("command", function(command)
    local action = nil
    if type(command) == "table" then
        action = command.action
    elseif type(command) == "string" then
        action = command
    end
    -- Only a start consumes the sender's display; a stop or a pause must not leave
    -- a stale monitor behind for the next recording.
    if type(action) == "string" and START_ACTIONS[normalizeEvent(action)]
        and type(command) == "table" and type(command.output) == "string"
        and command.output ~= "" then
        pendingOrigin = command.output
    end
    if type(action) == "string" then
        log(`command '{action}'`)
        handleAction(normalizeEvent(action), nil)
    end
end)

function onOutputsChanged()
    detectFirstMonitor()
    publish()
end

log("service loaded")
detectGpus()
detectCapabilities()
detectFirstMonitor()
publish()
