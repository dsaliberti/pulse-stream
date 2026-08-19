@preconcurrency import CoreBluetooth
import BluetoothHealth
import Foundation

@MainActor
final class HeartRatePeripheralManager: NSObject, ObservableObject {
  enum MalformedPacket: String, CaseIterable, Identifiable {
    case incompleteRRInterval
    case trailingByte
    case truncatedHeartRate

    var id: Self { self }

    var data: Data {
      switch self {
      case .incompleteRRInterval: Data([0b0001_0000, 72, 0])
      case .trailingByte: Data([0, 72, 0xFF])
      case .truncatedHeartRate: Data([0b0000_0001, 72])
      }
    }

    var title: String {
      switch self {
      case .incompleteRRInterval: "Incomplete RR interval"
      case .trailingByte: "Unexpected trailing byte"
      case .truncatedHeartRate: "Truncated 16-bit BPM"
      }
    }
  }

  enum SensorContact: String, CaseIterable, Identifiable {
    case detected
    case notDetected
    case unsupported

    var id: Self { self }

    var title: String {
      switch self {
      case .detected: "Good"
      case .notDetected: "Poor"
      case .unsupported: "Unsupported"
      }
    }

    var measurementValue: Bool? {
      switch self {
      case .detected: true
      case .notDetected: false
      case .unsupported: nil
      }
    }
  }

  enum Status: Equatable {
    case bluetoothUnavailable
    case ready
    case starting
    case advertising
    case subscribed
    case resetting
    case failed(message: String)

    var title: String {
      switch self {
      case .bluetoothUnavailable: "Bluetooth unavailable"
      case .ready: "Ready"
      case .starting: "Starting broadcaster"
      case .advertising: "Waiting for an iPhone"
      case .subscribed: "iPhone subscribed"
      case .resetting: "Dropping session"
      case let .failed(message): message
      }
    }
  }

  @Published private(set) var status = Status.bluetoothUnavailable
  @Published private(set) var isAdvertising = false
  @Published private(set) var subscriberCount = 0
  @Published private(set) var sentMeasurementCount = 0
  @Published var beatsPerMinute = 72
  @Published var energyExpendedKilojoules = 42
  @Published var includesEnergyExpended = false
  @Published var malformedPacket = MalformedPacket.truncatedHeartRate
  @Published var rrIntervalCount = 1
  @Published var sensorContact = SensorContact.detected
  @Published var uses16BitHeartRate = false
  @Published var variesAutomatically = true {
    didSet { updateAutomaticMeasurements() }
  }

  private static let heartRateServiceID = CBUUID(string: HeartRateProfile.serviceUUID)
  private static let measurementCharacteristicID = CBUUID(
    string: HeartRateProfile.measurementCharacteristicUUID
  )

  private var peripheralManager: CBPeripheralManager!
  private var measurementCharacteristic: CBMutableCharacteristic?
  private var subscribedCentralIDs: Set<UUID> = []
  private var measurementTask: Task<Void, Never>?
  private var pendingMeasurement: Data?
  private var sessionResetTask: Task<Void, Never>?
  private var variationStep = 1

  override init() {
    super.init()
    peripheralManager = CBPeripheralManager(
      delegate: self,
      queue: .main,
      options: [CBPeripheralManagerOptionShowPowerAlertKey: true]
    )
  }

  deinit {
    measurementTask?.cancel()
    sessionResetTask?.cancel()
  }

  func toggleBroadcasting() {
    isAdvertising ? stopBroadcasting() : startBroadcasting()
  }

  func startBroadcasting() {
    sessionResetTask?.cancel()
    sessionResetTask = nil
    guard peripheralManager.state == .poweredOn else {
      status = .bluetoothUnavailable
      return
    }
    publishServiceAndAdvertise()
  }

  func stopBroadcasting() {
    sessionResetTask?.cancel()
    sessionResetTask = nil
    tearDownBroadcasting(
      status: peripheralManager.state == .poweredOn ? .ready : .bluetoothUnavailable
    )
  }

  private func tearDownBroadcasting(status: Status) {
    measurementTask?.cancel()
    measurementTask = nil
    peripheralManager.stopAdvertising()
    peripheralManager.removeAllServices()
    measurementCharacteristic = nil
    subscribedCentralIDs.removeAll()
    subscriberCount = 0
    isAdvertising = false
    pendingMeasurement = nil
    self.status = status
  }

  func sendCurrentMeasurement() {
    let baseRRInterval = UInt16(60 * 1_024 / max(beatsPerMinute, 1))
    let measurement = HeartRateMeasurement(
      beatsPerMinute: UInt16(clamping: beatsPerMinute),
      contactDetected: sensorContact.measurementValue,
      energyExpended: includesEnergyExpended
        ? UInt16(clamping: energyExpendedKilojoules)
        : nil,
      rrIntervals: (0..<rrIntervalCount).map { index in
        baseRRInterval &+ UInt16(index * 8)
      }
    )
    send(measurement.encoded(format: uses16BitHeartRate ? .uint16 : .uint8))
  }

  func sendMalformedMeasurement() {
    send(malformedPacket.data)
  }

  func dropSession() {
    guard isAdvertising else { return }
    sessionResetTask?.cancel()
    tearDownBroadcasting(status: .resetting)

    sessionResetTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        return
      }
      guard let self, peripheralManager.state == .poweredOn else { return }
      sessionResetTask = nil
      publishServiceAndAdvertise()
    }
  }

  private func publishServiceAndAdvertise() {
    peripheralManager.stopAdvertising()
    peripheralManager.removeAllServices()

    let characteristic = CBMutableCharacteristic(
      type: Self.measurementCharacteristicID,
      properties: [.notify],
      value: nil,
      permissions: []
    )
    let service = CBMutableService(type: Self.heartRateServiceID, primary: true)
    service.characteristics = [characteristic]
    measurementCharacteristic = characteristic
    status = .starting
    peripheralManager.add(service)
  }

  private func send(_ data: Data) {
    guard let measurementCharacteristic, subscriberCount > 0 else { return }
    guard peripheralManager.updateValue(
      data,
      for: measurementCharacteristic,
      onSubscribedCentrals: nil
    ) else {
      pendingMeasurement = data
      return
    }
    pendingMeasurement = nil
    sentMeasurementCount += 1
  }

  private func updateAutomaticMeasurements() {
    measurementTask?.cancel()
    measurementTask = nil
    guard variesAutomatically, subscriberCount > 0 else { return }

    measurementTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let self else { return }
        beatsPerMinute += variationStep
        if beatsPerMinute >= 94 || beatsPerMinute <= 62 {
          variationStep *= -1
        }
        sendCurrentMeasurement()
      }
    }
  }
}

extension HeartRatePeripheralManager: CBPeripheralManagerDelegate {
  nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      if peripheral.state == .poweredOn {
        if status == .bluetoothUnavailable {
          status = .ready
        }
      } else {
        sessionResetTask?.cancel()
        sessionResetTask = nil
        tearDownBroadcasting(status: .bluetoothUnavailable)
      }
    }
  }

  nonisolated func peripheralManager(
    _ peripheral: CBPeripheralManager,
    didAdd service: CBService,
    error: (any Error)?
  ) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      guard service.uuid == Self.heartRateServiceID, status == .starting else { return }
      guard let error else {
        peripheralManager.startAdvertising([
          CBAdvertisementDataServiceUUIDsKey: [Self.heartRateServiceID],
          CBAdvertisementDataLocalNameKey: "PulseStream Mac",
        ])
        return
      }
      tearDownBroadcasting(
        status: .failed(message: "Could not publish service: \(error.localizedDescription)")
      )
    }
  }

  nonisolated func peripheralManagerDidStartAdvertising(
    _ peripheral: CBPeripheralManager,
    error: (any Error)?
  ) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      guard status == .starting else {
        peripheral.stopAdvertising()
        return
      }
      guard let error else {
        isAdvertising = true
        status = .advertising
        return
      }
      tearDownBroadcasting(
        status: .failed(message: "Could not advertise: \(error.localizedDescription)")
      )
    }
  }

  nonisolated func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didSubscribeTo characteristic: CBCharacteristic
  ) {
    Task { @MainActor [weak self] in
      guard let self, characteristic.uuid == Self.measurementCharacteristicID else { return }
      subscribedCentralIDs.insert(central.identifier)
      subscriberCount = subscribedCentralIDs.count
      status = .subscribed
      sendCurrentMeasurement()
      updateAutomaticMeasurements()
    }
  }

  nonisolated func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didUnsubscribeFrom characteristic: CBCharacteristic
  ) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      subscribedCentralIDs.remove(central.identifier)
      subscriberCount = subscribedCentralIDs.count
      if subscriberCount > 0 {
        status = .subscribed
      } else {
        status = isAdvertising ? .advertising : .ready
      }
      updateAutomaticMeasurements()
    }
  }

  nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    Task { @MainActor [weak self] in
      guard let self, let pendingMeasurement else { return }
      send(pendingMeasurement)
    }
  }
}
