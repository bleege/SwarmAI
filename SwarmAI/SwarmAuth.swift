import Foundation
import AuthenticationServices
import CryptoKit
import Security
import SwiftUI

/// Signs in to Foursquare with OAuth 2.1 (authorization code + PKCE, no client secret) and keeps the tokens in the Keychain.
@Observable
final class SwarmAuth {
    /// Foursquare has no dynamic client registration. Its OAuth server accepts a client ID that is the HTTPS URL of a
    /// client metadata document you host. Replace this placeholder with that URL before signing in. The document:
    /// {"client_id": "<this URL>", "client_name": "SwarmAI", "redirect_uris": ["swarmai://oauth"],
    ///  "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"], "token_endpoint_auth_method": "none"}
    static let clientID = "https://YOUR-DOMAIN/swarmai/oauth-client.json"
    static let callbackScheme = "swarmai"
    static let redirectURI = "\(callbackScheme)://oauth"
    /// Read-only scopes: the app never writes to the user's Swarm account.
    static let scopes = "mcp:connect venues:read checkins:read lists:read friends:read events:read location:read offline_access"
    /// The OAuth server, which is also the protected resource the tokens are for.
    static let server = URL(string: "https://api.foursquare.com")!

    private var tokens: Tokens? = Keychain.load()
    var isSignedIn: Bool { tokens != nil }

    func signIn(with session: WebAuthenticationSession) async throws {
        let verifier = Self.randomString()
        let state = Self.randomString()
        var url = URLComponents(url: Self.server.appending(path: "oauth21/authorize"), resolvingAgainstBaseURL: false)!
        url.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: Self.scopes),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: Self.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "resource", value: Self.server.absoluteString),
        ]
        let callback = try await session.authenticate(using: url.url!, callback: .customScheme(Self.callbackScheme),
                                                      preferredBrowserSession: nil, additionalHeaderFields: [:])
        let reply = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { reply.first { $0.name == name }?.value }
        guard value("state") == state, let code = value("code") else {
            throw SwarmError.server(value("error_description") ?? value("error") ?? "Sign-in didn't finish.")
        }
        try await requestTokens(["grant_type": "authorization_code", "code": code,
                                 "redirect_uri": Self.redirectURI, "code_verifier": verifier])
    }

    func signOut() {
        tokens = nil
        Keychain.save(nil)
    }

    /// A current access token, refreshed first when it is about to expire.
    // shortcut: two calls racing past expiry each refresh; fine while searches run one at a time, add a shared refresh task if that changes.
    func accessToken() async throws -> String {
        guard let tokens else { throw SwarmError.signedOut }
        if let expiresAt = tokens.expiresAt, expiresAt < .now.addingTimeInterval(60) {
            guard let refreshToken = tokens.refreshToken else { signOut(); throw SwarmError.signedOut }
            do {
                return try await requestTokens(["grant_type": "refresh_token", "refresh_token": refreshToken]).accessToken
            } catch {
                signOut()
                throw SwarmError.signedOut
            }
        }
        return tokens.accessToken
    }

    @discardableResult
    private func requestTokens(_ form: [String: String]) async throws -> Tokens {
        let fields = form.merging(["client_id": Self.clientID, "resource": Self.server.absoluteString]) { $1 }
        var request = URLRequest(url: Self.server.appending(path: "oauth21/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(fields).utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SwarmError.server("Foursquare sign-in failed: \(String(decoding: data, as: UTF8.self))")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let reply = try decoder.decode(TokenReply.self, from: data)
        let tokens = Tokens(accessToken: reply.accessToken,
                            refreshToken: reply.refreshToken ?? self.tokens?.refreshToken,  // servers may not rotate it
                            expiresAt: reply.expiresIn.map { .now.addingTimeInterval($0) })
        self.tokens = tokens
        Keychain.save(tokens)
        return tokens
    }

    // MARK: PKCE and form encoding

    static func randomString() -> String {
        var generator = SystemRandomNumberGenerator()   // cryptographically secure on Apple platforms
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
    }

    static func formEncode(_ fields: [String: String]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
    }
}

struct Tokens: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
}

private struct TokenReply: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval?
}

/// Stores the tokens as one generic-password Keychain item.
private enum Keychain {
    static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.bradleege.SwarmAI.foursquare",
        kSecAttrAccount as String: "tokens",
    ]

    static func load() -> Tokens? {
        var result: CFTypeRef?
        let query = item.merging([kSecReturnData as String: true]) { $1 }
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    static func save(_ tokens: Tokens?) {
        SecItemDelete(item as CFDictionary)
        guard let tokens, let data = try? JSONEncoder().encode(tokens) else { return }
        let attributes = item.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
