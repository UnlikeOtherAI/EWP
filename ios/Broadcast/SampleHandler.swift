import CoreImage
import ImageIO
import ReplayKit
import UniformTypeIdentifiers

final class SampleHandler: RPBroadcastSampleHandler {
    private let lock = NSLock()
    private let encodingQueue = DispatchQueue(label: "ewp.frames", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let network = BridgeHTTP.shared.session
    private var configuration: Configuration?
    private var sessionID: String?
    private var busy = false
    private var running = false
    private var lastFrame: CFTimeInterval = 0
    private var nextSessionAttempt: CFTimeInterval = 0
    private var generation = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        do {
            configuration = try Configuration.load()
            lock.lock(); running = true; lock.unlock()
            createSession()
        } catch { finishBroadcastWithError(error) }
    }

    private func createSession() {
        guard let configuration else { return }
        lock.lock()
        guard running, !busy else { lock.unlock(); return }
        let now = CACurrentMediaTime()
        guard now >= nextSessionAttempt else { lock.unlock(); return }
        // A refused connection can fail immediately. Incoming video callbacks
        // must not turn an offline bridge into a retry at the display frame rate.
        nextSessionAttempt = now + 2
        busy = true
        let expectedGeneration = generation
        lock.unlock()
        let body = try? JSONSerialization.data(withJSONObject: ["device_id": configuration.deviceID])
        network.dataTask(with: configuration.request("sessions", method: "POST", body: body)) { [weak self] data, response, error in
            guard let self else { return }
            var key: String?
            if (response as? HTTPURLResponse)?.statusCode == 201, let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                key = json["session_id"] as? String
            }
            self.lock.lock()
            let current = self.running && self.generation == expectedGeneration
            if current { self.sessionID = key }
            self.busy = false
            self.lock.unlock()
            if !current, let key { self.deleteSession(key) }
            if current, (response as? HTTPURLResponse)?.statusCode == 401 {
                self.finishBroadcastWithError(EWPError.message("Bridge token rejected. Reconnect in EWP."))
            }
            // On a network failure, the next incoming frame retries session creation.
        }.resume()
    }

    override func broadcastPaused() { stopSession(keepRunning: false) }
    override func broadcastResumed() {
        lock.lock(); running = true; lock.unlock()
        createSession()
    }
    override func broadcastFinished() { stopSession(keepRunning: false) }

    private func stopSession(keepRunning: Bool) {
        lock.lock()
        running = keepRunning
        generation += 1
        let previous = sessionID
        sessionID = nil
        lock.unlock()
        if let previous { deleteSession(previous) }
    }

    private func deleteSession(_ key: String) {
        guard let configuration else { return }
        network.dataTask(with: configuration.request("sessions/\(key)", method: "DELETE")).resume()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        guard running, !busy else { lock.unlock(); return }
        guard let key = sessionID else { lock.unlock(); createSession(); return }
        let now = CACurrentMediaTime()
        guard now - lastFrame >= 0.5 else { lock.unlock(); return }
        busy = true; lastFrame = now
        let expectedGeneration = generation
        lock.unlock()
        let orientation = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                            attachmentModeOut: nil) as? NSNumber)?.intValue ?? 1
        encodingQueue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                let image = CIImage(cvPixelBuffer: pixelBuffer)
                let scale = min(1, 1280 / max(image.extent.width, image.extent.height))
                let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                guard let cgImage = self.context.createCGImage(scaled, from: scaled.extent),
                      let configuration = self.configuration else { self.clearBusy(); return }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                    self.clearBusy(); return
                }
                CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
                guard CGImageDestinationFinalize(destination), data.length <= 512 * 1024 else { self.clearBusy(); return }
                self.lock.lock()
                let current = self.running && self.generation == expectedGeneration && self.sessionID == key
                self.lock.unlock()
                guard current else { self.clearBusy(); return }
                var request = configuration.request("sessions/\(key)/frames", method: "POST", body: data as Data, contentType: "image/jpeg")
                request.setValue(String(orientation), forHTTPHeaderField: "X-Orientation")
                self.network.dataTask(with: request) { [weak self] _, response, _ in
                    guard let self else { return }
                    self.lock.lock()
                    if (response as? HTTPURLResponse)?.statusCode == 404, self.sessionID == key { self.sessionID = nil }
                    self.busy = false
                    self.lock.unlock()
                    if (response as? HTTPURLResponse)?.statusCode == 401 {
                        self.finishBroadcastWithError(EWPError.message("Bridge token rejected. Reconnect in EWP."))
                    }
                }.resume()
            }
        }
    }

    private func clearBusy() { lock.lock(); busy = false; lock.unlock() }
}
