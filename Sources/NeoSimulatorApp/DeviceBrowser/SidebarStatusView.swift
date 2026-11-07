import SwiftUI

struct SidebarStatusView: View {
    enum Content: Equatable {
        case loading, empty, noMatches(String), failure(String)
    }

    let content: Content
    var retry: () -> Void = {}

    var body: some View {
        Group {
            switch content {
            case .loading:
                ProgressView { Text("Loading Devices…", bundle: #bundle) }
            case .empty:
                ContentUnavailableView {
                    Label { Text("No Devices", bundle: #bundle) } icon: { Image(systemName: "iphone") }
                } description: {
                    Text("Create a simulator or connect a device to get started.", bundle: #bundle)
                }
            case .noMatches(let query):
                if query.isEmpty {
                    ContentUnavailableView {
                        Label { Text("No Matching Devices", bundle: #bundle) } icon: { Image(systemName: "line.3.horizontal.decrease") }
                    } description: {
                        Text("Change the filters to see more devices.", bundle: #bundle)
                    }
                } else { ContentUnavailableView.search(text: query) }
            case .failure(let message):
                ContentUnavailableView {
                    Label { Text("Unable to Load Devices", bundle: #bundle) } icon: { Image(systemName: "exclamationmark.triangle") }
                } description: {
                    Text(message).lineLimit(4).help(message)
                } actions: {
                    Button(action: retry) { Text("Try Again", bundle: #bundle) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
