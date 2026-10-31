import Foundation

/// Pairing tokens and screen frames must never follow an HTTP redirect off the LAN.
final class BridgeHTTP: NSObject, URLSessionTaskDelegate {
    static let shared = BridgeHTTP()
    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.httpMaximumConnectionsPerHost = 2
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
