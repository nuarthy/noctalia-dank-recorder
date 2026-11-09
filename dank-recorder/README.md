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
| Plugin API | 36 |
| Entries | service `service`, bar widget `recorder`, shortcut `toggle`, panel `popout`, layer `confirm` |

## Requirements

- Noctalia v5.4.1 or later (the canvas bar is a `[[layer]]`, plugin API 36)
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
ln -sfn ~/Projects/noctalia-dank-recorder/dank-recorder ~/.local/share/noctalia/plugins/dank-recorder
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

The glyph alone carries the state: a grey camera when idle, the same camera in the accent
colour while a recording is armed and waiting for confirmation, a red stop square while it
runs. A vertical pill shows no wording - the capsule only has room for numbers.

**The pill is on the bar only while a recording is active.** That is the widget setting
**Keep the pill on the bar while idle**, off by default; turn it on from the pill's own
settings (middle-click the pill, or **Settings → Bar**) to keep a camera you can click to
start a recording. A hidden pill takes no space and no clicks, so start from a keybinding,
the control-center tile or the popout instead.

On a vertical bar the pill stacks the timer the way the built-in clock stacks its time:
minutes on the top line, seconds below (`0` / `42`), above nothing but the stop square.
A horizontal bar gets the inline form instead (`0:42`). The control-center tile shows the
same timer as its label while a recording runs, so the running time is visible wherever
you started it.

`barWidget.isVertical()` answers `false` for a side bar in Noctalia 5.3.0, so when it does,
the pill reads the bar's `position` from the shell config once per load instead of trusting
it.

The pill records the display **its bar sits on**: the command carries
`barWidget.outputName()`, so a pill on a second monitor captures that monitor even when
keyboard focus is elsewhere. The control-center tile sends `noctalia.focusedOutputName()`
from its own script snapshot, which the service cannot see on the command channel, and the
popout inherits the display of the pill that opened it. A keybinding or `noctalia msg`
start has no display of its own and follows the focused output; pass a connector
(`start HDMI-A-1`) to pin one.

The canvas bar shows the connector it was placed on, as a chip beside **Move**, so the bar
names its display while the screen shows where it actually appeared.

Clicking a recording pill shows `Stop?`. Click it again within three seconds to stop;
otherwise the pill returns to the elapsed time.

### Canvas confirmation bar

Before a recording starts, a bar appears over the screen that will be captured. It shows
the canvas and offers six actions:

The bar is a `[[layer]]`, so the plugin owns its geometry: the surface is exactly the card,
it appears on the display that will be recorded, and it reserves no screen space. The
surface is sized to its content and anchored to a single edge, which centres it horizontally
and keeps the card's own padding however many controls it holds; it sits along the bottom or
the top. **Move** swaps the two edges, and the service remembers the choice, so the next
recording starts in the same place. The bottom position anchors to the bottom edge, which
keeps the bar above the shell's own bar instead of over it.

Noctalia gives a layer's script no pointer events except the ones its own controls consume,
so the bar cannot be dragged by its background: **Move** is the equivalent control. The
starting edge is the **Canvas bar position** setting under **Settings → Plugins → Dank
Recorder**; changing it there takes precedence over the last **Move**.

| Button | Result |
| --- | --- |
| Move (arrows) | Swap the bar between the bottom and top edges. The choice is remembered. |
| Display (monitor icon) | Step the target to the next connected display. The bar moves to that display and the canvas label follows. Enabled when more than one display is connected. |
| Full screen | Capture the whole focused display. Enabled while a region is selected. |
| Region | Select the canvas again with `slurp`. The bar hides while the selection is open. |
| Sound / Muted | Include desktop audio, or mute. The source comes from the Audio setting. |
| Cancel | Discard the pending recording. |
| Start recording | Begin the recording. |

Only the bar itself takes pointer input, and it never takes keyboard focus, so a recording
started from here does not steal the keyboard from the window underneath. Turn the whole
step off with **Confirm before recording**.

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
noctalia msg plugin nuarthy/dank-recorder:service all start HDMI-A-1  # Show the bar for that display
noctalia msg plugin nuarthy/dank-recorder:service all start-region   # Select a region, then show the canvas bar
noctalia msg plugin nuarthy/dank-recorder:service all start-portal   # Start through the desktop portal
noctalia msg plugin nuarthy/dank-recorder:service all start-fullscreen  # Use the whole screen as the canvas
noctalia msg plugin nuarthy/dank-recorder:service all confirm        # Start the pending recording
noctalia msg plugin nuarthy/dank-recorder:service all cancel         # Discard the pending recording
noctalia msg plugin nuarthy/dank-recorder:service all reselect       # Select the region again
noctalia msg plugin nuarthy/dank-recorder:service all fullscreen     # Use the whole armed display as the canvas
noctalia msg plugin nuarthy/dank-recorder:service all cycle-output   # Step the armed target to the next display
noctalia msg plugin nuarthy/dank-recorder:service all move-confirm   # Swap the canvas bar between the bottom and top edges
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
| Canvas bar position | Bottom | Show the canvas bar along the bottom or the top edge. The bar's **Move** control swaps the two. |
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

The bar pill also has one setting of its own, in its widget menu (**Keep the pill on the
bar while idle**, off by default). Each pill instance keeps its own copy, so a pill on one
bar can stay visible while another one stays out of the way.

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

The plugin keeps a candidate list. The 2.5 s probe window is a deadline, not a fixed wait:
as soon as the recorder has written its container header, 250-350 ms after launch, the
recording counts as running, so the pill, the timer and the **Recording started**
notification follow the first frames instead of trailing them by the rest of the window. A
candidate that dies before that hands over to the next one at once. A candidate that is
still alive at the deadline is accepted without a file, which is what the portal target
looks like while its picker is open. The last candidate always allows the CPU fallback. The
recorder's own output is captured in
`~/.local/state/noctalia/plugins/data/nuarthy/dank-recorder/gpu-screen-recorder.log`, and
its last lines appear in the failure notification.

## Differences from the DMS plugin

The recording logic, states, button set and labels are the same. One timing changed: the
probe window ends when the recorder writes its first bytes instead of always running for
2.5 s, so the start notification is not late (see
[How the GPU fallback works](#how-the-gpu-fallback-works)). Three things differ because the
host platform does:

- **The canvas bar is a layer the plugin places, and Move replaces dragging.** The DMS bar
  could be dragged by its background. Noctalia's plugin API has no pointer press, move or
  release on a container - only its own controls (buttons, sliders, graphs) receive
  pointer input - so a bar script cannot follow a drag. The bar is therefore a `[[layer]]`
  whose position the service sets with `noctalia.layer.configure()`, and its **Move**
  control swaps it between the bottom and top edges. Nothing else about the bar changed.
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
