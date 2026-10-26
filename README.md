# Dank Recorder

Noctalia v5 screen recorder plugin. The plugin lives in [`dank-recorder/`](dank-recorder/);
`catalog.toml` indexes it so this repository can be added as a Noctalia plugin source:

```shell
noctalia msg plugins source add nuarthy git https://github.com/nuarthy/noctalia-dank-recorder
```

To work on it locally instead, symlink the plugin directory into the plugin folder:

```shell
ln -sfn ~/Projects/noctalia-dank-recorder/dank-recorder ~/.local/share/noctalia/plugins/dank-recorder
noctalia msg plugins enable nuarthy/dank-recorder
```

See [dank-recorder/README.md](dank-recorder/README.md) for requirements, settings, IPC commands and the differences from the DMS original.

MIT licensed.
