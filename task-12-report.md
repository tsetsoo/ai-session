# Task 12 Report: Plain SSH escape hatch

- Added `TerminalMode.plainShell`, which requests a PTY and SSH shell without invoking tmux.
- Added a `Plain SSH` host context-menu action that opens the terminal screen.
- Kept tmux attach sessions on `TerminalMode.attach`; the kill action is hidden for plain shells.
- Verification: `xcodebuild -project AISessionRemote.xcodeproj -scheme AISessionRemote -sdk iphonesimulator -configuration Debug -derivedDataPath DerivedData build` passed.
- Manual remote-shell verification was not run in this environment.
