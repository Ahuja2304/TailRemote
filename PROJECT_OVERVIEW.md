# TailRemote - Full Architecture & Technical Project Overview

**TailRemote** is a zero-dependency, ultra-low-latency remote desktop and touch-input control system designed for macOS (Host) and iOS (Client). It allows an iPhone to stream a Mac display at 60 FPS and control mouse cursor, clicks, scrolling, gestures, and unicode typing over a local TCP network.

---

## 🛠️ Tech Stack & Constraints

- **Language**: Swift 5.9+ (SwiftUI, AppKit, UIKit)
- **Dependencies**: **Zero Third-Party Libraries** (Apple Native Frameworks Only)
- **Frameworks Used**:
  - `Network.framework` (Low-latency TCP socket communication with custom protocol framer)
  - `ScreenCaptureKit` (Hardware-accelerated macOS display capture)
  - `VideoToolbox` (H.264 hardware encoding & zero-copy NAL unit extraction)
  - `AVFoundation` (`AVSampleBufferDisplayLayer` hardware video decoding)
  - `Quartz Event Services` (`CGEvent` synthetic HID input injection)
  - `SwiftUI` (Menu Bar Extra interface & iOS Client Workspace UI)

---

## 🏗️ System Architecture & Component Breakdown

```
 ┌────────────────────────────────────────────────────────┐
 │                      iPhone Client                     │
 │  ┌──────────────────────────────────────────────────┐  │
 │  │        iPhoneClientWorkspaceView (SwiftUI)       │  │
 │  │ ┌──────────────────────┐ ┌─────────────────────┐ │  │
 │  │ │AVSampleBufferDisplay │ │TailRemoteGestureView│ │  │
 │  │ └──────────────────────┘ └─────────────────────┘ │  │
 │  └──────────────────────────────────────────────────┘  │
 │                           │                            │
 │            ClientConnectionManager (TCP)               │
 └───────────────────────────┼────────────────────────────┘
                             │  TailRemoteProtocol (TCP :8088)
 ┌───────────────────────────┼────────────────────────────┐
 │            MacHostServer / NWListener                  │
 │                           │                            │
 │ ┌─────────────────────────┴──────────────────────────┐ │
 │ │                    MacHostSession                  │ │
 │ │  ┌───────────────────────┐ ┌────────────────────┐ │ │
 │ │  │ MacHostVideoPipeline  │ │  MacInputInjector  │ │ │
 │ │  │  (ScreenCaptureKit)   │ │  (Quartz CGEvent)  │ │ │
 │ │  └───────────────────────┘ └────────────────────┘ │ │
 │ └────────────────────────────────────────────────────┘ │
 │                                                        │
 │        TailRemoteHostApp (MenuBarExtra & NSApp)       │
 └────────────────────────────────────────────────────────┘
```

---

## 📡 1. Custom Network Protocol (`TailRemoteProtocol.swift`)

TailRemote implements a custom 6-byte big-endian binary framing protocol over TCP (`Network.framework`):

### Protocol Framing Structure
- **Byte 0**: `ChannelID` (`0x00` Control, `0x01` Input, `0x02` Video, `0x03` File Transfer)
- **Byte 1**: `MessageType` (`0x01` RequestIDR, `0x10` PointerMoveRel, `0x11` PointerMoveAbs, `0x12` MouseButton, `0x13` Scroll, `0x14` KeyStroke, `0x20` FormatDesc, `0x21` Keyframe, `0x22` P-Frame)
- **Bytes 2–5**: `PayloadLength` (UInt32 Big-Endian)

### Low-Latency Network Socket Tuning
- **`TCP_NODELAY` (`noDelay = true`)**: Enabled on both Host listener and Client sockets to disable Nagle's packet coalescing algorithm, ensuring touch events and video frames are transmitted instantly with zero socket buffering lag.

---

## 🎥 2. Real-Time Video Streaming Pipeline

### Host Capture & H.264 Encoding (`MacHostVideoPipeline.swift`)
- **Screen Capture**: Uses macOS `ScreenCaptureKit` at 60 FPS target.
- **Resolution Scaling**: Automatically scales display bounds to a maximum target resolution of **1920x1080** (maintaining aspect ratio). This reduces bandwidth by ~70% compared to raw 3.5K Retina capture.
- **Minimal Queue Depth**: `config.queueDepth = 3` to eliminate frame accumulation latency.
- **VideoToolbox Compression**:
  - Codec: `H.264` (`kCMVideoCodecType_H264`)
  - Mode: Real-time (`kVTCompressionPropertyKey_RealTime = true`)
  - Profile: Main Auto Level, `kVTCompressionPropertyKey_AllowFrameReordering = false`
  - Bitrate: Target **8 Mbps** (`kVTCompressionPropertyKey_AverageBitRate = 8_000_000`)
  - Entropy Mode: `kVTH264EntropyMode_CAVLC` (ultra-fast CAVLC hardware decoding on iOS)

### Client Hardware Decoding & Auto-Recovery (`iPhoneClientVideoDecoder.swift`)
- Uses `AVSampleBufferDisplayLayer` for zero-copy hardware rendering.
- **KVO Layer Monitoring**: Observes `displayLayer.status`. If an interruption error occurs (`.failed` / `-11847`), the decoder automatically flushes the layer (`displayLayer.flush()`), resets format description state, and transmits a Channel 0 `RequestIDR` packet to force a fresh keyframe + SPS/PPS payload from the Mac Host.

---

## 🖱️ 3. Input Translation & HID Engine (`InputTranslator.swift`)

### iOS Touch & Trackpad Gestures (`TrackpadUIView`)
- **1-Finger Pan**: Relative cursor movement (`mode == .trackpadRelative`) or absolute touch position (`mode == .directTouchAbsolute`).
- **2-Finger Pan**: Vertical/Horizontal scrolling (`onScroll`).
- **1-Finger Tap**: Left mouse click (`onMouseButton(.left, .down/.up)`).
- **2-Finger Tap**: Right mouse click (`onMouseButton(.right, .down/.up)`).

### macOS Synthetic Input Injection (`MacInputInjector`)
- **High-Precision Virtual Cursor Position (`virtualCursorPos`)**: Solved the classic macOS cursor freeze bug. Instead of re-reading Quartz's `CGEvent(source: nil)?.location` on every fast move event (which returns stale coordinates during rapid stream bursts), `MacInputInjector` maintains a high-precision `virtualCursorPos` in memory, accumulating `dx/dy` deltas and re-syncing from hardware location only when idle (>200ms).
- **Top Menu Bar Overdrive**: Absolute move events with `normalizedY <= 0.01` map `targetY = -20` to reveal the auto-hidden macOS Menu Bar.
- **Unicode Keystroke Injection (`injectKeystroke`)**: Uses `CGEventKeyboardSetUnicodeString` for full UTF-16 character typing (letters, numbers, symbols, spaces, emojis) alongside keycode mapping for Delete (`51`), Return (`36`), and Tab (`48`).

---

## 💻 4. macOS Menu Bar Server App (`MacHostApp.swift`)

- **Native MenuBarExtra Interface**: Built using SwiftUI `@main App` with `MenuBarExtra("TailRemote", systemImage: "antenna.radiowaves.left.and.right")` using `.menuBarExtraStyle(.window)`.
- **Menu Bar Accessory Agent**: `MacHostAppDelegate` enforces `NSApp.setActivationPolicy(.accessory)` and `INFOPLIST_KEY_LSUIElement = YES` so the app runs cleanly in the macOS status bar without a Dock icon.
- **Elevated Clamshell Mode (`PowerManager.swift`)**: Singleton managing lid-close sleep prevention via elevated AppleScript (`pmset disablesleep 1` / `pmset disablesleep 0`). AppleScript calls run asynchronously off the main thread to prevent blocking network listeners.
- **Dropdown Window (`TailRemoteMenuBarView.swift`)**: 260px wide dropdown menu displaying:
  - Active server indicator (green/red dot) & host IP/port (`Quintessa.local:8088`).
  - **Start/Stop Server** button.
  - **Prevent Lid-Close Sleep** switch.
  - **Quit TailRemote Host** (`Cmd+Q`) button with automatic clamshell assertion cleanup.

---

## 📱 5. iOS Landscape Workspace & Control Panel UI

- **Full-Bleed Landscape Stream**: `iPhoneClientWorkspaceView` renders `AVSampleBufferDisplayLayer` full-bleed in landscape.
- **Glassmorphic Floating Toolbar**: Auto-hiding top bar containing:
  - Latency badge (`ms`) & connection indicator.
  - Input mode switcher (Trackpad / Direct Touch).
  - Directory List / File Transfer panel trigger (`folder`).
  - Refresh Keyframe button (`arrow.clockwise.circle`).
  - Virtual Keyboard trigger (`keyboard`).
  - Control Panel toggle button (`sidebar.right`).
- **Compact Right-Side Control Panel (`ClientControlPanelView.swift`)**:
  - Designed for 16:9 / 16:10 letterboxed dead space.
  - Features a strict **48pt fixed width frame** to prevent full-screen expansion.
  - Includes Space navigation buttons, modifier key toggles (`⌘`, `⌥`, `⌃`, `⇧`), and a low-bandwidth performance switch.
  - Protected by `.allowsHitTesting(state.isControlPanelVisible)` so touches pass 100% freely to the trackpad stream when hidden.

---

## 📑 File Structure Map

```text
TailRemote/
├── Package.swift                                # SPM Manifest
├── TailRemote.xcodeproj/                        # Xcode Project File
└── Sources/
    ├── TailRemote/                              # Core & iOS Shared Library
    │   ├── TailRemoteProtocol.swift             # 6-Byte TCP Framing Protocol
    │   ├── InputTranslator.swift                # Gestures & MacInputInjector (Quartz HID)
    │   ├── ClientConnectionManager.swift        # iOS TCP Connection & Socket Management
    │   ├── iPhoneClientVideoDecoder.swift       # AVSampleBufferDisplayLayer Decoder
    │   ├── iPhoneClientWorkspaceView.swift       # iOS Landscape UI & Glassmorphic Overlay
    │   ├── ClientControlPanelView.swift         # Compact 48pt Right-Side Control Panel
    │   ├── MacHostVideoPipeline.swift           # ScreenCaptureKit & VideoToolbox Pipeline
    │   ├── FileBroker.swift                     # File Directory Transfer Manager
    │   └── SystemController.swift               # OS System Level Handlers
    ├── MacHost/                                 # macOS Menu Bar Executable Target
    │   ├── MacHostApp.swift                     # SwiftUI @main App & MacHostServer State
    │   ├── TailRemoteMenuBarView.swift          # MenuBarExtra 260pt Dropdown View
    │   └── PowerManager.swift                   # Elevated pmset Clamshell Mode Manager
    └── TailRemoteiOS/                           # iOS App Target
        └── TailRemoteiOSApp.swift               # iOS App Entry Point
```

---

## 🚀 How to Build & Run

### 1. Run Mac Host (Terminal / Xcode)
```bash
cd /Users/montero/.gemini/antigravity/scratch/TailRemote
swift run MacHost
```
- App appears in the macOS Menu Bar (`antenna.radiowaves.left.and.right`).
- Ensure Accessibility permission is enabled in **System Settings > Privacy & Security > Accessibility**.

### 2. Run iOS Client App (Xcode)
```bash
xcodebuild -project TailRemote.xcodeproj -scheme TailRemoteiOS -destination 'generic/platform=iOS Simulator' build
```
- Open **TailRemoteiOS** on an iPhone or iOS Simulator.
- Enter Mac Host address (e.g. `Quintessa.local:8088`) and tap **Connect**.
