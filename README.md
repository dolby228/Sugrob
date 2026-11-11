# Sugrob

Snow for your Mac desktop: flakes fall over everything, pile up on top of windows and the Dock, and can be swept away, rolled into snowballs and stacked into a snowman. Clicks go straight through the snow.

> Work in progress.

## Requirements

- macOS 13+
- Swift 5.9+ (Xcode 15 or newer)

## Build

```bash
swift build
swift test
./scripts/bundle.sh   # produces dist/Sugrob.app
```

CI builds the app on every pull request. The zipped `Sugrob.app` is uploaded as a workflow artifact.
