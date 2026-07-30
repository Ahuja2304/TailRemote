#if os(macOS)
import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import Network
import Dispatch
import CoreGraphics

// MARK: - Phase 2: MacHost Zero-Copy Ring Buffer Memory Pool

public final class VideoFrameBufferPool: @unchecked Sendable {
    public struct BufferSlot {
        public var data: Data
        public var frameID: UInt32
        public var isKeyframe: Bool
        public var isUsed: Bool
    }
    
    private let capacity: Int
    private var slots: [BufferSlot]
    private var writeIndex: Int = 0
    private let lock = NSLock()
    
    public init(capacity: Int = 16) {
        self.capacity = capacity
        self.slots = Array(repeating: BufferSlot(data: Data(), frameID: 0, isKeyframe: false, isUsed: false), count: capacity)
    }
    
    public func allocateSlot(size: Int, frameID: UInt32, isKeyframe: Bool) -> Int {
        lock.lock()
        defer { lock.unlock() }
        
        let index = writeIndex
        slots[index].data.removeAll(keepingCapacity: true)
        slots[index].data.reserveCapacity(size)
        slots[index].frameID = frameID
        slots[index].isKeyframe = isKeyframe
        slots[index].isUsed = true
        
        writeIndex = (writeIndex + 1) % capacity
        return index
    }
    
    public func writeData(_ data: Data, toSlot index: Int) {
        lock.lock()
        defer { lock.unlock() }
        slots[index].data.append(data)
    }
    
    public func getSlot(_ index: Int) -> BufferSlot {
        lock.lock()
        defer { lock.unlock() }
        return slots[index]
    }
}

// MARK: - MacHost Video Pipeline Manager with UDP Datagram Fragmenter

@available(macOS 12.3, *)
public final class MacHostVideoPipeline: NSObject, @unchecked Sendable {
    
    private var stream: SCStream?
    private var compressionSession: VTCompressionSession?
    private var udpConnection: NWConnection?
    
    private let bufferPool = VideoFrameBufferPool(capacity: 16)
    private var currentFrameID: UInt32 = 0
    
    private let videoQueue = DispatchQueue(label: "com.tailremote.video.pipeline", qos: .userInteractive)
    private var isBufferFull: Bool = false
    private var formatDescriptionSent: Bool = false
    private var encodedFrameCount: Int = 0
    
    private let maxMTUSize: Int = 1380 // 1400 MTU limit minus 8-byte datagram header + 12-byte Network framing overhead
    
    public init(connection: NWConnection? = nil) {
        self.udpConnection = connection
        super.init()
    }
    
    public func updateUDPConnection(_ connection: NWConnection) {
        self.udpConnection = connection
    }
    
    // MARK: - Public Controls & Screen Capture Access
    
    public func startCapture() async throws {
        if !CGPreflightScreenCaptureAccess() {
            logPrint("⚠️ MacHostVideoPipeline: Screen Recording permission missing! Requesting access...")
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                logPrint("❌ MacHostVideoPipeline: Screen Recording permission DENIED by user. Allow Terminal/MacHost in System Settings > Privacy & Security > Screen Recording.")
                throw NSError(domain: "MacHostVideoPipeline", code: -403, userInfo: [NSLocalizedDescriptionKey: "Screen Recording permission denied by user."])
            }
        }
        
        do {
            let shareableContent = try await SCShareableContent.current
            guard let primaryDisplay = shareableContent.displays.first else {
                logPrint("❌ MacHostVideoPipeline: No primary display found")
                throw NSError(domain: "MacHostVideoPipeline", code: -1, userInfo: [NSLocalizedDescriptionKey: "No primary display found"])
            }
            
            let rawWidth = primaryDisplay.width
            let rawHeight = primaryDisplay.height
            let maxDim: CGFloat = 1920.0
            let scale = min(1.0, maxDim / CGFloat(max(rawWidth, rawHeight)))
            let width = (Int(CGFloat(rawWidth) * scale) / 2) * 2
            let height = (Int(CGFloat(rawHeight) * scale) / 2) * 2
            
            try setupCompressionSession(width: Int32(width), height: Int32(height))
            
            let filter = SCContentFilter(display: primaryDisplay, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.showsCursor = false
            config.queueDepth = 3
            
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            try await stream.startCapture()
            
            self.stream = stream
            logPrint("🎥 MacHostVideoPipeline: ScreenCaptureKit capture started @ 60 FPS UDP Transport (\(width)x\(height))")
        } catch {
            logPrint("❌ MacHostVideoPipeline: ScreenCaptureKit Error: \(error)")
            throw error
        }
    }
    
    public func stopCapture() async {
        if let stream = stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            self.compressionSession = nil
        }
    }
    
    public func forceKeyframe() {
        videoQueue.async { [weak self] in
            self?.formatDescriptionSent = false
        }
    }
    
    public func updateConnectionReadiness(isBufferFull: Bool) {
        videoQueue.async { [weak self] in
            self?.isBufferFull = isBufferFull
        }
    }
    
    // MARK: - VTCompressionSession Setup
    
    private func setupCompressionSession(width: Int32, height: Int32) throws {
        var sessionOut: VTCompressionSession?
        
        let callback: VTCompressionOutputCallback = { outputCallbackRefCon, _, status, flags, sampleBuffer in
            guard status == noErr, let sampleBuffer = sampleBuffer, let refcon = outputCallbackRefCon else {
                return
            }
            let pipeline = Unmanaged<MacHostVideoPipeline>.fromOpaque(refcon).takeUnretainedValue()
            pipeline.handleEncodedFrame(sampleBuffer: sampleBuffer, flags: flags)
        }
        
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: refCon,
            compressionSessionOut: &sessionOut
        )
        
        guard status == noErr, let session = sessionOut else {
            throw NSError(domain: "MacHostVideoPipeline", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create VTCompressionSession"])
        }
        
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 8_000_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CAVLC)
        
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.compressionSession = session
    }
    
    private func encodeFrame(cvImageBuffer: CVImageBuffer, presentationTimeStamp: CMTime, duration: CMTime) {
        guard let session = compressionSession else { return }
        
        var flags: VTEncodeInfoFlags = []
        var frameProperties: [String: Any]? = nil
        
        if !formatDescriptionSent {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
        }
        
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: cvImageBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: frameProperties as CFDictionary?,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
    }
    
    // MARK: - Zero-Copy Ring Buffer & UDP Datagram Fragmenter
    
    private func handleEncodedFrame(sampleBuffer: CMSampleBuffer, flags: VTEncodeInfoFlags) {
        let isKeyframe: Bool
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let firstAttachment = attachments.first,
           let notSync = firstAttachment[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        } else {
            isKeyframe = true
        }
        
        if isBufferFull && !isKeyframe {
            return
        }
        
        if isKeyframe || !formatDescriptionSent {
            if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
                sendFormatDescription(formatDescription)
                formatDescriptionSent = true
            }
        }
        
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let blockBufferStatus = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        
        guard blockBufferStatus == noErr, let rawDataPointer = dataPointer, totalLength > 0 else { return }
        
        currentFrameID += 1
        let frameID = currentFrameID
        
        let subType: UInt8 = isKeyframe ? 0x02 : 0x03
        
        // 1. Allocate Ring Buffer Memory Slot
        let totalPayloadSize = 1 + totalLength
        let slotIndex = bufferPool.allocateSlot(size: totalPayloadSize, frameID: frameID, isKeyframe: isKeyframe)
        
        var fullFramePayload = Data([subType])
        let rawBuffer = UnsafeRawBufferPointer(start: rawDataPointer, count: totalLength)
        fullFramePayload.append(contentsOf: rawBuffer)
        
        bufferPool.writeData(fullFramePayload, toSlot: slotIndex)
        
        // 2. Dispatch MTU-Safe Datagram Fragments Over UDP Pipeline
        dispatchUDPFragments(frameID: frameID, payload: fullFramePayload)
        
        encodedFrameCount += 1
        if encodedFrameCount % 60 == 0 {
            logPrint("Host Pipeline (UDP): Encoded & Fragmented \(encodedFrameCount) video frames over UDP socket")
        }
    }
    
    private func dispatchUDPFragments(frameID: UInt32, payload: Data) {
        guard let connection = udpConnection else { return }
        
        let totalLength = payload.count
        let totalFragments = UInt16(ceil(Double(totalLength) / Double(maxMTUSize)))
        
        for fragID in 0..<totalFragments {
            let offset = Int(fragID) * maxMTUSize
            let chunkLength = min(maxMTUSize, totalLength - offset)
            let chunkData = payload.subdata(in: offset..<(offset + chunkLength))
            
            let header = UDPVideoDatagramHeader(frameID: frameID, fragmentID: fragID, totalFragments: totalFragments)
            var packet = header.serialize()
            packet.append(chunkData)
            
            packet.withUnsafeBytes { rawBuffer in
                let dispatchData = DispatchData(bytes: rawBuffer)
                connection.send(content: dispatchData, completion: .idempotent)
            }
        }
    }
    
    private func sendFormatDescription(_ formatDescription: CMFormatDescription) {
        var spsSize: Int = 0
        var spsCount: Int = 0
        var spsHeader: UnsafePointer<UInt8>?
        
        var ppsSize: Int = 0
        var ppsCount: Int = 0
        var ppsHeader: UnsafePointer<UInt8>?
        
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsHeader,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount,
            nalUnitHeaderLengthOut: nil
        )
        
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsHeader,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: &ppsCount,
            nalUnitHeaderLengthOut: nil
        )
        
        guard let sps = spsHeader, let pps = ppsHeader else { return }
        
        var payload = Data([0x01]) // Sub-type 0x01: Format Description
        
        let spsSizeUInt16 = UInt16(spsSize).bigEndian
        withUnsafeBytes(of: spsSizeUInt16) { payload.append(contentsOf: $0) }
        payload.append(sps, count: spsSize)
        
        let ppsSizeUInt16 = UInt16(ppsSize).bigEndian
        withUnsafeBytes(of: ppsSizeUInt16) { payload.append(contentsOf: $0) }
        payload.append(pps, count: ppsSize)
        
        currentFrameID += 1
        dispatchUDPFragments(frameID: currentFrameID, payload: payload)
        logPrint("🎥 MacHostVideoPipeline (UDP): Transmitted SPS/PPS Format Description (\(spsSize) SPS bytes, \(ppsSize) PPS bytes)")
    }
}

// MARK: - SCStreamOutput Extension

@available(macOS 12.3, *)
extension MacHostVideoPipeline: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        
        encodeFrame(cvImageBuffer: imageBuffer, presentationTimeStamp: pts, duration: duration)
    }
}
#endif
