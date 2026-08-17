import ComposableArchitecture

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
    public var retryAttempt = 0

    var isManualDisconnectPending = false

    public init() {}
  }

  public enum Action {
    case disconnectButtonTapped
    case eventReceived(HeartRateClient.Event)
    case recoveryAttemptTimedOut(attempt: Int)
    case retryDelayElapsed(attempt: Int)
    case scanButtonTapped
    case task
  }

  private enum CancelID {
    case attemptTimeout
    case events
    case retry
  }

  @Dependency(\.continuousClock) var clock
  @Dependency(\.heartRateClient) var heartRateClient

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      let heartRateClient = self.heartRateClient
      switch action {
      case .disconnectButtonTapped:
        state.beatsPerMinute = nil
        state.connection = .disconnected
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
          state.connection = .bluetoothUnavailable
          state.isManualDisconnectPending = false
          state.retryAttempt = 0
          return .merge(
            .cancel(id: CancelID.attemptTimeout),
            .cancel(id: CancelID.retry)
          )
        case let .connected(name):
          state.connection = .connected(name: name)
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
          let reconnect = scheduleReconnect(state: &state)
          return .merge(.cancel(id: CancelID.attemptTimeout), reconnect)
        case let .measurement(measurement):
          state.beatsPerMinute = measurement.beatsPerMinute
        case .scanning:
          state.beatsPerMinute = nil
          state.connection = .scanning
        }
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

      case .task:
        return .run { send in
          for await event in await heartRateClient.events() {
            await send(.eventReceived(event))
          }
        }
        .cancellable(id: CancelID.events, cancelInFlight: true)
      }
    }
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
