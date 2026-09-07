# AltTab dev: build identity and toolchain audit

Audit date: 2026-09-05. Source baseline: upstream AltTab 11.5.0. This document separates facts read from the checkout/toolchain from behavior that still needs a signed app test.

## Build in Xcode

Open `alt-tab-macos.xcodeproj` and select the shared **AltTab dev** scheme. Its Run and Profile actions use **Release**, with Swift `-O`, whole-module compilation, and no debugger or automatic QA windows. The separate **Debug** scheme remains available for debugging. Choose **My Mac** and build. `ai/build.sh`, `ai/run.sh`, and `ai/profile.sh` use the same Release product in `DerivedData`.

Before keeping permissions across repeated builds, select your own signing team and **Apple Development** identity in the app target's Signing & Capabilities settings for both Debug and Release. Alternatively, put your actual team identifier in the ignored `config/local.xcconfig`:

```xcconfig
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

Use the same certificate, team, bundle identifier, and app location throughout the comparison. No valid named code-signing identities were visible to `security find-identity -v -p codesigning` during this audit. The checked-in fallback is ad-hoc signing (`-`) so compilation does not require the original developer's certificate. Ad-hoc builds do **not** establish persistent privacy permissions across rebuilt binaries. Apple's code-signing requirements documentation explains that macOS uses the designated requirement to identify an app and distinguish development/distribution variants. [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

The test app has these values in Debug and Release:

| Property | Value |
| --- | --- |
| App filename and displayed name | `AltTab dev.app` / `AltTab dev` |
| Bundle identifier | `no.brakedalen.AltTab-dev` |
| Version / build | `11.5.1` / `11.5.1` |
| Minimum host macOS version | `26.0` |
| URL scheme | `no.brakedalen.AltTab-dev://` |
| Standard settings domain | `no.brakedalen.AltTab-dev` |
| License settings and Keychain service | `no.brakedalen.AltTab-dev.license` |
| Usage settings domain | `no.brakedalen.AltTab-dev.usage` |
| CLI Mach port | `no.brakedalen.AltTab-dev.cli` |
| Unit-test bundle and App mock identifier | `no.brakedalen.AltTab-dev.unit-tests` |

Accessibility and screen-recording consent must be granted to **AltTab dev** separately in System Settings. No official app preferences, TCC records, license keys, or login items are migrated or reset. For hotkey and performance comparisons, quit one AltTab variant before running the other; separate bundle identifiers do not isolate global keyboard shortcuts.

Start at login defaults to off. If enabled explicitly, `SMAppService.mainApp` registers this particular application. The legacy login-item scan, handwritten LaunchAgent, `ProcessType=Interactive`, and `LegacyTimers=true` override have been removed. macOS can require approval in its Login Items settings; the app opens that panel when approval is required after changing the preference. Registration requires code signing. [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), [Apple mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)

Official Sparkle update checks/installations and AppCenter crash reporting are disabled by the development-build flag, including manual update entry points. Their vendored libraries are still present in the build; they were not broadly upgraded in a capture-performance change. The move-to-Applications prompt is skipped for this development bundle. License logic and paid feature gates are unchanged: this identity has its own trial/activation state and does not inherit the official app's activation. Manual feedback and license activation still use upstream services when the user invokes them.

## Compiler, SDK, deployment target

Local commands returned Xcode **26.6 (17F113)**, Apple Swift **6.3.3**, and macOS SDK **26.5**. Apple's support table lists Xcode 26.6/macOS SDK 26.5 as the current stable toolchain, alongside Xcode 27 beta. This checkout uses `SDKROOT=macosx`, so the selected Xcode supplies the SDK. [Apple Xcode support table](https://developer.apple.com/support/xcode/)

The source language setting remains Swift **5.8**, which this compiler accepts as Swift 5 language mode; this is not a Swift 5.8 compiler or an old Apple SDK. Migrating the entire concurrency model to Swift 6 language mode is a separate change with its own correctness requirements. Local vendored package manifests use Swift tools version **5.9**. Source is Swift and Objective-C with programmatic AppKit UI. The app's UI uses AppKit, without an Electron or SwiftUI view tree. The repository's Node tools do not run as part of the app.

Before this change, the host minimum was 10.14.4, while CI explicitly selected Xcode **26.0.1**. That CI selection is older than the installed toolchain, but it already compiled against the macOS 26 SDK generation. Raising the deployment minimum to 26.0 allows direct use of current APIs; it does not itself prove a CPU or memory reduction. The original SDK26 weak-link workaround for ScreenCaptureKit is unnecessary with a 26.0 minimum.

## Runtime dependencies and system APIs

| Component | Checked-in version | Verified upstream status / development-build use |
| --- | --- | --- |
| ShortcutRecorder | `alt-tab-current@52c6273d233f7794e4fd5d22f50d2de0e4e41b19` | `git ls-remote` confirmed the same commit is the current `alt-tab-current` branch head. Active shortcut UI dependency, statically linked. [Fork](https://github.com/lwouis/ShortcutRecorder/tree/alt-tab-current) |
| Sparkle | 2.9.1 | Latest release is 2.9.6, including installer security fixes. No updater object is created in this test app, so automatic/manual update paths cannot replace it with an official build. Must review/upgrade before re-enabling updates. [Sparkle 2.9.6](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6) |
| Microsoft AppCenter | 4.3.0, local source package | Latest release is 5.12.1. AppCenter initialization and exception forwarding are disabled in this test app. [AppCenter releases](https://github.com/microsoft/appcenter-sdk-apple/releases) |
| PLCrashReporter | 1.11.1, binary xcframework | Latest release is 1.12.2. Included through AppCenterCrashes, whose reporting is disabled. [PLCrashReporter 1.12.2](https://github.com/microsoft/plcrashreporter/releases/tag/1.12.2) |

AppCenter Analytics & Diagnostics currently remain supported through **March 2027**, after another extension. Earlier sources that say June 2026 are stale. This service lifetime is distinct from the age of the vendored SDK. [Microsoft retirement notice](https://learn.microsoft.com/en-us/appcenter/retirement)

Apple frameworks used by the source include AppKit/Cocoa, Foundation, ApplicationServices Accessibility, CoreGraphics, ScreenCaptureKit, CoreText, IOKit/HID, Security, Carbon/HIToolbox, and now ServiceManagement and UniformTypeIdentifiers. ScreenCaptureKit window capture is already present upstream, including the macOS 26 screenshot API; the capture review addresses scheduling, image retention, and background policy rather than claiming the app only uses old capture technology.

The app also directly links the private **SkyLight** framework and resolves CGS/SLS and private Accessibility functions. These support window enumeration, Spaces, focus and WindowServer events. They are not converted into supported public APIs by selecting a new SDK. Removing them would require a separate functional redesign and regression testing of window switching/Spaces behavior.

## Build-only tooling

`package-lock.json` pins commitlint 8.1.0, semantic-release 15.13.24 (changelog 3.0.4/git 7.0.16), husky 3.1.0, lint-staged 13.3.0, fontkit 1.8.0, glob 10.4.5, marked 0.8.0, TypeScript 5.7.2, ts-node 10.9.2 and Node types 22.10.2. They serve repository formatting, resources, and release automation; they do not run inside AltTab. SwiftFormat is found on PATH rather than pinned. CocoaPods and Carthage are not used by this checkout; runtime vendors are local Swift Package Manager packages.

The upstream release workflow specifies Node 16 while `package.json` requires Node >=18. That is an existing release-pipeline inconsistency, separate from the runtime performance issue and not needed for a local Xcode build. This development pass does not run publishing, notarization, license activation, or the scripts that create/import signing certificates.

## Validation

The complete **Test** scheme ran in Release on this arm64 Mac with macOS 26.5.2: **953 passed, zero failed, zero skipped**, including all 22 new capture-scheduler tests. Xcode's result bundle independently reports `Passed` with no test failures. These unit tests exercise scheduling and state transitions; they do not replace a signed-app test of ScreenCaptureKit, Accessibility, login registration, or WindowServer resource use.

The final **Debug** build and optimized, ad-hoc-signed **AltTab dev / Release** build both succeeded using four Xcode build jobs. Swift compilation retained `-warnings-as-errors`; the Release app and tests used Swift 5 language mode, `-O`, and whole-module compilation. Remaining build messages concern vendored Objective-C documentation, an already-signed Sparkle binary skipped by the stripping step, and absent AppIntents metadata, not Swift compilation errors. `plutil`, shell syntax checks, and `git diff --check` passed.

Both generated app plists verified the identity/version/settings flags listed above. `vtool -show-build` verified **macOS minimum 26.0 and SDK 26.5 in both arm64 and x86_64 Release slices**. `codesign --verify --deep --strict` verified the complete Release app and nested frameworks/helpers. Its designated requirement is an ad-hoc code hash with no TeamIdentifier, so this verifies bundle integrity, **not** persistence of TCC permissions after rebuilding. Select a stable local signing identity as described above before the comparison. The app was neither launched nor copied into Applications during validation.

The deep-signature check also exposed invalid arm64 seals in both committed Sparkle helper binaries; the copied `Autoupdate` had the same SHA-256 as its vendor source. Development builds now sign their copied `Updater.app` and `Autoupdate` with the configured local identity before sealing the framework and host. Vendor binaries remain unchanged, and this does not enable updates.

The first complete-suite attempts exposed two existing assumptions about the test host. The sorting fixtures used `Aaa` before `Bbb`, but Norwegian `localizedStandardCompare` sorts `Aa` after `B`; they now use `Alpha` and `Beta` without changing production sorting. The test-only `ControlsTab.defaultShortcuts` mock force-unwrapped a literal backtick. A standalone probe linked against the same ShortcutRecorder object confirmed that this exact literal returned `nil` on the current keyboard layout, while every other key in that mock was valid. Its fixture now specifies physical ANSI grave (key code 50), consistent with the existing simulated keyboard events. Production defaults already derive the above-Tab key from the input source and use optional shortcut conversion; they are unchanged. No system locale or keyboard input source was changed to make the tests pass.

The permission startup review also found that the sparse Accessibility timer was armed before its distributed-notification observer existed. Registering the observer first selects the intended 60-second backstop immediately, instead of remaining at five seconds until the permissions window was shown and hidden. Screen-recording permission checks remain limited to startup or the visible permissions window. This is a verified scheduling correction, not evidence that it caused the observed WindowServer load.
