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

extension Array where Element == HeartRateSample {
  func chartSamples(maximumCount: Int) -> [HeartRateSample] {
    guard maximumCount > 0, count > maximumCount else { return self }

    let interval = Swift.max(1, Int(ceil(Double(count) / Double(maximumCount))))
    var result: [HeartRateSample] = []
    result.reserveCapacity(maximumCount)

    for index in indices where index.isMultiple(of: interval) {
      result.append(self[index])
    }

    for index in indices.dropFirst() where self[index - 1].segment != self[index].segment {
      result.append(self[index - 1])
      result.append(self[index])
    }

    if let last, result.last?.id != last.id {
      result.append(last)
    }

    return result
      .sorted { $0.id < $1.id }
      .reduce(into: []) { samples, sample in
        if samples.last?.id != sample.id {
          samples.append(sample)
        }
      }
  }
}
