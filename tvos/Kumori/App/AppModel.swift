import Foundation
import SwiftUI

/// The account and its games: sign-in, membership, library and running sessions.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var signedIn = false
    @Published private(set) var loading = true
    @Published private(set) var profile: Profile?
    @Published private(set) var membership: Membership?
    @Published private(set) var library: [Game] = []
    @Published private(set) var shelves: [Shelf] = []
    @Published private(set) var sessions: [ActiveSession] = []
    @Published private(set) var regions: [Region] = []
    @Published private(set) var problem: String?

    // Sign-in screen.
    @Published private(set) var challenge: DeviceChallenge?
    @Published private(set) var signInNote: String?

    private(set) var streamingBase = Nvidia.defaultStreaming
    private(set) var vpcId: String?
    private var tokens: Tokens?
    private var renewing: Task<Tokens, Error>?
    private var loginTask: Task<Void, Never>?

    let deviceId: String = {
        if let id = UserDefaults.standard.string(forKey: "deviceId") { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "deviceId")
        return id
    }()

    func start() async {
        if let d = Keychain.load(), let t = try? JSONDecoder().decode(Tokens.self, from: d) {
            tokens = t
            profile = Nvidia.profile(from: t.id ?? t.access)
            signedIn = true
            await load()
        }
        loading = false
    }

    /// A token the services accept, renewed first when it is about to run out.
    func serviceToken() async throws -> String {
        guard let t = tokens else { throw APIError(message: "Sign in first.", code: 401) }
        if t.staleAt > Date().addingTimeInterval(300) || !t.canRenew { return t.service }
        if let renewing { return try await renewing.value.service }
        let userId = profile?.userId
        let task = Task { try await Nvidia.renew(t, userId: userId) }
        renewing = task
        defer { renewing = nil }
        do {
            let fresh = try await task.value
            store(fresh)
            return fresh.service
        } catch let e as APIError where e.code != 0 {
            // The service refused the renewal, so the sign-in is over.
            signOut()
            throw e
        }
    }

    private func store(_ t: Tokens) {
        tokens = t
        Keychain.save(try? JSONEncoder().encode(t))
        if let p = Nvidia.profile(from: t.id ?? t.access) { profile = p }
    }

    // MARK: Sign-in

    /// Shows a code to enter on a phone or computer and waits for it to be used.
    func beginSignIn() {
        loginTask?.cancel()
        loginTask = Task {
            while !Task.isCancelled && !signedIn {
                do {
                    let provider = try await Nvidia.defaultProvider()
                    streamingBase = provider.streamingUrl
                    let c = try await Nvidia.startDeviceLogin(provider, deviceId: deviceId)
                    challenge = c
                    signInNote = nil
                    var wait = c.interval
                    waiting: while !Task.isCancelled && Date() < c.expiresAt {
                        try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                        switch try await Nvidia.pollDeviceLogin(c) {
                        case .pending: continue
                        case .slowDown: wait += 5
                        case .expired: break waiting
                        case .denied:
                            signInNote = "The sign-in was declined. Here is a new code."
                            break waiting
                        case .done(let t):
                            let full = (try? await Nvidia.withClientToken(t)) ?? t
                            store(full)
                            challenge = nil
                            signedIn = true
                            await load()
                            return
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    signInNote = "Couldn't reach NVIDIA. Trying again."
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
            }
        }
    }

    func signOut() {
        loginTask?.cancel()
        tokens = nil
        Keychain.save(nil)
        signedIn = false
        profile = nil
        membership = nil
        library = []
        shelves = []
        sessions = []
        challenge = nil
    }

    // MARK: Loading

    func load() async {
        problem = nil
        do {
            if let p = try? await Nvidia.defaultProvider() { streamingBase = p.streamingUrl }
            let token = try await serviceToken()
            let info = try await Nvidia.serverInfo(streamingBase: streamingBase, token: token)
            vpcId = info.vpcId
            regions = info.regions
            async let lib = Nvidia.library(token: token, vpcId: info.vpcId)
            async let rails = Nvidia.shelves(token: token, vpcId: info.vpcId)
            library = try await lib
            shelves = (try? await rails) ?? []
            if let id = profile?.userId {
                membership = try? await Nvidia.membership(token: token, userId: id, vpcId: info.vpcId)
            }
            await refreshSessions()
        } catch {
            if signedIn { problem = error.localizedDescription }
        }
    }

    func refreshSessions() async {
        guard let token = try? await serviceToken() else { return }
        if let list = try? await Nvidia.activeSessions(streamingBase: streamingBase, token: token, deviceId: deviceId) { sessions = list }
    }

    func search(_ text: String) async -> [Game] {
        guard let vpcId, let token = try? await serviceToken() else { return [] }
        return (try? await Nvidia.search(token: token, vpcId: vpcId, text: text)) ?? []
    }

    /// The game a running session belongs to, when it is one we know.
    func game(for s: ActiveSession) -> Game? {
        (library + shelves.flatMap(\.games)).first { g in g.id == s.appId || g.variants.contains { $0.id == s.appId } }
    }

    func session(for g: Game) -> ActiveSession? {
        sessions.first { s in g.id == s.appId || g.variants.contains { $0.id == s.appId } }
    }

    /// Games played most recently first, for the top of Home.
    var recent: [Game] {
        library.filter { $0.lastPlayed != nil }.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }
}
