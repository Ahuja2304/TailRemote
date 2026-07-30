#if os(macOS)
import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import Network
import Dispatch
import CoreGraphics

// MARK: - MacHost Video Pipeline Manager

@available(macOS 12.3, *)
public final class MacHostVideoPipeline: NSObject, @unchecked Sendable {
    
    private var stream: SCStream?
    private var compressionSession: VTCompressionSession?
    private var connection: NWConnection?
    
    private let videoQueue = DispatchQueue(label: "com.tailremote.video.pipeline", qos: .userInteractive)
    private var isBufferFull: Bool = false
    private var formatDescriptionSent: Bool = false
    private var encodedFrameCount: Int = 0
    
    public init(connection: NWConnection? = nil) {
        self.connection = connection
        super.init()
    }
    
    // MARK: - Public Controls & Explicit macOS Screen Capture Access Preflight
    
    public func startCapture() async throws {
        // Fix 1: Explicit Screen Recording Permission Preflight Check
        if !CGPreflightScreenCaptureAccess() {
            logPrint("⚠️ MacHostVideoPipeline: Screen Recording permission missing! Requesting access...")
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                logPrint("❌ MacHostVideoPipeline: Screen Recording permission DENIED by user. Open System Settings > Privacy & Security > Screen Recording and allow Terminal/MacHost.")
                throw NSError(domain: "MacHostVideoPipeline", code: -403, userInfo: [NSLocalizedDescriptionKey: "Screen Recording permission denied by user."])
            }
        }
        
        do {
            let shareableContent = try await SCShareableContent.current
            guard let primaryDisplay = shareableContent.displays.first else {
                logPrint("❌ MacHostVideoPipeline: No primary display found")
                throw NSError(domain: "MacHostVideoPipeline", code: -1, userInfo: [NSLocalizedDescriptionKey: "No primary display found"])
            }
            
            // 1. Initialize VTCompressionSession for H.264 Encoding with resolution scaling
            let rawWidth = primaryDisplay.width
            let rawHeight = primaryDisplay.height
            let maxDim: CGFloat = 1920.0
            let scale = min(1.0, maxDim / CGFloat(max(rawWidth, rawHeight)))
            let width = (Int(CGFloat(rawWidth) * scale) / 2) * 2 // Ensure even dimensions for H.264
            let height = (Int(CGFloat(rawHeight) * scale) / 2) * 2
            
            try setupCompressionSession(width: Int32(width), height: Int32(height))
            
            // 2. Configure ScreenCaptureKit Stream
            let filter = SCContentFilter(display: primaryDisplay, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60) // 60 FPS target
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.showsCursor = true
            config.queueDepth = 3 // Minimal queue depth to eliminate frame accumulation latency
            
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            try await stream.startCapture()
            
            self.stream = stream
            logPrint("🎥 MacHostVideoPipeline: ScreenCaptureKit capture started @ 60 FPS (\(width)x\(height) [Native: \(rawWidth)x\(rawHeight)])")
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
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 8_000_000 as CFNumber) // 8 Mbps target
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CAVLC) // Fast CAVLC entropy decoding
        
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.compressionSession = session
    }
    
    // MARK: - Encode Frame
    
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
    
    // MARK: - Zero-Copy NAL Unit Extraction & Congestion Control
    
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
        
        let rawBuffer = UnsafeRawBufferPointer(start: rawDataPointer, count: totalLength)
        let dispatchData = DispatchData(bytes: rawBuffer)
        
        let messageType: TailRemoteMessageType = isKeyframe ? .keyframe : .pFrame
        sendVideoPacket(data: dispatchData, messageType: messageType)
        
        // Fix 3: Host Pipeline Throttle Logging (Once every 60 frames)
        encodedFrameCount += 1
        if encodedFrameCount % 60 == 0 {
            logPrint("Host Pipeline: Encoded & transmitted \(encodedFrameCount) H.264 video frames over network")
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
        
        var payload = Data()
        
        let spsSizeUInt16 = UInt16(spsSize).bigEndian
        withUnsafeBytes(of: spsSizeUInt16) { payload.append(contentsOf: $0) }
        payload.append(sps, count: spsSize)
        
        let ppsSizeUInt16 = UInt16(ppsSize).bigEndian
        withUnsafeBytes(of: ppsSizeUInt16) { payload.append(contentsOf: $0) }
        payload.append(pps, count: ppsSize)
        
        payload.withUnsafeBytes { rawBuffer in
            let dispatchData = DispatchData(bytes: rawBuffer)
            sendVideoPacket(data: dispatchData, messageType: .formatDescription)
            logPrint("🎥 MacHostVideoPipeline: Transmitted SPS/PPS Format Description (\(spsSize) SPS bytes, \(ppsSize) PPS bytes)")
        }
    }
    
    private func sendVideoPacket(data: DispatchData, messageType: TailRemoteMessageType) {
        guard let connection = connection else { return }
        
        let message = NWProtocolFramer.Message(channel: .video, messageType: messageType)
        let context = NWConnection.ContentContext(identifier: "VideoPacket", metadata: [message])
        
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
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
