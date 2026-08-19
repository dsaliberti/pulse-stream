import Foundation

public enum HeartRateProfile {
  public static let serviceUUID = "180D"
  public static let measurementCharacteristicUUID = "2A37"
}

public enum HeartRateValueFormat: Equatable, Sendable {
  case uint8
  case uint16
}

public struct HeartRateMeasurement: Equatable, Sendable {
  public var beatsPerMinute: UInt16
  public var contactDetected: Bool?
  public var energyExpended: UInt16?
  public var rrIntervals: [UInt16]

  public init(
    beatsPerMinute: UInt16,
    contactDetected: Bool?,
    energyExpended: UInt16?,
    rrIntervals: [UInt16]
  ) {
    self.beatsPerMinute = beatsPerMinute
    self.contactDetected = contactDetected
    self.energyExpended = energyExpended
    self.rrIntervals = rrIntervals
  }

  public func encoded() -> Data {
    encoded(format: beatsPerMinute > UInt8.max ? .uint16 : .uint8)
  }

  public func encoded(format: HeartRateValueFormat) -> Data {
    precondition(
      format == .uint16 || beatsPerMinute <= UInt8.max,
      "An 8-bit heart-rate value cannot exceed 255 BPM"
    )
    var flags: UInt8 = format == .uint16 ? 0b0000_0001 : 0

    if let contactDetected {
      flags |= 0b0000_0100
      if contactDetected {
        flags |= 0b0000_0010
      }
    }
    if energyExpended != nil {
      flags |= 0b0000_1000
    }
    if !rrIntervals.isEmpty {
      flags |= 0b0001_0000
    }

    var bytes = [flags]
    if format == .uint16 {
      bytes.append(contentsOf: beatsPerMinute.littleEndianBytes)
    } else {
      bytes.append(UInt8(beatsPerMinute))
    }
    if let energyExpended {
      bytes.append(contentsOf: energyExpended.littleEndianBytes)
    }
    for interval in rrIntervals {
      bytes.append(contentsOf: interval.littleEndianBytes)
    }
    return Data(bytes)
  }

  public init(decoding data: Data) throws {
    let bytes = Array(data)
    guard let flags = bytes.first else { throw HeartRateMeasurementDecodingError.truncated }
    var index = 1

    func readUInt8() throws -> UInt8 {
      guard index < bytes.count else { throw HeartRateMeasurementDecodingError.truncated }
      defer { index += 1 }
      return bytes[index]
    }

    func readUInt16() throws -> UInt16 {
      guard index + 1 < bytes.count else { throw HeartRateMeasurementDecodingError.truncated }
      defer { index += 2 }
      return UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }

    beatsPerMinute = try flags & 0b0000_0001 == 0 ? UInt16(readUInt8()) : readUInt16()
    contactDetected = flags & 0b0000_0100 == 0 ? nil : flags & 0b0000_0010 != 0
    energyExpended = flags & 0b0000_1000 == 0 ? nil : try readUInt16()

    if flags & 0b0001_0000 != 0 {
      let remainingByteCount = bytes.count - index
      guard remainingByteCount >= 2, remainingByteCount.isMultiple(of: 2) else {
        throw HeartRateMeasurementDecodingError.invalidRRIntervals
      }
      var intervals: [UInt16] = []
      while index < bytes.count {
        try intervals.append(readUInt16())
      }
      rrIntervals = intervals
    } else {
      guard index == bytes.count else { throw HeartRateMeasurementDecodingError.unexpectedTrailingBytes }
      rrIntervals = []
    }
  }
}

public enum HeartRateMeasurementDecodingError: Error, Equatable, Sendable {
  case truncated
  case invalidRRIntervals
  case unexpectedTrailingBytes

  public var message: String {
    switch self {
    case .truncated: "Packet ended before all declared fields were present"
    case .invalidRRIntervals: "RR interval data must contain one or more complete 16-bit values"
    case .unexpectedTrailingBytes: "Packet contained bytes not declared by its flags"
    }
  }
}

private extension UInt16 {
  var littleEndianBytes: [UInt8] {
    [UInt8(truncatingIfNeeded: self), UInt8(truncatingIfNeeded: self >> 8)]
  }
}
