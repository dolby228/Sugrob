# Sugrob

Snow for your Mac desktop. Flakes fall over everything, pile up into drifts on top of windows and the Dock, and can be swept away, shovelled, rolled into snowballs and stacked into a snowman. Clicks go straight through the snow.

Landing with a live demo: https://dolby228.github.io/Sugrob/

## Install

1. Download `Sugrob.zip` from the [latest release](https://github.com/dolby228/Sugrob/releases/latest) (or the `Sugrob-app` artifact of any CI run).
2. Unzip and move `Sugrob.app` to `/Applications`.
3. The app is signed ad-hoc, not notarized: open it with right click → **Open** the first time.

A snowflake appears in the menu bar. There is no Dock icon.

Requirements: macOS 13 or newer, Apple Silicon or Intel.

## Usage

| What | How |
| --- | --- |
| Pause / resume | Menu bar → **Пауза** |
| Snowfall | **Снегопад**: Лёгкий, Ровный, Метель |
| Wind | **Ветер**: calm or one of four directions |
| Mitten | **Инструмент → Варежка**, then move the cursor through a drift to sweep it |
| Shovel | **Инструмент → Лопата**, drag along a drift to scoop, release to throw the load as one clump |
| Snowball | Hold ⌥ and drag along a drift, release to throw. Three stacked balls become a snowman |
| Clear everything | **Очистить сугробы** |
| Start at login | **Запускать при входе** |

Global mouse monitors only observe events, they never swallow them: the app under the cursor still receives the same click or drag.

## Privacy

Sugrob reads only window bounds via `CGWindowListCopyWindowInfo`. It does not read window contents or titles, needs no Screen Recording or Accessibility permission and makes no network requests.

## Build

```bash
swift build
swift test
./scripts/check-shaders.sh   # compile Metal shaders offline
./scripts/bundle.sh          # dist/Sugrob.app
```

Landing:

```bash
cd web
npm install
npm run dev
```

Pushing a `v*` tag publishes a GitHub release with `Sugrob.zip`.

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/SnowCore` | Platform-independent simulation: flakes, wind, drifts, snowballs, snowmen, shovel |
| `Sources/Sugrob/Overlay` | Transparent click-through windows, one per screen |
| `Sources/Sugrob/Windows` | Window and Dock tracking, coordinate conversion |
| `Sources/Sugrob/Render` | Metal renderer, power-aware particle budget |
| `Sources/Sugrob/Input` | Global mouse input for the tools |
| `Sources/Sugrob/MenuBar`, `Settings` | Menu bar controls and persisted preferences |
| `web` | Landing page with an interactive canvas demo |

## Debugging

- Show tracked window outlines: run with `SUGROB_DEBUG_WINDOWS=1 /Applications/Sugrob.app/Contents/MacOS/Sugrob` or enable **Показывать контуры окон** in the menu. Red lines must hug the top edges of windows.
- Logs: `log stream --predicate 'subsystem == "dev.sugrob"' --level debug` (categories `tracker`, `render`, `input`).
- If no snow appears but outlines do, Metal setup or shader compilation failed: check the `render` log.

More notes for contributors are in [`CLAUDE.md`](CLAUDE.md).
