import SwiftUI
import MapKit
import AuthenticationServices
import Playgrounds

struct RootView: View {
    @State private var swarm = SwarmClient()
    @State private var query = ""
    @State private var places: [Place] = []
    @State private var selection: Place?
    @State private var position: MapCameraPosition = .automatic
    @State private var center: CLLocationCoordinate2D?   // "near me" for searches that name no place
    @State private var isSearching = false
    @State private var message: String?
    @State private var searchTask: Task<Void, Never>?
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        // Side-by-side on iPad/Mac; collapses to list → map on iPhone.
        NavigationSplitView {
            List(places, id: \.self, selection: $selection) { place in
                VStack(alignment: .leading) {
                    Text(place.venue.name)
                    Text(place.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay { status }
            .navigationTitle("Results")
            .toolbar {
                if swarm.auth.isSignedIn {
                    Button("Sign Out") {
                        swarm.auth.signOut()
                        places = []
                    }
                }
            }
        } detail: {
            Map(position: $position, selection: $selection) {
                ForEach(places, id: \.self) { place in
                    Marker(place.venue.name, coordinate: place.coordinate).tag(place)
                }
            }
            .onMapCameraChange(frequency: .onEnd) { center = $0.region.center }
        }
        .searchable(text: $query, placement: .toolbarPrincipal, prompt: "Ask Swarm")
        // Search on Return, not per keystroke: each search runs the on-device model before calling Swarm.
        .onSubmit(of: .search) {
            searchTask?.cancel()
            searchTask = Task { await search() }
        }
        .onChange(of: selection) {
            if let selection {
                position = .region(MKCoordinateRegion(center: selection.coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500))
            }
        }
        .task(id: swarm.auth.isSignedIn) {
            guard swarm.auth.isSignedIn, let location = try? await swarm.lastLocation() else { return }
            center = location
            position = .region(MKCoordinateRegion(center: location, latitudinalMeters: 5000, longitudinalMeters: 5000))
        }
    }

    @ViewBuilder private var status: some View {
        if !swarm.auth.isSignedIn {
            ContentUnavailableView {
                Label("Sign in to Swarm", systemImage: "person.crop.circle")
            } description: {
                Text(message ?? "Search uses your Foursquare Swarm account.")
            } actions: {
                Button("Sign In") { Task { await signIn() } }
            }
        } else if isSearching {
            ProgressView()
        } else if let message {
            ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text(message))
        }
    }

    private func signIn() async {
        message = nil
        do {
            try await swarm.auth.signIn(with: webAuthenticationSession)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // The user closed the sign-in sheet.
        } catch {
            message = error.localizedDescription
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSearching = true
        message = nil
        defer { if !Task.isCancelled { isSearching = false } }
        do {
            let found = try await swarm.places(for: await SwarmRequest.route(text), near: center)
            guard !Task.isCancelled else { return }
            places = found
            selection = nil
            position = .automatic
            if found.isEmpty { message = "Nothing found for “\(text)”." }
        } catch {
            guard !Task.isCancelled else { return }
            places = []
            message = error.localizedDescription
        }
    }
}

#Preview {
    RootView()
}
