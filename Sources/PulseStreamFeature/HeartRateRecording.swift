import Foundation

public struct HeartRateSample: Codable, Equatable, Identifiable, Sendable {
  public let beatsPerMinute: UInt16
  public let id: Int
  public let segment: Int
  public let timestamp: Date

  public init(beatsPerMinute: UInt16, id: Int, segment: Int, timestamp: Date) {
    self.beatsPerMinute = beatsPerMinute
    self.id = id
    self.segment = segment
    self.timestamp = timestamp
  }
}

public struct HeartRateStatistics: Equatable, Sendable {
  public let average: Double
  public let maximum: UInt16
  public let minimum: UInt16

  public init(average: Double, maximum: UInt16, minimum: UInt16) {
    self.average = average
    self.maximum = maximum
    self.minimum = minimum
  }

  public init?(samples: [HeartRateSample]) {
    guard let first = samples.first else { return nil }

    var maximum = first.beatsPerMinute
    var minimum = first.beatsPerMinute
    var total = 0
    for sample in samples {
      maximum = max(maximum, sample.beatsPerMinute)
      minimum = min(minimum, sample.beatsPerMinute)
      total += Int(sample.beatsPerMinute)
    }

    self.average = Double(total) / Double(samples.count)
    self.maximum = maximum
    self.minimum = minimum
  }
}

public enum HeartRateRecording: Codable, Equatable, Sendable {
  case active(startedAt: Date)
  case finished(startedAt: Date, endedAt: Date)
  case idle

  public var isActive: Bool {
    if case .active = self { true } else { false }
  }
}

public struct HeartRateRecordingSnapshot: Codable, Equatable, Sendable {
  public let currentSegment: Int
  public let nextSampleID: Int
  public let recording: HeartRateRecording
  public let samples: [HeartRateSample]

  public init(
    currentSegment: Int,
    nextSampleID: Int,
    recording: HeartRateRecording,
    samples: [HeartRateSample]
  ) {
    self.currentSegment = currentSegment
    self.nextSampleID = nextSampleID
    self.recording = recording
    self.samples = samples
  }
}
