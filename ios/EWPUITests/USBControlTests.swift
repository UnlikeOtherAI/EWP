import XCTest

/// Developer-only UI driver. Its mailbox is accessible through Apple's paired
/// device service, not an HTTP listener or a production app URL scheme.
@MainActor
final class USBControlTests: XCTestCase {
    private var app = XCUIApplication(bundleIdentifier: "com.unlikeotherai.ewp")
    private var bundle = "com.unlikeotherai.ewp"
    private var refs: [String: XCUIElement] = [:]
    private var snapshotID = ""
    private var snapshotDate = Date.distantPast

    func testUSBControl() throws {
        guard ProcessInfo.processInfo.environment["EWP_USB_CONTROL"] == "1" else {
            throw XCTSkip("Start explicitly with EWP_USB_CONTROL=1 for physical MCP control.")
        }
        continueAfterFailure = false
        executionTimeAllowance = 3600
        app.activate()
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EWPControl", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let requestURL = folder.appendingPathComponent("request.json")
        let responseURL = folder.appendingPathComponent("response.json")
        var processed = Set<String>()
        let deadline = Date().addingTimeInterval(3500)
        while Date() < deadline {
            guard let data = try? Data(contentsOf: requestURL), data.count <= 65536,
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = request["id"] as? String, UUID(uuidString: id) != nil else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                continue
            }
            // Consume before acting. Never repeat an action after a lost reply.
            try FileManager.default.removeItem(at: requestURL)
            guard !processed.contains(id) else { continue }
            processed.insert(id)
            var response: [String: Any] = ["id": id, "ok": true]
            do {
                guard let expires = request["expires"] as? Double,
                      expires > Date().timeIntervalSince1970,
                      expires <= Date().timeIntervalSince1970 + 125 else { throw ControlError.expired }
                let command = request["command"] as? String ?? ""
                if command == "stop" {
                    response["stopped"] = true
                } else if command == "snapshot" {
                    response["state"] = snapshot()
                } else if command == "screenshot" {
                    response["png"] = XCUIScreen.main.screenshot().pngRepresentation.base64EncodedString()
                } else if command == "activate" {
                    guard let bundle = request["bundle"] as? String,
                          ["com.unlikeotherai.ewp", "com.apple.Preferences"].contains(bundle) else {
                        throw ControlError.unsupported
                    }
                    app = XCUIApplication(bundleIdentifier: bundle)
                    self.bundle = bundle
                    app.activate()
                    response["state"] = snapshot()
                } else {
                    guard request["snapshot_id"] as? String == snapshotID,
                          Date().timeIntervalSince(snapshotDate) < 120,
                          let ref = request["ref"] as? String, let element = refs[ref],
                          element.exists else { throw ControlError.stale }
                    switch command {
                    case "tap":
                        guard element.isEnabled, element.isHittable else { throw ControlError.notHittable }
                        element.tap()
                    case "paste":
                        guard [.textField, .secureTextField, .textView].contains(element.elementType),
                              element.isHittable else { throw ControlError.notHittable }
                        // The host fills the device clipboard over the paired USB
                        // service. Only key names enter XCTest's activity log.
                        element.tap()
                        element.typeKey("a", modifierFlags: .command)
                        element.typeKey("v", modifierFlags: .command)
                    case "swipe":
                        switch request["direction"] as? String {
                        case "up": element.swipeUp()
                        case "down": element.swipeDown()
                        case "left": element.swipeLeft()
                        case "right": element.swipeRight()
                        default: throw ControlError.unsupported
                        }
                    default: throw ControlError.unsupported
                    }
                    response["state"] = snapshot()
                }
            } catch {
                response["ok"] = false
                response["error"] = String(describing: error)
            }
            try JSONSerialization.data(withJSONObject: response).write(to: responseURL, options: .atomic)
            if response["stopped"] as? Bool == true { return }
        }
    }

    private func snapshot() -> [String: Any] {
        refs = [:]
        snapshotID = UUID().uuidString
        snapshotDate = Date()
        var result: [[String: Any]] = []
        var roots = [app]
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.alerts.firstMatch.exists { roots.append(system) }
        for root in roots {
            guard let tree = try? root.snapshot() else { continue }
            var occurrences: [String: Int] = [:]
            func visit(_ node: XCUIElementSnapshot) {
                guard refs.count < 350 else { return }
                let key = "\(node.elementType.rawValue)|\(node.identifier)|\(node.label)"
                let occurrence = occurrences[key, default: 0]
                occurrences[key] = occurrence + 1
                if node.label.isEmpty && node.identifier.isEmpty &&
                    ![.textField, .secureTextField, .searchField, .scrollView, .table, .collectionView].contains(node.elementType) {
                    for child in node.children { visit(child) }
                    return
                }
                let element = root.descendants(matching: node.elementType)
                    .matching(NSPredicate(format: "identifier == %@ AND label == %@", node.identifier, node.label))
                    .element(boundBy: occurrence)
                let ref = "e\(refs.count)"
                refs[ref] = element
                let secure = node.elementType == .secureTextField
                result.append(["ref": ref, "type": node.elementType.rawValue,
                               "id": node.identifier, "label": node.label,
                               "value": secure ? "[redacted]" : (node.value as? String ?? ""),
                               "enabled": node.isEnabled,
                               "visible": !node.frame.isEmpty && node.frame.intersects(tree.frame)])
                for child in node.children { visit(child) }
            }
            for child in tree.children { visit(child) }
        }
        snapshotDate = Date()
        return ["snapshot_id": snapshotID, "bundle": bundle, "elements": result]
    }

    private enum ControlError: Error { case expired, stale, notHittable, unsupported }
}
