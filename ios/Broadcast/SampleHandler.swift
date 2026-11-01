import CoreImage
import ImageIO
import ReplayKit
import UniformTypeIdentifiers

/// ReplayKit keeps this process alive while other apps are on screen. The
/// screen MCP lives here on the iOS device; no frames go through a computer.
final class SampleHandler: RPBroadcastSampleHandler {
    private let lock = NSLock()
    private let encodingQueue = DispatchQueue(label: "ewp.frames", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var frame: Data?
    private var received: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0
    private var running = false
    private var busy = false
    private var orientationValue: UInt32 = 1
    private var generation = 0
    @MainActor private var server: MCPServer?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        lock.lock(); running = true; lock.unlock()
        Task { @MainActor in
            do {
                let configuration = try Configuration.load()
                let tools = [
                    MCPTool(name: "get_status", description: "Check whether this device's screen broadcast has a recent frame."),
                    MCPTool(name: "get_screen", description: "Get the latest device screen, including other apps. Rejects frames older than five seconds."),
                    MCPTool(name: "stop_screen_sharing", description: "Stop this screen broadcast on the device.")
                ]
                let server = MCPServer(configuration: configuration, role: "screen", port: 7802, tools: tools) { [weak self] name, _ in
                    guard let self else { throw EWPError.message("Screen sharing has ended.") }
                    let (frame, live, orientation) = self.latest()
                    switch name {
                    case "get_status": return try MCPServer.text(["device_id": configuration.deviceID, "live": live, "sample_orientation": orientation])
                    case "get_screen":
                        guard live, let frame else { throw EWPError.message("No recent screen frame. Resume screen sharing on the device.") }
                        return [["type": "image", "data": frame.base64EncodedString(), "mimeType": "image/jpeg"]]
                    case "stop_screen_sharing":
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            self.finishBroadcastWithError(EWPError.message("Screen sharing stopped by your MCP client."))
                        }
                        return try MCPServer.text(["stopping": true])
                    default: throw EWPError.message("Unknown tool.")
                    }
                }
                self.server = server; server.start()
            } catch { finishBroadcastWithError(error) }
        }
    }

    private func latest() -> (Data?, Bool, UInt32) {
        lock.lock(); defer { lock.unlock() }
        return (frame, running && frame != nil && CACurrentMediaTime() - received <= 5, orientationValue)
    }

    override func broadcastPaused() {
        lock.lock(); running = false; frame = nil; received = 0; generation += 1; lock.unlock()
    }
    override func broadcastResumed() { lock.lock(); running = true; lock.unlock() }
    override func broadcastFinished() {
        lock.lock(); running = false; frame = nil; received = 0; generation += 1; lock.unlock()
        Task { @MainActor in server?.stop(); server = nil }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        let now = CACurrentMediaTime()
        guard running, !busy, now - lastFrame >= 0.5 else { lock.unlock(); return }
        busy = true; lastFrame = now
        let expectedGeneration = generation
        lock.unlock()
        let orientation = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                            attachmentModeOut: nil) as? NSNumber)?.uint32Value ?? 1
        encodingQueue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                var image = CIImage(cvPixelBuffer: pixelBuffer, options: [.applyOrientationProperty: false])
                if let orientation = CGImagePropertyOrientation(rawValue: orientation) { image = image.oriented(orientation) }
                let scale = min(1, 1280 / max(image.extent.width, image.extent.height))
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                var encoded: Data?
                if let cgImage = self.context.createCGImage(image, from: image.extent) {
                    let data = NSMutableData()
                    if let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
                        if CGImageDestinationFinalize(destination), data.length <= 512 * 1024 { encoded = data as Data }
                    }
                }
                self.lock.lock()
                if self.running, self.generation == expectedGeneration, let encoded { self.frame = encoded; self.received = CACurrentMediaTime(); self.orientationValue = orientation }
                self.busy = false
                self.lock.unlock()
            }
        }
    }
}
