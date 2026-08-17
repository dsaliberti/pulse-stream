import Foundation
import Testing
@testable import BluetoothHealth

@Suite("Heart Rate Measurement codec")
struct HeartRateMeasurementTests {
  @Test("Encodes and decodes an 8-bit heart rate")
  func eightBitHeartRate() throws {
    let measurement = HeartRateMeasurement(
      beatsPerMinute: 72,
      contactDetected: nil,
      energyExpended: nil,
      rrIntervals: []
    )

    let data = measurement.encoded()

    #expect(Array(data) == [0b0000_0000, 72])
    #expect(try HeartRateMeasurement(decoding: data) == measurement)
  }

  @Test("Encodes optional fields in little-endian order")
  func optionalFields() throws {
    let measurement = HeartRateMeasurement(
      beatsPerMinute: 300,
      contactDetected: true,
      energyExpended: 513,
      rrIntervals: [1_024]
    )

    let data = measurement.encoded()

    #expect(Array(data) == [
      0b0001_1111,
      0x2C, 0x01,
      0x01, 0x02,
      0x00, 0x04,
    ])
    #expect(try HeartRateMeasurement(decoding: data) == measurement)
  }

  @Test("Decodes multiple RR intervals")
  func multipleRRIntervals() throws {
    let measurement = try HeartRateMeasurement(
      decoding: Data([0b0001_0000, 60, 0x00, 0x04, 0x10, 0x04])
    )

    #expect(measurement.rrIntervals == [1_024, 1_040])
  }

  @Test("Rejects truncated packets")
  func truncatedPacket() {
    #expect(throws: HeartRateMeasurementDecodingError.truncated) {
      try HeartRateMeasurement(decoding: Data([0b0000_0001, 0x2C]))
    }
  }

  @Test("Rejects incomplete RR intervals")
  func incompleteRRInterval() {
    #expect(throws: HeartRateMeasurementDecodingError.invalidRRIntervals) {
      try HeartRateMeasurement(decoding: Data([0b0001_0000, 72, 0x00]))
    }
  }
}
