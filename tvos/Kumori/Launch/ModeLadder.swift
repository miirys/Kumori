import Foundation

/// A stream size and rate to ask the session service for.
struct ModeRequest: Equatable, CustomStringConvertible {
    var width: Int
    var height: Int
    var fps: Int

    var description: String { "\(width)x\(height)@\(fps)" }
}

/// Why the session service turned a request down, and what to do next.
enum Refusal: Equatable {
    /// About the account or sign-in. Asking again another way won't help.
    case account
    /// The size or rate was turned down. A smaller or slower stream may be accepted.
    case mode
    /// A server-side failure. Another server, or a smaller stream, often works.
    case server
    /// Anything else. Stop and show it.
    case other

    private static let accountCodes: Set<Int> = [7, 11, 50, 10, 13, 14, 15, 16, 17, 37, 38, 23, 24, 56, 26, 27, 28, 29, 30, 31, 32, 33, 45, 52, 53, 63, 35]

    static func classify(statusCode: Int, http: Int, detail: String?) -> Refusal {
        if accountCodes.contains(statusCode) || http == 401 || http == 403 { return .account }
        if [3, 4, 5, 8].contains(statusCode) || http >= 500 || (detail?.localizedCaseInsensitiveContains("INTERNAL") ?? false) { return .server }
        if [2, 18, 68].contains(statusCode) { return .mode }
        return .other
    }

    /// Worth asking again with a smaller or slower stream.
    var stepsDown: Bool { self == .mode || self == .server }
}

/// Errors the ladder can read.
protocol ClassifiedRefusal: Error {
    var refusal: Refusal { get }
}

/// The order in which modes are tried when the server turns one down.
///
/// Each size is tried at the chosen rate, then at 60 fps, before going smaller: the service
/// refuses a rate with the same codes it uses for a size, so keeping 120 fps all the way
/// down would fail every rung. 60 fps at 1080p is always on the ladder, since it is the
/// mode every membership and every route accepts.
enum ModeLadder {
    static let sizes: [(Int, Int)] = [(3840, 2160), (2560, 1440), (1920, 1080), (1280, 720)]
    static let safeFps = 60

    static func candidates(for ask: ModeRequest) -> [ModeRequest] {
        var out: [ModeRequest] = []
        func add(_ m: ModeRequest) { if !out.contains(m) { out.append(m) } }
        let rates = ask.fps > safeFps ? [ask.fps, safeFps] : [ask.fps]
        for fps in rates { add(ModeRequest(width: ask.width, height: ask.height, fps: fps)) }
        for (w, h) in sizes where h < ask.height {
            for fps in rates { add(ModeRequest(width: w, height: h, fps: fps)) }
        }
        return out
    }

    /// Tries each candidate at each place until one is accepted.
    /// - `attempt(mode, placeIndex)` asks the service; it throws a `ClassifiedRefusal` on refusal.
    /// - `onRung(mode, index)` is told before each new rung after the first.
    /// Returns what the service gave and the mode it actually accepted.
    @MainActor
    static func run<T>(
        _ ladder: [ModeRequest],
        places: Int,
        attempt: (ModeRequest, Int) async throws -> T,
        onRefused: (ModeRequest, Error) -> Void = { _, _ in },
        onRung: (ModeRequest, Int) -> Void = { _, _ in }
    ) async throws -> (T, ModeRequest, Int) {
        var last: Error?
        for (i, mode) in ladder.enumerated() {
            if i > 0 { onRung(mode, i) }
            for place in 0..<max(places, 1) {
                try Task.checkCancellation()
                do {
                    return (try await attempt(mode, place), mode, i)
                } catch let e as ClassifiedRefusal {
                    onRefused(mode, e)
                    if !e.refusal.stepsDown { throw e }
                    last = e
                    // A size or rate refusal is the same at every server. Only a server
                    // failure is worth asking somewhere else.
                    if e.refusal != .server { break }
                }
            }
        }
        throw last ?? CancellationError()
    }
}
