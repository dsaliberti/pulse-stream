import BluetoothHealth
import ComposableArchitecture
import Foundation

@Reducer
public struct HeartRateFeature {
  @ObservableState
  public struct State: Equatable {
    public enum Connection: Equatable, Sendable {
      case bluetoothUnavailable
      case connected(name: String)
      case connecting(name: String)
      case disconnected
      case discovering(name: String)
      case failed(HeartRateClient.Failure)
      case idle
      case reconnecting(attempt: Int, maximumAttempts: Int, delaySeconds: Int)
      case scanning

      var isRecoveryInProgress: Bool {
        switch self {
        case .connecting, .discovering, .reconnecting, .scanning:
          true
        case .bluetoothUnavailable, .connected, .disconnected, .failed, .idle:
          false
        }
      }
    }

    public var beatsPerMinute: UInt16?
    public var connection = Connection.idle
    public var latestMeasurement: HeartRateMeasurement?
    public var latestMeasurementError: HeartRateMeasurementDecodingError?
    public var persistenceError: String?
    public var receivedMeasurementCount = 0
    public var recording = HeartRateRecording.idle
    public var recordingElapsedSeconds = 0
    public var retryAttempt = 0
    public var rejectedMeasurementCount = 0
    public var samples: [HeartRateSample] = []

    var currentSegment = 0
    var isManualDisconnectPending = false
    var isStreamInterrupted = false
    var nextSampleID = 0

    public var statistics: HeartRateStatistics? {
      HeartRateStatistics(samples: samples)
    }

    var recordingSnapshot: HeartRateRecordingSnapshot {
      HeartRateRecordingSnapshot(
        currentSegment: currentSegment,
        nextSampleID: nextSampleID,
        recording: recording,
        samples: samples
      )
    }

    public init() {}
  }

  public enum Action {
    case applicationDidEnterBackground
    case applicationWillEnterForeground
    case disconnectButtonTapped
    case eventReceived(HeartRateClient.Event)
    case persistenceFailed(message: String)
    case recordingLoaded(HeartRateRecordingSnapshot)
    case recordingTimerTick
    case recoveryAttemptTimedOut(attempt: Int)
    case retryDelayElapsed(attempt: Int)
    case scanButtonTapped
    case startRecordingButtonTapped
    case stopRecordingButtonTapped
    case task
  }

  private enum CancelID {
    case attemptTimeout
    case events
    case retry
    case restoration
    case timer
  }

  @Dependency(\.continuousClock) var clock
  @Dependency(\.date) var date
  @Dependency(\.heartRateClient) var heartRateClient
  @Dependency(\.recordingPersistence) var recordingPersistence

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      let heartRateClient = self.heartRateClient
      let recordingPersistence = self.recordingPersistence
      switch action {
      case .applicationDidEnterBackground:
        guard state.recording != .idle else { return .none }
        updateElapsedTime(state: &state)
        return persist(state.recordingSnapshot)

      case .applicationWillEnterForeground:
        updateElapsedTime(state: &state)
        return .none

      case .disconnectButtonTapped:
        state.beatsPerMinute = nil
        state.latestMeasurement = nil
        state.connection = .disconnected
        markStreamInterrupted(state: &state)
        state.isManualDisconnectPending = true
        state.retryAttempt = 0
        return .merge(
          .cancel(id: CancelID.attemptTimeout),
          .cancel(id: CancelID.retry),
          .run { _ in await heartRateClient.disconnect() }
        )

      case let .eventReceived(event):
        switch event {
        case .bluetoothUnavailable:
          state.beatsPerMinute = nil
          state.latestMeasurement = nil
          state.connection = .bluetoothUnavailable
          markStreamInterrupted(state: &state)
          state.isManualDisconnectPending = false
          state.retryAttempt = 0
          return .merge(
            .cancel(id: CancelID.attemptTimeout),
            .cancel(id: CancelID.retry)
          )
        case let .connected(name):
          state.connection = .connected(name: name)
          state.isStreamInterrupted = false
          state.isManualDisconnectPending = false
          state.retryAttempt = 0
          return .merge(
            .cancel(id: CancelID.attemptTimeout),
            .cancel(id: CancelID.retry)
          )
        case let .connecting(name):
          state.connection = .connecting(name: name)
        case .disconnected:
          state.beatsPerMinute = nil
          state.latestMeasurement = nil
          markStreamInterrupted(state: &state)
          if state.isManualDisconnectPending {
            state.connection = .disconnected
            state.isManualDisconnectPending = false
            return .none
          }
          let reconnect = scheduleReconnect(state: &state)
          return .merge(.cancel(id: CancelID.attemptTimeout), reconnect)
        case let .discovering(name):
          state.connection = .discovering(name: name)
        case .failed:
          state.beatsPerMinute = nil
          state.latestMeasurement = nil
          markStreamInterrupted(state: &state)
          let reconnect = scheduleReconnect(state: &state)
          return .merge(.cancel(id: CancelID.attemptTimeout), reconnect)
        case let .measurement(measurement):
          state.beatsPerMinute = measurement.beatsPerMinute
          state.latestMeasurement = measurement
          state.receivedMeasurementCount += 1
          if state.recording.isActive {
            state.samples.append(
              HeartRateSample(
                beatsPerMinute: measurement.beatsPerMinute,
                id: state.nextSampleID,
                segment: state.currentSegment,
                timestamp: date.now
              )
            )
            state.nextSampleID += 1
            if state.samples.count > 3_600 {
              state.samples.removeFirst(state.samples.count - 3_600)
            }
            return persist(state.recordingSnapshot)
          }
        case let .measurementRejected(error):
          state.latestMeasurementError = error
          state.rejectedMeasurementCount += 1
        case .scanning:
          state.beatsPerMinute = nil
          state.latestMeasurement = nil
          state.connection = .scanning
        }
        return .none

      case let .persistenceFailed(message):
        state.persistenceError = message
        return .none

      case let .recordingLoaded(snapshot):
        state.currentSegment = snapshot.currentSegment
        state.nextSampleID = snapshot.nextSampleID
        state.recording = snapshot.recording
        state.samples = Array(snapshot.samples.suffix(3_600))
        if state.recording.isActive {
          state.currentSegment += 1
          state.isStreamInterrupted = true
          updateElapsedTime(state: &state)
          return recordingTimer()
        }
        updateElapsedTime(state: &state)
        return .none

      case .recordingTimerTick:
        updateElapsedTime(state: &state)
        return .none

      case let .recoveryAttemptTimedOut(attempt):
        guard
          state.retryAttempt == attempt,
          state.connection.isRecoveryInProgress
        else { return .none }
        let reconnect = scheduleReconnect(state: &state)
        return .merge(
          .run { _ in await heartRateClient.cancelConnectionAttempt() },
          reconnect
        )

      case let .retryDelayElapsed(attempt):
        guard
          state.retryAttempt == attempt,
          case .reconnecting = state.connection
        else { return .none }
        return .merge(
          .run { _ in await heartRateClient.scan() },
          .run { [clock] send in
            try await clock.sleep(for: .seconds(5))
            await send(.recoveryAttemptTimedOut(attempt: attempt))
          }
          .cancellable(id: CancelID.attemptTimeout, cancelInFlight: true)
        )

      case .scanButtonTapped:
        state.isManualDisconnectPending = false
        state.retryAttempt = 0
        return .merge(
          .cancel(id: CancelID.attemptTimeout),
          .cancel(id: CancelID.retry),
          .run { _ in await heartRateClient.scan() }
        )

      case .startRecordingButtonTapped:
        guard case .connected = state.connection else { return .none }
        state.currentSegment = 0
        state.isStreamInterrupted = false
        state.nextSampleID = 0
        state.persistenceError = nil
        state.recording = .active(startedAt: date.now)
        state.recordingElapsedSeconds = 0
        state.samples.removeAll(keepingCapacity: true)
        return .merge(
          persist(state.recordingSnapshot),
          recordingTimer()
        )

      case .stopRecordingButtonTapped:
        guard case let .active(startedAt) = state.recording else { return .none }
        state.recording = .finished(startedAt: startedAt, endedAt: date.now)
        updateElapsedTime(state: &state)
        return .merge(
          .cancel(id: CancelID.timer),
          persist(state.recordingSnapshot)
        )

      case .task:
        return .merge(
          .run { send in
            do {
              if let snapshot = try await recordingPersistence.load() {
                await send(.recordingLoaded(snapshot))
              }
            } catch {
              await send(.persistenceFailed(message: "The previous recording could not be restored"))
            }
          }
          .cancellable(id: CancelID.restoration, cancelInFlight: true),
          .run { send in
            for await event in await heartRateClient.events() {
              await send(.eventReceived(event))
            }
          }
          .cancellable(id: CancelID.events, cancelInFlight: true)
        )
      }
    }
  }

  private func persist(_ snapshot: HeartRateRecordingSnapshot) -> Effect<Action> {
    let recordingPersistence = self.recordingPersistence
    return .run { send in
      do {
        try await recordingPersistence.save(snapshot)
      } catch {
        await send(.persistenceFailed(message: "The recording could not be saved"))
      }
    }
  }

  private func recordingTimer() -> Effect<Action> {
    .run { [clock] send in
      while !Task.isCancelled {
        try await clock.sleep(for: .seconds(1))
        await send(.recordingTimerTick)
      }
    }
    .cancellable(id: CancelID.timer, cancelInFlight: true)
  }

  private func updateElapsedTime(state: inout State) {
    switch state.recording {
    case let .active(startedAt):
      state.recordingElapsedSeconds = max(0, Int(date.now.timeIntervalSince(startedAt)))
    case let .finished(startedAt, endedAt):
      state.recordingElapsedSeconds = max(0, Int(endedAt.timeIntervalSince(startedAt)))
    case .idle:
      state.recordingElapsedSeconds = 0
    }
  }

  private func markStreamInterrupted(state: inout State) {
    guard state.recording.isActive, !state.isStreamInterrupted else { return }
    state.currentSegment += 1
    state.isStreamInterrupted = true
  }

  private func scheduleReconnect(state: inout State) -> Effect<Action> {
    let maximumAttempts = 3
    guard state.retryAttempt < maximumAttempts else {
      state.connection = .failed(.reconnectionExhausted)
      return .none
    }

    state.retryAttempt += 1
    let attempt = state.retryAttempt
    let delaySeconds = 1 << (attempt - 1)
    state.connection = .reconnecting(
      attempt: attempt,
      maximumAttempts: maximumAttempts,
      delaySeconds: delaySeconds
    )
    return .run { [clock] send in
      try await clock.sleep(for: .seconds(delaySeconds))
      await send(.retryDelayElapsed(attempt: attempt))
    }
    .cancellable(id: CancelID.retry, cancelInFlight: true)
  }
}
