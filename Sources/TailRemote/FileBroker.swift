import Foundation
import Network
import QuickLookThumbnailing

#if os(macOS)
import AppKit

// MARK: - Phase 5: FileBroker Actor (macOS Non-Blocking 64KB Chunking Actor)

public actor FileBroker {
    private let chunkSize: Int = 64 * 1024 // Strict 64KB chunking limit
    
    public init() {}
    
    // MARK: - Directory Listing
    
    public func listDirectory(at url: URL) throws -> [String] {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
        
        return contents.map { $0.lastPathComponent }
    }
    
    // MARK: - QLThumbnailGenerator Preview Generation
    
    public func generateThumbnail(for url: URL, size: CGSize = CGSize(width: 128, height: 128)) async throws -> Data {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 1.0, representationTypes: .thumbnail)
        let generator = QLThumbnailGenerator.shared
        
        return try await withCheckedThrowingContinuation { continuation in
            generator.generateBestRepresentation(for: request) { thumbnail, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let nsImage = thumbnail?.nsImage,
                      let tiffData = nsImage.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiffData),
                      let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                    return
                }
                
                continuation.resume(returning: jpegData)
            }
        }
    }
    
    // MARK: - Non-Blocking 64KB Chunked File Streaming
    
    public func streamFile(at url: URL, over connection: NWConnection) async throws {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {
            try? fileHandle.close()
        }
        
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? UInt64 ?? 0
        let fileName = url.lastPathComponent
        
        // 1. Send File Header Metadata (Channel 3, Message Type 0x32)
        var headerPayload = Data()
        if let nameData = fileName.data(using: .utf8) {
            var nameLenBE = UInt16(nameData.count).bigEndian
            withUnsafeBytes(of: &nameLenBE) { headerPayload.append(contentsOf: $0) }
            headerPayload.append(nameData)
            
            var sizeBE = fileSize.bigEndian
            withUnsafeBytes(of: &sizeBE) { headerPayload.append(contentsOf: $0) }
            
            let message = NWProtocolFramer.Message(type: .authPIN)
            let context = NWConnection.ContentContext(identifier: "FileHeader", metadata: [message])
            connection.send(content: headerPayload, contentContext: context, isComplete: true, completion: .idempotent)
        }
        
        // 2. Stream File Data in Strict 64KB Chunks with Task.yield()
        var offset: UInt64 = 0
        
        while offset < fileSize {
            try Task.checkCancellation()
            
            try fileHandle.seek(toOffset: offset)
            guard let chunk = try fileHandle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            
            let message = NWProtocolFramer.Message(type: .authPIN)
            let context = NWConnection.ContentContext(identifier: "FileChunk_\(offset)", metadata: [message])
            
            connection.send(content: chunk, contentContext: context, isComplete: true, completion: .idempotent)
            
            offset += UInt64(chunk.count)
            
            // Non-blocking continuation yield to keep main thread and video queue smooth
            await Task.yield()
        }
    }
}
#endif
