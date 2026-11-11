import Foundation
import FoundationModels

/// What a search asks Swarm for. The on-device model only picks the case; app code makes the Swarm call,
/// so the model never handles venue data or coordinates.
@Generable
enum SwarmRequest: Equatable {
    case findPlaces(query: String, near: String?)
    case myCheckins(query: String?, near: String?, afterDate: String?, beforeDate: String?)
    case savedPlaces
    case friendsOutNow
    case events(query: String, near: String?, startDate: String?, endDate: String?)

    /// Falls back to a plain place search when Apple Intelligence is unavailable or the model fails.
    static func route(_ text: String) async -> SwarmRequest {
        guard SystemLanguageModel.default.isAvailable else { return .findPlaces(query: text, near: nil) }
        // A fresh session per search keeps old searches out of the model's small context window.
        let session = LanguageModelSession(instructions: instructions())
        do {
            return try await session.respond(to: text, generating: SwarmRequest.self).content.keepingOnlyTypedPlaces(from: text)
        } catch {
            return .findPlaces(query: text, near: nil)
        }
    }

    static func instructions(today: Date = .now) -> String {
        """
        Turn a search typed into a places app into one request.
        Today is \(today.formatted(.dateTime.weekday(.wide).month(.wide).day().year())), \(today.formatted(.iso8601.year().month().day())).
        - findPlaces: places to go. query is a place name exactly as typed, or else the kind of place in one or two words.
          "Ian's Pizza" → query "Ian's Pizza". "quiet coffee shop with wifi" → query "coffee". "best brunch near me" → query "brunch".
        - myCheckins: places the user has been or checked in at. query is a venue name or kind of place, or empty. Cities go in near, never in query.
          "bars I went to in Chicago last spring" → query "bars", near "Chicago". "check-ins in Milwaukee" → query empty, near "Milwaukee".
        - savedPlaces: the user's saved or bookmarked places.
        - friendsOutNow: where the user's friends are right now.
        - events: concerts, shows, games or other things happening. query is the kind of event.
        near is a city or neighborhood written in the search; leave it empty otherwise and never guess one.
        When the search mentions a time, set the first and last day as YYYY-MM-DD,
        like "this year" → \(today.formatted(.iso8601.year()))-01-01 to \(today.formatted(.iso8601.year().month().day())).
        """
    }

    /// The model sometimes invents a city ("best brunch near me" → Chicago) or copies a word from the instructions
    /// ("restaurant"). Keep `near`, and the check-in name filter, only when the user typed them, so an invented value
    /// can't override the map's location or hide check-ins.
    func keepingOnlyTypedPlaces(from text: String) -> SwarmRequest {
        func typed(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
                  text.localizedCaseInsensitiveContains(value) else { return nil }
            return value
        }
        switch self {
        case let .findPlaces(query, near):
            return .findPlaces(query: query, near: typed(near))
        case let .myCheckins(query, near, after, before):
            return .myCheckins(query: typed(query), near: typed(near), afterDate: after, beforeDate: before)
        case let .events(query, near, start, end):
            return .events(query: query, near: typed(near), startDate: start, endDate: end)
        case .savedPlaces, .friendsOutNow:
            return self
        }
    }
}
