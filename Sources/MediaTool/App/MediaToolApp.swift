import SwiftUI
import AppKit

final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var openedURLs: [URL] = []
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        AppState.shared.openedURLs = urls
        // Safety net: if the system ended up creating more than one window
        // for this file-open event, keep only the first one.
        DispatchQueue.main.async {
            let windows = NSApp.windows.filter { $0.isVisible }
            if windows.count > 1 {
                for window in windows.dropFirst() {
                    window.close()
                }
            }
        }
    }
}

@main
struct MediaToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var chat = ChatStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(chat)
                .frame(minWidth: 760, minHeight: 620)
        }
        .defaultSize(width: 920, height: 680)
    }
}

enum SidebarItem: Hashable {
    case media
    case peer(String)
}

struct RootView: View {
    @EnvironmentObject private var chat: ChatStore
    @ObservedObject private var appState = AppState.shared
    @State private var selection: SidebarItem? = .media

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Tools") {
                    Label("Media Tool", systemImage: "film")
                        .tag(SidebarItem.media)
                }
                Section("Macs on Network") {
                    if chat.sortedPeers.isEmpty {
                        Text("Searching…")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(chat.sortedPeers) { peer in
                        PeerRow(peer: peer,
                                status: chat.status(of: peer.id),
                                unread: chat.unread[peer.id] ?? 0)
                            .tag(SidebarItem.peer(peer.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            switch selection {
            case .peer(let id):
                ChatView(peerID: id).id(id)
            default:
                MediaView()
            }
        }
        .onChange(of: selection) { newSelection in
            if case .peer(let id) = newSelection {
                chat.activePeerID = id
            } else {
                chat.activePeerID = nil
            }
        }
        .onChange(of: appState.openedURLs) { newURLs in
            if !newURLs.isEmpty { selection = .media }
        }
    }
}
