import CoreMIDI
import Foundation

/// Listens to every connected MIDI source (USB, Bluetooth MIDI, network) and hands
/// channel messages to `onMessage`. What a message *does* is decided by the `midi` rules
/// in Config.swift.
///
/// Uses the MIDIPacketList API (macOS 10.11 / iOS 9) rather than the newer event-list
/// one so it builds for old OS targets.
final class MIDIInput {
    var onMessage: (([UInt8], String) -> Void)?
    private(set) var sourceNames: [String] = []

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: [MIDIEndpointRef] = []

    func start() {
        let s1 = MIDIClientCreateWithBlock("OO Rehearsal" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectAll() }
            }
        }
        guard s1 == noErr else { NSLog("MIDI client failed: \(s1)"); return }
        let s2 = MIDIInputPortCreateWithBlock(client, "in" as CFString, &port) { [weak self] list, refCon in
            self?.receive(list, refCon)
        }
        guard s2 == noErr else { NSLog("MIDI port failed: \(s2)"); return }
        connectAll()
    }

    /// Re-scan sources; called at start and whenever a device is plugged/unplugged.
    func connectAll() {
        for src in connected { MIDIPortDisconnectSource(port, src) }
        connected = []
        sourceNames = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            // refCon carries the index into sourceNames (+1 so it is never a null pointer).
            let ref = UnsafeMutableRawPointer(bitPattern: sourceNames.count + 1)
            if MIDIPortConnectSource(port, src, ref) == noErr {
                connected.append(src)
                sourceNames.append(Self.name(of: src))
            }
        }
    }

    private static func name(of ep: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &cf) == noErr, let s = cf?.takeRetainedValue() {
            return s as String
        }
        return "MIDI device"
    }

    private func receive(_ list: UnsafePointer<MIDIPacketList>, _ refCon: UnsafeMutableRawPointer?) {
        let idx = Int(bitPattern: refCon) - 1
        let from = (idx >= 0 && idx < sourceNames.count) ? sourceNames[idx] : ""
        // Walk packets through raw pointers: copying MIDIPacket by value would read
        // 256 bytes of `data` past the end of a short final packet.
        let listOffset = MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet)!
        let lenOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.length)!
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!
        let count = UnsafeRawPointer(list).load(as: UInt32.self)
        var pkt = (UnsafeRawPointer(list) + listOffset).assumingMemoryBound(to: MIDIPacket.self)
        var messages: [[UInt8]] = []
        for _ in 0..<count {
            let raw = UnsafeRawPointer(pkt)
            let len = Int(raw.load(fromByteOffset: lenOffset, as: UInt16.self))
            let bytes = Array(UnsafeBufferPointer(start: (raw + dataOffset).assumingMemoryBound(to: UInt8.self), count: len))
            messages += Self.split(bytes)
            pkt = UnsafePointer(MIDIPacketNext(pkt))
        }
        guard !messages.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            for m in messages { self?.onMessage?(m, from) }
        }
    }

    /// Split a packet into channel messages (note on/off, CC, program change...).
    /// System messages (sysex, clock) are skipped: no pedal action uses them.
    static func split(_ bytes: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var i = 0
        while i < bytes.count {
            let status = bytes[i]
            guard status & 0x80 != 0, status < 0xF0 else {
                i += 1
                if status == 0xF0 { while i < bytes.count && bytes[i] != 0xF7 { i += 1 }; i += 1 }
                continue
            }
            let hi = status & 0xF0
            let n = (hi == 0xC0 || hi == 0xD0) ? 2 : 3
            if i + n <= bytes.count { out.append(Array(bytes[i..<(i + n)])) }
            i += n
        }
        return out
    }
}
