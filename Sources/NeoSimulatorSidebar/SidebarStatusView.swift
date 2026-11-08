import SwiftUI

struct SidebarStatusView: View {
    let content: DeviceSidebarModel.Status
    var retry: () -> Void = {}

    var body: some View {
        Group {
            switch content {
            case .loading:
                ProgressView { Text("Loading Devices…") }
            case .empty:
                ContentUnavailableView {
                    Label { Text("No Devices") } icon: { Image(systemName: "iphone") }
                } description: {
                    Text("Create a simulator or connect a device to get started.")
                }
            case .noMatches(let query):
                if query.isEmpty {
                    ContentUnavailableView {
                        Label { Text("No Matching Devices") } icon: { Image(systemName: "line.3.horizontal.decrease") }
                    } description: {
                        Text("Change the filters to see more devices.")
                    }
                } else { ContentUnavailableView.search(text: query) }
            case .failure(let message):
                ContentUnavailableView {
                    Label { Text("Unable to Load Devices") } icon: { Image(systemName: "exclamationmark.triangle") }
                } description: {
                    Text(message).lineLimit(4).help(message)
                } actions: {
                    Button(action: retry) { Text("Try Again") }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
