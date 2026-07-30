import Foundation
import Network

// MARK: - TailRemote Protocol Channel & Message Specifications

@frozen
public enum TailRemoteChannel: UInt8, Sendable {
    case controlAndHandshake = 0x00
    case input                = 0x01
    case video                = 0x02
    case fileTransfer         = 0x03
}

@frozen
public enum TailRemoteMessageType: UInt8, Sendable {
    // Channel 0: Control & Handshake
    case requestIDR            = 0x01
    case codecConfiguration    = 0x02
    case systemCommand         = 0x04
    
    // Channel 1: Input Events
    case pointerMoveRelative   = 0x10
    case pointerMoveAbsolute   = 0x11
    case mouseButton           = 0x12
    case scrollEvent           = 0x13
    case keyStroke             = 0x14
    
    // Channel 2: Video Stream
    case formatDescription     = 0x20
    case keyframe              = 0x21
    case pFrame                = 0x22
    
    // Channel 3: File Transfer
    case fileDirectoryListReq  = 0x30
    case fileDirectoryListResp = 0x31
    case fileChunkHeader       = 0x32
    case fileChunkPayload      = 0x33
}

// MARK: - Protocol Framer Implementation (6-byte Big-Endian Header)

public final class TailRemoteFramer: NWProtocolFramerImplementation {
    public static let label = "TailRemoteProtocol"
    public static let definition = NWProtocolFramer.Definition(implementation: TailRemoteFramer.self)
    
    public init(framer: NWProtocolFramer.Instance) {}
    
    public func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        return .ready
    }
    
    public func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var header: TailRemoteHeader? = nil
            
            // Fix: Use parseInput inside handleInput (NOT parseOutput)
            let parsed = framer.parseInput(minimumIncompleteLength: 6, maximumLength: 6) { buffer, _ in
                guard let buffer = buffer, buffer.count >= 6 else { return 0 }
                
                let channelID = buffer.loadUnaligned(fromByteOffset: 0, as: UInt8.self)
                let messageType = buffer.loadUnaligned(fromByteOffset: 1, as: UInt8.self)
                let payloadLengthRaw = buffer.loadUnaligned(fromByteOffset: 2, as: UInt32.self)
                let payloadLength = UInt32(bigEndian: payloadLengthRaw)
                
                header = TailRemoteHeader(channelID: channelID, messageType: messageType, payloadLength: payloadLength)
                return 6
            }
            
            guard parsed, let header = header else { return 6 }
            
            let message = NWProtocolFramer.Message(channel: TailRemoteChannel(rawValue: header.channelID) ?? .controlAndHandshake,
                                                   messageType: TailRemoteMessageType(rawValue: header.messageType) ?? .requestIDR)
            
            if !framer.deliverInputNoCopy(length: Int(header.payloadLength), message: message, isComplete: true) {
                return Int(header.payloadLength)
            }
        }
    }
    
    public func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        guard let channelID = message.channelID,
              let messageType = message.messageType else { return }
        
        var headerData = Data(capacity: 6)
        headerData.append(channelID)
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

public struct TailRemoteHeader {
    public let channelID: UInt8
    public let messageType: UInt8
    public let payloadLength: UInt32
}

extension NWProtocolFramer.Message {
    public convenience init(channel: TailRemoteChannel, messageType: TailRemoteMessageType) {
        self.init(definition: TailRemoteFramer.definition)
        self["ChannelID"] = channel.rawValue
        self["MessageType"] = messageType.rawValue
    }
    
    public var channelID: UInt8? {
        return self["ChannelID"] as? UInt8
    }
    
    public var messageType: UInt8? {
        return self["MessageType"] as? UInt8
    }
}
