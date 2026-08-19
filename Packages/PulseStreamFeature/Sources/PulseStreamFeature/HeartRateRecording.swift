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
  case active(
    startedAt: Date,
    resumedAt: Date,
    accumulatedDuration: TimeInterval
  )
  case idle
  case paused(startedAt: Date, accumulatedDuration: TimeInterval)

  public var isActive: Bool {
    if case .active = self { true } else { false }
  }

  public var isPaused: Bool {
    if case .paused = self { true } else { false }
  }

  private enum CodingKeys: String, CaseIterable, CodingKey {
    case active
    case finished
    case idle
    case paused
  }

  private struct ActivePayload: Codable {
    let accumulatedDuration: TimeInterval?
    let resumedAt: Date?
    let startedAt: Date
  }

  private struct EmptyPayload: Codable {}

  private struct FinishedPayload: Codable {
    let endedAt: Date
    let startedAt: Date
  }

  private struct PausedPayload: Codable {
    let accumulatedDuration: TimeInterval
    let startedAt: Date
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let encodedCases = CodingKeys.allCases.filter(container.contains)
    guard encodedCases.count == 1, let encodedCase = encodedCases.first else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Expected exactly one heart-rate recording state"
        )
      )
    }

    switch encodedCase {
    case .active:
      let payload = try container.decode(ActivePayload.self, forKey: .active)
      self = .active(
        startedAt: payload.startedAt,
        resumedAt: payload.resumedAt ?? payload.startedAt,
        accumulatedDuration: max(0, payload.accumulatedDuration ?? 0)
      )

    case .finished:
      let payload = try container.decode(FinishedPayload.self, forKey: .finished)
      self = .paused(
        startedAt: payload.startedAt,
        accumulatedDuration: max(0, payload.endedAt.timeIntervalSince(payload.startedAt))
      )

    case .idle:
      _ = try container.decode(EmptyPayload.self, forKey: .idle)
      self = .idle

    case .paused:
      let payload = try container.decode(PausedPayload.self, forKey: .paused)
      self = .paused(
        startedAt: payload.startedAt,
        accumulatedDuration: max(0, payload.accumulatedDuration)
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .active(startedAt, resumedAt, accumulatedDuration):
      try container.encode(
        ActivePayload(
          accumulatedDuration: accumulatedDuration,
          resumedAt: resumedAt,
          startedAt: startedAt
        ),
        forKey: .active
      )

    case .idle:
      try container.encode(EmptyPayload(), forKey: .idle)

    case let .paused(startedAt, accumulatedDuration):
      try container.encode(
        PausedPayload(
          accumulatedDuration: accumulatedDuration,
          startedAt: startedAt
        ),
        forKey: .paused
      )
    }
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
