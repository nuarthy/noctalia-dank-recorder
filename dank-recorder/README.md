# Dank Recorder

A screen recorder plugin for [Noctalia](https://docs.noctalia.dev/noctalia/) v5, ported
from the [Dank Material Shell](https://github.com/AvengeMedia/DankMaterialShell) plugin
[nuarthy/dank-recorder](https://github.com/nuarthy/dank-recorder). It drives
[`gpu-screen-recorder`](https://git.dec05eba.com/gpu-screen-recorder/about), keeps the
same state machine, the same canvas confirmation bar and the same controls.

The recorder captures the monitor directly through KMS, so it needs no portal and works
with the discrete GPU powered off. When no hardware encoder is usable the recording
continues on the CPU.

| Field | Value |
| --- | --- |
| ID | `nuarthy/dank-recorder` |
| Plugin API | 34 |
| Entries | service `service`, bar widget `recorder`, shortcut `toggle`, panels `popout` and `confirm` |

## Requirements

- Noctalia v5.3.0 or later
- `gpu-screen-recorder` on `PATH` (the native package, not the Flatpak GUI build)
- `slurp` for region selection (optional)
- A working PipeWire session for audio (optional)

```shell
# Fedora
sudo dnf install gpu-screen-recorder slurp
# Arch Linux
sudo pacman -S gpu-screen-recorder slurp
# Debian and Ubuntu
sudo apt install gpu-screen-recorder-cli slurp
```

## Install

Noctalia loads plugins from `$XDG_DATA_HOME/noctalia/plugins/<plugin>`. Symlink this
checkout there, then enable the plugin once:

```shell
ln -sfn ~/Projects/noctalia-dank-recorder ~/.local/share/noctalia/plugins/dank-recorder
noctalia msg plugins enable nuarthy/dank-recorder
```

Edits to `.luau` files reload automatically; `noctalia msg config-reload` picks up
manifest changes.

## Place the controls

Add the bar pill to a bar in `~/.config/noctalia/settings.toml` (or through
**Settings → Bar**):

```toml
[bar.default]
end = [ "tray", "clock", "nuarthy/dank-recorder:recorder" ]
```

Add the control-center tile the same way:

```toml
[[control_center.shortcuts]]
type = "nuarthy/dank-recorder:toggle"
```

The control center shows up to six shortcuts, so drop one of the others if the row is
full.

## Use

| Action | Result |
| --- | --- |
| Left-click the bar pill | Start. The canvas bar appears first. |
| Right-click the bar pill | Open the popout with every control. |
| Control-center tile | Toggle the recorder. |

The pill records the display **its bar sits on**: the command carries
`barWidget.outputName()`, so a pill on a second monitor captures that monitor even when
keyboard focus is elsewhere. Keybindings and the control-center tile have no display of
their own and follow the focused output.

Clicking a recording pill shows `Stop?`. Click it again within three seconds to stop;
otherwise the pill returns to the elapsed time.

### Canvas confirmation bar

Before a recording starts, a bar appears at the bottom centre of the screen. It shows the
canvas that will be captured and offers five actions:

The plugin adds no padding of its own. Noctalia gives every panel a fixed inset, and it
places a tree whose height it has to infer slightly low - an auto-height row ended up
13 px from the top edge and 7 px from the bottom. Declaring the row's height
(`height = 42`) removes that guesswork: the measured margins are 15 px above and 16 px
below at 1.2 scale, i.e. equal within a pixel. Panel `height` values between 36 and 200
all render the same card, so the inset itself is not something a plugin can remove.
Place the bar at any screen anchor through the panel's injected **Position** setting
(**Settings → Plugins → Dank Recorder**, or the `confirm_position` key below);
`bottom_center` is the default.

```toml
[plugin_settings."nuarthy/dank-recorder"]
confirm_position = "bottom_left" # top_left … bottom_right, center
```

| Button | Result |
| --- | --- |
| Full screen | Capture the whole focused display. Enabled while a region is selected. |
| Region | Select the canvas again with `slurp`. |
| Sound / Muted | Include desktop audio, or mute. The source comes from the Audio setting. |
| Cancel | Discard the pending recording. |
| Start recording | Begin the recording. |

Only the bar itself takes pointer input, and it takes keyboard focus only when clicked.
Turn the step off with **Confirm before recording**.

Recordings are saved to `~/Videos/Screencasts` by default, or to the XDG videos folder's
`Screencasts` subdirectory when `XDG_VIDEOS_DIR` is set.

### Popout

The popout offers **Full screen** and **Region** tiles when idle, **Stop recording** and
**Pause**/**Resume** while a recording is active, and shortcuts to the output folder and
the most recent file. It also reports the detected GPUs and the hardware encoders
`gpu-screen-recorder --info` lists.

### Keybindings

Use the service entry, which is a singleton:

```kdl
// niri
binds {
    Mod+Shift+R { spawn "noctalia" "msg" "plugin" "nuarthy/dank-recorder:service" "all" "toggle"; }
    Mod+Shift+S { spawn "noctalia" "msg" "plugin" "nuarthy/dank-recorder:service" "all" "start-region"; }
}
```

### IPC commands

```shell
noctalia msg plugin nuarthy/dank-recorder:service all start          # Resolve the target, then show the canvas bar
noctalia msg plugin nuarthy/dank-recorder:service all start-region   # Select a region, then show the canvas bar
noctalia msg plugin nuarthy/dank-recorder:service all start-portal   # Start through the desktop portal
noctalia msg plugin nuarthy/dank-recorder:service all start-fullscreen  # Use the whole screen as the canvas
noctalia msg plugin nuarthy/dank-recorder:service all confirm        # Start the pending recording
noctalia msg plugin nuarthy/dank-recorder:service all cancel         # Discard the pending recording
noctalia msg plugin nuarthy/dank-recorder:service all reselect       # Select the region again
noctalia msg plugin nuarthy/dank-recorder:service all fullscreen     # Use the whole screen as the canvas
noctalia msg plugin nuarthy/dank-recorder:service all stop           # Stop and save
noctalia msg plugin nuarthy/dank-recorder:service all toggle         # Start or stop
noctalia msg plugin nuarthy/dank-recorder:service all pause          # Pause or resume
noctalia msg plugin nuarthy/dank-recorder:service all toggle-audio   # Mute or unmute for this session
noctalia msg plugin nuarthy/dank-recorder:service all status         # Log the state as JSON
noctalia msg plugin nuarthy/dank-recorder:service all open-folder    # Open the output folder
noctalia msg plugin nuarthy/dank-recorder:service all open-last      # Open the last recording
```

The camel-case names of the original plugin (`startRegion`, `toggleAudio`, `openFolder`,
`openLast`) are accepted too. `status` writes the JSON to
`~/.cache/noctalia/noctalia.log` and shows a notification, because plugin IPC has no
return channel.

## Settings

| Setting | Default | Notes |
| --- | --- | --- |
| Confirm before recording | On | Show the canvas bar before each recording. |
| Capture target | Focused output | Focused output, first monitor, a named monitor, a region, or the portal. |
| Monitor name | empty | Connector name such as `eDP-1` or `HDMI-A-1`. |
| Frame rate | 60 | 30, 60, or 120 FPS. |
| Quality | Very high | Constant-quality preset. |
| Video codec | H.264 | HEVC and AV1 can produce black bars on AMD. |
| Container | MP4 | MKV survives an interrupted recording better. |
| Audio | Desktop output | None, desktop output, output and microphone, or microphone. The canvas bar's Sound button mutes for the session without changing this. |
| Record the cursor | On | Include the mouse pointer. |
| Encoder | Auto | Auto uses the GPU encoder and drops to the CPU. CPU forces software encoding. |
| GPU preference | Automatic | Best effort. See below. |
| Low power mode | Off | Lets the AMD GPU drop to a lower power state. |
| Notifications | On | Show a notification when a recording starts, stops, or fails. |
| Output folder | empty | Empty uses the XDG videos folder, or `~/Videos/Screencasts`. |

## How the GPU fallback works

Every target is an explicit connector (`-w HDMI-A-1`), never gsr's `screen` keyword: the
man page defines `-w screen` as "record the first monitor found", which is the main
display even when another one is focused, and it made the canvas bar advertise one screen
while recording another. The first-monitor setting resolves `gpu-screen-recorder
--list-monitors` to a name, and the full-screen action keeps whichever display the bar was
armed on.

`gpu-screen-recorder` encodes on the GPU that drives the captured monitor, so the plugin
uses two mechanisms:

1. **GPU preference.** Selecting AMD, NVIDIA, or Intel pins that DRM device with
   `DRI_PRIME`. If the device is absent the driver ignores the request.
2. **Encoder fallback.** Every attempt passes `-fallback-cpu-encoding yes`, so a missing
   or failing GPU encoder drops to the CPU.

The plugin keeps a candidate list. When the preferred candidate exits inside its 2.5 s
probe window, the next candidate runs; the last one always allows the CPU fallback. The
recorder's own output is captured in
`~/.local/state/noctalia/plugins/data/nuarthy/dank-recorder/gpu-screen-recorder.log`, and
its last lines appear in the failure notification.

## Differences from the DMS plugin

The recording logic, states, button set, labels, and timings are the same. Three things
differ because the host platform does:

- **The canvas bar is a panel, not a layer surface.** Noctalia 5.3 supports plugin API 34
  and `[[layer]]` needs 36, so the bar is a persistent floating `[[panel]]`. It has the
  same contents and appears only while armed, but the plugin cannot drag it: a panel's
  geometry is host-owned, and the only positional control is the screen anchor above.
  The bar carries no padding of its own; the shell's panel inset sets the margin (15/16 px
  at these control sizes) and no plugin-side value changes it - negative padding is
  ignored, and panel heights from 36 to 200 px render the same card. Assigning the row an
  explicit height is what keeps the top and bottom margins equal.
  On a Noctalia that supports plugin API 36 the entry can be swapped for a `[[layer]]`
  with `anchors = ["bottom"]`, `height = 0` and `exclusive_zone = -1`, which drops the
  panel chrome; the plugin API still has no pointer-drag hook, so drag-to-move would come
  only from the shell.
- **Sound is a session mute.** Plugins cannot write their own settings, so the Sound
  button overrides the Audio setting until the shell restarts instead of persisting
  `none`.
- **No `status` return value.** Plugin IPC calls have no reply channel, so `status` logs
  its JSON and shows a summary notification.

## Troubleshooting

- **The recording starts, then stops in a few seconds.** The capture source is invalid.
  Select **Focused output** or a named monitor, and run
  `gpu-screen-recorder --list-monitors` to list monitors.
- **The video shows black bars.** Use H.264.
- **No audio in the file.** Check the Audio setting, confirm PipeWire runs
  (`systemctl --user status pipewire`), and check that the canvas bar does not say
  `Muted`.
- **The plugin reports a missing binary.** Install `gpu-screen-recorder` and enable the
  plugin again.
- **Nothing happens on a click.** Check `noctalia plugins lint` in the plugin directory
  and `~/.cache/noctalia/noctalia.log` for `dank-recorder:` lines.

## License

MIT. See [LICENSE](LICENSE).
