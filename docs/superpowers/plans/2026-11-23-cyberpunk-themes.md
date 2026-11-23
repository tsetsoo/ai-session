# Cyberpunk App Themes (Neon noir + Phosphor) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two switchable full-app skins, Neon noir and Phosphor, on Mac and iPhone. Each has its
own colors, terminal palette, styling, app icon and sounds. Standard stays exactly as it is today.

**Architecture:** An `@Observable` `SkinStore.shared` holds the selected `AppSkin`, kept in
UserDefaults under `app.skin`. `DS` and `AppTheme` color tokens become computed and switch on
`SkinStore.shared.skin`. SwiftUI tracks the read in any `body`, so a change re-renders without a
root `.id`. A `.skinned()` modifier at every scene root applies tint, color scheme, font design
and background. A few shared modifiers carry the non-color styling. The terminal palette, sounds
and icons are chosen by skin. The hub gets one optional per-device `sound` field for APNs.

**Tech Stack:** Swift 5.9 / SwiftUI (iOS 17, macOS 14), XcodeGen, XCTest; Rust (todo-server,
rusqlite); Python 3 + `afconvert` for the sounds; a Swift/CoreGraphics script for the icons.

**Spec:** `docs/superpowers/specs/2026-11-23-cyberpunk-themes-design.md`. Approved mockups are in
`.superpowers/brainstorm/60992-1795441653/content/direction.html` (A and C) and `icons-sounds.html`.

## Global Constraints

- Standard must be pixel-identical to today. Every token's `.standard` branch returns exactly the
  current expression (same hex values, same `.red`/`.green`/`.orange`/... system colors).
- The skins are dark only. With a skin on, the scene roots use `.preferredColorScheme(.dark)`,
  and the Terminal picker (System, Light, Dark) is hidden.
- No `.id(...)` on a root view to force a re-render. Switching must not tear down `TerminalView`s
  or SSH sessions.
- No animation added by the skins (no flicker, no pulsing glow). Glow is a static `.shadow`.
- Phosphor's scanlines and text glow apply **only** to the terminal surface. Neon noir has glow
  and no scanlines.
- Nothing writes into the app bundle at runtime. On the Mac, only `NSApp.applicationIconImage`
  changes. Signing stays Apple Development team `233QTK6KCL`.
- The skin is per device and isn't synced. The hub only receives a sound filename.
- Sounds are original synthesis (no samples), peak at −6 dBFS, `.caf`, 44.1 kHz mono Int16, made
  by `scripts/make-attention-sounds.py`.
- The anchor hex values are from the spec. Neon noir: window `#0B0A1A`, sidebar `#110F26`,
  terminal `#07061A`, text `#D9D6FF`, accent `#FF2E97`, status cyan `#00F0FF`, purple `#B967FF`,
  green `#39FF88`, yellow `#FFE45C`. Phosphor: background `#020A04`, surface `#031207`, green
  `#33FF77`.

## Review Focus

1. **Switching skins while a terminal is connected.** Expected: the colors change live, and the
   SSH session, scrollback and tmux attachment survive. The tmux reporter sends a dark notice
   when you go from Standard light to a skin. Tested by Task 3
   (`testSkinPalettesReportDark`), plus the Task 11 hand check.
2. **Standard regressions.** Expected: someone who never touches the picker sees no change, and
   the existing `DesignSystemTests` and `TerminalAppearanceTests` still pass. Tested by Task 2
   (`testStandardTokensMatchToday`).
3. **Legibility of dimmed or ANSI text in the skins.** Expected: the default foreground is at
   least 7:1 on the background, and every ANSI color except index 0 (black) is at least 3:1, so
   Claude's dimmed text and diffs stay readable. Tested by Task 3 (`testSkinPalettesAreLegible`).
4. **An old app or an existing device row talking to the new hub.** Expected: no `sound` field
   means `"default"`, and quiet-hours (passive) pushes stay silent even with a sound stored.
   Tested by Task 8 (`push_sound_defaults_and_passive_stays_silent`).
5. **A bad sound name sent to the hub.** Expected: anything other than a known
   `attention-….caf` name is rejected with 400 and nothing is stored, so a client can't inject
   arbitrary APNs fields. Tested by Task 8 (`push_sound_rejects_unknown_names`).

---

### Task 1: Skin model and store

**Files:**
- Create: `ai-session-remote/App/AISessionRemote/Theme/Skin.swift`
- Test: `ai-session-remote/App/AISessionRemoteTests/SkinTests.swift`

**Interfaces:**
- Produces:
  - `enum AppSkin: String, CaseIterable, Identifiable { case standard, neonNoir, phosphor }`
  - `var displayName: String` ("Standard", "Neon noir", "Phosphor")
  - `var isDark: Bool` (true for both skins)
  - `var soundSuffix: String?` (nil, "neon-noir", "phosphor")
  - `var iconName: String?` (nil, "AppIcon-NeonNoir", "AppIcon-Phosphor")
  - `@MainActor @Observable final class SkinStore { static let shared: SkinStore; static let defaultsKey = "app.skin"; var skin: AppSkin; init(defaults: UserDefaults = .standard) }`
  - Setting `skin` writes the raw value to `defaults`. An unknown or missing value reads as `.standard`.

- [ ] **Step 1: Write the failing tests** in `SkinTests`:
  - `testDefaultsToStandard`: a fresh suite (`UserDefaults(suiteName: UUID().uuidString)!`) gives `.standard`.
  - `testPersistsSelection`: set `.phosphor`, then a new `SkinStore(defaults:)` on the same suite gives `.phosphor`.
  - `testUnknownRawValueFallsBack`: `defaults.set("vaporwave", forKey: "app.skin")` gives `.standard`.
  - `testMetadata`: `AppSkin.neonNoir.soundSuffix == "neon-noir"`, `AppSkin.standard.iconName == nil`, `AppSkin.phosphor.isDark == true`, `AppSkin.standard.isDark == false`.
- [ ] **Step 2: Run** `cd ai-session-remote && xcodegen generate && xcodebuild test -scheme AISessionRemote -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:AISessionRemoteTests/SkinTests CODE_SIGNING_ALLOWED=NO`. Expected: FAIL (doesn't compile). If that simulator is missing, use any one from `xcrun simctl list devices available`.
- [ ] **Step 3: Implement** `Skin.swift` as specified.
- [ ] **Step 4: Run the same command.** Expected: PASS.
- [ ] **Step 5: Commit** `Add AppSkin and SkinStore`.

### Task 2: Skin-aware design tokens

**Files:**
- Modify: `ai-session-remote/App/AISessionRemote/Theme/DesignSystem.swift`
- Modify: `ai-session-remote/App/AISessionRemote/Theme/AppTheme.swift` (`color(for:)`, `reachabilityColor`)
- Test: `ai-session-remote/App/AISessionRemoteTests/DesignSystemTests.swift` (add tests; keep the existing ones)

**Interfaces:**
- Consumes: `SkinStore.shared.skin`, `AppSkin`.
- Produces: the existing `DS` members become `static var` with the same names and types:
  `accent`, `accentSolid`, `accentTint`, `accentOnTint`, `onAccent`, `error`, `warning`,
  `chipFill`. These new `DS` tokens are added (all `Color` unless noted):
  - `success`: Standard `.green`
  - `info`: Standard `.blue`
  - `attention`: Standard `.orange`
  - `merged`: Standard `.purple`
  - `star`: Standard `.yellow`
  - `destructive`: Standard `.red`
  - `diffAdded`: Standard `.green`
  - `diffRemoved`: Standard `.red`
  - `windowBackground` and `surface` (`Color?`, see below)
  - `selectionFill`
  - `selectionStroke`

  Also new:
  - `static var glow: Color?`: nil for Standard and Phosphor, magenta for Neon noir.
  - `static func radius(_ base: CGFloat) -> CGFloat`: `base` for Standard and Neon noir, `0` for Phosphor.
  - `static var skin: AppSkin { SkinStore.shared.skin }`, used internally by the tokens.
  - `windowBackground` and `surface` are `Color?`, nil for Standard (meaning: don't paint, keep the system backgrounds).
- Each token is `switch skin { case .standard: <today's exact value>; case .neonNoir: …; case .phosphor: … }`.
- The non-Standard values use the anchors from Global Constraints. In Phosphor, `error`, `warning`, `destructive` and `diffRemoved` are a red-amber (around `#FF5F4A`), `warning` and `attention` are amber (around `#FFC447`), `diffAdded` and `success` are `#33FF77`, and `info` is `#7DFFB0`. `selectionFill` is `#33FF77` with `onAccent` set to `#020A04` (the inverted row). In Neon noir, `error` is around `#FF5A4E` and `warning` around `#FFB648`, which keeps them distinct from the `#FF2E97` accent.

- [ ] **Step 1: Write the failing tests:**
  - `testStandardTokensMatchToday`: with `SkinStore.shared.skin = .standard`, `UIColor(DS.accent)` resolved light is `#B4532E` and dark is `#E8916F`; `DS.error` light is `#C4302B`; `DS.success == .green`; `DS.windowBackground == nil`; `DS.radius(10) == 10`; `DS.glow == nil`.
  - `testPhosphorTokens`: with skin `.phosphor`, `DS.radius(10) == 0`, and `UIColor(DS.accent)` resolved dark is `#33FF77`.
  - `testNeonNoirAccentIsDistinctFromError`: the RGB distance between `DS.accent` and `DS.error` is above 0.25 (each channel 0–1, Euclidean).
  - Every test resets `SkinStore.shared.skin = .standard` in `tearDown`.
- [ ] **Step 2: Run** `-only-testing:AISessionRemoteTests/DesignSystemTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the tokens. Give `AppTheme.color(for:)` and `reachabilityColor` the same `switch` (Standard unchanged; skins: Claude `#FF2E97` or `#33FF77`, Codex `#00F0FF` or `#7DFFB0`, Cursor and Shell lavender `#B9B6E8` or `#1FAF55`).
- [ ] **Step 4: Run** the full suite `-only-testing:AISessionRemoteTests`. Expected: PASS, including `testAccentAssetMatchesDesignSystemAccent`.
- [ ] **Step 5: Commit** `Make design tokens follow the app skin`.

### Task 3: Skin terminal palettes

**Files:**
- Modify: `ai-session-remote/App/AISessionRemote/Theme/TerminalAppearance.swift`
- Modify: the five `@AppStorage("terminal.theme")` readers so they call the new `palette(...)`:
  - `Terminal/TerminalScreen.swift:686`
  - `Views/Frame/FrameStateView.swift:78`
  - `Views/Frame/ConversationFrame.swift:1560`
  - `Views/Frame/ConversationFrame.swift:1577`
  - `Views/Frame/TerminalSurface.swift:429`
- Modify: `ai-session-remote/Sources/AISessionCore/Board/TerminalContrastGuard.swift`: make `static func contrast(_:_:)` `public`.
- Test: `ai-session-remote/App/AISessionRemoteTests/TerminalAppearanceTests.swift`

**Interfaces:**
- Produces:
  - `static let neonNoir: TerminalPalette`, `static let phosphor: TerminalPalette`
  - `TerminalAppearance.palette(theme: TerminalTheme, colorScheme: ColorScheme, skin: AppSkin) -> TerminalPalette`: a skin overrides the theme. The old two-argument function stays and forwards with `.standard`.
  - `var isDark: Bool` on `TerminalPalette` (background luminance below 0.5). The reporter's theme comes from this, so tmux is told "dark" under a skin.
- Neon noir: background `#07061A`, foreground `#D9D6FF`, cursor `#FF2E97`, selection `#FF2E97` at 0.30, ANSI neon (pink, cyan `#00F0FF`, green `#39FF88`, yellow `#FFE45C`, purple `#B967FF`).
- Phosphor: background `#010703`, foreground `#33FF77`, cursor `#33FF77`, selection `#33FF77` at 0.25, ANSI green-dominant but with distinct red-amber, amber, cyan-green and white-green so the 16 colors stay distinguishable.

- [ ] **Step 1: Write the failing tests:**
  - `testSkinOverridesTheme`: `palette(theme: .light, colorScheme: .light, skin: .neonNoir) == .neonNoir`, and `palette(theme: .light, colorScheme: .light, skin: .standard) == .light`.
  - `testSkinPalettesHaveSixteenAnsiColors`.
  - `testSkinPalettesAreLegible`: for each of `.neonNoir` and `.phosphor`, `TerminalContrastGuard.contrast(fg, bg) >= 7`, and for ANSI indices 1–15, `contrast(ansi[i], bg) >= 3`.
  - `testSkinPalettesReportDark`: `.neonNoir.isDark && .phosphor.isDark && !TerminalPalette.light.isDark`.
  - `testPhosphorAnsiColorsAreDistinct`: no two of ANSI indices 1–6 are within an RGB distance of 0.15.
- [ ] **Step 2: Run** `-only-testing:AISessionRemoteTests/TerminalAppearanceTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the palettes and the overload. Update the five readers to pass `SkinStore.shared.skin`. Wherever `TerminalThemeReporter`'s theme is derived (`TerminalScreen.swift` around lines 123–124 and wherever it's updated), use `palette.isDark` instead of the color scheme.
- [ ] **Step 4: Run** the test class and `cd ai-session-remote && swift test --filter TerminalContrastGuard`. Expected: PASS.
- [ ] **Step 5: Commit** `Add Neon noir and Phosphor terminal palettes`.

### Task 4: Root skinning and the App theme setting

**Files:**
- Create: `ai-session-remote/App/AISessionRemote/Theme/SkinModifiers.swift`
- Modify: `ai-session-remote/App/AISessionRemote/AISessionRemoteApp.swift` (add `.skinned()` to the root of every `WindowGroup` and of `Settings`)
- Modify: `ai-session-remote/App/AISessionRemote/Views/Shell/MacShell.swift` (around line 861: the `NSWindow`'s hosting root gets `.skinned()`)
- Modify: `ai-session-remote/App/AISessionRemote/Views/Shell/SettingsView.swift` (new `Page.appearance`, row "Appearance" with `paintpalette`, above Terminal; replace `.tint(DS.accent)` with `.skinned()`)
- Modify: `ai-session-remote/App/AISessionRemote/Views/Shell/SettingsPages.swift` (new `AppearanceSettingsView`; `TerminalSettingsView` hides its Theme picker when `SkinStore.shared.skin != .standard`)
- Test: `ai-session-remote/App/AISessionRemoteTests/SkinTests.swift`

**Interfaces:**
- Consumes: `DS.*`, `SkinStore.shared`.
- Produces: `extension View { func skinned() -> some View }`, which applies:
  - `.tint(DS.accent)`
  - `.preferredColorScheme(skin.isDark ? .dark : nil)`
  - `.fontDesign(skin == .phosphor ? .monospaced : nil)`
  - when `DS.windowBackground` is non-nil: `.scrollContentBackground(.hidden)` and `.background(DS.windowBackground)`

  `struct AppearanceSettingsView: View` is a `Form` with `Picker("App theme", selection: …)` over `AppSkin.allCases` and the footer "Changes the whole app, its icon and its sounds."

- [ ] **Step 1: Write the failing test** `testSkinnedModifierCompilesForAllSkins`: it builds `Text("x").skinned()` inside a `UIHostingController` for each skin, calls `loadViewIfNeeded()`, and asserts the view isn't nil. It's a smoke test; the real check is the Task 11 hand check.
- [ ] **Step 2: Run** `-only-testing:AISessionRemoteTests/SkinTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the modifier, the Settings page and the scene wiring.
- [ ] **Step 4: Run** the tests, then `xcodebuild build -scheme AISessionRemoteMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`. Expected: tests PASS and the Mac build succeeds.
- [ ] **Step 5: Commit** `Skin every scene root and add the App theme setting`.

### Task 5: Shared skin styles and the terminal frame

**Files:**
- Modify: `ai-session-remote/App/AISessionRemote/Theme/SkinModifiers.swift`
- Modify: `ai-session-remote/App/AISessionRemote/Views/Components/AccentButtonStyle.swift`
- Modify: `ai-session-remote/App/AISessionRemote/Views/Frame/TerminalSurface.swift` (wrap the terminal representable)
- Test: `ai-session-remote/App/AISessionRemoteTests/SkinTests.swift`

**Interfaces:**
- Produces:
  - `func skinnedSelection(_ isSelected: Bool) -> some View`. Standard is a no-op. Neon noir: `selectionFill` background, a 1 pt `selectionStroke` border at `DS.radius(6)`, and `.shadow(color: DS.glow, radius: 6)`. Phosphor: a `#33FF77` fill, with `.foregroundStyle(DS.onAccent)` so the row inverts.
  - `func skinnedCard() -> some View`. Standard is a no-op. Skins: a `DS.surface` fill, a 1 pt border, and `DS.radius(10)` corners.
  - `func skinnedTerminalFrame() -> some View`. Standard is a no-op. Neon noir: a 1 pt magenta border with a static glow. Phosphor: a 1 pt `#1F7A3D` border plus `ScanlineOverlay`.
  - `struct ScanlineOverlay: View`, drawn with `Canvas`: horizontal lines 1 pt black at 0.25 opacity every 3 pt, with `.allowsHitTesting(false)` and `.accessibilityHidden(true)`. No animation.
  - `AccentButtonStyle`: Standard is unchanged. Neon noir: a clear background, a 1 pt `DS.info` border, `DS.info` text and a cyan glow. Phosphor: a `DS.accent` fill, `DS.onAccent` text and `DS.radius` corners.

- [ ] **Step 1: Write the failing test** `testScanlinesDoNotTakeTouches`: render `ScanlineOverlay` in a hosting controller and assert that `hitTest` at its center returns no `ScanlineOverlay`-owned view (or, if SwiftUI makes that impractical, assert `ScanlineOverlay.lineSpacing == 3` and `ScanlineOverlay.lineOpacity == 0.25` as `static let`s).
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** the styles and apply `skinnedTerminalFrame()` in `TerminalSurface.swift`. Phosphor's terminal text glow: in `TerminalAppearance.apply`, when the palette is `.phosphor`, set `view.layer.shadowColor` to the foreground, `shadowRadius` 2, `shadowOpacity` 0.6 and `shadowOffset` .zero (macOS: `view.wantsLayer = true` first). Reset these for other palettes.
- [ ] **Step 4: Run** the tests and the Mac build. Expected: PASS.
- [ ] **Step 5: Commit** `Add skin selection, card, button and terminal frame styles`.

### Task 6: View sweep: hardcoded colors and the shared styles

**Files (modify):**
- Every hardcoded system color moves to a `DS` token. In Standard each token returns the same system color, so nothing changes on screen:
  - `Views/HostsListView.swift`: lines 134 and 225
  - `Views/Lists/ListActions.swift`: lines 313 and 324
  - `Views/Lists/TodoListView.swift`: line 209
  - `Views/Projects/MemoryViews.swift`: line 175 stays `.indigo` in Standard; add `DS.memory` with Standard `.indigo`
  - `Views/Frame/PhoneConversationView.swift`: line 186
  - `Views/Frame/AddAgentSheet.swift`: line 94
  - `Views/Frame/ConversationFrame.swift`: line 615
  - `Views/Frame/Chat/ChatWorkerCard.swift`: lines 54 and 69–71
  - `Views/Components/PullRequestChip.swift`: lines 46 and 48
  - `Views/Automation/IdeasPanes.swift`: lines 85 and 90
  - `Views/Automation/PhoneAutomation.swift`: lines 160 and 164
  - `Views/Automation/AutomationModels.swift`: lines 106–108
  - `Views/Review/ReviewView.swift`: lines 937, 1139, 1880 and 1882
  - `Views/Todos/ConversationLinkViews.swift`: lines 29, 35 and 448
  - `Views/Todos/ComputersView.swift`: line 42
- `Views/Frame/KeyBar.swift`: the palette `init(_ scheme:)` becomes `init(_ scheme: ColorScheme, skin: AppSkin)`. Neon noir: bar `#110F26`, key `#1A1640`, key pressed `#2A2260`, label `#D9D6FF`, separator `#2B2550`. Phosphor: bar `#031207`, key `#062812`, key pressed `#0B3D1C`, label `#33FF77`, separator `#1F7A3D`.
- `skinnedSelection(_:)` goes on the selected row in `Views/Lists/ConversationRow.swift` and `Views/Lists/TodoRow.swift`, and on the Mac sidebar rows in `Views/Shell/SidebarView.swift`.
- `skinnedCard()` goes on `Views/Frame/Chat/ChatPromptCard.swift`, `ChatWorkerCard.swift`, `ChatCodeBlock.swift` and the assistant bubble in `ChatMessageView.swift`.

**Interfaces:** consumes the Task 2 tokens and the Task 5 modifiers. Produces nothing new.

- [ ] **Step 1: Write the failing test** `testNoHardcodedSystemColorsOutsideTheme` in `SkinTests`. It reads every `.swift` file under `App/AISessionRemote/Views` (path from `#filePath`) and asserts that none matches the regex `\.(tint|foregroundStyle)\(\.(red|green|orange|purple|yellow|indigo|blue)\)` or `Color\.(red|green|orange|purple|blue)\b`. On failure, the message lists the file and line.
- [ ] **Step 2: Run.** Expected: FAIL, listing the sites above.
- [ ] **Step 3: Replace each site** with its token, update `KeyBar` and its call sites, and apply the modifiers.
- [ ] **Step 4: Run** the full `AISessionRemoteTests`, the Mac tests (`xcodebuild test -scheme AISessionRemoteMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`) and an iOS build. Expected: all PASS.
- [ ] **Step 5: Commit** `Route view colors through skin tokens and apply skin styles`.

### Task 7: Themed sounds (Mac chimes, banners, iPhone local notifications)

**Files:**
- Modify: `ai-session-remote/scripts/make-attention-sounds.py`
- Create (generated, committed):
  - `ai-session-remote/App/AISessionRemote/Resources/Sounds/attention-needs-you-neon-noir.caf`
  - `ai-session-remote/App/AISessionRemote/Resources/Sounds/attention-review-neon-noir.caf`
  - `ai-session-remote/App/AISessionRemote/Resources/Sounds/attention-needs-you-phosphor.caf`
  - `ai-session-remote/App/AISessionRemote/Resources/Sounds/attention-review-phosphor.caf`
- Modify: `ai-session-remote/App/AISessionRemote/Platform/AttentionSound.swift`
- Modify: `ai-session-remote/App/AISessionRemote/Services/Notifications/NotificationCenterCoordinator.swift` (around lines 311 and 400: `content.sound`)
- Test: `ai-session-remote/App/AISessionRemoteTests/SkinTests.swift`

**Interfaces:**
- Produces:
  - `AttentionSound.bundledName(for kind: AttentionKind, skin: AppSkin) -> String`: today's name when `skin.soundSuffix` is nil, otherwise `"<today's name>-<suffix>"`. The existing `bundledName(for:)` forwards with `SkinStore.shared.skin`.
  - `static func skinSound(for kind: AttentionKind, skin: AppSkin) -> UNNotificationSound?`: nil for Standard (the caller keeps `.default`), otherwise the named `.caf`.
- Sound recipes (from the spec):
  - Neon noir "Needs you": sawtooth notes C5, E5, G5, C6 starting 70 ms apart, each 220 ms, with a low-pass that falls from 4200 Hz to a third of that, resonance Q 6.
  - Neon noir "Review": one square-wave note at 880 Hz, 180 ms, low-pass 2600 Hz, with a 130 ms echo at 0.35 feedback.
  - Phosphor "Needs you": two square-wave beeps at 1046.5 Hz, 90 ms each and 140 ms apart, held flat with a 10 ms release.
  - Phosphor "Review": one square-wave note at 587.33 Hz, 120 ms, held flat.
- The script keeps writing today's two files byte-identically. Check with `git diff --stat` after running it.

- [ ] **Step 1: Write the failing tests:**
  - `testBundledNameFollowsSkin`: `bundledName(for: .needsYou, skin: .standard) == "attention-needs-you"` and `bundledName(for: .review, skin: .phosphor) == "attention-review-phosphor"`.
  - `testSkinSoundFilesAreBundled`: for every skin with a suffix and both kinds, `Bundle(for: AppModel.self).url(forResource:withExtension: "caf")` is non-nil.
  - `testStandardKeepsDefaultNotificationSound`: `skinSound(for: .needsYou, skin: .standard) == nil`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Extend the script** (add `square` and `saw` generators, a one-pole low-pass, and an echo), run `python3 scripts/make-attention-sounds.py`, and confirm today's two `.caf` files are unchanged in `git status`.
- [ ] **Step 4: Wire it up.** The Mac `sound(_:kind:)` default case uses `bundledName(for:skin:)`. `bannerSound(for:)` follows automatically. In the iOS coordinator, `content.sound = AttentionSound.skinSound(for: kind, skin: SkinStore.shared.skin) ?? .default`. `AttentionSound` is iOS-safe already. Only the `NSSound` code is `#if os(macOS)`.
- [ ] **Step 5: Run** the tests. Expected: PASS. Listen to each file once with `afplay`.
- [ ] **Step 6: Commit** `Add Neon noir and Phosphor attention sounds`.

### Task 8: Hub: per-device push sound

**Files:**
- Modify: `todo-app/crates/todo-shared/src/lib.rs`: `PushDeviceRequest` gets `#[serde(default)] pub sound: Option<String>`. `PushDevice` gets `pub sound: Option<String>`.
- Modify: `todo-app/crates/todo-server/src/db.rs`: `SCHEMA_VERSION` goes to `43`. Inside `if target_version >= 43`, use the `column_exists` pattern for `ALTER TABLE push_devices ADD COLUMN sound TEXT;`, and add the column to the `CREATE TABLE IF NOT EXISTS push_devices` statement (around line 1570). Add a doc line for v43 in the schema history comment (around line 1128).
- Modify: `todo-app/crates/todo-server/src/push/store.rs`:
  - `DeviceTarget` gets `pub sound: Option<String>`.
  - `upsert_device` writes `sound`. A missing value stores NULL, so switching back to Standard clears it.
  - `devices_for_push`, `DEVICE_COLS` and `row_to_device` read it.
- Modify: `todo-app/crates/todo-server/src/push/apns.rs`: `build_payload(alert: &Alert, sound: Option<&str>) -> serde_json::Value`. Non-passive pushes set `aps.sound` to `sound.unwrap_or("default")`. Passive pushes stay silent. `send` passes `target.sound.as_deref()`. Update the other callers (including `today.rs:1269` and the tests) to pass `None`.
- Modify: `todo-app/crates/todo-server/src/push/handlers.rs`: the device PUT handler calls `valid_push_sound`.
- Create: `pub fn valid_push_sound(name: &str) -> bool` in `push/store.rs`. It's true only for these four names; anything else gets 400 `"unknown sound"`:
  - `attention-needs-you-neon-noir.caf`
  - `attention-needs-you-phosphor.caf`
  - `attention-review-neon-noir.caf`
  - `attention-review-phosphor.caf`
- Push alerts are "needs you" or "done" kinds. Use the needs-you file name the client sends; the hub doesn't pick per kind.
- Test: unit tests in `push/store.rs`, `push/apns.rs` and `push/handlers.rs`, following the existing test modules.

**Interfaces:**
- Produces: the JSON field `sound` (snake_case, optional) on `PUT /api/push/devices`, and the `sound` field on `GET` device listings.

- [ ] **Step 1: Write the failing tests:**
  - `push_sound_defaults_and_passive_stays_silent` (apns.rs):
    - `build_payload(&waiting_alert(), None)["aps"]["sound"] == "default"`
    - `build_payload(&waiting_alert(), Some("attention-needs-you-phosphor.caf"))["aps"]["sound"] == "attention-needs-you-phosphor.caf"`
    - with `passive: true` and `Some(...)`, `["aps"].get("sound").is_none()`
  - `upsert_device_stores_and_clears_sound` (store.rs): upsert with `Some("attention-needs-you-neon-noir.caf")`; `devices_for_push()[0].sound` matches; upsert again with `None` and it's `None`.
  - `push_sound_rejects_unknown_names` (handlers.rs, or `valid_push_sound` directly):
    - `!valid_push_sound("default")`
    - `!valid_push_sound("../x.caf")`
    - `!valid_push_sound("attention-needs-you.caf")`
    - `valid_push_sound("attention-needs-you-phosphor.caf")`
  - `old_client_registration_without_sound_parses`: `serde_json::from_str::<PushDeviceRequest>` of a body without `sound` gives `sound == None` (next to the existing test at `lib.rs:2380`).
  - Migration: extend the existing v-upgrade test pattern in `db.rs` so a v42 database gains `push_devices.sound`.
- [ ] **Step 2: Run** `cd todo-app && cargo test push_sound upsert_device_stores old_client`. Expected: FAIL.
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4: Run** `cd todo-app && cargo test`. Expected: all PASS.
- [ ] **Step 5: Commit** `Hub: per-device APNs sound for app skins (schema v43)`.

### Task 9: App: send the push sound and re-register on skin change

**Files:**
- Modify: `ai-session-remote/Sources/AISessionCore/TodoHub/TodoHubModels.swift`: `PushDeviceRegistration` gets `public var sound: String?`, an init parameter `sound: String? = nil`, and `PushDevice` gets `public var sound: String?`. The coding keys follow the existing snake_case encoder; check how `bundleId` maps to `bundle_id`.
- Modify: `ai-session-remote/App/AISessionRemote/Services/Notifications/NotificationCenterCoordinator.swift`: `uploadToken()` passes `sound: AttentionSound.skinSoundFileName(for: .needsYou, skin: SkinStore.shared.skin)`.
- Modify: `ai-session-remote/App/AISessionRemote/Platform/AttentionSound.swift`: add `static func skinSoundFileName(for: AttentionKind, skin: AppSkin) -> String?`, which returns `bundledName(...) + ".caf"`, or nil for Standard.
- Modify: `AppearanceSettingsView` (Task 4): on change of the picker, `Task { await NotificationCenterCoordinator.shared.uploadToken() }`. `uploadToken` is a no-op when push is off or there's no token.
- Test: `ai-session-remote/Tests/AISessionCoreTests/` (the existing TodoHub model tests file that covers push registration; find it with `grep -l PushDeviceRegistration Tests`).

- [ ] **Step 1: Write the failing tests:**
  - `testPushRegistrationEncodesSound`: with `sound: "attention-needs-you-phosphor.caf"`, the JSON has `"sound":"attention-needs-you-phosphor.caf"`.
  - `testPushRegistrationOmitsNilSound`: with `nil`, the JSON either has no `sound` key or `null`. Either way the hub stores NULL; assert whichever the encoder produces.
  - `testSkinSoundFileName` (in the app's `SkinTests`): `.standard` gives nil, and `.neonNoir` gives `"attention-needs-you-neon-noir.caf"`.
- [ ] **Step 2: Run** `cd ai-session-remote && swift test --filter PushDevice`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test` and the app tests. Expected: PASS.
- [ ] **Step 5: Commit** `Send the skin's push sound to the hub`.

### Task 10: Skin app icons

**Files:**
- Create: `ai-session-remote/scripts/make-skin-icons.swift`. It's a standalone `swift` script using CoreGraphics and ImageIO that writes PNGs. Run it with `swift scripts/make-skin-icons.swift`.
- Create (generated, committed):
  - `ai-session-remote/App/AISessionRemote/Assets.xcassets/AppIcon-NeonNoir.appiconset/` (iOS 1024 + `Contents.json`, same layout as `AppIcon.appiconset`'s iOS entry)
  - `ai-session-remote/App/AISessionRemote/Assets.xcassets/AppIcon-Phosphor.appiconset/` (same)
  - `ai-session-remote/App/AISessionRemote/Assets.xcassets/DockIcon-NeonNoir.imageset/` and `DockIcon-Phosphor.imageset/` (a 1024 PNG with the macOS rounded-rect mask and margin like the existing Mac icon, for `NSImage(named:)`)
- Modify: `ai-session-remote/project.yml`, iOS target settings: `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES: "AppIcon-NeonNoir AppIcon-Phosphor"` and `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS: YES`. Leave the Mac target's `ASSETCATALOG_COMPILER_APPICON_NAME` alone.
- Create: `ai-session-remote/App/AISessionRemote/Platform/SkinIcon.swift`
- Modify: `AppearanceSettingsView` (picker change) and app launch (`AISessionRemoteApp` `.onAppear` of the main window) to call `SkinIcon.apply(SkinStore.shared.skin)`.
- Test: `ai-session-remote/App/AISessionRemoteTests/SkinTests.swift`

**Interfaces:**
- Produces: `@MainActor enum SkinIcon { static func apply(_ skin: AppSkin) }`.
  - iOS: when `UIApplication.shared.supportsAlternateIcons` and `alternateIconName != skin.iconName`, call `setAlternateIconName(skin.iconName)` (nil restores the primary). Log errors and don't surface them.
  - macOS: `NSApp.applicationIconImage = skin == .standard ? nil : NSImage(named: "DockIcon-" + suffix)`, where nil restores the bundle icon. This must not disturb the Dock badge that `AttentionPulse` sets.
- Icon geometry follows `icons-sounds.html` on a 1024 canvas (×10.24 from the 100-unit SVG):
  - **Neon noir:** an indigo gradient from `#1A1240` to `#07061A`, cyan grid lines at 0.18 opacity, the bubble path stroked magenta `#FF2E97` with a blur glow, and a cyan `>` and `_`.
  - **Phosphor:** a radial gradient from `#062812` to `#010703`, the pixel bubble, `>` and `_` in `#33FF77` with a glow, and 1-in-3 scanlines at 0.35 over the whole icon.
  - iOS icons are full-bleed squares, because the system masks them.

- [ ] **Step 1: Write the failing tests:**
  - `testAlternateIconsAreBundled`: `Bundle.main.infoDictionary?["CFBundleIcons"]` → `CFBundleAlternateIcons` has the keys `AppIcon-NeonNoir` and `AppIcon-Phosphor`. Run this against the iOS host app.
  - `testSkinIconNamesMatchAssets`: `AppSkin.neonNoir.iconName == "AppIcon-NeonNoir"`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Generate the icons** with the script, look at the PNGs (open them) and compare them against `icons-sounds.html`. Then add the project settings, run `xcodegen generate` and implement `SkinIcon`.
- [ ] **Step 4: Run** the tests, an iOS build and a Mac build. Expected: PASS.
- [ ] **Step 5: Commit** `Add Neon noir and Phosphor app icons`.

### Task 11: Verify, install and hand check

- [ ] **Step 1: Run everything.**
  - `cd todo-app && cargo test`
  - `cd ai-session-remote && swift test`
  - `scripts/todo/test-todo-scripts.sh`
  - iOS `AISessionRemoteTests`
  - `AISessionRemoteMacTests`

  Expected: all PASS.
- [ ] **Step 2: Rebuild the Mac app** with `ai-session-remote/scripts/rebuild-mac-app.sh`, after rebasing onto `origin/main`. Then check that it launches without keychain prompts.
- [ ] **Step 3: Hand check on the Mac** with a live terminal conversation open. Switch Standard → Neon noir → Phosphor → Standard. Confirm:
  - The terminal stays connected and keeps its scrollback.
  - The Dock icon changes and comes back.
  - Lists, sidebar, chat, buttons and Settings are restyled.
  - Standard looks like before (compare a screenshot taken before Step 2).
  - Settings › Notifications plays the skin's chime as "Default".
- [ ] **Step 4: Ask the user** before pushing to `main`, because that publishes `pi-latest` and deploys hub v43. After deploying, check `GET /api/push/devices` shows `sound` for the phone.
- [ ] **Step 5: Install on the iPhone** (see the memory note on deploying over SSH). Switch skins, accept the icon alert, trigger a "needs you" push and hear the skin sound.
