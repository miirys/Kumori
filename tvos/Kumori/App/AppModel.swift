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
    /// True once a load has come back, so an empty Home or Library can say "nothing here"
    /// instead of showing a spinner forever.
    @Published private(set) var loaded = false

    // Sign-in screen.
    @Published private(set) var challenge: DeviceChallenge?
    @Published private(set) var signInNote: String?

    private(set) var streamingBase = Nvidia.defaultStreaming
    private(set) var vpcId: String?
    private var tokens: Tokens?
    private var renewing: Task<Tokens, Error>?
    private var loginTask: Task<Void, Never>?
    /// Goes up at every sign-out. Work that started before then checks it and lets go of
    /// its answer, so a load or renewal still in flight can't bring the old account back.
    private var epoch = 0
    private var clientCheckedAt = Date.distantPast
    #if DEBUG
    /// Set by the fixture harness: no network, no keychain, answers come from fixtures.
    private(set) var fixtureMode = false
    private(set) var fixtureSearchFails = false
    #endif

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

    /// A token the services accept, renewed first when it is about to run out, or when
    /// `force` says a service has just refused it.
    ///
    /// Only a refused renewal ends the sign-in. A network failure or a busy server never does.
    func serviceToken(force: Bool = false) async throws -> String {
        guard var t = tokens else { throw APIError(message: "Sign in first.", code: 401) }
        let mine = epoch
        // The client token is what keeps the sign-in alive, and it runs out too. Fetch a
        // fresh one at every start and a few times a day while the access token still works.
        let recheck: TimeInterval = (t.client ?? "").isEmpty ? 300 : 6 * 3600
        if t.staleAt > Date().addingTimeInterval(60), Date().timeIntervalSince(clientCheckedAt) > recheck {
            clientCheckedAt = Date()
            if let fresh = try? await Nvidia.withClientToken(t) {
                guard mine == epoch else { throw CancellationError() }
                store(fresh)
                t = fresh
            }
        }
        let expired = t.staleAt <= Date()
        if !force && t.staleAt > Date().addingTimeInterval(300) { return t.service }
        let over = APIError(message: "Your sign-in has expired.", code: 401)
        guard t.canRenew else {
            // Nothing to renew with. While the token still works, use it; after that the
            // only way forward is to sign in again.
            if !expired && !force { return t.service }
            signOut(note: "Your sign-in has expired. Sign in again to continue.")
            throw over
        }
        if let renewing { return try await renewing.value.service }
        let userId = profile?.userId
        let task = Task { try await Nvidia.renew(t, userId: userId) }
        renewing = task
        defer { if mine == epoch { renewing = nil } }
        do {
            let fresh = try await task.value
            guard mine == epoch else { throw CancellationError() }
            store(fresh)
            clientCheckedAt = Date()
            if let full = try? await Nvidia.withClientToken(fresh), mine == epoch {
                store(full)
                return full.service
            }
            return fresh.service
        } catch let e as APIError where (400...403).contains(e.code) {
            guard mine == epoch else { throw CancellationError() }
            // NVIDIA said no. If the token had not run out yet, keep using it for now.
            if !expired && !force { return t.service }
            signOut(note: "Your sign-in has expired. Sign in again to continue.")
            throw over
        } catch {
            // Offline, or NVIDIA is having trouble (a 5xx or 429): the saved tokens may still work.
            if error is CancellationError || expired || force { throw error }
            return t.service
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
        #if DEBUG
        if fixtureMode { return }
        #endif
        loginTask?.cancel()
        loginTask = Task {
            // A note that explains the code on screen (why the sign-in ended, or that the
            // last code was declined) stays up with the next code.
            var keepNote = signInNote != nil
            while !Task.isCancelled && !signedIn {
                do {
                    let provider = try await Nvidia.defaultProvider()
                    streamingBase = provider.streamingUrl
                    let c = try await Nvidia.startDeviceLogin(provider, deviceId: deviceId)
                    challenge = c
                    if !keepNote { signInNote = nil }
                    keepNote = false
                    var wait = c.interval
                    var blips = 0
                    waiting: while !Task.isCancelled && Date() < c.expiresAt {
                        try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                        let answer: Poll
                        do {
                            answer = try await Nvidia.pollDeviceLogin(c)
                            blips = 0
                        } catch {
                            // One dropped request must not replace the code: the person may
                            // be typing it right now. Keep asking for about a minute.
                            if Task.isCancelled || error is CancellationError { return }
                            blips += 1
                            if blips > 12 { throw error }
                            continue waiting
                        }
                        switch answer {
                        case .pending: continue
                        case .slowDown: wait += 5
                        case .expired: break waiting
                        case .denied:
                            signInNote = "The sign-in was declined. Here is a new code."
                            keepNote = true
                            break waiting
                        case .done(let t):
                            let full = (try? await Nvidia.withClientToken(t)) ?? t
                            // try? above swallows a cancellation. A sign-in that was cancelled
                            // or replaced meanwhile (signed out, or a new code asked for)
                            // must not save its account.
                            if Task.isCancelled { return }
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
                    if Task.isCancelled { return }
                    signInNote = "Couldn't reach NVIDIA. Trying again."
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
            }
        }
    }

    /// `note` says why, when it wasn't the person's own choice. It shows on the sign-in screen.
    func signOut(note: String? = nil) {
        loginTask?.cancel()
        epoch += 1
        renewing?.cancel()
        renewing = nil
        clientCheckedAt = .distantPast
        signInNote = note
        problem = nil
        vpcId = nil
        tokens = nil
        Keychain.save(nil)
        signedIn = false
        profile = nil
        membership = nil
        library = []
        shelves = []
        sessions = []
        challenge = nil
        loaded = false
    }

    // MARK: Loading

    func load() async {
        #if DEBUG
        if fixtureMode { return }
        #endif
        problem = nil
        let mine = epoch
        do {
            if let p = try? await Nvidia.defaultProvider(), mine == epoch { streamingBase = p.streamingUrl }
            do {
                try await loadAll(token: try await serviceToken(), epoch: mine)
                if mine == epoch { loaded = true }
            } catch let e as APIError where e.code == 401 || e.code == 403 {
                // A service turned the token down before its time. Renew it and try once more.
                guard mine == epoch, signedIn else { return }
                try await loadAll(token: try await serviceToken(force: true), epoch: mine)
                if mine == epoch { loaded = true }
            }
        } catch {
            if signedIn && mine == epoch && !(error is CancellationError) { problem = error.localizedDescription }
        }
    }

    private func loadAll(token: String, epoch mine: Int) async throws {
        let info = try await Nvidia.serverInfo(streamingBase: streamingBase, token: token)
        guard mine == epoch else { return }
        vpcId = info.vpcId
        regions = info.regions
        async let lib = Nvidia.library(token: token, vpcId: info.vpcId)
        async let rails = Nvidia.shelves(token: token, vpcId: info.vpcId)
        let games = try await lib
        let railsNow = (try? await rails) ?? []
        guard mine == epoch else { return }
        library = games
        shelves = railsNow
        if let id = profile?.userId {
            let m = try? await Nvidia.membership(token: token, userId: id, vpcId: info.vpcId)
            guard mine == epoch else { return }
            membership = m
        }
        await refreshSessions()
    }

    func refreshSessions() async {
        let mine = epoch
        guard let token = try? await serviceToken() else { return }
        if let list = try? await Nvidia.activeSessions(streamingBase: streamingBase, token: token, deviceId: deviceId), mine == epoch {
            sessions = list
        }
    }

    /// Games that match, or nil when the search itself failed or was overtaken by a newer one.
    func search(_ text: String) async -> [Game]? {
        #if DEBUG
        if fixtureMode {
            if fixtureSearchFails { return nil }
            return library.filter { $0.title.localizedCaseInsensitiveContains(text) }
        }
        #endif
        guard let vpcId, let token = try? await serviceToken() else { return nil }
        return try? await Nvidia.search(token: token, vpcId: vpcId, text: text)
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

#if DEBUG
/// Seeds the real model for the fixture harness, so the real screens can be photographed
/// on the Simulator without an account or a network.
extension AppModel {
    struct FixtureState {
        var signedIn = true
        var loading = false
        var loaded = true
        var profile: Profile?
        var membership: Membership?
        var library: [Game] = []
        var shelves: [Shelf] = []
        var sessions: [ActiveSession] = []
        var regions: [Region] = []
        var problem: String?
        var challenge: DeviceChallenge?
        var signInNote: String?
        var searchFails = false
    }

    func applyFixture(_ s: FixtureState) {
        fixtureMode = true
        fixtureSearchFails = s.searchFails
        signedIn = s.signedIn
        loading = s.loading
        loaded = s.loaded
        profile = s.profile
        membership = s.membership
        library = s.library
        shelves = s.shelves
        sessions = s.sessions
        regions = s.regions
        problem = s.problem
        challenge = s.challenge
        signInNote = s.signInNote
    }
}
#endif
