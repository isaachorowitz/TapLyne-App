import SwiftUI

@main
struct CompanionApp: App {
    @StateObject private var connection = CompanionConnection()
    @StateObject private var speech = ConversationSpeech()
    @StateObject private var realtime = RealtimeVoice()
    var body: some Scene {
        WindowGroup {
            CompanionView(connection: connection, speech: speech, realtime: realtime)
                .onOpenURL { connection.acceptPairing($0) }
        }
    }
}
