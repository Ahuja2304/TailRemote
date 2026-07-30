import Foundation
import Network

// MARK: - TailRemote TLV Protocol Definition (Phase 1)

@frozen
public enum TailRemoteMessageType: UInt8, Sendable {
    case authPIN          = 0x01
    case videoFrame       = 0x02
    case mouseInput       = 0x03
    case keyboardCommand  = 0x04
}

// MARK: - TLV Header Structure: Byte 0 (Type) + Bytes 1-4 (UInt32 BE Length)

public struct TailRemoteHeader {
    public let messageType: UInt8
    public let payloadLength: UInt32
    
    public init(messageType: UInt8, payloadLength: UInt32) {
        self.messageType = messageType
        self.payloadLength = payloadLength
    }
}

// MARK: - UDP Datagram Fragment Header Structure (8 Bytes Total)

public struct UDPVideoDatagramHeader {
    public let frameID: UInt32
    public let fragmentID: UInt16
    public let totalFragments: UInt16
    
    public init(frameID: UInt32, fragmentID: UInt16, totalFragments: UInt16) {
        self.frameID = frameID
        self.fragmentID = fragmentID
        self.totalFragments = totalFragments
    }
    
    public func serialize() -> Data {
        var data = Data(capacity: 8)
        var fID = frameID.bigEndian
        var fragID = fragmentID.bigEndian
        var totalFrags = totalFragments.bigEndian
        
        withUnsafeBytes(of: &fID) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &fragID) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &totalFrags) { data.append(contentsOf: $0) }
        return data
    }
    
    public static func parse(from data: Data) -> (header: UDPVideoDatagramHeader, payload: Data)? {
        guard data.count >= 8 else { return nil }
        
        let fIDRaw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let fragIDRaw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self) }
        let totalFragsRaw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self) }
        
        let header = UDPVideoDatagramHeader(
            frameID: UInt32(bigEndian: fIDRaw),
            fragmentID: UInt16(bigEndian: fragIDRaw),
            totalFragments: UInt16(bigEndian: totalFragsRaw)
        )
        
        let payload = data.subdata(in: 8..<data.count)
        return (header, payload)
    }
}

// MARK: - NWProtocolFramer Implementation for TLV (5-byte Header)

public final class TailRemoteFramer: NWProtocolFramerImplementation {
    public static let label = "TailRemoteProtocol"
    public static let definition = NWProtocolFramer.Definition(implementation: TailRemoteFramer.self)
    
    public init(framer: NWProtocolFramer.Instance) {}
    
    public func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        return .ready
    }
    
    public func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var typeRaw: UInt8 = 0
            var payloadLength: UInt32 = 0
            
            let parsed = framer.parseInput(minimumIncompleteLength: 5, maximumLength: 5) { buffer, _ in
                guard let buffer = buffer, buffer.count >= 5 else { return 0 }
                
                typeRaw = buffer.loadUnaligned(fromByteOffset: 0, as: UInt8.self)
                let lengthRaw = buffer.loadUnaligned(fromByteOffset: 1, as: UInt32.self)
                payloadLength = UInt32(bigEndian: lengthRaw)
                return 5
            }
            
            guard parsed else { return 5 }
            
            let message = NWProtocolFramer.Message(type: TailRemoteMessageType(rawValue: typeRaw) ?? .authPIN)
            
            if !framer.deliverInputNoCopy(length: Int(payloadLength), message: message, isComplete: true) {
                return Int(payloadLength)
            }
        }
    }
    
    public func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        guard let messageType = message.messageType else { return }
        
        var headerData = Data(capacity: 5)
        headerData.append(messageType)
        var lengthBE = UInt32(messageLength).bigEndian
        withUnsafeBytes(of: &lengthBE) { headerData.append(contentsOf: $0) }
        
        framer.writeOutput(data: headerData)
        if messageLength > 0 {
            try? framer.writeOutputNoCopy(length: messageLength)
        }
    }
    
    public func wakeup(framer: NWProtocolFramer.Instance) {}
    public func stop(framer: NWProtocolFramer.Instance) -> Bool { return true }
    public func cleanup(framer: NWProtocolFramer.Instance) {}
}

extension NWProtocolFramer.Message {
    public convenience init(type: TailRemoteMessageType) {
        self.init(definition: TailRemoteFramer.definition)
        self["MessageType"] = type.rawValue
    }
    
    public var messageType: UInt8? {
        return self["MessageType"] as? UInt8
    }
}
