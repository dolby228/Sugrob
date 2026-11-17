# Changelog

All notable changes to Sugrob are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-17

First public release.

### Added

- Snow falls over the whole desktop on every screen and piles up into drifts on the top edges of windows and on the Dock; clicks go through the snow.
- Mitten: sweeps drifts and knocks falling flakes out of the air.
- Shovel: scoops snow and throws it as one clump that lands as a pile.
- Snowballs (hold ⌥ and drag along a drift); three stacked balls become a snowman.
- Menu bar controls: pause, snowfall (light / steady / blizzard), wind, tool, clear; global hotkeys ⌃⌥⌘S, ⌃⌥⌘,, ⌃⌥⌘K, ⌃⌥⌘Q.
- Settings window, Dock icon with a context menu, start at login, diagnostics report.
- Exact Dock size through Accessibility, offered once after the first launch in a small non-modal panel; the grant survives updates (ad-hoc signature with a designated requirement on the bundle identifier); a one-click reset for grants left by older builds.
- Dock width estimate from the Dock preferences when Accessibility is not granted.

### Fixed

- Snow and snowmen survive a Space switch, ⌘H and minimize; snow crumbles only when a window really closes.
- ⌥-click on another window no longer hides the snow layer.
- The mitten no longer sweeps snow hidden behind a front window; no trench after a cursor jump.
- ⌥ snowballs: no swallowed clicks on thin snow or at the ball limit, ⌥ works with a still cursor.
- A carried shovel load no longer takes over clicks on buttons; no snow lost when the shovel crosses screens.
- Even snowfall in wind; no flake streams along window sides.
- Dock frame is read off the main thread (no stutter), stays put while the Dock magnifies, and is hidden with auto-hide and in full-screen Spaces.
- The settings window no longer pops up by itself with an auto-hidden menu bar or in full screen.
- A login item waiting for approval can be turned off.

### Changed

- Smaller snowman and lower drifts.
- Lower CPU use while paused and while drifts are at rest.

[Unreleased]: https://github.com/dolby228/Sugrob/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/dolby228/Sugrob/releases/tag/v0.1.0
