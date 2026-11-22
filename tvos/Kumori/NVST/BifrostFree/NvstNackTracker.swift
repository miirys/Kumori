import Foundation

/// What retransmission requests achieved, in the terms of the seat's `0x20a` stats report.
public struct NvstNackCounters: Equatable, Sendable {
    /// Requests sent; one request can name many packets.
    public var requestsSent: UInt64 = 0
    /// Packets named across all requests, retries included.
    public var packetsRequested: UInt64 = 0
    /// Requested packets that then arrived in time to fill their gap.
    public var packetsReceived: UInt64 = 0
    /// Packets named again because the first answer did not arrive.
    public var packetsRetried: UInt64 = 0
}

/// Which missing video packets to ask the seat for, when to ask again, and how long an answer is
/// still worth waiting for. Owned by `NvstVideoReceiver` and used under its lock.
///
/// The official client runs the same loop in `NackTracker::GetNackBatch`: a first request once
/// its initial delay has passed, another each time the round trip plus a back-off has gone by
/// without the packet, and no more after `video.rtpNackMaxRetries` — the 3 this client announces.
/// The two delays are configuration bytes whose values were not recovered, so the ones here are
/// this client's own.
struct NvstNackTracker {
    /// Requests per packet before it is given up.
    static let maximumRequests = 3
    /// Added to the round trip before a request counts as unanswered: the seat's own handling
    /// time and ordinary arrival jitter.
    static let retryMarginNanoseconds: UInt64 = 5_000_000
    /// The longest any packet is waited for, whatever the round trip. Frames behind the gap are
    /// held for this long, so it bounds the freeze a slow or silent seat can cause.
    static let maximumWaitNanoseconds: UInt64 = 80_000_000
    /// More missing packets than this is an outage, which a keyframe repairs sooner.
    static let maximumPending = 128
    /// Used until the first measured round trip; the official tracker starts at 30 ms as well.
    static let defaultRoundTripNanoseconds: UInt64 = 30_000_000

    private struct Entry {
        let detectedAt: UInt64
        var lastRequestAt: UInt64 = 0
        var requests = 0
    }

    var roundTripNanoseconds = NvstNackTracker.defaultRoundTripNanoseconds
    private(set) var counters = NvstNackCounters()
    private var pending: [UInt64: Entry] = [:]

    var isEmpty: Bool { pending.isEmpty }

    private var retryInterval: UInt64 { roundTripNanoseconds + Self.retryMarginNanoseconds }

    /// Registers packets that were skipped over by a later arrival.
    mutating func noteMissing(_ indices: ClosedRange<UInt64>, now: UInt64) {
        guard indices.count <= Self.maximumPending - pending.count else { return }
        for index in indices { pending[index] = Entry(detectedAt: now) }
    }

    /// A missing packet turned up. `wasResent` is false for one rebuilt locally from FEC, which
    /// the seat never sent again.
    mutating func noteArrived(_ index: UInt64, wasResent: Bool) {
        guard let entry = pending.removeValue(forKey: index) else { return }
        if wasResent, entry.requests > 0 { counters.packetsReceived += 1 }
    }

    /// Stops waiting for everything up to and including `index`: the gap was given up.
    mutating func abandon(through index: UInt64) {
        pending = pending.filter { $0.key > index }
    }

    /// The packets to ask for now, in order, marking them as asked.
    mutating func takeDue(now: UInt64) -> [UInt64] {
        var due: [UInt64] = []
        for (index, entry) in pending {
            let isFirst = entry.requests == 0
            guard isFirst || (entry.requests < Self.maximumRequests && now >= entry.lastRequestAt + retryInterval) else { continue }
            pending[index]?.lastRequestAt = now
            pending[index]?.requests += 1
            if !isFirst { counters.packetsRetried += 1 }
            due.append(index)
        }
        guard !due.isEmpty else { return [] }
        counters.requestsSent += 1
        counters.packetsRequested += UInt64(due.count)
        return due.sorted()
    }

    /// Whether an answer for `index` can still arrive: it has requests left, or its last one is
    /// not overdue yet.
    func isAwaiting(_ index: UInt64, now: UInt64) -> Bool {
        guard let entry = pending[index], now < entry.detectedAt + Self.maximumWaitNanoseconds else { return false }
        return entry.requests < Self.maximumRequests || now < entry.lastRequestAt + retryInterval
    }
}
