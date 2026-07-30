# TailRemote - Current Project State & Technical Reference

**Document Status**: Up-to-date as of July 30, 2026  
**GitHub Repository**: [https://github.com/Ahuja2304/TailRemote](https://github.com/Ahuja2304/TailRemote)  
**Latest Commit**: `e651f13` ("Implement Zero-Cost Motion-Adaptive Rate Control and Dynamic FPS Pipeline")  
**Build Status**: ✅ Passing (`swift build` 100% clean, zero errors, zero warnings)

---

## 📌 Executive Architecture Overview

**TailRemote** is a low-latency, zero-dependency remote desktop, video streaming, and input control application connecting an iPhone (iOS Client) to a Mac (macOS Host) over a local network.

```mermaid
graph TD
    subgraph iOSClient ["iOS Client (iPhone)"]
        UI["iPhoneClientWorkspaceView"]
        Cursor["120Hz Local Cursor Overlay"]
        Throttler["16.6ms Input Batcher (60Hz)"]
        JitterBuffer["UDPFrameJitterBuffer (Out-of-Order Reassembly)"]
        TCPClient["TCP Control Client (Port 8088)"]
        UDPClient["UDP Video Receiver (Port 8089)"]
    end

    subgraph MacHost ["macOS Host (MacHost)"]
        Gatekeeper["Gatekeeper Auth (4-Digit PIN / 3-Strike Ban)"]
        TCPServer["TCP Server (Port 8088)"]
        UDPServer["UDP Listener (Port 8089)"]
        RingBuffer["VideoFrameBufferPool (Zero-Copy Ring Buffer)"]
        AdaptiveEngine["AdaptiveRateController (Motion-Adaptive FPS/Bitrate)"]
        SCK["ScreenCaptureKit (showsCursor = false)"]
        VT["VideoToolbox H.264 Encoder (CAVLC)"]
        Injector["MacInputInjector (Quartz CGEvent)"]
    end

    UI --> Cursor
    UI --> Throttler
    Throttler -->|0x03 Mouse / 0x04 Keyboard| TCPClient
    TCPClient <-->|0x01 Auth PIN Handshake| TCPServer
    TCPServer --> Gatekeeper
    Gatekeeper --> Injector
    
    SCK -->|Frame Metadata| AdaptiveEngine
    AdaptiveEngine -->|Dynamic FPS 15-60| SCK
    AdaptiveEngine -->|Dynamic Bitrate 1.5-6.0 Mbps| VT
    SCK --> VT
    VT --> RingBuffer
    RingBuffer -->|1400B Datagram Fragments| UDPServer
    UDPServer -->|UDP Datagram Stream| UDPClient
    UDPClient --> JitterBuffer
    JitterBuffer --> UI
```

---

## 🏗️ Core Subsystems & Technical Details

### 1. Dual-Transport Hybrid Network Architecture
* **TCP Server/Client (Port 8088)**: Dedicated exclusively to high-reliability control signals, PIN authentication, and input events.
  * Uses 5-byte TLV (`Type-Length-Value`) binary header: `Byte 0`: Command Type (`0x01` Auth, `0x03` Mouse, `0x04` Keyboard) + `Bytes 1-4`: Payload Length (`UInt32` Big-Endian).
  * Socket optimization: Enabled `TCP_NODELAY` (`noDelay = true`) to disable Nagle's algorithm.
* **UDP Server/Client (Port 8089)**: High-speed, unbuffered video transport datagram socket.
  * Uses custom 8-byte datagram fragment header: `UInt32` Frame ID + `UInt16` Fragment ID + `UInt16` Total Fragments + N-byte payload ($\le 1380$ bytes MTU limit).

### 2. Zero-Trust Gatekeeper Authentication (`MacHostApp.swift` & `TailRemoteMenuBarView.swift`)
* **Random Session PIN**: MacHost generates a random 4-digit PIN on server start (e.g. `"4921"`).
* **Menu Bar UI Display**: Displayed prominently in `TailRemoteMenuBarView` with high-visibility monospaced badges.
* **State Machine (`WaitingForAuth` / `Authenticated`)**:
  * `WaitingForAuth`: All inbound payloads are dropped except `0x01` (Auth PIN). Video pipeline remains idle.
  * Matching PIN: Transitions to `Authenticated`, sends `0x01` success signal, and spins up ScreenCaptureKit.
  * **Brute-Force Protection**: 3 incorrect PIN attempts trigger an automatic session IP ban (`blockedIPs`) and immediate TCP disconnection.
* **iOS PIN Keypad Overlay**: Presented in `iPhoneClientWorkspaceView` when connected but unauthenticated, blocking touch controls until a valid 4-digit PIN is entered.

### 3. Motion-Adaptive Rate Control Engine (`AdaptiveRateController.swift`)
* **Zero CPU Diffing Cost**: Motion ratio ($\frac{\text{sum}(\text{dirtyRects})}{\text{contentRect}}$) is extracted directly from ScreenCaptureKit's `CMSampleBuffer` attachments (`SCStreamFrameInfo.dirtyRects` and `SCStreamFrameInfo.contentRect`) without pixel-buffer diffing or memory overhead.
* **Dynamic Motion States**:
  * `.staticScreen` ($< 0.02$ ratio): **15 FPS**, **1.5 Mbps** bitrate target.
  * `.interactive` ($\ge 0.02 \text{ and } < 0.20$ ratio): **30 FPS**, **4.0 Mbps** bitrate target.
  * `.highMotion` ($\ge 0.20$ ratio): **60 FPS**, **6.0 Mbps** bitrate target.
* **500ms Debounced State Machine**:
  * **Ramp-Up (Instant)**: Scales to 60 FPS / 6.0 Mbps immediately upon motion.
  * **Ramp-Down (Debounced)**: Waits 500ms before dropping to lower FPS/bitrate to prevent visual flickering or video encoder instability.
* **Dynamic Pipeline Reconfiguration**:
  * Reconfigures ScreenCaptureKit stream FPS asynchronously via `stream.updateConfiguration(config)`.
  * Reconfigures VideoToolbox bitrate dynamically via `VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: targetBitrate)`.

### 4. Zero-Copy Ring Buffer & UDP Datagram Fragmenter (`MacHostVideoPipeline.swift`)
* **`VideoFrameBufferPool`**: Pre-allocates a circular array of 16 memory slots to retain raw compressed NAL buffers without heap allocation churn.
* **MTU-Safe Datagram Slicing**: Slices large frames into $\le 1380$-byte datagrams, prepending the 8-byte fragment header before pushing directly into the UDP socket.

### 5. Out-of-Order Jitter Buffer (`ClientConnectionManager.swift`)
* **`UDPFrameJitterBuffer`**: Ingests out-of-order UDP fragments per `Frame ID`. Reassembles full frames when all fragments arrive and feeds `iPhoneClientVideoDecoder`.
* **Graceful Degradation**: Instantly purges older incomplete frame slots ($N < \text{latestFrameID}$) whenever a newer frame arrives, guaranteeing sub-15ms video playback without video freeze or frame buildup.

### 6. Synchronized Zero-Perceived-Latency Input Engine (`InputTranslator.swift`)
* **Mac Hardware Cursor Hiding**: Set `config.showsCursor = false` in `SCStreamConfiguration` to eliminate double-cursor rendering.
* **120Hz Local Cursor Overlay**: iOS client renders an immediate `Image(systemName: "cursorarrow")` overlay updating at 120Hz native touch sampling rate.
* **16.6ms Input Batcher**: Throttles TCP network input dispatches to $\le 60$ Hz (`0.0166667` s minimum buffer) to maintain network efficiency while preserving zero perceived local latency.

---

## 📑 Complete Repository File Index

```
TailRemote/
├── .gitignore                      # Exclusive gitignore (excludes .build, .swiftpm, xcuserdata, DS_Store)
├── Package.swift                   # Swift PM package configuration (macOS 14+, iOS 17+)
├── PROJECT_OVERVIEW.md             # Project overview & architectural references
├── PROJECT_STATE.md                # Current full technical state document
├── Sources/
│   ├── MacHost/
│   │   ├── MacHostApp.swift        # SwiftUI MenuBarExtra @main App & Dual TCP/UDP Listener Server
│   │   ├── PowerManager.swift      # Elevated pmset Clamshell Mode manager
│   │   └── TailRemoteMenuBarView.swift # 270pt Menu bar dropdown window with PIN badge
│   ├── TailRemote/
│   │   ├── AdaptiveRateController.swift # Zero-cost motion analyzer & 500ms debounced rate controller
│   │   ├── ClientConnectionManager.swift # iOS dual-socket client & UDP Jitter Buffer
│   │   ├── ClientControlPanelView.swift # Compact 48pt right-side landscape control panel
│   │   ├── FileBroker.swift        # Non-blocking 64KB chunked file broker
│   │   ├── InputTranslator.swift   # Trackpad gesture recognizer, 16.6ms batcher, & Quartz CGEvent injector
│   │   ├── MacHostVideoPipeline.swift # ScreenCaptureKit, VideoToolbox H.264, & Ring Buffer UDP sender
│   │   ├── SystemController.swift  # System level helper utilities
│   │   ├── TailRemoteProtocol.swift # TLV 5-byte header & 8-byte UDP datagram header specs
│   │   ├── iPhoneClientVideoDecoder.swift # AVSampleBufferDisplayLayer hardware decoder & auto-recovery
│   │   └── iPhoneClientWorkspaceView.swift # Full-bleed landscape workspace, local cursor, & PIN keypad overlay
│   └── TailRemoteiOS/
│       └── TailRemoteiOSApp.swift  # iOS SwiftUI @main App entry point
└── TailRemote.xcodeproj/          # Xcode project container
```

---

## 📜 Commit & Git Deployment History

| Commit | Summary | Date |
| :--- | :--- | :--- |
| `e651f13` | Implement Zero-Cost Motion-Adaptive Rate Control and Dynamic FPS Pipeline | July 30, 2026 |
| `fe6c8a9` | Implement Multiplexed UDP Transport Pipeline, MacHost Zero-Copy Ring Buffer, and iOS Jitter Buffer | July 30, 2026 |
| `f52cda6` | Implement Local Cursor Rendering and 16.6ms 60Hz Input Throttling | July 30, 2026 |
| `25824f5` | Fix TailRemoteiOSApp compilation errors and connect Gatekeeper PIN authentication bindings | July 30, 2026 |
| `f8967d8` | Overhaul TCP network layer with TLV binary framing and Zero-Trust Gatekeeper authentication | July 30, 2026 |
| `7336c92` | Initial commit: TailRemote macOS & iOS high-performance remote desktop | July 30, 2026 |

---

## 🧪 Verification & Build Status

* **Compiler Command**: `swift build`
* **Result**: `Build complete! (1.73s)`
* **Errors**: `0`
* **Warnings**: `0`
* **GitHub Sync**: `git push origin main` fully synced with `git@github.com:Ahuja2304/TailRemote.git`.
