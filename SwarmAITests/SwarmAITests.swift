import Testing
import Foundation
import CoreLocation
import FoundationModels
@testable import SwarmAI

struct SwarmClientTests {
    /// A real `search_venues` reply (public venue data) using `SwarmClient.venueFields`.
    static let venuesJSON = #"{"venues":[{"id":"4b242b74f964a520cc6224e3","name":"Ian’s Pizza Madison | Frances Street","location":{"address":"319 N Frances St","city":"Madison","lat":43.07294817941555,"lng":-89.39563737731555}}]}"#

    static func rpcReply(text: String, isError: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": "1",
            "result": ["content": [["type": "text", "text": text]], "isError": isError],
        ])
    }

    @Test func decodesPlainJSONReply() throws {
        let result = try SwarmClient.jsonRPCResult(from: Self.rpcReply(text: Self.venuesJSON), contentType: "application/json")
        let reply: VenuesReply = try SwarmClient.toolOutput(result)
        let place = Place(id: reply.venues[0].id, venue: reply.venues[0])
        #expect(place.venue.name == "Ian’s Pizza Madison | Frances Street")
        #expect(place.coordinate.latitude == 43.07294817941555)
        #expect(place.subtitle == "319 N Frances St, Madison")
    }

    @Test func decodesEventStreamReplyAfterANotification() throws {
        let reply = String(decoding: try Self.rpcReply(text: Self.venuesJSON), as: UTF8.self)
        let stream = """
            event: message
            data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}}

            event: message
            data: \(reply)

            """
        let result = try SwarmClient.jsonRPCResult(from: Data(stream.utf8), contentType: "text/event-stream")
        let venues: VenuesReply = try SwarmClient.toolOutput(result)
        #expect(venues.venues.count == 1)
    }

    @Test func jsonRPCErrorThrows() {
        let body = Data(#"{"jsonrpc":"2.0","id":"1","error":{"code":-32602,"message":"Unknown tool"}}"#.utf8)
        #expect(throws: SwarmError.self) { try SwarmClient.jsonRPCResult(from: body, contentType: "application/json") }
    }

    @Test func toolErrorThrowsWithItsMessage() throws {
        let result = try SwarmClient.jsonRPCResult(from: Self.rpcReply(text: "Requires ll or near", isError: true),
                                                   contentType: "application/json")
        #expect(throws: SwarmError.self) { let _: VenuesReply = try SwarmClient.toolOutput(result) }
    }

    @Test func modelDatesBecomeTimestamps() {
        #expect(SwarmClient.timestamp("2026-01-01") == 1_767_225_600)
        #expect(SwarmClient.timestamp("next spring") == nil)
        #expect(SwarmClient.timestamp(nil) == nil)
    }

    @Test func searchAreaPrefersTypedPlaceThenMapCenter() throws {
        #expect(try SwarmClient.area("Austin", "1,2")["near"] as? String == "Austin")
        #expect(try SwarmClient.area(nil, "1,2")["ll"] as? String == "1,2")
        #expect(throws: SwarmError.self) { try SwarmClient.area(nil, nil) }
    }
}

struct SwarmAuthTests {
    @Test func pkceChallengeIsBase64URLSHA256() {
        // Expected value computed independently: printf '%s' <verifier> | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '='
        #expect(SwarmAuth.challenge(for: "dBjftJeZ4CVP-mJ92K9qzArR9g9pS4TXJ8X5zEv-LfE") == "bcTmc7RhCF695zyHD90htBogyR8mBYMgk7u7zaRkt1g")
    }

    @Test func verifiersAreRandomAndURLSafe() {
        let a = SwarmAuth.randomString(), b = SwarmAuth.randomString()
        #expect(a != b)
        #expect(a.count == 43)
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func formEncodingEscapesReservedCharacters() {
        #expect(SwarmAuth.formEncode(["scope": "a b+c", "redirect_uri": "swarmai://oauth"])
                == "redirect_uri=swarmai%3A%2F%2Foauth&scope=a%20b%2Bc")
    }
}

struct SwarmRequestTests {
    @Test func dropsPlacesTheUserDidNotType() {
        #expect(SwarmRequest.findPlaces(query: "brunch", near: "Chicago").keepingOnlyTypedPlaces(from: "best brunch near me")
                == .findPlaces(query: "brunch", near: nil))
        #expect(SwarmRequest.findPlaces(query: "tacos", near: "Austin").keepingOnlyTypedPlaces(from: "tacos in austin")
                == .findPlaces(query: "tacos", near: "Austin"))
        #expect(SwarmRequest.myCheckins(query: "restaurant", near: "Milwaukee", afterDate: nil, beforeDate: nil)
                    .keepingOnlyTypedPlaces(from: "check-ins in Milwaukee")
                == .myCheckins(query: nil, near: "Milwaukee", afterDate: nil, beforeDate: nil))
    }

    /// Runs the real on-device model, so it only runs where Apple Intelligence is available.
    @Test(.enabled(if: SystemLanguageModel.default.isAvailable), arguments: [
        ("pizza", "findPlaces"),
        ("quiet coffee shop with wifi", "findPlaces"),
        ("tacos in Austin", "findPlaces"),
        ("best brunch near me", "findPlaces"),
        ("where did I eat in Chicago last spring", "myCheckins"),
        ("bars I went to in Denver", "myCheckins"),
        ("my saved places", "savedPlaces"),
        ("where are my friends right now", "friendsOutNow"),
        ("concerts this weekend", "events"),
    ])
    func routesPhrase(_ phrase: String, to expected: String) async {
        let request = await SwarmRequest.route(phrase)
        #expect(request.kind == expected, "\(phrase) → \(request)")
    }

    @Test(.enabled(if: SystemLanguageModel.default.isAvailable))
    func keepsATypedCityAndNeverInventsOne() async {
        guard case let .findPlaces(_, near) = await SwarmRequest.route("tacos in Austin") else { Issue.record(); return }
        #expect(near == "Austin")
        guard case let .findPlaces(_, invented) = await SwarmRequest.route("best brunch near me") else { Issue.record(); return }
        #expect(invented == nil)
    }
}

extension SwarmRequest {
    var kind: String {
        switch self {
        case .findPlaces: "findPlaces"
        case .myCheckins: "myCheckins"
        case .savedPlaces: "savedPlaces"
        case .friendsOutNow: "friendsOutNow"
        case .events: "events"
        }
    }
}
