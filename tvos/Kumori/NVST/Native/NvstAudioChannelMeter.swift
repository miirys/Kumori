import Foundation

/// The level of each decoded audio channel, and its level above 200 Hz, over the time since the
/// last reading. It tells the channels of a surround stream apart without surround speakers: an
/// LFE channel reads far lower above 200 Hz than overall, a full-range channel reads the same.
public struct NvstAudioChannelMeter: Sendable {
    public struct Reading: Equatable, Sendable {
        /// RMS in dBFS, floored at -120.
        public let level: Double
        public let levelAbove200Hz: Double
    }

    /// One-pole high-pass at 200 Hz for 48 kHz audio: 1 / (1 + 2π · 200 / 48000).
    static let highPassCoefficient: Float = 0.97449

    private var sums: [Double] = []
    private var highSums: [Double] = []
    private var lastInput: [Float] = []
    private var lastHigh: [Float] = []
    private var frames = 0

    public init() {}

    /// Adds interleaved samples, `channels` per frame.
    public mutating func add(_ samples: [Float], channels: Int) {
        guard channels > 0 else { return }
        if sums.count != channels {
            sums = [Double](repeating: 0, count: channels)
            highSums = sums
            lastInput = [Float](repeating: 0, count: channels)
            lastHigh = lastInput
            frames = 0
        }
        let frameCount = samples.count / channels
        for frame in 0..<frameCount {
            for channel in 0..<channels {
                let input = samples[frame * channels + channel]
                let high = Self.highPassCoefficient * (lastHigh[channel] + input - lastInput[channel])
                lastInput[channel] = input
                lastHigh[channel] = high
                sums[channel] += Double(input * input)
                highSums[channel] += Double(high * high)
            }
        }
        frames += frameCount
    }

    /// One reading per channel for everything added since the last call; empty when nothing was.
    public mutating func take() -> [Reading] {
        guard frames > 0 else { return [] }
        let count = Double(frames)
        func decibels(_ sum: Double) -> Double { max(-120, 10 * log10(sum / count + 1e-12)) }
        let readings = sums.indices.map { Reading(level: decibels(sums[$0]), levelAbove200Hz: decibels(highSums[$0])) }
        sums = [Double](repeating: 0, count: sums.count)
        highSums = sums
        frames = 0
        return readings
    }

    /// "level/level above 200 Hz" per channel, in decoded order.
    public static func summary(_ readings: [Reading]) -> String {
        readings.map { String(format: "%.0f/%.0f", $0.level, $0.levelAbove200Hz) }.joined(separator: " ")
    }
}
