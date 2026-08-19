@preconcurrency import CoreBluetooth
import BluetoothHealth
import Dependencies
import Foundation

public struct HeartRateClient: Sendable {
  public enum Failure: Equatable, Sendable {
    case characteristicDiscoveryFailed(description: String?)
    case connectionFailed(description: String?)
    case discoveryTimedOut
    case invalidMeasurement
    case measurementUnavailable(description: String?)
    case reconnectionExhausted
    case serviceDiscoveryFailed(description: String?)
    case serviceInvalidated
    case subscriptionFailed(description: String?)

    public var message: String {
      switch self {
      case let .characteristicDiscoveryFailed(description):
        description ?? "Heart Rate Measurement characteristic not found"
      case let .connectionFailed(description):
        description ?? "Connection failed"
      case .discoveryTimedOut:
        "PulseStream Mac wasn’t found"
      case .invalidMeasurement:
        "Heart rate measurement could not be decoded"
      case let .measurementUnavailable(description):
        description ?? "Heart rate measurement was empty"
      case .reconnectionExhausted:
        "Could not restore the heart-rate connection"
      case let .serviceDiscoveryFailed(description):
        description ?? "Heart Rate Service not found"
      case .serviceInvalidated:
        "The Heart Rate Service changed"
      case let .subscriptionFailed(description):
        description ?? "Could not subscribe to heart rate measurements"
      }
    }
  }

  public enum Event: Equatable, Sendable {
    case bluetoothUnavailable
    case connected(name: String)
    case connecting(name: String)
    case disconnected
    case discovering(name: String)
    case failed(Failure)
    case measurement(HeartRateMeasurement)
    case measurementRejected(HeartRateMeasurementDecodingError)
    case scanning
  }

  public var cancelConnectionAttempt: @Sendable () async -> Void
  public var disconnect: @Sendable () async -> Void
  public var events: @Sendable () async -> AsyncStream<Event>
  public var scan: @Sendable () async -> Void

  public init(
    cancelConnectionAttempt: @escaping @Sendable () async -> Void,
    disconnect: @escaping @Sendable () async -> Void,
    events: @escaping @Sendable () async -> AsyncStream<Event>,
    scan: @escaping @Sendable () async -> Void
  ) {
    self.cancelConnectionAttempt = cancelConnectionAttempt
    self.disconnect = disconnect
    self.events = events
    self.scan = scan
  }
}

extension HeartRateClient: DependencyKey {
  public static var liveValue: Self {
    Self(
      cancelConnectionAttempt: { await LiveHeartRateCentral.shared.cancelConnectionAttempt() },
      disconnect: { await LiveHeartRateCentral.shared.disconnect() },
      events: { await LiveHeartRateCentral.shared.events() },
      scan: { await LiveHeartRateCentral.shared.scan() }
    )
  }

  public static var testValue: Self {
    Self(
      cancelConnectionAttempt: {},
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
  private var scanRequested = false
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
    scanRequested = false
    suppressNextDisconnectEvent = false
    guard let peripheral else {
      continuation?.yield(.disconnected)
      return
    }
    centralManager.cancelPeripheralConnection(peripheral)
  }

  func cancelConnectionAttempt() {
    centralManager.stopScan()
    scanRequested = false
    guard let peripheral else { return }
    suppressNextDisconnectEvent = true
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
    }
  }

  func scan() {
    scanRequested = true

    switch centralManager.state {
    case .poweredOn:
      startRequestedScan()
    case .unknown, .resetting:
      return
    case .unsupported, .unauthorized, .poweredOff:
      continuation?.yield(.bluetoothUnavailable)
    @unknown default:
      continuation?.yield(.bluetoothUnavailable)
    }
  }

  private func startRequestedScan() {
    guard scanRequested, centralManager.state == .poweredOn else { return }
    scanRequested = false

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

  private func fail(_ failure: HeartRateClient.Failure) {
    centralManager.stopScan()
    continuation?.yield(.failed(failure))
    if let peripheral {
      suppressNextDisconnectEvent = true
      centralManager.cancelPeripheralConnection(peripheral)
    }
  }

  private func stopEvents(ifCurrent eventStreamID: Int) {
    guard self.eventStreamID == eventStreamID else { return }
    centralManager.stopScan()
    scanRequested = false
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
      switch central.state {
      case .poweredOn:
        startRequestedScan()
      case .unknown, .resetting:
        break
      case .unsupported, .unauthorized, .poweredOff:
        continuation?.yield(.bluetoothUnavailable)
      @unknown default:
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
      if suppressNextDisconnectEvent {
        suppressNextDisconnectEvent = false
        return
      }
      continuation?.yield(.failed(.connectionFailed(description: error?.localizedDescription)))
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
  nonisolated func peripheral(
    _ peripheral: CBPeripheral,
    didModifyServices invalidatedServices: [CBService]
  ) {
    let heartRateServiceID = CBUUID(string: HeartRateProfile.serviceUUID)
    let didInvalidateHeartRateService = invalidatedServices.contains {
      $0.uuid == heartRateServiceID
    }
    Task { @MainActor [weak self] in
      guard
        let self,
        peripheral == self.peripheral,
        didInvalidateHeartRateService
      else { return }
      fail(.serviceInvalidated)
    }
  }

  nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
    Task { @MainActor [weak self] in
      guard let self, peripheral == self.peripheral else { return }
      guard error == nil,
        let service = peripheral.services?.first(where: { $0.uuid == Self.heartRateServiceID })
      else {
        fail(.serviceDiscoveryFailed(description: error?.localizedDescription))
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
        fail(.characteristicDiscoveryFailed(description: error?.localizedDescription))
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
        fail(.subscriptionFailed(description: error?.localizedDescription))
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
        fail(.measurementUnavailable(description: error?.localizedDescription))
        return
      }
      do {
        continuation?.yield(.measurement(try HeartRateMeasurement(decoding: data)))
      } catch let error as HeartRateMeasurementDecodingError {
        continuation?.yield(.measurementRejected(error))
      }
    }
  }
}
