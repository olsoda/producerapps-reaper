# ProducerApps for REAPER

REAPER tools by ProducerApps, distributed through [ReaPack](https://reapack.com).

## Install

1. In REAPER: Extensions → ReaPack → **Import repositories…**, and paste:
   ```
   https://github.com/olsoda/producerapps-reaper/raw/main/index.xml
   ```
2. Extensions → ReaPack → **Browse packages…**, find the tool, right-click → Install, then
   Apply.

ReaPack shows the repository as **ProducerApps**, installs the scripts under
`Scripts/ProducerApps/`, and keeps them updated.

Most tools need **ReaImGui** and **js_ReaScriptAPI**. Both are in the ReaTeam Extensions
repository, which ReaPack includes by default.

## Tools

| Tool | What it does |
|---|---|
| [Reap Detective](docs/reap-detective.md) | Beat Detective-style multitrack drum editing: detect hits on the key tracks, separate every track at them, quantize with review flags, and smooth with crossfades placed before each transient. |

## Development

ReaPack takes the top-level folder as a package's category (`Items Editing/`, ...). Each tool
is one package file with a ReaPack header (`@version`, `@author`, `@provides`, ...). Its helper
modules carry `@noindex` and ship with it through `@provides`. Files at the repository root,
`docs/` and `tests/` are not packaged.

To run a working copy in REAPER instead of the ReaPack install, link the repository into
REAPER's Scripts folder and load the scripts with Actions → New action → Load ReaScript…:

```bash
ln -s ~/programming/reap_detective ~/Library/Application\ Support/REAPER/Scripts/ProducerApps-dev
```

Don't keep the link alongside the ReaPack install, or every action will appear twice.

Run the tests with Lua 5.4+:

```bash
lua tests/run.lua && lua tests/gui_smoke.lua
```

### Releasing

Bump `@version` (and write `@changelog`) in the tool's package file, commit, and push to
`main`. The *deploy* workflow runs [reapack-index](https://github.com/cfillion/reapack-index),
which adds the new version to `index.xml` and commits it; ReaPack users get it on their next
sync. On every push, *check* validates the package headers and *test* runs the Lua tests.

To add a tool, put its package file in a category folder and push. It will show up in the
same ProducerApps repository.

## License

MIT. See [LICENSE](LICENSE).
