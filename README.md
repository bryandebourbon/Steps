# Steps

Native SwiftUI iOS app for today’s walk: a MapKit path on top, a progress-vs-average step chart underneath, and Robinhood-style press-and-hold scrubbing that moves the map marker through the day.

This is an Xcode project. It is not a web app and will not run in a browser or on Linux.

## Open in Xcode (macOS)

1. Open `Steps.xcodeproj` in Xcode 16 or later (iOS 17 SDK).
2. Select the **Steps** scheme and an iPhone simulator (or a physical iPhone).
3. Choose your Development Team under the Steps target → Signing & Capabilities. HealthKit requires a signed team on a real device.
4. Press Run.

If you change the file list and prefer regenerating the project, install [XcodeGen](https://github.com/yonaskolb/XcodeGen) and run `xcodegen generate` from the repo root. The checked-in `.xcodeproj` already opens without that step.

## What you get

- **Map (top):** today’s walking polyline, dimmed remaining path while scrubbing, and a position marker.
- **Stats:** large step count plus distance, active time, flights, and calories.
- **Progress chart (bottom):** cumulative steps vs a typical-day average on a dark card. Press and hold, then drag horizontally to scrub. A crosshair and tooltip show time, exact steps, and distance. `UISelectionFeedbackGenerator` ticks as the selected sample changes; `UIImpactFeedbackGenerator` fires when scrubbing starts. The map marker jumps to where those steps happened.
- **Sample day:** on Simulator (no pedometer hardware) the app loads a seeded Mission District, San Francisco walk so scrubbing is meaningful without a real outing.
- **Live day:** on a physical iPhone, CoreMotion / HealthKit totals and CoreLocation points are used when available. An empty morning shows a real empty state with **Show a sample day**.
- **Loading / error:** a loading screen on launch, and a retryable error screen if today’s walk cannot be built.

## Permissions

The target includes HealthKit entitlements, `UIBackgroundModes = location`, and these usage strings:

| Key | Why |
| --- | --- |
| `NSLocationWhenInUseUsageDescription` | Draw the live path |
| `NSLocationAlwaysAndWhenInUseUsageDescription` / `NSLocationAlwaysUsageDescription` | Keep the path going if you leave the app briefly |
| `NSMotionUsageDescription` | Pedometer steps, distance, floors |
| `NSHealthShareUsageDescription` | Read Health step, distance, flight, and energy samples |

Grant Location, Motion, and Health when prompted on a device. Simulator location can be faked under Features → Location; the seeded sample day is still what you scrub there.

## Requirements

- macOS with Xcode 16+
- iOS 17+
- No backend, auth, or API keys
