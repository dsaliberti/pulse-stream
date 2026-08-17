# PulseStream

PulseStream is an end-to-end Bluetooth Low Energy reference implementation built with Swift, SwiftUI, CoreBluetooth, and the Composable Architecture.

The macOS app is a peripheral that publishes the Bluetooth SIG Heart Rate Service (`180D`) and sends Heart Rate Measurement notifications (`2A37`). The reusable `BluetoothHealth` library owns the standard profile identifiers and bidirectional packet codec shared by the broadcaster and iOS central/client.

## Current milestone: end-to-end heart rate

The broadcaster supports:

- standards-based heart-rate packets;
- adjustable or automatically varying BPM;
- BLE subscription status;
- CoreBluetooth notification backpressure;
- a shared, platform-neutral Heart Rate Measurement encoder/decoder;
- a **Drop Session** control that removes and republishes the service so the client can exercise recovery.

CoreBluetooth peripherals cannot directly connect to or disconnect a central. The iPhone client owns the connection. **Start Broadcasting** makes the Mac discoverable; **Drop Session** deliberately invalidates the published service instead of claiming to perform a central-initiated disconnect.

The iOS app uses the Composable Architecture to scan for the Heart Rate Service, connect to the Mac, subscribe to Heart Rate Measurement notifications, decode them through `BluetoothHealth`, and display the live BPM. Its CoreBluetooth central is exposed as a controllable dependency so reducer tests run without BLE hardware.

Unexpected connection loss enters a bounded recovery policy with one-, two-, and four-second backoff. Each attempt has a finite discovery timeout, can be cancelled by the user, and explicitly stops its underlying CoreBluetooth work. After recovery is exhausted, the app remains idle until the user starts a new scan.

The client can record timestamped measurements into a bounded in-memory session and render them with Swift Charts. It derives live minimum, average, and maximum BPM statistics while keeping recording lifecycle separate from the BLE connection. A recovered connection continues the active recording in a new chart segment so the interruption remains visible rather than implying continuous data.

## Run

Open `PulseStream.xcworkspace` in an Xcode version that includes the iOS 26 SDK. Run the `HeartRateBroadcaster` scheme on **My Mac**, then run the `PulseStream` scheme on a physical iPhone. The workspace contains both native apps and their local Swift packages.

The first launch may request Bluetooth access. End-to-end BLE testing requires a physical iPhone.

To build both native apps from Terminal using the active Xcode command-line tools:

```sh
xcodebuild -workspace PulseStream.xcworkspace \
  -scheme HeartRateBroadcaster \
  -destination 'platform=macOS' build

xcodebuild -workspace PulseStream.xcworkspace \
  -scheme PulseStream \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

## Test

```sh
swift test
```

## Repository shape

```text
PulseStream
├── PulseStream.xcworkspace
├── PulseStream.xcodeproj
├── Apps/HeartRateBroadcaster (native macOS app)
├── Apps/PulseStream (native iOS app)
├── BluetoothHealth package
│   └── heart-rate profile and packet codec
├── PulseStreamFeature package
│   ├── TCA feature and SwiftUI view
│   ├── injectable CoreBluetooth central
│   └── deterministic reducer tests
└── package and feature tests
```
