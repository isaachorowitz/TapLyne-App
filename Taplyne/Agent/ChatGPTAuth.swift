import AppKit
import Combine
import CryptoKit
import Foundation
import Network
import Security
import TaplyneServer

@MainActor
final class ChatGPTAuth: ObservableObject {
    static let shared = ChatGPTAuth()

    struct Profile: Codable, Identifiable, Hashable {
        let id: String
        let clientID: String
        let subject: String
        var email: String?
        var displayName: String?
        var connected: Bool
        var sharingEnabled: Bool
        var label: String {
            displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "ChatGPT account \(id.prefix(6))"
        }
    }

    struct Tokens: Codable, Equatable {
        var clientID: String
        var subject: String
        var access: String
        var refresh: String?
        var identity: String
        var expires: Date
        var earliestRefresh: Date?
        var scopes: [String]
        var email: String?
        var displayName: String?
        var sharingEnabled: Bool { scopes.contains(ChatGPTAuth.requiredScope) }
    }

    struct Model: Identifiable, Hashable { var id: String; var name: String }
    struct RunSession { let profileID: String; let accessToken: String; let models: [Model] }

    static let profilesDefaultsKey = "chatGPTProfilesV2"
    static let activeProfileDefaultsKey = "chatGPTActiveProfileV2"
    nonisolated static let requiredScope = "chatgpt.tokens.use.direct"
    private static let issuer = "https://auth.openai.com"
    private static let tokenURL = URL(string: issuer + "/api/accounts/oauth/token")!
    private static let resource = "https://api.openai.com/v1"

    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var activeProfileID: String?
    @Published private(set) var signingIn = false
    @Published private(set) var models: [Model] = []
    @Published var error: String?

    var activeProfile: Profile? { profiles.first { $0.id == activeProfileID } }
    var signedIn: Bool { activeProfile?.connected == true }
    var sharingEnabled: Bool { signedIn && activeProfile?.sharingEnabled == true }

    private var loginTask: Task<Void, Never>?
    private var listener: OAuthLoopback?
    private var loginGeneration = UUID()
    private var profileGenerations: [String: UUID] = [:]
    private var refreshTasks: [String: Task<Tokens, Error>] = [:]
    private var modelCache: [String: [Model]] = [:]
    private let defaults: UserDefaults
    private let session: URLSession
    private let credentialReader: (String) -> String?
    private let credentialWriter: (String, String) -> Bool
    private let credentialDeleter: (String) -> Void

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = PrivateHTTPClient.session,
        credentialReader: @escaping (String) -> String? = { Keychain.read($0) },
        credentialWriter: @escaping (String, String) -> Bool = { Keychain.write($0, account: $1) },
        credentialDeleter: @escaping (String) -> Void = { Keychain.delete($0) }
    ) {
        self.defaults = defaults
        self.session = session
        self.credentialReader = credentialReader
        self.credentialWriter = credentialWriter
        self.credentialDeleter = credentialDeleter
        if let data = defaults.data(forKey: Self.profilesDefaultsKey),
           let saved = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = saved.map { profile in
                var profile = profile
                if credential(for: profile.id) == nil { profile.connected = false; profile.sharingEnabled = false }
                return profile
            }
        }
        let requested = defaults.string(forKey: Self.activeProfileDefaultsKey)
        activeProfileID = profiles.contains { $0.id == requested } ? requested : profiles.first?.id
        persistProfiles()
    }

    func signIn() {
        if let profile = activeProfile, !profile.connected { reauthorize(profile.id) }
        else { addAccount() }
    }
    func addAccount() { beginSignIn(profileID: nil) }
    func reauthorize(_ profileID: String) { beginSignIn(profileID: profileID) }

    private func beginSignIn(profileID: String?) {
        guard !signingIn else { return }
        let selected = profileID.flatMap { id in profiles.first { $0.id == id } }
        guard profileID == nil || selected != nil else { error = "That saved ChatGPT registration is unavailable."; return }
        error = nil
        signingIn = true
        let attempt = UUID()
        loginGeneration = attempt
        loginTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let state = try Self.random(), nonce = try Self.random(), verifier = try Self.random()
                let callback = OAuthLoopback()
                listener = callback
                let redirect = try await callback.start(expectedState: state)
                let previous = selected.flatMap { self.credential(for: $0.id) }
                let registered = selected?.clientID
                var fields = [
                    "client_id": registered ?? "dynamic_agent_client", "response_type": "code", "redirect_uri": redirect,
                    "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct", "resource": Self.resource,
                    "state": state, "nonce": nonce,
                    "code_challenge": Self.base64(Data(SHA256.hash(data: Data(verifier.utf8)))), "code_challenge_method": "S256",
                    "ext_agent_host_id": hostID()
                ]
                if registered == nil { fields["agent_name_hint"] = "Taplyne" }
                else if let hint = previous?.identity.nilIfEmpty { fields["id_token_hint"] = hint }
                else if let email = selected?.email?.nilIfEmpty { fields["login_hint"] = email }
                if selected?.sharingEnabled == false { fields["prompt"] = "consent" }
                var components = URLComponents(string: Self.issuer + "/api/accounts/authorize")!
                components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
                guard let address = components.url, NSWorkspace.shared.open(address) else { throw Failure("Could not open the ChatGPT sign-in browser.") }
                let result = try await callback.wait()
                try Task.checkCancellation()
                guard loginGeneration == attempt, result["state"] == state else { throw Failure("Sign-in state did not match. Start a fresh sign-in.") }
                if let code = result["error"], !code.isEmpty {
                    throw Failure(result["error_description"]?.nilIfEmpty ?? "ChatGPT sign-in was cancelled or denied.")
                }
                guard let code = result["code"], !code.isEmpty else { throw Failure("ChatGPT sign-in returned no authorization code.") }
                let clientID: String
                if let registered {
                    guard result["client_id"] == nil || result["client_id"] == registered else { throw Failure("ChatGPT returned a different registration. The saved account was not changed.") }
                    clientID = registered
                } else {
                    guard let issued = result["client_id"], !issued.isEmpty, issued != "dynamic_agent_client" else { throw Failure("ChatGPT did not finish registering Taplyne.") }
                    clientID = issued
                }
                let response = try await post(Self.tokenURL, ["grant_type": "authorization_code", "client_id": clientID, "code": code,
                    "code_verifier": verifier, "redirect_uri": redirect, "resource": Self.resource])
                let record = try await parse(response, client: clientID, nonce: nonce, expectedSubject: selected?.subject, previous: previous)
                let profile = Self.profile(from: record)
                guard selected == nil || selected?.id == profile.id else { throw Failure("Sign-in returned a different ChatGPT account. The saved account was not changed.") }
                guard loginGeneration == attempt else { return }
                try save(record, profileID: profile.id)
                upsert(profile)
                activeProfileID = profile.id
                modelCache[profile.id] = nil
                models = []
                persistProfiles()
                if profile.sharingEnabled {
                    do { try await loadModels(for: profile.id) }
                    catch { self.error = message(for: error, operation: "loading models") }
                } else {
                    error = "This account is connected, but ChatGPT plan usage is not enabled. Reconnect it and approve plan usage, or use your own OpenAI API key."
                }
            } catch is CancellationError {
            } catch {
                if loginGeneration == attempt { self.error = message(for: error, operation: "sign-in") }
            }
            if loginGeneration == attempt {
                signingIn = false
                listener?.stop(); listener = nil; loginTask = nil
            }
        }
    }

    func cancelSignIn() {
        loginGeneration = UUID()
        loginTask?.cancel(); loginTask = nil
        listener?.stop(); listener = nil
        signingIn = false
    }

    func selectProfile(_ profileID: String) async {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { error = "That saved ChatGPT registration is unavailable."; return }
        error = nil
        activeProfileID = profileID
        models = modelCache[profileID] ?? []
        persistProfiles()
        guard profile.connected, profile.sharingEnabled else { return }
        do { try await loadModels(for: profileID) }
        catch let failure { error = message(for: failure, operation: "loading models") }
    }

    func signOut() async { await signOut(profileID: activeProfileID) }
    func signOut(profileID: String?) async {
        guard let profileID, let profile = profiles.first(where: { $0.id == profileID }) else { return }
        if signingIn { cancelSignIn() }
        bumpGeneration(for: profileID)
        refreshTasks.removeValue(forKey: profileID)?.cancel()
        let old = credential(for: profileID)
        var revocationConfirmed = true
        if let refresh = old?.refresh?.nilIfEmpty {
            do {
                let discovery = try await get(URL(string: Self.issuer + "/.well-known/openid-configuration")!)
                guard let raw = discovery["revocation_endpoint"] as? String, let url = URL(string: raw),
                      url.scheme == "https", url.host == "auth.openai.com" else { throw Failure("Invalid revocation endpoint.") }
                _ = try await post(url, ["token": refresh, "token_type_hint": "refresh_token", "client_id": profile.clientID], allowEmpty: true)
            } catch { revocationConfirmed = false }
        }
        credentialDeleter(Self.credentialAccount(profileID))
        update(profileID) { $0.connected = false; $0.sharingEnabled = false }
        modelCache[profileID] = nil
        if activeProfileID == profileID { models = [] }
        persistProfiles()
        if !revocationConfirmed { error = "Signed out locally. Remote revocation could not be confirmed; disconnect Taplyne in ChatGPT Settings if needed." }
    }

    func forgetProfile(_ profileID: String) {
        guard profiles.contains(where: { $0.id == profileID && !$0.connected }) else { error = "Sign out before forgetting this ChatGPT registration."; return }
        bumpGeneration(for: profileID)
        credentialDeleter(Self.credentialAccount(profileID))
        modelCache[profileID] = nil
        profiles.removeAll { $0.id == profileID }
        if activeProfileID == profileID { activeProfileID = profiles.first?.id; models = activeProfileID.flatMap { modelCache[$0] } ?? [] }
        persistProfiles()
    }

    func accessToken() async throws -> String {
        guard let activeProfileID else { throw Failure("Choose or connect a ChatGPT account in Settings.") }
        return try await accessToken(for: activeProfileID)
    }

    func accessToken(for profileID: String) async throws -> String {
        guard let profile = profiles.first(where: { $0.id == profileID }), profile.connected,
              var record = credential(for: profileID) else { throw Failure("This ChatGPT account is signed out. Reconnect it in Settings.") }
        guard record.clientID == profile.clientID, record.subject == profile.subject else { throw Failure("The saved ChatGPT credentials do not match this account. Reconnect it.") }
        guard record.sharingEnabled else { throw Failure("ChatGPT plan usage is not enabled for this account. Reconnect it or use your own API key.") }
        if record.expires.timeIntervalSinceNow > 90 { return record.access }
        if let task = refreshTasks[profileID] { return try await task.value.access }
        if let earliest = record.earliestRefresh, earliest > Date() { throw Failure("ChatGPT asked Taplyne to wait before renewing. Try again later; no phone action was retried.") }
        guard let refresh = record.refresh?.nilIfEmpty else { expire(profileID); throw Failure("This ChatGPT session cannot be renewed. Reconnect it in Settings.") }
        let version = generation(for: profileID)
        let task = Task<Tokens, Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            let response = try await post(Self.tokenURL, ["grant_type": "refresh_token", "client_id": record.clientID,
                "refresh_token": refresh, "resource": Self.resource])
            let next = try await parse(response, client: record.clientID, nonce: nil, expectedSubject: record.subject, previous: record)
            guard generation(for: profileID) == version, !Task.isCancelled else { throw CancellationError() }
            try save(next, profileID: profileID)
            record = next
            update(profileID) {
                $0.connected = true; $0.sharingEnabled = next.sharingEnabled
                $0.email = next.email ?? $0.email; $0.displayName = next.displayName ?? $0.displayName
            }
            persistProfiles()
            return next
        }
        refreshTasks[profileID] = task
        do {
            let next = try await task.value
            refreshTasks[profileID] = nil
            return next.access
        } catch {
            refreshTasks[profileID] = nil
            if let http = error as? HTTPFailure, [400, 401].contains(http.status) { expire(profileID) }
            throw Failure(message(for: error, operation: "session renewal"))
        }
    }

    func captureRun() async throws -> RunSession {
        guard let profileID = activeProfileID else { throw Failure("Choose or connect a ChatGPT account in Settings.") }
        let token = try await accessToken(for: profileID)
        if modelCache[profileID]?.isEmpty != false { try await loadModels(for: profileID) }
        let available = modelCache[profileID] ?? []
        guard !available.isEmpty else { throw Failure("No eligible models are available for this ChatGPT account.") }
        return RunSession(profileID: profileID, accessToken: token, models: available)
    }

    func loadModels() async throws {
        guard let activeProfileID else { throw Failure("Choose or connect a ChatGPT account in Settings.") }
        try await loadModels(for: activeProfileID)
    }
    func loadModels(for profileID: String) async throws {
        let token = try await accessToken(for: profileID)
        let response = try await get(URL(string: Self.resource + "/models")!, key: token)
        let available = (response["models"] as? [[String: Any]] ?? []).compactMap { item -> Model? in
            guard item["visibility"] as? String == "list", let slug = item["slug"] as? String, !slug.isEmpty else { return nil }
            return Model(id: slug, name: item["display_name"] as? String ?? slug)
        }
        guard !available.isEmpty else { throw Failure("No eligible ChatGPT models are available for this account.") }
        modelCache[profileID] = available
        if activeProfileID == profileID { models = available }
    }

    private func parse(_ response: [String: Any], client: String, nonce: String?, expectedSubject: String?, previous: Tokens?) async throws -> Tokens {
        guard response["token_type"] as? String == "Bearer", let access = response["access_token"] as? String, !access.isEmpty,
              let duration = Self.number(response["expires_in"]), duration > 0,
              let identity = response["id_token"] as? String, !identity.isEmpty else { throw Failure("ChatGPT returned an incomplete token response. The saved account was not changed.") }
        let keys = try await get(URL(string: Self.issuer + "/.well-known/jwks.json")!)
        let claims = try Self.validate(identity, keys: keys, client: client, nonce: nonce)
        guard let subject = claims["sub"] as? String, !subject.isEmpty, expectedSubject == nil || expectedSubject == subject else { throw Failure("The returned ChatGPT identity did not match the selected account.") }
        let scopes = (response["scope"] as? String ?? "").split(separator: " ").map(String.init)
        return Tokens(clientID: client, subject: subject, access: access,
            refresh: (response["refresh_token"] as? String)?.nilIfEmpty ?? previous?.refresh,
            identity: identity, expires: Date().addingTimeInterval(duration),
            earliestRefresh: Self.number(response["earliest_refresh_at"]).map { Date(timeIntervalSince1970: $0) }, scopes: scopes,
            email: claims["email"] as? String ?? previous?.email, displayName: claims["name"] as? String ?? previous?.displayName)
    }

    private func hostID() -> String {
        if let saved = defaults.string(forKey: "chatGPTHostID"), saved.hasPrefix("urn:uuid:") { return saved }
        let value = "urn:uuid:" + UUID().uuidString.lowercased()
        defaults.set(value, forKey: "chatGPTHostID")
        return value
    }
    private func credential(for profileID: String) -> Tokens? {
        guard let raw = credentialReader(Self.credentialAccount(profileID)), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }
    private func save(_ record: Tokens, profileID: String) throws {
        let data = try JSONEncoder().encode(record)
        guard credentialWriter(String(decoding: data, as: UTF8.self), Self.credentialAccount(profileID)) else { throw Failure("Keychain could not save the ChatGPT connection securely.") }
    }
    static func credentialAccount(_ profileID: String) -> String { "chatgpt-profile-" + profileID }
    static func profile(from record: Tokens) -> Profile {
        let id = SHA256.hash(data: Data((record.clientID + ":" + record.subject).utf8)).map { String(format: "%02x", $0) }.joined()
        return Profile(id: id, clientID: record.clientID, subject: record.subject, email: record.email,
            displayName: record.displayName, connected: true, sharingEnabled: record.sharingEnabled)
    }
    private func upsert(_ profile: Profile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile } else { profiles.append(profile) }
        profiles.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        _ = generation(for: profile.id)
    }
    private func update(_ profileID: String, _ body: (inout Profile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        body(&profiles[index])
    }
    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Self.profilesDefaultsKey) }
        defaults.set(activeProfileID, forKey: Self.activeProfileDefaultsKey)
    }
    private func generation(for profileID: String) -> UUID {
        if let value = profileGenerations[profileID] { return value }
        let value = UUID(); profileGenerations[profileID] = value; return value
    }
    private func bumpGeneration(for profileID: String) { profileGenerations[profileID] = UUID() }
    private func expire(_ profileID: String) {
        bumpGeneration(for: profileID)
        credentialDeleter(Self.credentialAccount(profileID))
        update(profileID) { $0.connected = false; $0.sharingEnabled = false }
        modelCache[profileID] = nil
        if activeProfileID == profileID { models = [] }
        persistProfiles()
    }

    private func message(for error: Error, operation: String) -> String {
        if let failure = error as? Failure { return failure.message }
        if let http = error as? HTTPFailure {
            switch http.status {
            case 400, 401: return "The ChatGPT session expired or was revoked. Reconnect this account in Settings."
            case 403: return "ChatGPT plan usage is unavailable for this account or workspace. Use another eligible account or your own API key."
            case 429: return "ChatGPT temporarily limited this account. Review ChatGPT Settings → Usage and try again later."
            case 500...599: return "ChatGPT is temporarily unavailable while \(operation). Your saved account was preserved."
            default: return http.detail?.nilIfEmpty ?? "ChatGPT could not finish \(operation) (HTTP \(http.status))."
            }
        }
        return "ChatGPT could not finish \(operation). Check the connection and try again."
    }
    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    static func validate(_ jwt: String, keys: [String: Any], client: String, nonce: String?, now: Date = Date()) throws -> [String: Any] {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerData = unbase64(String(parts[0])), let payload = unbase64(String(parts[1])),
              let signature = unbase64(String(parts[2])), let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let jwk = (keys["keys"] as? [[String: Any]])?.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              jwk["use"] == nil || jwk["use"] as? String == "sig", let n = jwk["n"] as? String, let e = jwk["e"] as? String,
              let modulus = unbase64(n), let exponent = unbase64(e) else { throw Failure("Sign-in identity signature is invalid.") }
        func der(_ tag: UInt8, _ value: Data) -> Data {
            let count = value.count
            let length: [UInt8] = count < 128 ? [UInt8(count)] : count < 256 ? [0x81, UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 255)]
            return Data([tag] + length) + value
        }
        func integer(_ data: Data) -> Data { der(0x02, data.first.map { $0 & 128 != 0 } == true ? Data([0]) + data : data) }
        let keyData = der(0x30, integer(modulus) + integer(exponent))
        guard let key = SecKeyCreateWithData(keyData as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: payload) as? [String: Any], claims["iss"] as? String == issuer,
              let expiry = number(claims["exp"]), expiry > now.timeIntervalSince1970,
              let issued = number(claims["iat"]), issued <= now.timeIntervalSince1970 + 60,
              nonce == nil || claims["nonce"] as? String == nonce else { throw Failure("Sign-in identity could not be verified.") }
        let audiences = claims["aud"] as? [String] ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(client), audiences.count == 1 || claims["azp"] as? String == client,
              claims["nbf"] == nil || (number(claims["nbf"]) ?? .infinity) <= now.timeIntervalSince1970 + 60 else { throw Failure("Sign-in identity belongs to another client.") }
        return claims
    }

    static func base64(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func unbase64(_ value: String) -> Data? {
        let normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4))
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure("Could not create a secure sign-in request.") }
        return base64(Data(bytes))
    }
    private func get(_ url: URL, key: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return try await perform(request)
    }
    private func post(_ url: URL, _ fields: [String: String], allowEmpty: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 20); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents(); components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        return try await perform(request, allowEmpty: allowEmpty)
    }
    private func perform(_ request: URLRequest, allowEmpty: Bool = false) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw Failure("ChatGPT returned an invalid network response.") }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let nested = object?["error"] as? [String: Any]
            throw HTTPFailure(status: http.statusCode, code: nested?["code"] as? String,
                detail: nested?["message"] as? String ?? object?["detail"] as? String)
        }
        if allowEmpty, data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure("ChatGPT returned an invalid response.") }
        return object
    }

    struct Failure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
    struct HTTPFailure: Error { let status: Int; let code: String?; let detail: String? }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

@MainActor
final class OAuthLoopback {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var outcome: Result<[String: String], Error>?
    private var timeout: Task<Void, Never>?
    private var expectedState = ""
    private var connections: [UUID: NWConnection] = [:]

    func start(expectedState: String) async throws -> String {
        self.expectedState = expectedState
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { ready in
            var resumed = false
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    guard !resumed else { return }
                    if case .ready = state, let port = listener.port { resumed = true; ready.resume(returning: "http://127.0.0.1:\(port)/auth/callback") }
                    else if case .failed = state { resumed = true; ready.resume(throwing: ChatGPTAuth.Failure("Could not open the local sign-in callback.")) }
                    else if case .cancelled = state { resumed = true; ready.resume(throwing: CancellationError()) }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                Task { @MainActor in
                    guard let self, self.connections.count < 8, self.outcome == nil else { connection.cancel(); return }
                    let id = UUID(); self.connections[id] = connection; self.receive(connection, id: id, data: Data())
                    Task { [weak self] in try? await Task.sleep(for: .seconds(10)); self?.connections.removeValue(forKey: id)?.cancel() }
                }
            }
            listener.start(queue: .main)
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(180)) } catch { return }
                self?.finish(.failure(ChatGPTAuth.Failure("Sign-in expired. Start again when ready.")))
            }
        }
    }
    func wait() async throws -> [String: String] {
        if let outcome { return try outcome.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func stop() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<[String: String], Error>) {
        guard outcome == nil else { return }
        outcome = result; continuation?.resume(with: result); continuation = nil
        timeout?.cancel(); timeout = nil; listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }; connections.removeAll()
    }
    private func receive(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, complete, failure in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let data = data + (chunk ?? Data())
                guard data.count <= 8192, failure == nil else { connection.cancel(); return }
                let raw = String(decoding: data, as: UTF8.self)
                guard raw.contains("\r\n\r\n") else {
                    if !complete { self.receive(connection, id: id, data: data) } else { connection.cancel() }
                    return
                }
                let line = raw.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard line.count == 3, line[0] == "GET", let url = URLComponents(string: String(line[1])),
                      url.path == "/auth/callback", url.scheme == nil, let items = url.queryItems,
                      Set(items.map(\.name)).count == items.count else { connection.cancel(); return }
                let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                guard fields["state"] == self.expectedState else { self.connections.removeValue(forKey: id); connection.cancel(); return }
                self.connections.removeValue(forKey: id)
                let body = "Return to Taplyne to see the sign-in result."
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                self.finish(.success(fields))
            }
        }
    }
}
