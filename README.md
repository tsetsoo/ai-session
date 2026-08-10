# AI Session Remote

An iOS app for managing remote hosts and AI coding sessions.

## Requirements

- Xcode 16 or later
- XcodeGen (`brew install xcodegen`)

## Generate and open

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
open AISessionRemote.xcodeproj
```

The project uses the local `AISessionCore` Swift package and targets iOS 17 or later.

## Build from the command line

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -scheme AISessionRemote \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build
```
