# SwarmAI

Ask Foursquare Swarm questions in plain language and see the answers on a map. A native SwiftUI app for iPhone, iPad and Mac.

> **Status:** blocked on sign-in. See [Authentication status](#authentication-status-blocked).

## Goals

- **Search Swarm in plain language.** One search box handles requests like:
  - "tacos in Austin"
  - "where did I eat in Chicago last spring"
  - "my saved places"
  - "where are my friends right now"
  - "concerts this weekend"
- **On-device AI only.** Apple's Foundation Models framework works out what the search is asking for. There's no cloud LLM and no AI API key. The model only picks the kind of request and fills in its fields. It never sees venue data, and the app makes the Swarm call itself.
- **No server.** Sign-in, token storage and API calls all happen inside the app. There is no backend to run or secure.
- **Read-only.** The app requests read-only scopes and never creates, edits or deletes anything in the user's Swarm account.
- **One codebase** for iOS, iPadOS and macOS.

## How it works

```
search text → SwarmRequest.route (on-device model) → SwarmClient.places (Swarm MCP tool call) → list + map
```

| The user asks for | Request | Swarm MCP tool |
|---|---|---|
| Places to go | `findPlaces` | `search_venues` |
| Places they've been | `myCheckins` | `search_checkins` |
| Saved places | `savedPlaces` | `get_list` (`self/todos`) |
| Where friends are now | `friendsOutNow` | `friends_nearby` |
| Things happening | `events` | `search_events` |

- `SwarmAI/SwarmRequest.swift`: the `@Generable` request type and the model prompt.
  - If the model adds a city the user didn't type, the app removes it.
  - If Apple Intelligence is unavailable, every search runs as a plain place search.
- `SwarmAI/SwarmClient.swift`: a small client for MCP's Streamable HTTP transport, talking to `https://api.foursquare.com/v2/streaming/mcp/swarm-beta?v=20261027`. A search that names no place searches around the map's center.
- `SwarmAI/SwarmAuth.swift`: OAuth 2.1 with PKCE. Tokens are stored in the Keychain.
- `SwarmAI/RootView.swift`: a `NavigationSplitView` with a results list and a map.
- `oauth/oauth-client.json`: the app's OAuth client ID document, published with GitHub Pages.

## Requirements

- Xcode 27.2, targeting iOS, iPadOS and macOS 27.2.
- Apple Intelligence, for routing searches. Without it, every search is a place search.
- A Foursquare Swarm account.

## Building and testing

Open `SwarmAI.xcodeproj` and run the `SwarmAI` scheme. To run the tests:

```sh
xcodebuild test -project SwarmAI.xcodeproj -scheme SwarmAI -destination 'platform=macOS'
```

- Routing tests use the real on-device model, so they only run where Apple Intelligence is available.
- Test fixtures contain only public venue data, never anyone's check-ins or location.

## Authentication status: blocked

The app can't sign in yet. Every Swarm call needs a token, so the app goes no further than its sign-in screen.

### What Foursquare requires

Foursquare publishes its OAuth requirements for the Swarm MCP server as server metadata:

- **Sign-in flow:** OAuth 2.1 authorization code with PKCE (`S256`), using `https://api.foursquare.com/oauth21/authorize` and `/oauth21/token`.
- **Public clients only:** `token_endpoint_auth_method` must be `none`, so the app never holds a client secret.
- **No dynamic client registration and no device code flow.** The app can't register itself, and it can't sign in by showing a code to enter elsewhere.
- **`client_id_metadata_document_supported: true`:** the client ID can be the HTTPS address of a JSON document that describes the app.

### What the app does

- **Client ID:** `https://www.leege.io/SwarmAI/oauth/oauth-client.json`. This document is served by GitHub Pages from `oauth/` in this repo.
- **Redirect:** `io.leege.swarmai:/oauth`, a custom URL scheme. `ASWebAuthenticationSession` catches it, so no URL type or web server is needed.
- **Tokens:** the app exchanges the sign-in code itself, using PKCE, and stores the tokens in the Keychain.

### Why sign-in fails

Signing in on the Mac ends on this Foursquare page:

> **Authorization Error**
>
> Client domain 'www.leege.io' is not in the trusted domains list

Foursquare only accepts client ID documents from domains on its own trusted list. `nfolkert.github.io`, which hosts the client ID document from Foursquare's Muse setup instructions, is on that list. `www.leege.io` is not. Because the domain check fails first, Foursquare hasn't yet checked the app-scheme redirect `io.leege.swarmai:/oauth`.

The token endpoint confirms the same thing without a sign-in. These checks exchange a fake code, and Foursquare checks the client ID before the code:

| `client_id` sent | Foursquare's reply |
|---|---|
| `https://www.leege.io/SwarmAI/oauth/oauth-client.json` | `401 invalid_client`: "Unknown client_id" |
| The same document with an HTTPS redirect (`oauth/https-test.json`) | `401 invalid_client`: "Unknown client_id" |
| [The Muse client ID document](https://nfolkert.github.io/swarm_mcp_cimd_proxy/muse.js) on `nfolkert.github.io` | `400 invalid_grant`: the client is accepted, and only the fake code is rejected |
| A Foursquare-issued developer console ID | `401 invalid_client`: "client_secret is required". This is a confidential client, which an app with no server can't use. |

A missing file gets "Unknown client_id" even on a trusted domain, so this check can't show whether a domain is trusted until a real document is hosted there.

`oauth/https-test.json` is no longer needed and can be deleted.

### Options ruled out

- **Embedding a client secret** (the Foursquare-issued ID). Anything shipped in an app can be extracted from it.
- **A Places API service key.** It's a server-side secret, and it creates new users owned by the app that have no Swarm history. It isn't an OAuth credential for the MCP server.
- **Classic v2 OAuth.** It needs a client secret kept on a server.
- **A loopback redirect** to a local HTTP listener. Ruled out as Mac-only.
- **An embedded web view for sign-in.** RFC 8252 forbids it for native apps.
- **Dynamic client registration and device code flow.** Foursquare offers neither.

### How to unblock

1. **Ask Foursquare to add `www.leege.io` to its trusted domains.** Nothing in the app changes. Include:
   - Client ID: `https://www.leege.io/SwarmAI/oauth/oauth-client.json`
   - Redirect: `io.leege.swarmai:/oauth`
   - Client type: public, PKCE `S256`, no secret
   - A question: does Foursquare accept custom-scheme redirects?
2. **Or host the document on a trusted domain.** For example, propose adding a `swarmai.json` to [`nfolkert/swarm_mcp_cimd_proxy`](https://github.com/nfolkert/swarm_mcp_cimd_proxy). The repo exists for clients that can't host their own document.
   - Then change `SwarmAuth.clientID` to that file's URL.
   - The trade-off: someone else controls the file.

It's unknown whether every `github.io` site is trusted or only `nfolkert.github.io`. Testing that would need a document on a `github.io` address that isn't redirected; `bleege.github.io` redirects to `www.leege.io`.

To check whether a client ID is accepted, without signing anyone in:

```sh
curl -sS https://api.foursquare.com/oauth21/token \
  -d grant_type=authorization_code -d code=fake-code \
  --data-urlencode client_id=https://www.leege.io/SwarmAI/oauth/oauth-client.json \
  --data-urlencode redirect_uri=io.leege.swarmai:/oauth \
  -d code_verifier=fake-verifier-fake-verifier-fake-verifier-0000 \
  -d resource=https://api.foursquare.com
```

`invalid_grant` means the client is accepted. "Unknown client_id" means it isn't.

## Known limitations

- The Swarm MCP server is a beta. Its `ask` tool returned `404 No matching endpoint` in testing, so the app doesn't use it.
- Dates in searches are approximate. For example, "this weekend" doesn't always map to Saturday and Sunday.
- `search_venues` returns nothing for long phrases, so the model shortens a search to the kind of place, e.g. "quiet coffee shop with wifi" → "coffee".
