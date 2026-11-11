import Foundation
import CoreLocation

/// A row in the results list and a pin on the map.
struct Place: Hashable {
    let id: String      // venue ID, or check-in ID where the same venue can appear twice
    let venue: Venue
    var note: String?   // check-in date, friend's name or event names; the address is shown otherwise

    var coordinate: CLLocationCoordinate2D { .init(latitude: venue.location.lat, longitude: venue.location.lng) }
    var subtitle: String {
        note ?? [venue.location.address, venue.location.city].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The Swarm `Venue` model, narrowed to the fields `SwarmClient.venueFields` asks for.
struct Venue: Decodable, Hashable {
    let id: String
    let name: String
    let location: Location

    struct Location: Decodable, Hashable {
        var address: String?
        var city: String?
        let lat: Double
        let lng: Double
    }
}

enum SwarmError: LocalizedError {
    case signedOut, needsLocation, server(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in to Swarm to search."
        case .needsLocation: "Add a place to your search, like “pizza in Madison”."
        case .server(let message): message
        }
    }
}

/// Calls tools on Foursquare's Swarm MCP server over MCP's Streamable HTTP transport (JSON-RPC over HTTPS).
@Observable
final class SwarmClient {
    static let endpoint = URL(string: "https://api.foursquare.com/v2/streaming/mcp/swarm-beta")!
    /// Tool results leave out coordinates by default; every call asks for them through the tool's `filter`.
    static let venueFields = "{id, name, location: {address, city, lat, lng}}"

    let auth = SwarmAuth()
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var protocolVersion: String?   // set once the MCP session is initialized

    // MARK: Requests

    /// Makes the Swarm call for a routed request. `center` (the map's center) is used when the search names no place.
    func places(for request: SwarmRequest, near center: CLLocationCoordinate2D?) async throws -> [Place] {
        let ll = center.map { "\($0.latitude),\($0.longitude)" }
        let v = Self.venueFields

        switch request {
        case let .findPlaces(query, near):
            let reply: VenuesReply = try await callTool("search_venues",
                ["query": query, "limit": 30].merging(try Self.area(near, ll)) { $1 },
                filter: "{venues: [\(v)]}")
            return reply.venues.map { Place(id: $0.id, venue: $0) }

        case let .myCheckins(query, near, afterDate, beforeDate):
            var arguments: [String: Any] = ["limit": 50]
            arguments["query"] = query
            arguments["near"] = near
            arguments["afterTimestamp"] = Self.timestamp(afterDate)
            arguments["beforeTimestamp"] = Self.timestamp(beforeDate).map { $0 + 86_400 }  // include the whole last day
            let reply: CheckinsReply = try await callTool("search_checkins", arguments,
                filter: "{checkins: {items: [{id, createdAt, venue: \(v)}]}}")
            return reply.checkins.items.map {
                Place(id: $0.id, venue: $0.venue, note: Date(timeIntervalSince1970: $0.createdAt).formatted(date: .abbreviated, time: .omitted))
            }

        case .savedPlaces:
            let reply: ListReply = try await callTool("get_list", ["listId": "self/todos", "limit": 100],
                filter: "{list: {listItems: {items: [{id, venue: \(v)}]}}}")
            return reply.list.listItems.items.compactMap { item in item.venue.map { Place(id: item.id, venue: $0) } }

        case .friendsOutNow:
            guard let ll else { throw SwarmError.needsLocation }
            let reply: FriendsReply = try await callTool("friends_nearby", ["ll": ll, "limit": 30],
                filter: "{recent: [{id, createdAt, user: {displayName}, venue: \(v)}]}")
            return reply.recent.map { Place(id: $0.id, venue: $0.venue, note: $0.user?.displayName) }

        case let .events(query, near, startDate, endDate):
            var arguments: [String: Any] = ["query": query, "limit": 20].merging(try Self.area(near, ll)) { $1 }
            arguments["startDate"] = startDate.flatMap { Self.timestamp($0) == nil ? nil : $0 }
            arguments["endDate"] = endDate.flatMap { Self.timestamp($0) == nil ? nil : $0 }
            let reply: EventsReply = try await callTool("search_events", arguments,
                filter: "{venues: [{venue: \(v), events: {items: [{name}]}}]}")
            return reply.venues.map {
                Place(id: $0.venue.id, venue: $0.venue, note: $0.events.items.compactMap(\.name).joined(separator: " · "))
            }
        }
    }

    /// The user's last location reported to Swarm, used as "near me" before the map has moved.
    func lastLocation() async throws -> CLLocationCoordinate2D? {
        let reply: LastLocationReply = try await callTool("last_location", [:], filter: nil)
        guard let lat = reply.lat, let lng = reply.lng else { return nil }
        return .init(latitude: lat, longitude: lng)
    }

    /// Swarm's search tools need `near` (a place name) or `ll` (coordinates).
    static func area(_ near: String?, _ ll: String?) throws -> [String: Any] {
        if let near { return ["near": near] }
        if let ll { return ["ll": ll] }
        throw SwarmError.needsLocation
    }

    /// "YYYY-MM-DD" from the model → Unix seconds at UTC midnight; nil when the model wrote something else.
    static func timestamp(_ day: String?) -> Int? {
        guard let day, let date = try? Date(day, strategy: .iso8601.year().month().day()) else { return nil }
        return Int(date.timeIntervalSince1970)
    }

    // MARK: MCP transport

    private func callTool<T: Decodable>(_ name: String, _ arguments: [String: Any], filter: String?) async throws -> T {
        if protocolVersion == nil {
            let reply = try await send("initialize", [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "SwarmAI", "version": "1.0"],
            ])
            protocolVersion = reply?["protocolVersion"] as? String ?? "2025-06-18"
            _ = try await send("notifications/initialized", nil)
        }
        var arguments = arguments
        arguments["filter"] = filter
        let result = try await send("tools/call", ["name": name, "arguments": arguments])
        return try Self.toolOutput(result ?? [:])
    }

    private func send(_ method: String, _ params: [String: Any]?) async throws -> [String: Any]? {
        let isNotification = method.hasPrefix("notifications/")
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        message["params"] = params
        if !isNotification { message["id"] = UUID().uuidString }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Start a fresh MCP session on the next call; a 404 here usually means the server dropped ours.
            sessionID = nil
            protocolVersion = nil
            if status == 401 {
                auth.signOut()
                throw SwarmError.signedOut
            }
            throw SwarmError.server("Swarm returned HTTP \(status).")
        }
        if let id = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = id }
        if isNotification { return nil }
        return try Self.jsonRPCResult(from: data, contentType: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"))
    }

    /// Streamable HTTP answers with plain JSON or a server-sent event stream; the reply is the message carrying `result` or `error`.
    static func jsonRPCResult(from data: Data, contentType: String?) throws -> [String: Any] {
        let messages: [Data] = contentType?.hasPrefix("text/event-stream") == true
            // shortcut: assumes each event's JSON is on one `data:` line, which is how JSON-RPC replies are sent in practice; join multi-line events if a server splits them.
            ? String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                .filter { $0.hasPrefix("data:") }
                .map { Data($0.dropFirst(5).utf8) }
            : [data]
        for message in messages {
            guard let json = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else { continue }
            if let error = json["error"] as? [String: Any] {
                throw SwarmError.server(error["message"] as? String ?? "Swarm returned an error.")
            }
            if let result = json["result"] as? [String: Any] { return result }
        }
        throw SwarmError.server("Swarm sent no reply.")
    }

    /// Swarm tools return their JSON as the text of the first content item.
    static func toolOutput<T: Decodable>(_ result: [String: Any]) throws -> T {
        let content = result["content"] as? [[String: Any]] ?? []
        let text = content.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
        if result["isError"] as? Bool == true { throw SwarmError.server(text.isEmpty ? "Swarm returned an error." : text) }
        return try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }
}

// MARK: Tool replies, shaped by the filters above

struct Items<Item: Decodable>: Decodable { let items: [Item] }
struct VenuesReply: Decodable { let venues: [Venue] }
struct CheckinsReply: Decodable { let checkins: Items<Checkin> }
struct FriendsReply: Decodable { let recent: [Checkin] }
struct LastLocationReply: Decodable { let lat: Double?, lng: Double? }

struct Checkin: Decodable {
    let id: String
    let createdAt: TimeInterval
    let venue: Venue
    let user: User?
    struct User: Decodable { let displayName: String }
}

struct ListReply: Decodable {
    let list: List
    struct List: Decodable { let listItems: Items<Item> }
    struct Item: Decodable { let id: String; let venue: Venue? }   // an item can be a tip with no venue
}

struct EventsReply: Decodable {
    let venues: [Entry]
    struct Entry: Decodable { let venue: Venue; let events: Items<Event> }
    struct Event: Decodable { let name: String? }
}
