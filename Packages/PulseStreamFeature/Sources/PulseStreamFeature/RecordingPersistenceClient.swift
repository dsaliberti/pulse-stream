import Dependencies
import Foundation
import Sharing

public struct RecordingPersistenceClient: Sendable {
  public var load: @Sendable () async throws -> HeartRateRecordingSnapshot?
  public var save: @Sendable (HeartRateRecordingSnapshot) async throws -> Void

  public init(
    load: @escaping @Sendable () async throws -> HeartRateRecordingSnapshot?,
    save: @escaping @Sendable (HeartRateRecordingSnapshot) async throws -> Void
  ) {
    self.load = load
    self.save = save
  }
}

extension RecordingPersistenceClient: DependencyKey {
  public static var liveValue: Self {
    .sharingFileStorage()
  }

  public static var testValue: Self {
    Self(load: { nil }, save: { _ in })
  }
}

extension RecordingPersistenceClient {
  static func sharingFileStorage(
    fileURL: URL? = nil
  ) -> Self {
    let fileURL = fileURL ?? URL.applicationSupportDirectory
      .appending(component: "PulseStream")
      .appending(component: "recording.json")
    let snapshot = Shared<HeartRateRecordingSnapshot?>(
      .fileStorage(fileURL)
    )
    return Self(
      load: {
        try await snapshot.load()
        return snapshot.wrappedValue
      },
      save: { value in
        snapshot.withLock { $0 = value }
        try await snapshot.save()
      }
    )
  }
}

extension DependencyValues {
  public var recordingPersistence: RecordingPersistenceClient {
    get { self[RecordingPersistenceClient.self] }
    set { self[RecordingPersistenceClient.self] = newValue }
  }
}
