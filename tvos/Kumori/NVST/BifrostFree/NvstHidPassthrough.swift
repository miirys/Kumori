import Foundation

/// The raw-HID leg of NVST remote input: a client-side controller (DualShock 4 / DualSense class)
/// forwarded as its own HID reports rather than as an XInput pad, and the seat's output reports
/// (rumble, light bar, adaptive triggers) coming back the same way.
///
/// Wire formats recovered from the official client (arm64 `libBifrost2` `RiClientBackend::
/// GetHidChangePacketId`, `sendHidEvent`, `ServerControl::handleServerCommand` case `0x206`/`0x11`;
/// `libGeronimo` `HIDDevicesController::handleHidChangeEvent`, `GeronimoIOInterface::
/// handleDynamicHidChangeEvent`, `RIDeviceMediator::handleHidChangedEvent`). This file is the
/// codec plus the two devices built on it: the one the official client synthesizes from plain
/// gamepad state, a DualShock 4 (`SynthesizedDualShock4` below, from `GamepadHIDSynthesizer` and
/// `GeronimoIOInterface::sendSynthesizedHidDevices`), and a DualSense sent down the route that
/// client uses for a device it opens itself (`DualSense` below, from `HIDDevicesController` and
/// `HIDDevice`), which the seat answers with `GENERIC_DEVICE_RESPONSE_EVENT` (`0x206`/`0x1a`).
public enum NvstHidPassthrough {
    /// `NvstHidControl_t`, the second byte of a change event. Geronimo removes the device on 3 and
    /// treats 1 as added; the mediator's other value is logged as unknown.
    public enum Change: UInt8, Equatable, Sendable {
        case added = 1
        case removed = 3
    }

    /// Client → seat: a HID device appeared or went away. RI packet type `0x12`, 14-byte body:
    /// `[u8 deviceId][u8 change][u32 BE flags][u16 BE vendorId][u16 BE productId][u16 BE field3][u16 BE field4]`.
    /// The two trailing words come straight from Geronimo's `NvstDeviceDataSimple_t` (four u16s:
    /// vendor, product, then two the disassembly does not name — version number and usage are the
    /// likeliest). `flags` bit 1 makes the official mediator ignore the event.
    public struct ChangeEvent: Equatable, Sendable {
        public let deviceId: UInt8
        public let change: Change
        public let flags: UInt32
        public let vendorId: UInt16
        public let productId: UInt16
        public let field3: UInt16
        public let field4: UInt16

        public init(deviceId: UInt8, change: Change, flags: UInt32 = 0, vendorId: UInt16, productId: UInt16, field3: UInt16 = 0, field4: UInt16 = 0) {
            self.deviceId = deviceId
            self.change = change
            self.flags = flags
            self.vendorId = vendorId
            self.productId = productId
            self.field3 = field3
            self.field4 = field4
        }

        /// The RI packet, ready for the `0x206` envelope (`NvstRemoteInput.framed`).
        public var packet: Data {
            var writer = NvstByteWriter(capacity: 14)
            writer.u8(deviceId)
            writer.u8(change.rawValue)
            writer.u32BE(flags)
            writer.u16BE(vendorId)
            writer.u16BE(productId)
            writer.u16BE(field3)
            writer.u16BE(field4)
            return NvstRemoteInput.packet(type: .hidChange, body: writer.data)
        }

        /// The packet without its length word, `[u32 LE 0x12][body]`: the form an input event has
        /// before the transport frames it.
        public var event: Data { Data(packet.dropFirst(4)) }

        /// Reads `event` back.
        public init?(event: Data) {
            var reader = NvstByteReader(event)
            guard event.count == 18, let type = try? reader.u32LE(), type == NvstRemoteInput.PacketType.hidChange.rawValue,
                  let deviceId = try? reader.u8(), let change = (try? reader.u8()).flatMap(Change.init(rawValue:)),
                  let flags = try? reader.u32BE(), let vendorId = try? reader.u16BE(), let productId = try? reader.u16BE(),
                  let field3 = try? reader.u16BE(), let field4 = try? reader.u16BE() else { return nil }
            self.init(deviceId: deviceId, change: change, flags: flags, vendorId: vendorId, productId: productId,
                      field3: field3, field4: field4)
        }
    }

    /// Client → seat: one HID input report. Rides command `0x20d` like the gamepad state: after the
    /// `[0x23][u64 BE µs]` prefix comes either the partially-reliable wrapper
    /// `[0x26][deviceId + 4][u16 BE sequence]` and a `0x21` length-prefixed event, or a bare `0x22`
    /// and the event. The event is `[u32 LE 0x11][u8 deviceId][u8 kind][u8 reportType][report]`.
    /// `sendHidEvent` keeps one sequence counter per device (ten slots) and uses the wrapper only
    /// for devices whose bit is set in `ri.enablePartiallyReliableTransferHid`.
    public struct Report: Equatable, Sendable {
        public static let eventType: UInt32 = 0x11
        public let deviceId: UInt8
        /// The second event byte. `serializeHidEventPayload` writes the device's USB interface
        /// number here for an input report and the error flag (1 for a failed read) for the
        /// answer to a get-report request; a synthesized pad writes its own constant.
        public let kind: UInt8
        /// `NvstHidReportType_t`. Client to seat: 0 an input report, 2 or 3 the answer to a
        /// get-report request. Seat to client, as `HIDDevice::processHidOutputPayload` switches on
        /// it: 0 and 1 an output report to write, 2 get input report, 3 get feature report, 4 a
        /// feature report to write.
        public let reportType: UInt8
        public let data: Data

        public init(deviceId: UInt8, kind: UInt8 = 0, reportType: UInt8 = 1, data: Data) {
            self.deviceId = deviceId
            self.kind = kind
            self.reportType = reportType
            self.data = data
        }

        /// The event without its wrapper: `[u32 LE 0x11][u8 deviceId][u8 kind][u8 reportType][report]`.
        public var event: Data {
            var writer = NvstByteWriter(capacity: 7 + data.count)
            writer.u32LE(Self.eventType)
            writer.u8(deviceId)
            writer.u8(kind)
            writer.u8(reportType)
            writer.bytes(data)
            return writer.data
        }

        /// Reads `event` back.
        public init?(event: Data) {
            var reader = NvstByteReader(event)
            guard event.count >= 7, let type = try? reader.u32LE(), type == Self.eventType,
                  let deviceId = try? reader.u8(), let kind = try? reader.u8(), let reportType = try? reader.u8() else { return nil }
            self.init(deviceId: deviceId, kind: kind, reportType: reportType, data: Data(reader.unread))
        }

        /// The wrapper's index byte is the device id plus four: `handlePrSequenceNumber<10>` is
        /// called with that offset because the four gamepads own indices 0...3.
        public static let partiallyReliableIndexOffset: UInt8 = 4

        /// The `0x20d` payload for the session clock. With a `sequence` it is the partially-reliable
        /// form for the input channel; without one it is the reliable form for the control channel.
        public func payload(sequence: UInt16?, timestampMicroseconds: UInt64) -> Data {
            let event = self.event
            var writer = NvstByteWriter(capacity: 1 + 8 + 4 + 3 + event.count)
            writer.u8(GeronimoInputEnvelope.headerByte)
            writer.u64BE(timestampMicroseconds)
            guard let sequence else {
                writer.u8(GeronimoInputEnvelope.singleReliablePayloadTag)
                writer.bytes(event)
                return writer.data
            }
            writer.u8(GeronimoInputEnvelope.partiallyReliablePayloadTag)
            writer.u8(deviceId &+ Self.partiallyReliableIndexOffset)
            writer.u16BE(sequence)
            writer.u8(GeronimoInputEnvelope.lengthPrefixedPayloadTag)
            writer.u16BE(UInt16(clamping: event.count))
            writer.bytes(event)
            return writer.data
        }

        public func command(sequence: UInt16?, timestampMicroseconds: UInt64) -> NvstControlCommand {
            NvstControlCommand(code: .gamepadEvent, payload: payload(sequence: sequence, timestampMicroseconds: timestampMicroseconds))
        }
    }

    /// Seat → client: an output report for one HID device (rumble, light bar, adaptive triggers),
    /// command `0x206` whose payload is `[u32 LE 0x11][u8 deviceId][u8 kind][u8 reportType][report]`.
    /// The official dispatcher rejects a payload under 7 bytes ("Corrupted STREAMER_RI_COMMAND
    /// PACKET_HID received") and otherwise raises `NvstClientEvent_t` type 21, which Geronimo
    /// writes to the device with `IOHIDDeviceSetReport`.
    public static func parseOutputReport(_ command: NvstControlCommand) -> Report? {
        guard command.code == .remoteInput else { return nil }
        return Report(event: command.payload)
    }

    /// Seat → client: the answer to the change event that announced a device the client opened
    /// itself, `0x206` with `[u32 LE 0x1a][u8 requestId][u8 status][u32 BE flags][u8 deviceId]`
    /// (`ServerControl::handleServerCommand` logs the first and last byte as "requestId: %u,
    /// deviceId: %u"). The request id is the device id the change event carried; the device id is
    /// the one the seat wants on that device's reports from then on.
    public struct ChangeResponse: Equatable, Sendable {
        public static let eventType: UInt32 = 0x1a
        public let requestId: UInt8
        public let status: UInt8
        public let flags: UInt32
        public let deviceId: UInt8

        /// `GeronimoIOInterface::handleHidChangeResponseEvent` takes status 1 as allowed, and
        /// `HIDDevice::start` treats device id `0xff` as a refusal and 0 as no id at all.
        public var isAccepted: Bool { status == 1 && deviceId != 0xff && deviceId != 0 }

        public static func parse(_ command: NvstControlCommand) -> ChangeResponse? {
            guard command.code == .remoteInput, command.payload.count >= 11 else { return nil }
            var reader = NvstByteReader(command.payload)
            guard let type = try? reader.u32LE(), type == eventType,
                  let requestId = try? reader.u8(), let status = try? reader.u8(),
                  let flags = try? reader.u32BE(), let deviceId = try? reader.u8() else { return nil }
            return ChangeResponse(requestId: requestId, status: status, flags: flags, deviceId: deviceId)
        }
    }

    /// Which seat device id each announced device was given. The app addresses a device by the
    /// request id it announced it with; the wire carries the seat's id once the seat has answered.
    public struct DeviceTable: Sendable {
        private var seatIds: [UInt8: UInt8?] = [:]
        public init() {}

        /// A device was announced under `requestId` and waits for the seat's answer.
        public mutating func request(_ requestId: UInt8) { seatIds[requestId] = .some(nil) }

        /// Records the seat's answer. True if the device was accepted, false if it was refused,
        /// nil if no announced device was waiting under that request id.
        public mutating func resolve(_ response: ChangeResponse) -> Bool? {
            guard let pending = seatIds[response.requestId], pending == nil else { return nil }
            seatIds[response.requestId] = response.isAccepted ? .some(response.deviceId) : nil
            return response.isAccepted
        }

        /// Whether a device is announced under `requestId`, answered or not.
        public func isAnnounced(_ requestId: UInt8) -> Bool { seatIds[requestId] != nil }

        public func seatId(forRequest requestId: UInt8) -> UInt8? { seatIds[requestId] ?? nil }

        public func requestId(forSeat deviceId: UInt8) -> UInt8? { seatIds.first { $0.value == deviceId }?.key }

        /// Forgets the device; returns the seat id it had, if the seat had accepted it.
        public mutating func remove(request requestId: UInt8) -> UInt8? { seatIds.removeValue(forKey: requestId) ?? nil }
    }

    /// `ri.hidDeviceMask` from the seat's DESCRIBE, as `GeronimoIOInterface::
    /// applyServerHidCapabilities` reads it ("Configuring server supported Hid devices: Supports
    /// DS4: %s, DS5: %s (raw:%x)"): DS4 is `raw & 4`, DS5 is `raw & 2`. The official capture
    /// announces 4 back, a seat that takes a DualShock 4 only.
    public struct SeatCapability: Equatable, Sendable {
        public let raw: UInt32
        /// `ri.enablePartiallyReliableTransferHid`: bit `deviceId` set means that device's reports
        /// use the partially-reliable wrapper. `sendHidEvent` keeps ten sequence slots, so an id
        /// of 10 or more (every device the seat names itself) is always sent reliably.
        public let partiallyReliableDevices: UInt32
        public init(raw: UInt32, partiallyReliableDevices: UInt32 = 0) {
            self.raw = raw
            self.partiallyReliableDevices = partiallyReliableDevices
        }
        public var supportsDualShock4: Bool { raw & 0x4 != 0 }
        public var supportsDualSense: Bool { raw & 0x2 != 0 }
        public func usesPartiallyReliableTransfer(deviceId: UInt8) -> Bool {
            deviceId < 10 && partiallyReliableDevices & (1 << UInt32(deviceId)) != 0
        }
        public var summary: String {
            "hidDeviceMask=0x\(String(raw, radix: 16)) ds4=\(supportsDualShock4) ds5=\(supportsDualSense) partiallyReliable=0x\(String(partiallyReliableDevices, radix: 16))"
        }
    }

    /// The DualShock 4 the official client presents for a pad it only knows as gamepad state
    /// (`GamepadHIDSynthesizer::buildSynthesizedDS4State`). It does this for a DualSense too
    /// (`RIDeviceMediator::shouldSynthesizeSonyController` sends pids `0x0ce6`/`0x0df2` down the
    /// same route when the seat supports DS4): there is no synthesized DualSense in that client.
    ///
    /// A synthesized pad is announced with a change event that carries no vendor or product, only
    /// its device id and `flags` 1, and it must not also be in the gamepad connected bitmap
    /// (`RIDeviceMediator::buildGamepadBitmap` counts standard pads only). No response is awaited.
    public enum SynthesizedDualShock4 {
        /// Synthesized pads take device ids 6...9, one per gamepad slot.
        public static let firstDeviceId: UInt8 = 6
        /// The second event byte of a synthesized report; its report-type byte is 0.
        public static let reportKind: UInt8 = 4
        public static let reportLength = 64

        public static func deviceId(gamepadIndex: Int) -> UInt8 { firstDeviceId + UInt8(gamepadIndex & 0x03) }

        public static func gamepadIndex(deviceId: UInt8) -> Int? {
            (firstDeviceId ..< firstDeviceId + 4).contains(deviceId) ? Int(deviceId - firstDeviceId) : nil
        }

        public static func changeEvent(gamepadIndex: Int, connected: Bool) -> ChangeEvent {
            ChangeEvent(deviceId: deviceId(gamepadIndex: gamepadIndex), change: connected ? .added : .removed,
                        flags: 1, vendorId: 0, productId: 0)
        }

        /// The pad as the gamepad path already describes it: `NvstGamepadPacket.Button` bits,
        /// byte triggers and XInput axes (up and right positive), plus the one control XInput lacks.
        public struct State: Equatable, Sendable {
            public var buttons: UInt16
            public var leftTrigger: UInt8
            public var rightTrigger: UInt8
            public var leftStickX: Int16
            public var leftStickY: Int16
            public var rightStickX: Int16
            public var rightStickY: Int16
            public var touchpadPressed: Bool
            public var motion: Motion

            public init(buttons: UInt16, leftTrigger: UInt8, rightTrigger: UInt8, leftStickX: Int16, leftStickY: Int16,
                        rightStickX: Int16, rightStickY: Int16, touchpadPressed: Bool = false, motion: Motion = .zero) {
                self.buttons = buttons
                self.leftTrigger = leftTrigger
                self.rightTrigger = rightTrigger
                self.leftStickX = leftStickX
                self.leftStickY = leftStickY
                self.rightStickX = rightStickX
                self.rightStickY = rightStickY
                self.touchpadPressed = touchpadPressed
                self.motion = motion
            }
        }

        /// Gyroscope and accelerometer readings in the raw units of both Sony pads, which the
        /// neutral calibration (`DualSense.featureReport(0x05)`) describes: about 16.4 per degree
        /// a second, and 8192 per g. Axes: X to the right, Y up, Z towards the player; the gyro
        /// turns about the same axes (pitch, yaw, roll). Zero means "no sensor", as a pad without
        /// motion data reports.
        public struct Motion: Equatable, Sendable {
            public var gyroX: Int16, gyroY: Int16, gyroZ: Int16
            public var accelX: Int16, accelY: Int16, accelZ: Int16

            public static let zero = Motion(gyroX: 0, gyroY: 0, gyroZ: 0, accelX: 0, accelY: 0, accelZ: 0)
            public static let gyroUnitsPerDegreePerSecond = 8856.0 / 540.0
            public static let accelUnitsPerG = 8192.0

            public init(gyroX: Int16, gyroY: Int16, gyroZ: Int16, accelX: Int16, accelY: Int16, accelZ: Int16) {
                (self.gyroX, self.gyroY, self.gyroZ) = (gyroX, gyroY, gyroZ)
                (self.accelX, self.accelY, self.accelZ) = (accelX, accelY, accelZ)
            }

            /// From degrees a second and g, clamped to the sensor range.
            public init(degreesPerSecond gyro: (Double, Double, Double), g accel: (Double, Double, Double)) {
                func raw(_ value: Double, _ scale: Double) -> Int16 {
                    Int16(min(max((value * scale).rounded(), Double(Int16.min)), Double(Int16.max)))
                }
                self.init(gyroX: raw(gyro.0, Self.gyroUnitsPerDegreePerSecond), gyroY: raw(gyro.1, Self.gyroUnitsPerDegreePerSecond),
                          gyroZ: raw(gyro.2, Self.gyroUnitsPerDegreePerSecond),
                          accelX: raw(accel.0, Self.accelUnitsPerG), accelY: raw(accel.1, Self.accelUnitsPerG),
                          accelZ: raw(accel.2, Self.accelUnitsPerG))
            }

            /// Gyro X, Y, Z then accelerometer X, Y, Z, each little-endian: the twelve bytes both
            /// pads carry, at 13 in a DualShock 4 report and at 16 in a DualSense one.
            static func bytes(_ motion: Motion) -> [UInt8] {
                [motion.gyroX, motion.gyroY, motion.gyroZ, motion.accelX, motion.accelY, motion.accelZ]
                    .flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
            }
        }

        /// The hat nibble for the four D-pad bits (bit 0 up, 1 down, 2 left, 3 right): 0 is north,
        /// clockwise to 7, and 8 is released. Opposing directions cancel.
        static func hat(dPad: UInt16) -> UInt8 {
            let vertical = (dPad & 0x1 != 0 ? 1 : 0) - (dPad & 0x2 != 0 ? 1 : 0)
            let horizontal = (dPad & 0x8 != 0 ? 1 : 0) - (dPad & 0x4 != 0 ? 1 : 0)
            switch (horizontal, vertical) {
            case (0, 1): return 0
            case (1, 1): return 1
            case (1, 0): return 2
            case (1, -1): return 3
            case (0, -1): return 4
            case (-1, -1): return 5
            case (-1, 0): return 6
            case (-1, 1): return 7
            default: return 8
            }
        }

        /// The four stick bytes both Sony pads report, left X and Y then right X and Y: unsigned,
        /// with up at 0.
        static func stickBytes(_ state: State) -> [UInt8] {
            func axis(_ value: Int) -> UInt8 { UInt8((min(max(value, -32768), 32767) + 32768) >> 8) }
            return [axis(Int(state.leftStickX)), axis(-Int(state.leftStickY)), axis(Int(state.rightStickX)), axis(-Int(state.rightStickY))]
        }

        /// The three button bytes both Sony pads report: the hat with the face buttons, the
        /// shoulder, trigger, menu and stick buttons, then PS and the touchpad click.
        static func buttonBytes(_ state: State) -> [UInt8] {
            typealias Button = NvstGamepadPacket.Button
            func pressed(_ mask: UInt16) -> Bool { state.buttons & mask != 0 }
            return [
                hat(dPad: state.buttons & 0x000f)
                    | (pressed(Button.x) ? 0x10 : 0) | (pressed(Button.a) ? 0x20 : 0)
                    | (pressed(Button.b) ? 0x40 : 0) | (pressed(Button.y) ? 0x80 : 0),
                (pressed(Button.leftShoulder) ? 0x01 : 0) | (pressed(Button.rightShoulder) ? 0x02 : 0)
                    | (state.leftTrigger != 0 ? 0x04 : 0) | (state.rightTrigger != 0 ? 0x08 : 0)
                    | (pressed(Button.back) ? 0x10 : 0) | (pressed(Button.start) ? 0x20 : 0)
                    | (pressed(Button.leftThumb) ? 0x40 : 0) | (pressed(Button.rightThumb) ? 0x80 : 0),
                (pressed(Button.guide) ? 0x01 : 0) | (state.touchpadPressed ? 0x02 : 0)
            ]
        }

        /// The 64-byte USB input report `0x01`, laid out as the official synthesizer fills it:
        /// sticks, buttons, triggers, the 5.33 µs timestamp, motion, "cable connected, battery
        /// full" and one touch packet with both fingers up. The official synthesizer leaves motion
        /// at zero; it is filled here only when the player turned motion controls on.
        public static func report(_ state: State, gamepadIndex: Int, timestampMicroseconds: UInt64) -> Report {
            var data = [UInt8](repeating: 0, count: reportLength)
            data[0] = 0x01
            data[1...4] = stickBytes(state)[...]
            data[5...7] = buttonBytes(state)[...]
            data[8] = state.leftTrigger
            data[9] = state.rightTrigger
            let ticks = UInt16(truncatingIfNeeded: (timestampMicroseconds &* 3) >> 4)
            data[10] = UInt8(truncatingIfNeeded: ticks)
            data[11] = UInt8(truncatingIfNeeded: ticks >> 8)
            data[13...24] = Motion.bytes(state.motion)[...]
            data[30] = 0x1b
            data[33] = 1
            data[35] = 0x80
            data[39] = 0x80
            return Report(deviceId: deviceId(gamepadIndex: gamepadIndex), kind: reportKind, reportType: 0, data: Data(data))
        }

        /// The rumble in a seat output report for a synthesized pad, as `parseGamepadHidOutput`
        /// reads it: report `0x05` with the rumble flag, byte 4 the weak motor and byte 5 the strong
        /// one, scaled to the haptic event's 16-bit range. Nil for any other device or report.
        public static func rumble(in report: Report) -> NvstHapticEvent? {
            let data = [UInt8](report.data)
            guard let index = gamepadIndex(deviceId: report.deviceId), data.count >= 6, data[0] == 0x05, data[1] & 0x01 != 0 else { return nil }
            return NvstHapticEvent(gamepadIndex: UInt16(index), leftMotor: UInt16(data[5]) << 8, rightMotor: UInt16(data[4]) << 8)
        }
    }

    /// A DualSense announced as the DualSense it is, so the game on the seat can drive its
    /// adaptive triggers. The official client only does this for a pad it holds open through
    /// hidapi, forwarding the pad's own reports; Game Controller gives no such access, so the
    /// reports here are built from gamepad state in the same USB layout, and the seat's output
    /// reports are read back into the effects Game Controller can play.
    ///
    /// The device is announced under a request id with its USB vendor, product and release number
    /// (`HIDDevicesController::devicesConnected`), and stays silent until the seat's
    /// `ChangeResponse` names the device id for its reports (`HIDDevice::start`).
    public enum DualSense {
        public typealias State = SynthesizedDualShock4.State

        public static let vendorId: UInt16 = 0x054c
        public static let productId: UInt16 = 0x0ce6
        /// The USB release number hidapi reports for the pad.
        public static let releaseNumber: UInt16 = 0x0100
        /// `HIDDevicesController::handleHidChangeEvent` sends every device it opened with these flags.
        public static let changeFlags: UInt32 = 0xf
        /// Request ids start at 10: lower device ids belong to the gamepads and synthesized pads
        /// (`GeronimoIOInterface::handleHidOutputEvent` routes on that boundary).
        public static let firstRequestId: UInt8 = 10
        /// The pad's HID interface on USB, sent as the second byte of each input report.
        public static let interfaceNumber: UInt8 = 3
        public static let reportLength = 64

        public static func requestId(gamepadIndex: Int) -> UInt8 { firstRequestId + UInt8(gamepadIndex & 0x03) }

        public static func gamepadIndex(requestId: UInt8) -> Int? {
            (firstRequestId ..< firstRequestId + 4).contains(requestId) ? Int(requestId - firstRequestId) : nil
        }

        public static func changeEvent(gamepadIndex: Int) -> ChangeEvent {
            ChangeEvent(deviceId: requestId(gamepadIndex: gamepadIndex), change: .added, flags: changeFlags,
                        vendorId: vendorId, productId: productId, field3: releaseNumber)
        }

        /// A removal names the device by the id the seat gave it and carries no identity.
        public static func removalEvent(deviceId: UInt8) -> ChangeEvent {
            ChangeEvent(deviceId: deviceId, change: .removed, flags: changeFlags, vendorId: 0, productId: 0)
        }

        /// The 64-byte USB input report `0x01`: sticks, triggers, the sequence number
        /// `TransformPacketDS5::transformInput` uses to drop repeats, buttons, the sensor timestamp
        /// it stamps (a third of a microsecond per tick), motion, both touch points up and
        /// "charged, on a cable". The report is addressed to the request id; the
        /// transport swaps in the seat's device id.
        public static func report(_ state: State, gamepadIndex: Int, sequence: UInt8, timestampMicroseconds: UInt64) -> Report {
            var data = [UInt8](repeating: 0, count: reportLength)
            data[0] = 0x01
            data[1...4] = SynthesizedDualShock4.stickBytes(state)[...]
            data[5] = state.leftTrigger
            data[6] = state.rightTrigger
            data[7] = sequence
            data[8...10] = SynthesizedDualShock4.buttonBytes(state)[...]
            data[16...27] = SynthesizedDualShock4.Motion.bytes(state.motion)[...]
            let ticks = UInt32(truncatingIfNeeded: timestampMicroseconds &* 3)
            for byte in 0..<4 { data[28 + byte] = UInt8(truncatingIfNeeded: ticks >> (8 * UInt32(byte))) }
            data[33] = 0x80
            data[37] = 0x80
            data[53] = 0x2a
            return Report(deviceId: requestId(gamepadIndex: gamepadIndex), kind: interfaceNumber, reportType: 0, data: Data(data))
        }

        /// The two rumble motors of an output report, each `0...255`.
        public struct Rumble: Equatable, Sendable {
            /// The right, high-frequency motor.
            public let weak: UInt8
            /// The left, low-frequency motor.
            public let strong: UInt8
        }

        /// What one adaptive trigger should do, in the terms Game Controller plays: positions
        /// and strengths are `0...1`, and the ten array slots are the trigger's ten zones from
        /// released to fully pulled.
        public enum TriggerEffect: Equatable, Sendable {
            case off
            /// Resistance per zone.
            case feedback(strengths: [Float])
            /// Resistance between two positions that gives way past the second, like a trigger pull.
            case weapon(start: Float, end: Float, strength: Float)
            /// Vibration per zone at one frequency.
            case vibration(amplitudes: [Float], frequency: Float)

            /// One trigger's eleven bytes of an output report: the mode, then its parameters. The
            /// zoned modes (`0x21`, `0x25`, `0x26`) carry a ten-bit zone mask and three bits of
            /// strength per zone; the older modes (`0x01`, `0x02`, `0x06`) carry positions and
            /// strengths as plain bytes. Any other mode has no Game Controller call and ends the
            /// effect.
            init(bytes: [UInt8]) {
                func unit(_ byte: UInt8) -> Float { Float(byte) / 255 }
                let zones = UInt16(bytes[1]) | UInt16(bytes[2]) << 8
                let levels = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[3 + $1]) << (8 * UInt32($1)) }
                func zoned() -> [Float] {
                    (0..<10).map { zones & (1 << UInt16($0)) != 0 ? Float((levels >> (3 * UInt32($0))) & 0x7) / 8 + 0.125 : 0 }
                }
                func from(_ position: UInt8, _ strength: UInt8) -> [Float] {
                    (0..<10).map { Float($0) / 9 >= unit(position) ? unit(strength) : 0 }
                }
                switch bytes[0] {
                case 0x21: self = .feedback(strengths: zoned())
                case 0x25:
                    guard zones != 0 else { self = .off; return }
                    self = .weapon(start: Float(zones.trailingZeroBitCount) / 9, end: Float(15 - zones.leadingZeroBitCount) / 9,
                                   strength: Float(bytes[3] & 0x7) / 8 + 0.125)
                case 0x26: self = .vibration(amplitudes: zoned(), frequency: unit(bytes[9]))
                case 0x01: self = .feedback(strengths: from(bytes[1], bytes[2]))
                case 0x02: self = .weapon(start: unit(bytes[1]), end: unit(bytes[2]), strength: unit(bytes[3]))
                case 0x06: self = .vibration(amplitudes: from(bytes[3], bytes[2]), frequency: unit(bytes[1]))
                default: self = .off
                }
            }

            /// The trigger vibration that stands in for body rumble (each motor `0...1`) on a host
            /// that does not take a DualSense, where the game cannot address the triggers itself.
            /// `strength` is the user's own scale for the triggers. The stronger motor sets the
            /// level, to the nearest of the pad's eighths, so a value too low to turn a real motor
            /// leaves the triggers alone; the heavy motor leading gives a slow pulse, the light one
            /// a faster buzz. A trigger pulled less than a third of the way stays still: the
            /// vibration is for the finger that is acting, and at rest it shakes the whole pad.
            static func mirroringRumble(weak: Float, strong: Float, strength: Float = 1) -> TriggerEffect {
                let weak = min(max(weak * strength, 0), 1), strong = min(max(strong * strength, 0), 1)
                let level = (max(weak, strong) * 8).rounded() / 8
                guard level > 0 else { return .off }
                return .vibration(amplitudes: [0, 0, 0] + [Float](repeating: level, count: 7), frequency: (strong >= weak ? 25 : 60) / 255)
            }
        }

        /// The parts of a seat output report the pad can act on. A nil field was not flagged as
        /// valid in the report and keeps its current state.
        public struct Output: Equatable, Sendable {
            public let rumble: Rumble?
            public let rightTrigger: TriggerEffect?
            public let leftTrigger: TriggerEffect?
        }

        /// Reads USB output report `0x02`: the two valid-flag bytes, the motors at 3 and 4, the
        /// right trigger's effect at 11 and the left's at 22. Rumble is flagged in the first flag
        /// byte, or by newer hosts in the third flag byte at 39. Nil for anything that is not an
        /// output report to write.
        public static func output(in report: Report) -> Output? {
            let data = [UInt8](report.data)
            guard report.reportType <= 1, data.count >= 33, data[0] == 0x02 else { return nil }
            let rumbleFlagged = data[1] & 0x03 != 0 || (data.count > 39 && data[39] & 0x04 != 0)
            return Output(
                rumble: rumbleFlagged ? Rumble(weak: data[3], strong: data[4]) : nil,
                rightTrigger: data[1] & 0x04 != 0 ? TriggerEffect(bytes: Array(data[11..<22])) : nil,
                leftTrigger: data[1] & 0x08 != 0 ? TriggerEffect(bytes: Array(data[22..<33])) : nil)
        }

        /// The feature reports a host reads from the pad over USB, with neutral contents: the
        /// motion calibration (`0x05`), the pairing record (`0x09`) and the firmware record
        /// (`0x20`). The official client reads these from the pad itself; this pad has none to
        /// read, so the calibration describes an ideal sensor and the records are blank past
        /// their fixed fields.
        static func featureReport(_ id: UInt8) -> [UInt8]? {
            switch id {
            case 0x05:
                // Gyro bias x3, then plus and minus per axis, the two reference speeds, then
                // accelerometer plus and minus per axis; all little-endian int16.
                let values: [Int16] = [0, 0, 0, 8856, -8856, 8856, -8856, 8856, -8856, 540, 540, 8192, -8192, 8192, -8192, 8192, -8192]
                var report = [UInt8](repeating: 0, count: 41)
                report[0] = id
                for (index, value) in values.enumerated() {
                    report[1 + index * 2] = UInt8(truncatingIfNeeded: value)
                    report[2 + index * 2] = UInt8(truncatingIfNeeded: value >> 8)
                }
                return report
            case 0x09:
                // The pad's address, locally administered.
                return [id, 0x01, 0x00, 0x00, 0x00, 0x00, 0x02] + [UInt8](repeating: 0, count: 13)
            case 0x20:
                // Build date and time, then version fields left at zero.
                return [id] + Array("Jan 01 202300:00:00".utf8) + [UInt8](repeating: 0, count: 44)
            default: return nil
            }
        }

        /// The answer to a seat get-report request (`[report id][u16 LE length]`, report type 2
        /// or 3), as `HIDDevice::processHidOutputPayload` sends it: the report under the same
        /// type, or the error flag and no data when the read failed. Nil if `request` is not a
        /// get-report request.
        public static func response(toGetReport request: Report) -> Report? {
            let data = [UInt8](request.data)
            guard request.reportType == 2 || request.reportType == 3, data.count == 3 else { return nil }
            let length = Int(data[1]) | Int(data[2]) << 8
            guard request.reportType == 3, let report = featureReport(data[0]) else {
                return Report(deviceId: request.deviceId, kind: 1, reportType: request.reportType, data: Data())
            }
            return Report(deviceId: request.deviceId, kind: 0, reportType: request.reportType, data: Data(report.prefix(length)))
        }
    }
}
