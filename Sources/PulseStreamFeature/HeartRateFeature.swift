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
      case failed(message: String)
      case idle
      case scanning
    }

    public var beatsPerMinute: UInt16?
    public var connection = Connection.idle

    public init() {}
  }

  public enum Action {
    case disconnectButtonTapped
    case eventReceived(HeartRateClient.Event)
    case scanButtonTapped
    case task
  }

  private enum CancelID { case events }

  @Dependency(\.heartRateClient) var heartRateClient

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      let heartRateClient = self.heartRateClient
      switch action {
      case .disconnectButtonTapped:
        return .run { _ in
          await heartRateClient.disconnect()
        }

      case let .eventReceived(event):
        switch event {
        case .bluetoothUnavailable:
          state.beatsPerMinute = nil
          state.connection = .bluetoothUnavailable
        case let .connected(name):
          state.connection = .connected(name: name)
        case let .connecting(name):
          state.connection = .connecting(name: name)
        case .disconnected:
          state.beatsPerMinute = nil
          state.connection = .disconnected
        case let .discovering(name):
          state.connection = .discovering(name: name)
        case let .failed(message):
          state.beatsPerMinute = nil
          state.connection = .failed(message: message)
        case let .measurement(measurement):
          state.beatsPerMinute = measurement.beatsPerMinute
        case .scanning:
          state.beatsPerMinute = nil
          state.connection = .scanning
        }
        return .none

      case .scanButtonTapped:
        return .run { _ in
          await heartRateClient.scan()
        }

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
}
