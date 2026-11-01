import Foundation
import Network

struct Service: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
    let role: String
}

@MainActor
final class Discovery: NSObject, ObservableObject, @preconcurrency NetServiceDelegate {
    @Published var services: [Service] = []
    @Published var error: String?
    private var browser: NWBrowser?
    private var resolving: [NetService] = []

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_mcp._tcp", domain: "local."), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.error = nil
                case .waiting(let error), .failed(let error): self?.error = "Device discovery: \(error.localizedDescription)"
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
        let role = txt["role"].flatMap { String(data: $0, encoding: .utf8) } ?? "mcp"
        let id = sender.name + ":" + String(sender.port)
        services.removeAll { $0.id == id }
        services.append(Service(id: id, name: sender.name, url: url, role: role))
    }
}
