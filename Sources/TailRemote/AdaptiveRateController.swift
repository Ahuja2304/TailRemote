#if os(macOS)
import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia

// MARK: - Phase 1: Motion States & Rate Control Enums

@frozen
public enum MotionState: Int, Comparable, Sendable {
    case staticScreen = 0  // < 0.02 ratio -> 15 FPS, 1.5 Mbps
    case interactive  = 1  // >= 0.02 & < 0.20 -> 30 FPS, 4.0 Mbps
    case highMotion   = 2  // >= 0.20 -> 60 FPS, 6.0 Mbps
    
    public static func < (lhs: MotionState, rhs: MotionState) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
    
    public var targetFPS: Int {
        switch self {
        case .staticScreen: return 15
        case .interactive:  return 30
        case .highMotion:   return 60
        }
    }
    
    public var targetBitrate: Int32 {
        switch self {
        case .staticScreen: return 1_500_000 // 1.5 Mbps
        case .interactive:  return 4_000_000 // 4.0 Mbps
        case .highMotion:   return 6_000_000 // 6.0 Mbps
        }
    }
}

// MARK: - Phase 2: Zero-Cost Motion Analyzer & Debounced Rate Controller

@available(macOS 12.3, *)
public final class AdaptiveRateController: @unchecked Sendable {
    private(set) public var currentState: MotionState = .highMotion
    private var pendingState: MotionState?
    private var debounceTask: Task<Void, Never>?
    private let lock = NSLock()
    
    public var onStateChange: ((MotionState) -> Void)?
    
    public init() {}
    
    // MARK: - Zero-Cost Metadata Extraction (dirtyRects & contentRect)
    
    public func analyzeFrame(sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let firstAttachment = attachments.first else {
            return
        }
        
        let contentRect: CGRect
        if let rectDict = firstAttachment[SCStreamFrameInfo.contentRect as CFString] as? [String: Any],
           let rect = CGRect(dictionaryRepresentation: rectDict as CFDictionary) {
            contentRect = rect
        } else if let rect = firstAttachment[SCStreamFrameInfo.contentRect as CFString] as? CGRect {
            contentRect = rect
        } else {
            contentRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }
        
        var totalDirtyArea: CGFloat = 0
        if let dirtyRectsArray = firstAttachment[SCStreamFrameInfo.dirtyRects as CFString] as? [[String: Any]] {
            for rectDict in dirtyRectsArray {
                if let rect = CGRect(dictionaryRepresentation: rectDict as CFDictionary) {
                    totalDirtyArea += rect.width * rect.height
                }
            }
        } else if let dirtyRects = firstAttachment[SCStreamFrameInfo.dirtyRects as CFString] as? [CGRect] {
            for rect in dirtyRects {
                totalDirtyArea += rect.width * rect.height
            }
        }
        
        let totalArea = max(1.0, contentRect.width * contentRect.height)
        let motionRatio = Double(totalDirtyArea / totalArea)
        
        let newDetectedState: MotionState
        if motionRatio < 0.02 {
            newDetectedState = .staticScreen
        } else if motionRatio < 0.20 {
            newDetectedState = .interactive
        } else {
            newDetectedState = .highMotion
        }
        
        processStateUpdate(newDetectedState)
    }
    
    // MARK: - 500ms Debounced State Machine
    
    private func processStateUpdate(_ newState: MotionState) {
        lock.lock()
        defer { lock.unlock() }
        
        if newState > currentState {
            // Ramp-Up (Instant): Apply higher FPS & Bitrate immediately to eliminate lag
            debounceTask?.cancel()
            debounceTask = nil
            pendingState = nil
            currentState = newState
            let targetState = currentState
            
            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(targetState)
            }
        } else if newState < currentState {
            // Ramp-Down (Debounced 500ms): Wait 500ms to ensure motion has truly ceased
            pendingState = newState
            if debounceTask == nil {
                debounceTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms debounce
                    if !Task.isCancelled {
                        self?.commitRampDownState()
                    }
                }
            }
        }
    }
    
    private func commitRampDownState() {
        lock.lock()
        defer { lock.unlock() }
        
        if let targetDownState = pendingState, targetDownState < currentState {
            currentState = targetDownState
            let finalState = currentState
            pendingState = nil
            debounceTask = nil
            
            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(finalState)
            }
        } else {
            debounceTask = nil
        }
    }
}
#endif
