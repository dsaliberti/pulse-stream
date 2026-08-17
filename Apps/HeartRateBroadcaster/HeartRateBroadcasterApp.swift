import SwiftUI

@main
struct HeartRateBroadcasterApp: App {
  @StateObject private var broadcaster = HeartRatePeripheralManager()

  var body: some Scene {
    WindowGroup {
      ContentView(broadcaster: broadcaster)
    }
    .windowResizability(.contentSize)
  }
}
