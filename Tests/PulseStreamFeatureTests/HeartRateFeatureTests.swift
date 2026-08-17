import BluetoothHealth
import ComposableArchitecture
import CustomDump
import Foundation
import Testing
@testable import PulseStreamFeature

@Suite("Heart rate feature")
struct HeartRateFeatureTests {
  private actor CallCounter {
    private(set) var value = 0

    func increment() {
      value += 1
    }
  }

  private func measurement(_ beatsPerMinute: UInt16) -> HeartRateClient.Event {
    .measurement(
      HeartRateMeasurement(
        beatsPerMinute: beatsPerMinute,
        contactDetected: true,
        energyExpended: nil,
        rrIntervals: []
      )
    )
  }

  @Test("Production persistence round-trips a recording snapshot")
  func productionPersistenceRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = RecordingPersistenceClient.fileSystem(
      fileURL: directory.appendingPathComponent("recording.json")
    )
    let snapshot = HeartRateRecordingSnapshot(
      currentSegment: 2,
      nextSampleID: 8,
      recording: .finished(
        startedAt: Date(timeIntervalSince1970: 1_000),
        endedAt: Date(timeIntervalSince1970: 1_060)
      ),
      samples: [
        HeartRateSample(
          beatsPerMinute: 72,
          id: 7,
          segment: 2,
          timestamp: Date(timeIntervalSince1970: 1_030)
        )
      ]
    )

    try await persistence.save(snapshot)
    let restoredSnapshot = try await persistence.load()

    expectNoDifference(restoredSnapshot, snapshot)
  }

  @Test("Streams connection state and measurements")
  @MainActor
  func streamsMeasurements() async {
    let (stream, continuation) = AsyncStream<HeartRateClient.Event>.makeStream()
    let store = TestStore(initialState: HeartRateFeature.State()) {
      HeartRateFeature()
    } withDependencies: {
      $0.heartRateClient.events = { stream }
    }

    await store.send(.task)

    continuation.yield(.scanning)
    await store.receive(\.eventReceived) {
      $0.connection = .scanning
    }

    continuation.yield(.connecting(name: "PulseStream Mac"))
    await store.receive(\.eventReceived) {
      $0.connection = .connecting(name: "PulseStream Mac")
    }

    continuation.yield(.connected(name: "PulseStream Mac"))
    await store.receive(\.eventReceived) {
      $0.connection = .connected(name: "PulseStream Mac")
    }

    continuation.yield(
      .measurement(
        HeartRateMeasurement(
          beatsPerMinute: 72,
          contactDetected: true,
          energyExpended: nil,
          rrIntervals: [853]
        )
      )
    )
    await store.receive(\.eventReceived) {
      $0.beatsPerMinute = 72
    }

    continuation.finish()
    await store.finish()

    var expectedState = HeartRateFeature.State()
    expectedState.beatsPerMinute = 72
    expectedState.connection = .connected(name: "PulseStream Mac")
    expectNoDifference(store.state, expectedState)
  }

  @Test("Records timestamped samples and derives statistics")
  @MainActor
  func recordsSamplesAndStatistics() async {
    let clock = TestClock()
    let now = Date(timeIntervalSince1970: 1_000)
    var state = HeartRateFeature.State()
    state.connection = .connected(name: "PulseStream Mac")
    let store = TestStore(initialState: state) {
      HeartRateFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date.now = now
    }

    await store.send(.startRecordingButtonTapped) {
      $0.recording = .active(startedAt: now)
    }
    await store.send(.eventReceived(measurement(70))) {
      $0.beatsPerMinute = 70
      $0.nextSampleID = 1
      $0.samples.append(
        HeartRateSample(beatsPerMinute: 70, id: 0, segment: 0, timestamp: now)
      )
    }
    await store.send(.eventReceived(measurement(80))) {
      $0.beatsPerMinute = 80
      $0.nextSampleID = 2
      $0.samples.append(
        HeartRateSample(beatsPerMinute: 80, id: 1, segment: 0, timestamp: now)
      )
    }
    await store.send(.eventReceived(measurement(90))) {
      $0.beatsPerMinute = 90
      $0.nextSampleID = 3
      $0.samples.append(
        HeartRateSample(beatsPerMinute: 90, id: 2, segment: 0, timestamp: now)
      )
    }

    expectNoDifference(
      store.state.statistics,
      HeartRateStatistics(average: 80, maximum: 90, minimum: 70)
    )
    await store.send(.stopRecordingButtonTapped) {
      $0.recording = .finished(startedAt: now, endedAt: now)
    }
    await store.finish()
  }

  @Test("Preserves a recording across a connection interruption")
  @MainActor
  func recordingPreservesConnectionGap() async {
    let clock = TestClock()
    let now = Date(timeIntervalSince1970: 1_000)
    var state = HeartRateFeature.State()
    state.connection = .connected(name: "PulseStream Mac")
    let store = TestStore(initialState: state) {
      HeartRateFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date.now = now
    }

    await store.send(.startRecordingButtonTapped) {
      $0.recording = .active(startedAt: now)
    }
    await store.send(.eventReceived(measurement(70))) {
      $0.beatsPerMinute = 70
      $0.nextSampleID = 1
      $0.samples.append(
        HeartRateSample(beatsPerMinute: 70, id: 0, segment: 0, timestamp: now)
      )
    }
    await store.send(.eventReceived(.disconnected)) {
      $0.beatsPerMinute = nil
      $0.connection = .reconnecting(attempt: 1, maximumAttempts: 3, delaySeconds: 1)
      $0.currentSegment = 1
      $0.isStreamInterrupted = true
      $0.retryAttempt = 1
    }
    await store.send(.eventReceived(.connected(name: "PulseStream Mac"))) {
      $0.connection = .connected(name: "PulseStream Mac")
      $0.isStreamInterrupted = false
      $0.retryAttempt = 0
    }
    await store.send(.eventReceived(measurement(75))) {
      $0.beatsPerMinute = 75
      $0.nextSampleID = 2
      $0.samples.append(
        HeartRateSample(beatsPerMinute: 75, id: 1, segment: 1, timestamp: now)
      )
    }
    await store.send(.stopRecordingButtonTapped) {
      $0.recording = .finished(startedAt: now, endedAt: now)
    }
    await store.finish()
  }

  @Test("Stops recording without stopping the live measurement")
  @MainActor
  func stopsRecording() async {
    let now = Date(timeIntervalSince1970: 1_000)
    var state = HeartRateFeature.State()
    state.connection = .connected(name: "PulseStream Mac")
    state.recording = .active(startedAt: now)
    let store = TestStore(initialState: state) {
      HeartRateFeature()
    } withDependencies: {
      $0.date.now = now
    }

    await store.send(.stopRecordingButtonTapped) {
      $0.recording = .finished(startedAt: now, endedAt: now)
    }
    await store.send(.eventReceived(measurement(88))) {
      $0.beatsPerMinute = 88
    }
  }

  @Test("Updates duration from controlled clock and date dependencies")
  @MainActor
  func updatesRecordingDuration() async {
    let clock = TestClock()
    let currentDate = LockIsolated(Date(timeIntervalSince1970: 1_000))
    var state = HeartRateFeature.State()
    state.connection = .connected(name: "PulseStream Mac")
    let store = TestStore(initialState: state) {
      HeartRateFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date = DateGenerator { currentDate.value }
    }

    await store.send(.startRecordingButtonTapped) {
      $0.recording = .active(startedAt: Date(timeIntervalSince1970: 1_000))
    }
    currentDate.setValue(Date(timeIntervalSince1970: 1_065))
    await clock.advance(by: .seconds(1))
    await store.receive(\.recordingTimerTick) {
      $0.recordingElapsedSeconds = 65
    }
    await store.send(.stopRecordingButtonTapped) {
      $0.recording = .finished(
        startedAt: Date(timeIntervalSince1970: 1_000),
        endedAt: Date(timeIntervalSince1970: 1_065)
      )
    }
    await store.finish()
  }

  @Test("Restores an active recording as a new connection segment")
  @MainActor
  func restoresActiveRecording() async {
    let clock = TestClock()
    let startedAt = Date(timeIntervalSince1970: 1_000)
    let restoredAt = Date(timeIntervalSince1970: 1_030)
    let sample = HeartRateSample(
      beatsPerMinute: 72,
      id: 0,
      segment: 0,
      timestamp: startedAt
    )
    let snapshot = HeartRateRecordingSnapshot(
      currentSegment: 0,
      nextSampleID: 1,
      recording: .active(startedAt: startedAt),
      samples: [sample]
    )
    let store = TestStore(initialState: HeartRateFeature.State()) {
      HeartRateFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date.now = restoredAt
      $0.recordingPersistence.load = { snapshot }
    }

    await store.send(.task)
    await store.receive(\.recordingLoaded) {
      $0.currentSegment = 1
      $0.isStreamInterrupted = true
      $0.nextSampleID = 1
      $0.recording = .active(startedAt: startedAt)
      $0.recordingElapsedSeconds = 30
      $0.samples = [sample]
    }
    await store.send(.stopRecordingButtonTapped) {
      $0.recording = .finished(startedAt: startedAt, endedAt: restoredAt)
    }
    await store.finish()
  }

  @Test("Persists lifecycle changes and the latest samples")
  @MainActor
  func persistsRecording() async {
    let clock = TestClock()
    let now = Date(timeIntervalSince1970: 1_000)
    let savedSnapshots = LockIsolated<[HeartRateRecordingSnapshot]>([])
    var state = HeartRateFeature.State()
    state.connection = .connected(name: "PulseStream Mac")
    let store = TestStore(initialState: state) {
      HeartRateFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date.now = now
      $0.recordingPersistence.save = { snapshot in
        savedSnapshots.withValue { $0.append(snapshot) }
      }
    }

    await store.send(.startRecordingButtonTapped) {
      $0.recording = .active(startedAt: now)
    }
    await store.send(.eventReceived(measurement(72))) {
      $0.beatsPerMinute = 72
      $0.nextSampleID = 1
      $0.samples.append(
        HeartRateSample(beatsPerMinute: 72, id: 0, segment: 0, timestamp: now)
      )
    }
    await store.send(.applicationDidEnterBackground)
    await store.send(.stopRecordingButtonTapped) {
      $0.recording = .finished(startedAt: now, endedAt: now)
    }
    await store.finish()

    expectNoDifference(savedSnapshots.value.last, store.state.recordingSnapshot)
  }

  @Test("Retries an unexpected disconnection after one second")
  @MainActor
  func unexpectedDisconnectRetries() async {
    let clock = TestClock()
    let scanCalls = CallCounter()
    var state = HeartRateFeature.State()
    state.beatsPerMinute = 72
    state.connection = .connected(name: "PulseStream Mac")
    let store = TestStore(initialState: state) {
      HeartRateFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.heartRateClient.scan = {
        await scanCalls.increment()
      }
    }

    await store.send(.eventReceived(.disconnected)) {
      $0.beatsPerMinute = nil
      $0.connection = .reconnecting(attempt: 1, maximumAttempts: 3, delaySeconds: 1)
      $0.retryAttempt = 1
    }

    await clock.advance(by: .seconds(1))
    await store.receive(\.retryDelayElapsed)
    await store.send(.eventReceived(.connected(name: "PulseStream Mac"))) {
      $0.connection = .connected(name: "PulseStream Mac")
      $0.retryAttempt = 0
    }
    await store.finish()

    let scanCallCount = await scanCalls.value
    #expect(scanCallCount == 1)
  }

  @Test("Times out scans and exhausts the bounded recovery policy")
  @MainActor
  func scanTimeoutExhaustsRecovery() async {
    let cancelCalls = CallCounter()
    let clock = TestClock()
    let store = TestStore(initialState: HeartRateFeature.State()) {
      HeartRateFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.heartRateClient.cancelConnectionAttempt = {
        await cancelCalls.increment()
      }
    }

    await store.send(.eventReceived(.disconnected)) {
      $0.connection = .reconnecting(attempt: 1, maximumAttempts: 3, delaySeconds: 1)
      $0.retryAttempt = 1
    }

    await clock.advance(by: .seconds(1))
    await store.receive(\.retryDelayElapsed)
    await clock.advance(by: .seconds(5))
    await store.receive(\.recoveryAttemptTimedOut) {
      $0.connection = .reconnecting(attempt: 2, maximumAttempts: 3, delaySeconds: 2)
      $0.retryAttempt = 2
    }

    await clock.advance(by: .seconds(2))
    await store.receive(\.retryDelayElapsed)
    await clock.advance(by: .seconds(5))
    await store.receive(\.recoveryAttemptTimedOut) {
      $0.connection = .reconnecting(attempt: 3, maximumAttempts: 3, delaySeconds: 4)
      $0.retryAttempt = 3
    }

    await clock.advance(by: .seconds(4))
    await store.receive(\.retryDelayElapsed)
    await clock.advance(by: .seconds(5))
    await store.receive(\.recoveryAttemptTimedOut) {
      $0.connection = .failed(.reconnectionExhausted)
    }
    await store.finish()

    let cancelCallCount = await cancelCalls.value
    #expect(cancelCallCount == 3)
  }

  @Test("Stops after three failed recovery attempts")
  @MainActor
  func recoveryExhaustion() async {
    let clock = TestClock()
    var state = HeartRateFeature.State()
    state.beatsPerMinute = 72
    state.connection = .connected(name: "PulseStream Mac")
    let store = TestStore(initialState: state) {
      HeartRateFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }

    await store.send(.eventReceived(.failed(.connectionFailed(description: "Connection lost")))) {
      $0.beatsPerMinute = nil
      $0.connection = .reconnecting(attempt: 1, maximumAttempts: 3, delaySeconds: 1)
      $0.retryAttempt = 1
    }

    await clock.advance(by: .seconds(1))
    await store.receive(\.retryDelayElapsed)

    await store.send(.eventReceived(.failed(.connectionFailed(description: nil)))) {
      $0.connection = .reconnecting(attempt: 2, maximumAttempts: 3, delaySeconds: 2)
      $0.retryAttempt = 2
    }

    await clock.advance(by: .seconds(2))
    await store.receive(\.retryDelayElapsed)

    await store.send(.eventReceived(.failed(.connectionFailed(description: nil)))) {
      $0.connection = .reconnecting(attempt: 3, maximumAttempts: 3, delaySeconds: 4)
      $0.retryAttempt = 3
    }

    await clock.advance(by: .seconds(4))
    await store.receive(\.retryDelayElapsed)

    await store.send(.eventReceived(.failed(.connectionFailed(description: nil)))) {
      $0.connection = .failed(.reconnectionExhausted)
    }
    await store.finish()
  }

  @Test("A manual disconnect cancels recovery")
  @MainActor
  func manualDisconnectCancelsRecovery() async {
    let clock = TestClock()
    let disconnectCalls = CallCounter()
    let store = TestStore(initialState: HeartRateFeature.State()) {
      HeartRateFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.heartRateClient.disconnect = {
        await disconnectCalls.increment()
      }
    }

    await store.send(.eventReceived(.disconnected)) {
      $0.connection = .reconnecting(attempt: 1, maximumAttempts: 3, delaySeconds: 1)
      $0.retryAttempt = 1
    }

    await store.send(.disconnectButtonTapped) {
      $0.connection = .disconnected
      $0.isManualDisconnectPending = true
      $0.retryAttempt = 0
    }

    await clock.advance(by: .seconds(1))
    await store.finish()

    let disconnectCallCount = await disconnectCalls.value
    #expect(disconnectCallCount == 1)
  }

  @Test("Scan button invokes the Bluetooth dependency")
  @MainActor
  func scanButtonInvokesDependency() async {
    let calls = CallCounter()
    let store = TestStore(initialState: HeartRateFeature.State()) {
      HeartRateFeature()
    } withDependencies: {
      $0.heartRateClient.scan = {
        await calls.increment()
      }
    }

    await store.send(.scanButtonTapped).finish()

    let callCount = await calls.value
    #expect(callCount == 1)
  }
}
