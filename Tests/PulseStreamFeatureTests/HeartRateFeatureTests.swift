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

  @Test("Clears a stale measurement when disconnected")
  @MainActor
  func disconnectClearsMeasurement() async {
    var state = HeartRateFeature.State()
    state.beatsPerMinute = 72
    state.connection = .connected(name: "PulseStream Mac")
    let store = TestStore(initialState: state) {
      HeartRateFeature()
    }

    await store.send(.eventReceived(.disconnected)) {
      $0.beatsPerMinute = nil
      $0.connection = .disconnected
    }
    var expectedState = HeartRateFeature.State()
    expectedState.connection = .disconnected
    expectNoDifference(store.state, expectedState)
  }

  @Test("Reports failures without retaining a stale measurement")
  @MainActor
  func failureClearsMeasurement() async {
    var state = HeartRateFeature.State()
    state.beatsPerMinute = 72
    state.connection = .connected(name: "PulseStream Mac")
    let store = TestStore(initialState: state) {
      HeartRateFeature()
    }

    await store.send(.eventReceived(.failed(message: "Connection lost"))) {
      $0.beatsPerMinute = nil
      $0.connection = .failed(message: "Connection lost")
    }
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
