import SwiftUI
import MapKit
import Playgrounds

struct RootView: View {
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var selection: MKMapItem?
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        // Side-by-side on iPad/Mac; collapses to list → map on iPhone.
        NavigationSplitView {
            List(results, id: \.self, selection: $selection) { item in
                VStack(alignment: .leading) {
                    Text(item.name ?? "Unknown")
                    if let address = item.address?.shortAddress {
                        Text(address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Results")
        } detail: {
            Map(position: $position, selection: $selection) {
                ForEach(results, id: \.self) { item in
                    Marker(item: item).tag(item)
                }
            }
        }
        .searchable(text: $query, placement: .toolbarPrincipal, prompt: "Search")
        .task(id: query) { await search() }
        .onChange(of: selection) {
            if let selection { position = .item(selection) }
        }
    }

    private func search() async {
        guard !query.isEmpty else { results = []; return }
        // Debounce: .task(id:) cancels this task when the query changes again.
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        // MKLocalSearch throws when nothing matches; treat that as no results.
        let items = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
        guard !Task.isCancelled else { return }
        results = items
        selection = nil
        position = .automatic
    }
}

#Preview {
    RootView()
}
