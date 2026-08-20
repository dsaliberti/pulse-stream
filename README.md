# PulseStream

[![Testing](https://github.com/dsaliberti/pulse-stream/actions/workflows/Testing.yaml/badge.svg)](https://github.com/dsaliberti/pulse-stream/actions/workflows/Testing.yaml)

PulseStream is an end-to-end Bluetooth Low Energy showcase built with Swift 6,
SwiftUI, CoreBluetooth, Swift Charts, and the Point-Free ecosystem. A native
macOS peripheral publishes live heart-rate notifications, while a native iOS
central discovers, connects, records, restores, and diagnoses the stream.

https://github.com/user-attachments/assets/9599d1ae-b6f8-4ec1-af11-42edc32c2021

> [!NOTE]
> PulseStream generates simulated heart-rate measurements for engineering
> demonstration purposes. It is not a medical device.

The project follows the
[Bluetooth SIG Heart Rate Service 1.0 specification](https://www.bluetooth.com/specifications/specs/heart-rate-service-1-0/)
using the Heart Rate Service (`180D`) and Heart Rate Measurement characteristic
(`2A37`), so its packet format and optional fields match real heart-rate sensors
rather than a custom protocol.

## Highlights

### Reliable BLE lifecycle

- Filtered discovery for the standard Heart Rate Service
- Connection, service discovery, characteristic discovery, and notification subscription
- Bounded recovery with one-, two-, and four-second backoff
- Five-second discovery timeout for every recovery attempt
- Explicit cancellation and terminal failure states
- Generic Attribute Profile (GATT) service invalidation handling
- Peripheral notification backpressure handling

### Heart-rate recording

- Timestamped, bounded sample history rendered with Swift Charts
- Minimum, average, and maximum BPM statistics
- Recording duration driven by controllable clock and date dependencies
- Independent BLE and recording lifecycles: pausing capture does not interrupt
  the live heart-rate stream
- Visible chart segmentation across connection interruptions
- Active and paused session persistence using Point-Free Sharing file storage
- Foreground/background persistence with immediate restoration; active sessions
  reconnect automatically while paused sessions remain idle
- Confirmed destructive clearing of recorded samples and chart data

### Protocol lab

- Standard 8-bit and 16-bit BPM representations
- Sensor-contact support and good/poor contact states
- Optional accumulated energy expenditure
- Zero-to-multiple RR intervals—the elapsed time between consecutive ECG R
  waves—per notification, converted from standard 1/1024-second units to
  milliseconds
- Deliberate malformed-packet injection from macOS
- Typed, non-fatal decoder failures on iOS
- Accepted/rejected packet counters with actionable diagnostics

Malformed notifications are rejected individually. They do not discard the
last valid measurement, interrupt an active recording, or force a healthy BLE
connection to restart.

## Architecture

```text
PulseStreamBroadcaster (macOS peripheral)
        │  CoreBluetooth notifications: 180D / 2A37
        ▼
LiveHeartRateCentral (iOS dependency)
        │  typed async events
        ▼
HeartRateFeature (TCA reducer)
        ├── connection and recovery state
        ├── recording lifecycle
        ├── protocol diagnostics
        └── Point-Free Sharing persistence
                │
                ▼
        HeartRateView (SwiftUI + Charts)

BluetoothHealth (shared Swift package)
        └── profile UUIDs and bidirectional packet codec
```

CoreBluetooth is isolated behind a controllable dependency. The reducer owns
application policy, while `BluetoothHealth` owns byte-level protocol behavior.
This keeps BLE hardware out of deterministic feature tests.

## Requirements

- A Mac with Bluetooth enabled
- Xcode with the iOS 26 SDK
- A physical iPhone running iOS 26 with Bluetooth enabled

The iOS Simulator cannot perform this Mac-peripheral-to-iPhone-central test.

## Run on devices

1. Open `PulseStream.xcworkspace` in Xcode.
2. Select the `PulseStreamBroadcaster` scheme and run it on **My Mac**.
3. Press **Start Broadcasting** in the Mac app.
4. Select the `PulseStream` scheme and a physical iPhone.
5. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`, then set its
   `DEVELOPMENT_TEAM` value to your Apple Developer team identifier. The local
   file is gitignored, so personal signing does not dirty the shared project.
6. Run the iOS app, approve Bluetooth access, and press **Scan for Broadcaster**.

On the first build, allow Xcode to finish resolving the Swift packages. Xcode
may then ask you to approve the
[Swift macros](https://developer.apple.com/documentation/swift/applying-macros)
supplied by the Point-Free dependencies; approve them, then build again.

The iOS target declares the `bluetooth-central` background mode. A valid local
code-signing configuration is therefore required when installing it on a device.
The macOS broadcaster does not require an Apple Developer team for local use;
Xcode can sign it with **Sign to Run Locally**.

CoreBluetooth peripherals cannot directly disconnect a central. The Mac app's
**Drop Session** button removes and republishes its Generic Attribute Profile
(GATT) service—the standard BLE structure containing services and
characteristics—to exercise the client's real invalidation and recovery path.

## Build from Terminal

Commands use the currently selected stable Xcode command-line tools:

```sh
xcodebuild -workspace PulseStream.xcworkspace \
  -scheme PulseStreamBroadcaster \
  -destination 'platform=macOS' build

xcodebuild -workspace PulseStream.xcworkspace \
  -scheme PulseStream \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

## Tests

```sh
swift test --package-path Packages/BluetoothHealth
swift test --package-path Packages/PulseStreamFeature
```

The suite covers packet encoding/decoding, optional fields, malformed data,
connection recovery, cancellation, timeouts, recording, persistence, lifecycle
restoration, protocol presentation, and non-fatal packet rejection.

## Repository structure

```text
PulseStream
├── Apps
│   ├── PulseStreamBroadcaster  # native macOS CoreBluetooth peripheral
│   └── PulseStream             # native iOS application entry point
├── Config                       # shared build settings and signing template
├── Packages
│   ├── BluetoothHealth         # shared Heart Rate Service codec package
│   └── PulseStreamFeature      # iOS TCA feature package
├── PulseStream.xcodeproj
└── PulseStream.xcworkspace
```

## License

PulseStream is available under the MIT License.
