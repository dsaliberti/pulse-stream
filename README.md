# PulseStream

PulseStream is an end-to-end Bluetooth Low Energy experiment built with Swift and CoreBluetooth.

The macOS app is a peripheral that publishes the Bluetooth SIG Heart Rate Service (`180D`) and sends Heart Rate Measurement notifications (`2A37`). The reusable `BluetoothHealth` library owns the standard profile identifiers and bidirectional packet codec shared by the broadcaster and iOS central/client.

## Current milestone: broadcaster and shared codec

The broadcaster supports:

- standards-based heart-rate packets;
- adjustable or automatically varying BPM;
- BLE subscription status;
- CoreBluetooth notification backpressure;
- a shared, platform-neutral Heart Rate Measurement encoder/decoder;
- a **Drop Session** control that removes and republishes the service so the client can exercise recovery.

CoreBluetooth peripherals cannot directly connect to or disconnect a central. The iPhone client owns the connection. **Start Broadcasting** makes the Mac discoverable; **Drop Session** deliberately invalidates the published service instead of claiming to perform a central-initiated disconnect.

## Run

Open `PulseStream.xcworkspace` in Xcode, select the `HeartRateBroadcaster` scheme, and run it on **My Mac**. The workspace contains the native macOS app project and the local `BluetoothHealth` Swift package.

The first launch may request Bluetooth access. End-to-end BLE testing requires a physical iPhone.

To build the native app from Terminal using the active Xcode command-line tools:

```sh
xcodebuild -workspace PulseStream.xcworkspace \
  -scheme HeartRateBroadcaster \
  -destination 'platform=macOS' build
```

## Test

```sh
swift test
```

## Planned repository shape

```text
PulseStream
├── PulseStream.xcworkspace
├── PulseStream.xcodeproj
├── Apps/HeartRateBroadcaster (native macOS app)
├── BluetoothHealth package
│   ├── heart-rate profile and packet codec (implemented)
│   ├── generic BLE transport (planned)
│   └── deterministic test implementations (planned)
└── iOS PulseStream
    └── scan, connect, stream, chart and recover
```
