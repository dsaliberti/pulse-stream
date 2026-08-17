import Charts
import ComposableArchitecture
import Foundation
import SwiftUI

public struct PulseStreamRootView: View {
  private let store = Store(initialState: HeartRateFeature.State()) {
    HeartRateFeature()
  }

  public init() {}

  public var body: some View {
    HeartRateView(store: store)
  }
}

public struct HeartRateView: View {
  @Environment(\.scenePhase) private var scenePhase
  @ScaledMetric(relativeTo: .largeTitle) private var beatsPerMinuteFontSize = 88

  public let store: StoreOf<HeartRateFeature>

  public init(store: StoreOf<HeartRateFeature>) {
    self.store = store
  }

  public var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 28) {
          liveHeartRate

          Label(connectionTitle, systemImage: connectionSymbol)
            .foregroundStyle(connectionColor)
            .multilineTextAlignment(.center)

          measurementDetails(
            store.latestMeasurement.map(HeartRateMeasurementDetails.init)
          )

          protocolDiagnostics

          recordingContent

          Button(buttonTitle) {
            store.send(buttonAction)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .frame(maxWidth: .infinity)
        }
        .padding(24)
      }
      .navigationTitle("PulseStream")
      .task {
        await store.send(.task).finish()
      }
      .onChange(of: scenePhase) { _, scenePhase in
        scenePhaseChanged(scenePhase)
      }
    }
  }

  @ViewBuilder
  private var recordingContent: some View {
    VStack(spacing: 16) {
      if store.recording != .idle {
        HStack {
          Label(
            store.recording.isActive ? "Recording" : "Recorded",
            systemImage: store.recording.isActive ? "record.circle.fill" : "checkmark.circle"
          )
          .foregroundStyle(store.recording.isActive ? .red : .secondary)
          Spacer()
          Text(formattedRecordingDuration)
            .font(.body.monospacedDigit())
          Text("\(store.samples.count) samples")
            .foregroundStyle(.secondary)
        }
        .font(.subheadline)
      }

      if !store.samples.isEmpty {
        Chart(store.samples) { sample in
          LineMark(
            x: .value("Time", sample.timestamp),
            y: .value("BPM", sample.beatsPerMinute),
            series: .value("Connection segment", sample.segment)
          )
          .foregroundStyle(.red)
          .interpolationMethod(.catmullRom)
        }
        .chartLegend(.hidden)
        .frame(height: 180)
        .accessibilityLabel("Recorded heart rate chart")

        if let statistics = store.statistics {
          HStack {
            statistic(title: "Minimum", value: String(statistics.minimum))
            Spacer()
            statistic(
              title: "Average",
              value: statistics.average.formatted(.number.precision(.fractionLength(0)))
            )
            Spacer()
            statistic(title: "Maximum", value: String(statistics.maximum))
          }
        }
      }

      Button(store.recording.isActive ? "Stop Recording" : "Start Recording") {
        store.send(
          store.recording.isActive
            ? .stopRecordingButtonTapped
            : .startRecordingButtonTapped
        )
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .disabled(!store.recording.isActive && !isConnected)

      if let persistenceError = store.persistenceError {
        Label(persistenceError, systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(.orange)
      }
    }
  }

  private var liveHeartRate: some View {
    HStack(spacing: 20) {
      Image(systemName: "heart.fill")
        .font(.system(size: 52))
        .foregroundStyle(.red)
        .symbolEffect(.pulse, options: .repeating, isActive: store.beatsPerMinute != nil)
        .accessibilityHidden(true)

      HStack(alignment: .firstTextBaseline, spacing: 8) {
        ZStack(alignment: .trailing) {
          Text("888")
            .hidden()
            .accessibilityHidden(true)
          Text(store.beatsPerMinute.map(String.init) ?? "--")
            .contentTransition(.numericText())
        }
          .font(.system(size: beatsPerMinuteFontSize, weight: .bold, design: .rounded))
        Text("BPM")
          .font(.headline)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }

  private var formattedRecordingDuration: String {
    let minutes = store.recordingElapsedSeconds / 60
    let seconds = store.recordingElapsedSeconds % 60
    return String(format: "%d:%02d", minutes, seconds)
  }

  private var protocolDiagnostics: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Protocol diagnostics")
        .font(.headline)

      LabeledContent("Accepted packets", value: store.receivedMeasurementCount.formatted())
      LabeledContent("Rejected packets", value: store.rejectedMeasurementCount.formatted())

      if let error = store.latestMeasurementError {
        Label(error.message, systemImage: "exclamationmark.triangle.fill")
          .font(.footnote)
          .foregroundStyle(.orange)
      }
    }
    .padding(16)
    .background(.quaternary, in: .rect(cornerRadius: 16))
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func measurementDetails(_ details: HeartRateMeasurementDetails?) -> some View {
    let displayedDetails = details ?? HeartRateMeasurementDetails(
      contact: .unsupported,
      energyExpendedKilojoules: nil,
      rrIntervalsMilliseconds: []
    )

    return VStack(alignment: .leading, spacing: 12) {
      Text("Measurement details")
        .font(.headline)
        .unredacted()

      LabeledContent("Sensor contact") {
        Label(
          contactTitle(displayedDetails.contact),
          systemImage: contactSymbol(displayedDetails.contact)
        )
        .foregroundStyle(contactColor(displayedDetails.contact))
      }

      LabeledContent("Latest RR interval") {
        Text(
          displayedDetails.latestRRIntervalMilliseconds.map {
            $0.formatted(.number.precision(.fractionLength(0))) + " ms"
          } ?? "Not reported"
        )
        .monospacedDigit()
      }

      LabeledContent("RR intervals in packet") {
        Text(displayedDetails.rrIntervalsMilliseconds.count.formatted())
          .monospacedDigit()
      }

      LabeledContent("Energy expended") {
        Text(
          displayedDetails.energyExpendedKilojoules.map { "\($0) kJ" }
            ?? "Not reported"
        )
        .monospacedDigit()
      }
    }
    .padding(16)
    .background(.quaternary, in: .rect(cornerRadius: 16))
    .frame(maxWidth: .infinity, alignment: .leading)
    .redacted(reason: details == nil ? .placeholder : [])
    .accessibilityHidden(details == nil)
  }

  private func contactTitle(_ contact: HeartRateMeasurementDetails.Contact) -> String {
    switch contact {
    case .detected: "Good"
    case .notDetected: "Poor"
    case .unsupported: "Unsupported"
    }
  }

  private func contactSymbol(_ contact: HeartRateMeasurementDetails.Contact) -> String {
    switch contact {
    case .detected: "checkmark.circle.fill"
    case .notDetected: "exclamationmark.circle.fill"
    case .unsupported: "minus.circle"
    }
  }

  private func contactColor(_ contact: HeartRateMeasurementDetails.Contact) -> Color {
    switch contact {
    case .detected: .green
    case .notDetected: .orange
    case .unsupported: .secondary
    }
  }

  private var isConnected: Bool {
    if case .connected = store.connection { true } else { false }
  }

  private func statistic(title: String, value: String) -> some View {
    VStack(spacing: 2) {
      Text(value)
        .font(.title3.monospacedDigit().bold())
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  private func scenePhaseChanged(_ scenePhase: ScenePhase) {
    switch scenePhase {
    case .active:
      store.send(.applicationWillEnterForeground)
    case .background:
      store.send(.applicationDidEnterBackground)
    case .inactive:
      break
    @unknown default:
      break
    }
  }

  private var buttonAction: HeartRateFeature.Action {
    switch store.connection {
    case .connected, .connecting, .discovering, .reconnecting:
      .disconnectButtonTapped
    case .bluetoothUnavailable, .disconnected, .failed, .idle, .scanning:
      .scanButtonTapped
    }
  }

  private var buttonTitle: String {
    switch store.connection {
    case .connected, .connecting, .discovering: "Disconnect"
    case .reconnecting: "Cancel Retry"
    case .scanning: "Scan Again"
    case .bluetoothUnavailable, .disconnected, .failed, .idle: "Scan for Mac"
    }
  }

  private var connectionColor: Color {
    switch store.connection {
    case .connected: .green
    case .failed, .bluetoothUnavailable: .red
    case .connecting, .discovering, .reconnecting, .scanning: .orange
    case .disconnected, .idle: .secondary
    }
  }

  private var connectionSymbol: String {
    switch store.connection {
    case .bluetoothUnavailable: "antenna.radiowaves.left.and.right.slash"
    case .connected: "checkmark.circle.fill"
    case .connecting, .discovering, .reconnecting: "ellipsis.circle"
    case .disconnected: "xmark.circle"
    case .failed: "exclamationmark.triangle"
    case .idle: "heart"
    case .scanning: "antenna.radiowaves.left.and.right"
    }
  }

  private var connectionTitle: String {
    switch store.connection {
    case .bluetoothUnavailable: "Bluetooth is unavailable"
    case let .connected(name): "Streaming from \(name)"
    case let .connecting(name): "Connecting to \(name)…"
    case .disconnected: "Disconnected"
    case let .discovering(name): "Discovering \(name)…"
    case let .failed(failure): failure.message
    case .idle: "Ready to scan"
    case let .reconnecting(attempt, maximumAttempts, delaySeconds):
      "Connection lost. Retry \(attempt) of \(maximumAttempts) in \(delaySeconds)s…"
    case .scanning: "Looking for PulseStream Mac…"
    }
  }
}

#Preview {
  HeartRateView(
    store: Store(
      initialState: HeartRateFeature.State(
        beatsPerMinute: 72,
        connection: .connected(name: "PulseStream Mac")
      )
    ) {
      HeartRateFeature()
    } withDependencies: {
      $0.heartRateClient = .testValue
    }
  )
}

private extension HeartRateFeature.State {
  init(beatsPerMinute: UInt16?, connection: Connection) {
    self.init()
    self.beatsPerMinute = beatsPerMinute
    self.connection = connection
  }
}
