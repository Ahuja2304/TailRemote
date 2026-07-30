import Foundation
import CoreGraphics
import SwiftUI
import QuartzCore
import os.log

#if canImport(UIKit)
import UIKit
#endif

#if os(macOS)
import ApplicationServices
#endif

private let logger = OSLog(subsystem: "com.tailremote", category: "Diagnostics")

// MARK: - Mouse Button & State Enums

@frozen
public enum MouseButtonType: UInt8, Sendable {
    case left = 0x01
    case right = 0x02
    case middle = 0x03
}

@frozen
public enum MouseButtonState: UInt8, Sendable {
    case down = 0x01
    case up = 0x02
}

// MARK: - Native Keystroke Catcher (UIKeyInput Protocol with Aggressive Autocorrect Disable)

#if os(iOS)
public struct RemoteKeyboardCatcher: UIViewRepresentable {
    @Binding var isFirstResponder: Bool
    public var onKeystroke: ((String) -> Void)
    
    public init(isFirstResponder: Binding<Bool>, onKeystroke: @escaping (String) -> Void) {
        self._isFirstResponder = isFirstResponder
        self.onKeystroke = onKeystroke
    }

    public func makeUIView(context: Context) -> KeyInputView {
        let view = KeyInputView()
        view.onKeystroke = onKeystroke
        return view
    }

    public func updateUIView(_ uiView: KeyInputView, context: Context) {
        uiView.onKeystroke = onKeystroke
        DispatchQueue.main.async {
            if isFirstResponder && !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            } else if !isFirstResponder && uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
        }
    }
}

public class KeyInputView: UIView, UIKeyInput, UITextInputTraits {
    public var onKeystroke: ((String) -> Void)?

    public override var canBecomeFirstResponder: Bool { true }
    
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var smartDashesType: UITextSmartDashesType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    public var keyboardType: UIKeyboardType = .asciiCapable

    public var hasText: Bool { true }
    
    public func insertText(_ text: String) {
        onKeystroke?(text)
    }
    
    public func deleteBackward() {
        onKeystroke?("\u{7F}")
    }
    
    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        return false
    }
}
#endif

// MARK: - Phase 1: Zero-Latency Mac Trackpad Gesture View with Non-Blocking Background Network Sending

#if os(iOS)
public struct TailRemoteGestureView: UIViewRepresentable {
    public var mode: ImmersiveWorkspaceState.InputMode
    public var onLocalCursorMove: ((CGPoint) -> Void)?
    public var onRelativeMove: ((Float, Float) -> Void)?
    public var onAbsoluteMove: ((Float, Float) -> Void)?
    public var onMouseButton: ((MouseButtonType, MouseButtonState) -> Void)?
    public var onScroll: ((Float, Float) -> Void)?
    public var onUserInteraction: (() -> Void)?
    
    public init(
        mode: ImmersiveWorkspaceState.InputMode,
        onLocalCursorMove: ((CGPoint) -> Void)? = nil,
        onRelativeMove: ((Float, Float) -> Void)? = nil,
        onAbsoluteMove: ((Float, Float) -> Void)? = nil,
        onMouseButton: ((MouseButtonType, MouseButtonState) -> Void)? = nil,
        onScroll: ((Float, Float) -> Void)? = nil,
        onUserInteraction: (() -> Void)? = nil
    ) {
        self.mode = mode
        self.onLocalCursorMove = onLocalCursorMove
        self.onRelativeMove = onRelativeMove
        self.onAbsoluteMove = onAbsoluteMove
        self.onMouseButton = onMouseButton
        self.onScroll = onScroll
        self.onUserInteraction = onUserInteraction
    }

    public func makeUIView(context: Context) -> TrackpadUIView {
        let view = TrackpadUIView()
        view.mode = mode
        view.onLocalCursorMove = onLocalCursorMove
        view.onRelativeMove = onRelativeMove
        view.onAbsoluteMove = onAbsoluteMove
        view.onMouseButton = onMouseButton
        view.onScroll = onScroll
        view.onUserInteraction = onUserInteraction
        return view
    }

    public func updateUIView(_ uiView: TrackpadUIView, context: Context) {
        uiView.mode = mode
        uiView.onLocalCursorMove = onLocalCursorMove
        uiView.onRelativeMove = onRelativeMove
        uiView.onAbsoluteMove = onAbsoluteMove
        uiView.onMouseButton = onMouseButton
        uiView.onScroll = onScroll
        uiView.onUserInteraction = onUserInteraction
    }
}

public class TrackpadUIView: UIView {
    public var mode: ImmersiveWorkspaceState.InputMode = .trackpadRelative
    
    public var onLocalCursorMove: ((CGPoint) -> Void)?
    public var onRelativeMove: ((Float, Float) -> Void)?
    public var onAbsoluteMove: ((Float, Float) -> Void)?
    public var onMouseButton: ((MouseButtonType, MouseButtonState) -> Void)?
    public var onScroll: ((Float, Float) -> Void)?
    public var onUserInteraction: (() -> Void)?
    
    private var lastDispatchTime: Date = .distantPast
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        self.isMultipleTouchEnabled = true
        self.backgroundColor = .clear
        setupGestures()
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
    
    private func setupGestures() {
        let movePan = UIPanGestureRecognizer(target: self, action: #selector(handleMovePan(_:)))
        movePan.minimumNumberOfTouches = 1
        movePan.maximumNumberOfTouches = 1
        self.addGestureRecognizer(movePan)
        
        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        self.addGestureRecognizer(scrollPan)
        
        let leftTap = UITapGestureRecognizer(target: self, action: #selector(handleLeftTap(_:)))
        leftTap.require(toFail: scrollPan)
        self.addGestureRecognizer(leftTap)
        
        let rightTap = UITapGestureRecognizer(target: self, action: #selector(handleRightTap(_:)))
        rightTap.numberOfTouchesRequired = 2
        self.addGestureRecognizer(rightTap)
    }
    
    @objc private func handleMovePan(_ sender: UIPanGestureRecognizer) {
        onUserInteraction?()
        let location = sender.location(in: self)
        let translation = sender.translation(in: self)
        sender.setTranslation(.zero, in: self)
        
        // 1. Immediate 120Hz Local Cursor Update on Main Thread (Zero Latency)
        if mode == .trackpadRelative {
            onLocalCursorMove?(translation)
        } else {
            onLocalCursorMove?(location)
        }
        
        // Handle gesture end / cancel cleanly
        if sender.state == .ended || sender.state == .cancelled {
            lastDispatchTime = .distantPast
            return
        }
        
        // 2. 16.6ms Throttler Check
        let now = Date()
        guard now.timeIntervalSince(lastDispatchTime) >= 0.0166667 else {
            return
        }
        lastDispatchTime = now
        
        let currentMode = mode
        let boundsSize = bounds
        
        // Phase 1 & 4: Dispatch TCP network call off Main Thread to background queue + High-precision Telemetry
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let timestamp = CACurrentMediaTime()
            os_log("Touch detected at %.6f -> Sent over TCP", log: logger, type: .info, timestamp)
            
            if currentMode == .trackpadRelative {
                if translation != .zero {
                    self?.onRelativeMove?(Float(translation.x), Float(translation.y))
                }
            } else if currentMode == .directTouchAbsolute {
                let normX = max(0.0, min(1.0, Float(location.x / boundsSize.width)))
                let normY = max(0.0, min(1.0, Float(location.y / boundsSize.height)))
                self?.onAbsoluteMove?(normX, normY)
            }
        }
    }
    
    @objc private func handleScrollPan(_ sender: UIPanGestureRecognizer) {
        onUserInteraction?()
        let translation = sender.translation(in: self)
        if translation != .zero {
            sender.setTranslation(.zero, in: self)
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                self?.onScroll?(Float(translation.x), Float(translation.y))
            }
        }
    }
    
    @objc private func handleLeftTap(_ sender: UITapGestureRecognizer) {
        onUserInteraction?()
        let location = sender.location(in: self)
        let boundsSize = bounds
        let currentMode = mode
        
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            if currentMode == .directTouchAbsolute {
                let normX = max(0.0, min(1.0, Float(location.x / boundsSize.width)))
                let normY = max(0.0, min(1.0, Float(location.y / boundsSize.height)))
                self?.onAbsoluteMove?(normX, normY)
            }
            self?.onMouseButton?(.left, .down)
            Thread.sleep(forTimeInterval: 0.05)
            self?.onMouseButton?(.left, .up)
        }
    }
    
    @objc private func handleRightTap(_ sender: UITapGestureRecognizer) {
        onUserInteraction?()
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.onMouseButton?(.right, .down)
            Thread.sleep(forTimeInterval: 0.05)
            self?.onMouseButton?(.right, .up)
        }
    }
}
#endif

// MARK: - macOS Input Injector (Quartz Event Services)

#if os(macOS)
public struct MacInputInjector {
    private static var virtualCursorPos: CGPoint?
    private static var lastEventTime: Date?
    
    public static func checkAccessibilityPermissions() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            logPrint("⚠️ macOS Input Warning: Accessibility permission NOT granted!")
        }
        return trusted
    }
    
    public static func injectRelativeMove(dx: Float, dy: Float) {
        _ = checkAccessibilityPermissions()
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let now = Date()
        
        if let lastTime = lastEventTime, now.timeIntervalSince(lastTime) < 0.2, let currentVirtual = virtualCursorPos {
            virtualCursorPos = currentVirtual
        } else {
            virtualCursorPos = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        }
        lastEventTime = now
        
        var current = virtualCursorPos ?? .zero
        current.x = max(0, min(bounds.width, current.x + CGFloat(dx)))
        current.y = max(0, min(bounds.height, current.y + CGFloat(dy)))
        virtualCursorPos = current
        
        let timestamp = CACurrentMediaTime()
        os_log("Input received at %.6f -> CGEvent injected", log: logger, type: .info, timestamp)
        
        let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: current, mouseButton: .left)
        moveEvent?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        moveEvent?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        moveEvent?.post(tap: .cghidEventTap)
    }
    
    public static func injectAbsoluteMove(normalizedX: Float, normalizedY: Float, screenWidth: CGFloat, screenHeight: CGFloat) {
        _ = checkAccessibilityPermissions()
        let currentPos = virtualCursorPos ?? (CGEvent(source: nil)?.location ?? .zero)
        
        let targetX = max(0, min(screenWidth, CGFloat(normalizedX) * screenWidth))
        let targetY: CGFloat
        if normalizedY <= 0.01 {
            targetY = -20
        } else {
            targetY = max(0, min(screenHeight, CGFloat(normalizedY) * screenHeight))
        }
        
        let targetPoint = CGPoint(x: targetX, y: targetY)
        virtualCursorPos = targetPoint
        lastEventTime = Date()
        
        let deltaX = targetX - currentPos.x
        let deltaY = targetY - currentPos.y
        
        let timestamp = CACurrentMediaTime()
        os_log("Input received at %.6f -> CGEvent injected", log: logger, type: .info, timestamp)
        
        let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: targetPoint, mouseButton: .left)
        moveEvent?.setIntegerValueField(.mouseEventDeltaX, value: Int64(deltaX))
        moveEvent?.setIntegerValueField(.mouseEventDeltaY, value: Int64(deltaY))
        moveEvent?.post(tap: .cghidEventTap)
    }
    
    public static func injectMouseButton(button: MouseButtonType, state: MouseButtonState) {
        _ = checkAccessibilityPermissions()
        let currentPos = CGEvent(source: nil)?.location ?? .zero
        let eventType: CGEventType
        let cgButton: CGMouseButton
        
        switch (button, state) {
        case (.left, .down):
            eventType = .leftMouseDown
            cgButton = .left
        case (.left, .up):
            eventType = .leftMouseUp
            cgButton = .left
        case (.right, .down):
            eventType = .rightMouseDown
            cgButton = .right
        case (.right, .up):
            eventType = .rightMouseUp
            cgButton = .right
        case (.middle, .down):
            eventType = .otherMouseDown
            cgButton = .center
        case (.middle, .up):
            eventType = .otherMouseUp
            cgButton = .center
        }
        
        let timestamp = CACurrentMediaTime()
        os_log("Input received at %.6f -> CGEvent injected", log: logger, type: .info, timestamp)
        
        let mouseEvent = CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: currentPos, mouseButton: cgButton)
        mouseEvent?.post(tap: .cghidEventTap)
    }
    
    public static func injectScroll(scrollDx: Float, scrollDy: Float) {
        _ = checkAccessibilityPermissions()
        let timestamp = CACurrentMediaTime()
        os_log("Input received at %.6f -> CGEvent injected", log: logger, type: .info, timestamp)
        
        let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(scrollDy), wheel2: Int32(scrollDx), wheel3: 0)
        scrollEvent?.post(tap: .cghidEventTap)
    }
    
    public static func injectKeystroke(_ charStr: String) {
        _ = checkAccessibilityPermissions()
        let timestamp = CACurrentMediaTime()
        os_log("Input received at %.6f -> CGEvent injected", log: logger, type: .info, timestamp)
        
        if charStr == "\u{7F}" || charStr == "\u{08}" {
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true)
            keyDown?.post(tap: .cghidEventTap)
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: false)
            keyUp?.post(tap: .cghidEventTap)
            return
        }
        
        if charStr == "\n" || charStr == "\r" {
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true)
            keyDown?.post(tap: .cghidEventTap)
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false)
            keyUp?.post(tap: .cghidEventTap)
            return
        }
        
        if charStr == "\t" {
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true)
            keyDown?.post(tap: .cghidEventTap)
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: false)
            keyUp?.post(tap: .cghidEventTap)
            return
        }
        
        var utf16Chars = Array(charStr.utf16)
        guard !utf16Chars.isEmpty else { return }
        
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        keyDown?.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: &utf16Chars)
        keyDown?.post(tap: .cghidEventTap)
        
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        keyUp?.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: &utf16Chars)
        keyUp?.post(tap: .cghidEventTap)
    }
}
#endif
