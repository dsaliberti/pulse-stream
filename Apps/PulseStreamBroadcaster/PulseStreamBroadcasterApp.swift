import SwiftUI

@main
struct PulseStreamBroadcasterApp: App {
  @StateObject private var broadcaster = HeartRatePeripheralManager()

  var body: some Scene {
    WindowGroup {
      ContentView(broadcaster: broadcaster)
    }
    .windowResizability(.contentSize)
  }
}
