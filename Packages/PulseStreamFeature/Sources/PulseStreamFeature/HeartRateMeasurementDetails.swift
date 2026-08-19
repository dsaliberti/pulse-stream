import BluetoothHealth
import Foundation

public struct HeartRateMeasurementDetails: Equatable, Sendable {
  public enum Contact: Equatable, Sendable {
    case detected
    case notDetected
    case unsupported
  }

  public let contact: Contact
  public let energyExpendedKilojoules: UInt16?
  public let rrIntervalsMilliseconds: [Double]

  public init(measurement: HeartRateMeasurement) {
    contact = switch measurement.contactDetected {
    case true: .detected
    case false: .notDetected
    case nil: .unsupported
    }
    energyExpendedKilojoules = measurement.energyExpended
    rrIntervalsMilliseconds = measurement.rrIntervals.map {
      Double($0) * 1_000 / 1_024
    }
  }

  public init(
    contact: Contact,
    energyExpendedKilojoules: UInt16?,
    rrIntervalsMilliseconds: [Double]
  ) {
    self.contact = contact
    self.energyExpendedKilojoules = energyExpendedKilojoules
    self.rrIntervalsMilliseconds = rrIntervalsMilliseconds
  }

  public var latestRRIntervalMilliseconds: Double? {
    rrIntervalsMilliseconds.last
  }
}
