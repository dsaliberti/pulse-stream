import SwiftUI

struct ContentView: View {
  @ObservedObject var broadcaster: HeartRatePeripheralManager

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      header
      Divider()
      measurementControls
      Divider()
      actionButtons
    }
    .padding(28)
    .frame(width: 460)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Heart Rate Broadcaster")
        .font(.largeTitle.bold())
      Label(broadcaster.status.title, systemImage: statusSymbol)
        .foregroundStyle(statusColor)
      Text("Subscribers: \(broadcaster.subscriberCount) · Measurements sent: \(broadcaster.sentMeasurementCount)")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var measurementControls: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        Text("\(broadcaster.beatsPerMinute)")
          .font(.system(size: 56, weight: .semibold, design: .rounded))
          .contentTransition(.numericText())
        Text("BPM")
          .font(.title3)
          .foregroundStyle(.secondary)
      }

      Slider(value: $broadcaster.beatsPerMinute.double, in: 40...180, step: 1)
        .disabled(broadcaster.variesAutomatically)

      Toggle("Vary heart rate automatically", isOn: $broadcaster.variesAutomatically)

      Button("Send Measurement") {
        broadcaster.sendCurrentMeasurement()
      }
      .disabled(broadcaster.subscriberCount == 0)
    }
  }

  private var actionButtons: some View {
    HStack {
      Button(broadcaster.isAdvertising ? "Stop Broadcasting" : "Start Broadcasting") {
        broadcaster.toggleBroadcasting()
      }
      .buttonStyle(.borderedProminent)

      Button("Drop Session") {
        broadcaster.dropSession()
      }
      .disabled(broadcaster.subscriberCount == 0)

      Spacer()
    }
  }

  private var statusSymbol: String {
    switch broadcaster.status {
    case .bluetoothUnavailable: "antenna.radiowaves.left.and.right.slash"
    case .ready: "checkmark.circle"
    case .advertising: "antenna.radiowaves.left.and.right"
    case .subscribed: "iphone.radiowaves.left.and.right"
    case .resetting: "arrow.clockwise"
    }
  }

  private var statusColor: Color {
    switch broadcaster.status {
    case .bluetoothUnavailable: .red
    case .ready: .secondary
    case .advertising: .orange
    case .subscribed: .green
    case .resetting: .orange
    }
  }
}

private extension Int {
  var double: Double {
    get { Double(self) }
    set { self = Int(newValue) }
  }
}
