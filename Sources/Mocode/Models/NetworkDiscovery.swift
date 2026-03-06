import Foundation
import Network
import UIKit

private struct DiscoveryCandidate: Hashable {
    let ip: String
    let name: String?
    let source: ServerSource
    let sshHost: String?
}

@MainActor
final class NetworkDiscovery: ObservableObject {
    @Published var servers: [DiscoveredServer] = []
    @Published var isScanning = false
    @Published var scanError: String?

    private var scanTask: Task<Void, Never>?
    private var activeScanID = UUID()

    func startScanning(apiKey: String) {
        stopScanning()
        let scanID = UUID()
        activeScanID = scanID

        servers = []
        scanError = nil
        isScanning = true

        if OnDeviceCodexFeature.isEnabled {
            servers.append(DiscoveredServer(
                id: "local",
                name: UIDevice.current.name,
                hostname: "127.0.0.1",
                port: nil,
                source: .local,
                hasCodexServer: true
            ))
        }
        #if targetEnvironment(simulator)
        if !OnDeviceCodexFeature.isEnabled {
            servers.append(DiscoveredServer(
                id: "simulator-host-loopback",
                name: "This Mac (localhost)",
                hostname: "127.0.0.1",
                port: 22,
                source: .manual,
                hasCodexServer: false
            ))
        }
        #endif

        scanTask = Task { await discoverTailscaleDevices(apiKey: apiKey, scanID: scanID) }
    }

    func stopScanning() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    // MARK: - Tailscale Cloud API Discovery

    private func discoverTailscaleDevices(apiKey: String, scanID: UUID) async {
        defer {
            if activeScanID == scanID {
                isScanning = false
            }
        }
        guard !Task.isCancelled else { return }

        let candidates: [DiscoveryCandidate]
        do {
            candidates = try await Self.fetchTailscaleDevices(apiKey: apiKey)
        } catch {
            guard !Task.isCancelled, activeScanID == scanID else { return }
            scanError = error.localizedDescription
            return
        }

        guard !Task.isCancelled, activeScanID == scanID else { return }

        for candidate in candidates.sorted(by: Self.candidateSortOrder) {
            let id = "\(candidate.source.rawString)-\(candidate.ip)"
            guard !servers.contains(where: { $0.id == id }) else { continue }
            servers.append(DiscoveredServer(
                id: id,
                name: candidate.name ?? candidate.ip,
                hostname: candidate.sshHost ?? candidate.ip,
                port: nil,
                source: candidate.source,
                hasCodexServer: false
            ))
        }
    }

    nonisolated private static func fetchTailscaleDevices(apiKey: String) async throws -> [DiscoveryCandidate] {
        guard let url = URL(string: "https://api.tailscale.com/api/v2/tailnet/-/devices?fields=default") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw NSError(domain: "Tailscale", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid API key"])
        }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "Tailscale", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Tailscale API error (\(http.statusCode))"])
        }

        return parseTailscaleAPIResponse(data: data)
    }

    nonisolated private static func parseTailscaleAPIResponse(data: Data) -> [DiscoveryCandidate] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [[String: Any]] else {
            return []
        }

        var candidates: [DiscoveryCandidate] = []
        for device in devices {
            let hostname = device["hostname"] as? String
            let name = device["name"] as? String  // MagicDNS FQDN
            let addresses = (device["addresses"] as? [String]) ?? []

            // Use the MagicDNS name (e.g. "mac.tail1234.ts.net") as sshHost
            let sshHost = cleanedDNSName(name)
            let displayName = cleanedHostName(hostname) ?? sshHost

            guard let ipv4 = addresses.first(where: { isIPv4Address($0) }) else { continue }
            candidates.append(
                DiscoveryCandidate(
                    ip: ipv4,
                    name: displayName,
                    source: .tailscale,
                    sshHost: sshHost
                )
            )
        }
        return candidates
    }

    // MARK: - Helpers

    nonisolated private static func candidateSortOrder(lhs: DiscoveryCandidate, rhs: DiscoveryCandidate) -> Bool {
        let leftName = lhs.name ?? lhs.ip
        let rightName = rhs.name ?? rhs.ip
        return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
    }

    nonisolated private static func cleanedHostName(_ value: String?) -> String? {
        guard var value, !value.isEmpty else { return nil }
        if value.hasSuffix(".") {
            value.removeLast()
        }
        if value.hasSuffix(".local") {
            value = String(value.dropLast(6))
        }
        return value.isEmpty ? nil : value
    }

    nonisolated private static func cleanedDNSName(_ value: String?) -> String? {
        guard var value, !value.isEmpty else { return nil }
        if value.hasSuffix(".") {
            value.removeLast()
        }
        return value.isEmpty ? nil : value.lowercased()
    }

    nonisolated private static func isIPv4Address(_ value: String) -> Bool {
        var addr = in_addr()
        return value.withCString { cstr in
            inet_pton(AF_INET, cstr, &addr) == 1
        }
    }
}
