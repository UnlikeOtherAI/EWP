import Foundation
import Network

struct Service: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
    let role: String
    let deviceID: String
    /// The human name the device publishes, when it has one.
    let givenName: String?
    let firmware: String?
}

/// One physical device, however many endpoints it advertises. A phone shows
/// up twice while it is sharing its screen; a person sees one device.
struct DiscoveredDevice: Identifiable, Equatable {
    let id: String
    let endpoints: [Service]

    var isKeyboard: Bool { endpoints.contains { $0.role == "keyboard" } }
    var roles: [String] { endpoints.map(\.role).sorted() }
    var givenName: String? { endpoints.compactMap(\.givenName).first { !$0.isEmpty } }
    var firmware: String? { endpoints.compactMap(\.firmware).first }

    /// The endpoint to talk to: a board has one, a phone answers on its app.
    var primary: Service? {
        endpoints.first { $0.role == "app" } ?? endpoints.first { $0.role == "keyboard" } ?? endpoints.first
    }

    var title: String {
        if let givenName, !givenName.isEmpty { return givenName }
        return primary?.name ?? id
    }
}

@MainActor
final class Discovery: NSObject, ObservableObject, @preconcurrency NetServiceDelegate {
    @Published var services: [Service] = []
    @Published private(set) var isSearching = false
    @Published var error: String?
    private var browser: NWBrowser?
    private var resolving: [NetService] = []

    /// Keyboards are the only discovered role a person acts on from home.
    var keyboards: [DiscoveredDevice] { devices.filter(\.isKeyboard) }

    /// Endpoints folded into the devices that host them, named devices first.
    var devices: [DiscoveredDevice] {
        Dictionary(grouping: services.filter { !$0.deviceID.isEmpty }, by: \.deviceID)
            .map { DiscoveredDevice(id: $0.key, endpoints: $0.value.sorted { $0.role < $1.role }) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Everything except this device, which has its own screen in the app.
    func others(excluding deviceID: String) -> [DiscoveredDevice] {
        devices.filter { $0.id != deviceID }
    }

    /// This device's own advertisement, once it has been seen on the network.
    /// Resolving ourselves proves a client on this Wi-Fi can reach us too.
    func own(deviceID: String) -> Service? {
        services.first { $0.deviceID == deviceID && $0.role == "app" }
    }

    func start() {
        guard browser == nil else { return }
        isSearching = true
        let browser = NWBrowser(for: .bonjour(type: "_mcp._tcp", domain: "local."), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.error = nil
                case .waiting(let error), .failed(let error):
                    self?.error = "Device discovery: \(error.localizedDescription)"
                    self?.isSearching = false
                case .cancelled: self?.isSearching = false
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                var names = Set<String>()
                for result in results {
                    guard case let .service(name, type, domain, _) = result.endpoint else { continue }
                    names.insert(name)
                    guard !self.resolving.contains(where: { $0.name == name }) else { continue }
                    let service = NetService(domain: domain, type: type, name: name)
                    service.delegate = self
                    self.resolving.append(service)
                    service.resolve(withTimeout: 5)
                }
                self.services.removeAll { !names.contains($0.name) }
                self.resolving.removeAll { !names.contains($0.name) }
                self.isSearching = self.services.count < names.count
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func restart() {
        browser?.cancel(); browser = nil
        for service in resolving { service.delegate = nil; service.stop() }
        resolving.removeAll(); services.removeAll(); error = nil
        start()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0,
              let url = URL(string: "http://\(host):\(sender.port)/mcp") else { return }
        let txt = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        func value(_ key: String) -> String? { txt[key].flatMap { String(data: $0, encoding: .utf8) } }
        let id = sender.name + ":" + String(sender.port)
        services.removeAll { $0.id == id }
        services.append(Service(id: id, name: sender.name, url: url,
                                role: value("role") ?? "mcp", deviceID: value("id") ?? "",
                                givenName: value("name"), firmware: value("fw")))
        isSearching = services.count < resolving.count
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 === sender }
        isSearching = services.count < resolving.count
    }
}
