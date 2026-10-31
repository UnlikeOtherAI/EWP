import Foundation
import Network

struct Service: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
    let bridge: Bool
}

@MainActor
final class Discovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published var services: [Service] = []
    @Published var error: String?
    private var browsers: [NetServiceBrowser] = []
    private var resolving: [NetService] = []

    func start() {
        guard browsers.isEmpty else { return }
        for type in ["_ewp._tcp.", "_ewpbridge._tcp."] {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browsers.append(browser)
            browser.searchForServices(ofType: type, inDomain: "local.")
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        resolving.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName,
              let url = URL(string: "http://\(host):\(sender.port)") else { return }
        let item = Service(id: sender.type + sender.name, name: sender.name, url: url,
                           bridge: sender.type == "_ewpbridge._tcp.")
        services.removeAll { $0.id == item.id }
        services.append(item)
        error = nil
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0.id == service.type + service.name }
        resolving.removeAll { $0 == service }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        error = "Discovery failed. Allow Local Network access in Settings, then reopen EWP."
    }
}
