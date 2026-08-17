@preconcurrency import CoreBluetooth
import BluetoothHealth
import Foundation

@MainActor
final class HeartRatePeripheralManager: NSObject, ObservableObject {
  enum Status: Equatable {
    case bluetoothUnavailable
    case ready
    case advertising
    case subscribed
    case resetting

    var title: String {
      switch self {
      case .bluetoothUnavailable: "Bluetooth unavailable"
      case .ready: "Ready"
      case .advertising: "Waiting for an iPhone"
      case .subscribed: "iPhone subscribed"
      case .resetting: "Dropping session"
      }
    }
  }

  @Published private(set) var status = Status.bluetoothUnavailable
  @Published private(set) var isAdvertising = false
  @Published private(set) var subscriberCount = 0
  @Published private(set) var sentMeasurementCount = 0
  @Published var beatsPerMinute = 72
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
  }

  func toggleBroadcasting() {
    isAdvertising ? stopBroadcasting() : startBroadcasting()
  }

  func startBroadcasting() {
    guard peripheralManager.state == .poweredOn else {
      status = .bluetoothUnavailable
      return
    }
    publishServiceAndAdvertise()
  }

  func stopBroadcasting() {
    measurementTask?.cancel()
    measurementTask = nil
    peripheralManager.stopAdvertising()
    peripheralManager.removeAllServices()
    measurementCharacteristic = nil
    subscribedCentralIDs.removeAll()
    subscriberCount = 0
    isAdvertising = false
    pendingMeasurement = nil
    status = peripheralManager.state == .poweredOn ? .ready : .bluetoothUnavailable
  }

  func sendCurrentMeasurement() {
    let measurement = HeartRateMeasurement(
      beatsPerMinute: UInt16(clamping: beatsPerMinute),
      contactDetected: true,
      energyExpended: nil,
      rrIntervals: [UInt16(60 * 1_024 / max(beatsPerMinute, 1))]
    )
    send(measurement.encoded())
  }

  func dropSession() {
    guard isAdvertising else { return }
    status = .resetting
    stopBroadcasting()

    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1))
      self?.startBroadcasting()
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
        status = .ready
      } else {
        stopBroadcasting()
        status = .bluetoothUnavailable
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
      guard error == nil else {
        stopBroadcasting()
        return
      }
      peripheralManager.startAdvertising([
        CBAdvertisementDataServiceUUIDsKey: [Self.heartRateServiceID],
        CBAdvertisementDataLocalNameKey: "PulseStream Mac",
      ])
      isAdvertising = true
      status = .advertising
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
      status = subscriberCount == 0 ? .advertising : .subscribed
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
