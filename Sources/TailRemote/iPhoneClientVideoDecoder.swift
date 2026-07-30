import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

// MARK: - Zero-Copy H.264 Video Decoder for iOS Client

public final class iPhoneClientVideoDecoder: NSObject, @unchecked Sendable {
    private var formatDescription: CMFormatDescription?
    public let displayLayer: AVSampleBufferDisplayLayer
    private var receivedFrameCount: Int = 0
    private var droppedFrameCount: Int = 0
    private var statusObservation: NSKeyValueObservation?
    
    public var onRequestIDRKeyframe: (() -> Void)?
    
    public init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        self.displayLayer.videoGravity = .resizeAspect
        super.init()
        
        // KVO Observation on displayLayer.status and displayLayer.error with Automatic Recovery
        self.statusObservation = displayLayer.observe(\.status, options: [.initial, .new]) { [weak self] layer, _ in
            switch layer.status {
            case .rendering:
                print("🟢 Decoder: AVSampleBufferDisplayLayer is actively RENDERING video")
            case .failed:
                print("❌ CRITICAL Decoder Error: AVSampleBufferDisplayLayer FAILED with error: \(String(describing: layer.error))")
                DispatchQueue.main.async {
                    layer.flush()
                    self?.formatDescription = nil
                    self?.onRequestIDRKeyframe?()
                    print("⚡️ Decoder Auto-Recovery: Flushed failed layer & requested fresh IDR Keyframe from Mac Host")
                }
            default:
                print("🔄 Decoder: AVSampleBufferDisplayLayer status changed to: \(layer.status.rawValue)")
            }
        }
    }
    
    // MARK: - Handle Inbound Format Description (Message 0x20)
    
    public func handleFormatDescription(data: Data) {
        guard data.count >= 4 else {
            print("❌ Decoder: Received malformed formatDescription data (count < 4)")
            return
        }
        
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            
            let spsSizeRaw = baseAddress.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            let spsSize = Int(UInt16(bigEndian: spsSizeRaw))
            offset += 2
            
            guard offset + spsSize <= data.count else { return }
            let spsPointer = baseAddress.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            offset += spsSize
            
            guard offset + 2 <= data.count else { return }
            let ppsSizeRaw = baseAddress.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            let ppsSize = Int(UInt16(bigEndian: ppsSizeRaw))
            offset += 2
            
            guard offset + ppsSize <= data.count else { return }
            let ppsPointer = baseAddress.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            
            let parameterSetPointers: [UnsafePointer<UInt8>] = [spsPointer, ppsPointer]
            let parameterSetSizes: [Int] = [spsSize, ppsSize]
            
            var newFormatDescription: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: 2,
                parameterSetPointers: parameterSetPointers,
                parameterSetSizes: parameterSetSizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &newFormatDescription
            )
            
            if status == noErr {
                self.formatDescription = newFormatDescription
                print("🎥 Decoder: CMVideoFormatDescription created successfully (SPS: \(spsSize) bytes, PPS: \(ppsSize) bytes)")
                DispatchQueue.main.async { [weak self] in
                    self?.displayLayer.flush()
                }
            } else {
                print("❌ CRITICAL: Failed to create Format Description. OSStatus: \(status)")
            }
        }
    }
    
    // MARK: - Zero-Latency Handle Inbound Video Frame (Message 0x21 / 0x22)
    
    public func handleVideoFrame(data: Data, isKeyframe: Bool) {
        guard let formatDescription = formatDescription else {
            droppedFrameCount += 1
            if droppedFrameCount % 60 == 1 {
                print("⚠️ Decoder dropping frame: Format Description (SPS/PPS) has not been received or parsed yet (Total dropped: \(droppedFrameCount))")
            }
            return
        }
        
        let frameSize = data.count
        var blockBuffer: CMBlockBuffer?
        
        let blockBufferStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frameSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frameSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        if blockBufferStatus != kCMBlockBufferNoErr {
            print("❌ CRITICAL: Failed to create CMBlockBuffer. OSStatus: \(blockBufferStatus)")
            return
        }
        
        guard let blockBuffer = blockBuffer else { return }
        
        data.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                CMBlockBufferReplaceDataBytes(with: baseAddress, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: frameSize)
            }
        }
        
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime.invalid,
            decodeTimeStamp: CMTime.invalid
        )
        
        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray = [frameSize]
        
        let sampleBufferStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )
        
        if sampleBufferStatus != noErr {
            print("❌ CRITICAL: Failed to create CMSampleBuffer. OSStatus: \(sampleBufferStatus)")
            return
        }
        
        guard let sampleBuffer = sampleBuffer else { return }
        
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachmentsArray) > 0 {
            let attachments = unsafeBitCast(CFArrayGetValueAtIndex(attachmentsArray, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(attachments, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.displayLayer.status == .failed {
                print("⚠️ Decoder: Flushing failed displayLayer: \(String(describing: self.displayLayer.error))")
                self.displayLayer.flush()
                self.formatDescription = nil
                self.onRequestIDRKeyframe?()
                return
            }
            self.displayLayer.enqueue(sampleBuffer)
            
            self.receivedFrameCount += 1
            if self.receivedFrameCount % 60 == 0 {
                print("Decoder: Received and enqueued \(self.receivedFrameCount) frames. Layer status: \(self.displayLayer.status.rawValue)")
            }
        }
    }
}
