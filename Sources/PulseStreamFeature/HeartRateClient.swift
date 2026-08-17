@preconcurrency import CoreBluetooth
import BluetoothHealth
import Dependencies
import Foundation

public struct HeartRateClient: Sendable {
  public enum Event: Equatable, Sendable {
    case bluetoothUnavailable
    case connected(name: String)
    case connecting(name: String)
    case disconnected
    case discovering(name: String)
    case failed(message: String)
    case measurement(HeartRateMeasurement)
    case scanning
  }

  public var disconnect: @Sendable () async -> Void
  public var events: @Sendable () async -> AsyncStream<Event>
  public var scan: @Sendable () async -> Void

  public init(
    disconnect: @escaping @Sendable () async -> Void,
    events: @escaping @Sendable () async -> AsyncStream<Event>,
    scan: @escaping @Sendable () async -> Void
  ) {
    self.disconnect = disconnect
    self.events = events
    self.scan = scan
  }
}

extension HeartRateClient: DependencyKey {
  public static var liveValue: Self {
    Self(
      disconnect: { await LiveHeartRateCentral.shared.disconnect() },
      events: { await LiveHeartRateCentral.shared.events() },
      scan: { await LiveHeartRateCentral.shared.scan() }
    )
  }

  public static var testValue: Self {
    Self(
      disconnect: {},
      events: {
        AsyncStream { continuation in
          continuation.finish()
        }
      },
      scan: {}
    )
  }
}

extension DependencyValues {
  public var heartRateClient: HeartRateClient {
    get { self[HeartRateClient.self] }
    set { self[HeartRateClient.self] = newValue }
  }
}

@MainActor
private final class LiveHeartRateCentral: NSObject {
  static let shared = LiveHeartRateCentral()

  private static let heartRateServiceID = CBUUID(string: HeartRateProfile.serviceUUID)
  private static let measurementCharacteristicID = CBUUID(
    string: HeartRateProfile.measurementCharacteristicUUID
  )

  private var centralManager: CBCentralManager!
  private var continuation: AsyncStream<HeartRateClient.Event>.Continuation?
  private var deviceName = "PulseStream Mac"
  private var eventStreamID = 0
  private var peripheral: CBPeripheral?
  private var suppressNextDisconnectEvent = false

  private override init() {
    super.init()
    centralManager = CBCentralManager(
      delegate: self,
      queue: .main,
      options: [CBCentralManagerOptionShowPowerAlertKey: true]
    )
  }

  func disconnect() {
    centralManager.stopScan()
    suppressNextDisconnectEvent = false
    guard let peripheral else {
      continuation?.yield(.disconnected)
      return
    }
    centralManager.cancelPeripheralConnection(peripheral)
  }

  func events() -> AsyncStream<HeartRateClient.Event> {
    AsyncStream(bufferingPolicy: .bufferingNewest(20)) { continuation in
      self.continuation?.onTermination = nil
      self.continuation?.finish()
      eventStreamID += 1
      let eventStreamID = eventStreamID
      self.continuation = continuation
      continuation.onTermination = { @Sendable [weak self] _ in
        Task { @MainActor in
          self?.stopEvents(ifCurrent: eventStreamID)
        }
      }
      scan()
    }
  }

  func scan() {
    switch centralManager.state {
    case .poweredOn:
      break
    case .unknown:
      return
    case .resetting, .unsupported, .unauthorized, .poweredOff:
      continuation?.yield(.bluetoothUnavailable)
      return
    @unknown default:
      continuation?.yield(.bluetoothUnavailable)
      return
    }

    suppressNextDisconnectEvent = false
    if let peripheral {
      centralManager.cancelPeripheralConnection(peripheral)
      self.peripheral = nil
    }
    continuation?.yield(.scanning)
    centralManager.scanForPeripherals(
      withServices: [Self.heartRateServiceID],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    )
  }

  private func fail(_ message: String) {
    centralManager.stopScan()
    continuation?.yield(.failed(message: message))
    if let peripheral {
      suppressNextDisconnectEvent = true
      centralManager.cancelPeripheralConnection(peripheral)
    }
  }

  private func stopEvents(ifCurrent eventStreamID: Int) {
    guard self.eventStreamID == eventStreamID else { return }
    centralManager.stopScan()
    continuation = nil
    if let peripheral {
      centralManager.cancelPeripheralConnection(peripheral)
      self.peripheral = nil
    }
  }
}

extension LiveHeartRateCentral: CBCentralManagerDelegate {
  nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      if central.state == .poweredOn {
        scan()
      } else {
        continuation?.yield(.bluetoothUnavailable)
      }
    }
  }

  nonisolated func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
    Task { @MainActor [weak self] in
      guard let self, self.peripheral == nil else { return }
      central.stopScan()
      deviceName =
        advertisedName
        ?? peripheral.name
        ?? "PulseStream Mac"
      self.peripheral = peripheral
      peripheral.delegate = self
      continuation?.yield(.connecting(name: deviceName))
      central.connect(peripheral)
    }
  }

  nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    Task { @MainActor [weak self] in
      guard let self, peripheral == self.peripheral else { return }
      continuation?.yield(.discovering(name: deviceName))
      peripheral.discoverServices([Self.heartRateServiceID])
    }
  }

  nonisolated func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: (any Error)?
  ) {
    Task { @MainActor [weak self] in
      guard let self, peripheral == self.peripheral else { return }
      self.peripheral = nil
      continuation?.yield(.failed(message: error?.localizedDescription ?? "Connection failed"))
    }
  }

  nonisolated func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    timestamp: CFAbsoluteTime,
    isReconnecting: Bool,
    error: (any Error)?
  ) {
    Task { @MainActor [weak self] in
      guard let self, peripheral == self.peripheral else { return }
      self.peripheral = nil
      if suppressNextDisconnectEvent {
        suppressNextDisconnectEvent = false
        return
      }
      continuation?.yield(.disconnected)
    }
  }
}

extension LiveHeartRateCentral: CBPeripheralDelegate {
  nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
    Task { @MainActor [weak self] in
      guard let self, peripheral == self.peripheral else { return }
      guard error == nil,
        let service = peripheral.services?.first(where: { $0.uuid == Self.heartRateServiceID })
      else {
        fail(error?.localizedDescription ?? "Heart Rate Service not found")
        return
      }
      peripheral.discoverCharacteristics([Self.measurementCharacteristicID], for: service)
    }
  }

  nonisolated func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: (any Error)?
  ) {
    Task { @MainActor [weak self] in
      guard let self, peripheral == self.peripheral else { return }
      guard error == nil,
        let characteristic = service.characteristics?.first(where: {
          $0.uuid == Self.measurementCharacteristicID
        })
      else {
        fail(error?.localizedDescription ?? "Heart Rate Measurement characteristic not found")
        return
      }
      peripheral.setNotifyValue(true, for: characteristic)
    }
  }

  nonisolated func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: (any Error)?
  ) {
    Task { @MainActor [weak self] in
      guard let self, peripheral == self.peripheral else { return }
      guard characteristic.uuid == Self.measurementCharacteristicID else { return }
      guard error == nil, characteristic.isNotifying else {
        fail(error?.localizedDescription ?? "Could not subscribe to heart rate measurements")
        return
      }
      continuation?.yield(.connected(name: deviceName))
    }
  }

  nonisolated func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: (any Error)?
  ) {
    Task { @MainActor [weak self] in
      guard let self, peripheral == self.peripheral else { return }
      guard characteristic.uuid == Self.measurementCharacteristicID else { return }
      guard error == nil, let data = characteristic.value else {
        fail(error?.localizedDescription ?? "Heart rate measurement was empty")
        return
      }
      do {
        continuation?.yield(.measurement(try HeartRateMeasurement(decoding: data)))
      } catch {
        fail("Heart rate measurement could not be decoded")
      }
    }
  }
}
