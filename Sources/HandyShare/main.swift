import AppKit
import Foundation
import SwiftUI

struct Printer: Identifiable, Hashable {
    let id: String
    let name: String
    let location: String
    let source: Source
    let status: String
    let uri: String?

    enum Source: String {
        case cups = "CUPS"
        case airPrint = "AirPrint"
    }
}

@MainActor
final class PrinterModel: NSObject, ObservableObject {
    @Published private(set) var printers: [Printer] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published var errorMessage: String?

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []

    override init() {
        super.init()
        browser.delegate = self
        refresh()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil

        browser.stop()
        services.removeAll()
        browser.searchForServices(ofType: "_ipp._tcp.", inDomain: "local.")

        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                PrinterModel.loadCUPSPrinters()
            }.value
            guard let self else { return }
            self.mergeCUPS(result)
            self.isRefreshing = false
            self.lastRefresh = Date()
        }
    }

    func printTestPage(to printer: Printer) {
        guard printer.source == .cups else {
            errorMessage = "AirPrint-Gerät zuerst als CUPS-Drucker hinzufügen."
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lp")
        process.arguments = ["-d", printer.name, "/System/Library/CoreServices/DefaultDesktop.jpg"]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                errorMessage = "Testdruck konnte nicht gestartet werden."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func mergeCUPS(_ cups: [Printer]) {
        let airPrint = printers.filter { $0.source == .airPrint }
        printers = cups + airPrint.filter { candidate in
            !cups.contains { $0.location == candidate.location }
        }
    }

    nonisolated private static func loadCUPSPrinters() -> [Printer] {
        let output = run("/usr/bin/lpstat", arguments: ["-v"])
        let statuses = run("/usr/bin/lpstat", arguments: ["-a"])
            .split(separator: "\n")
            .reduce(into: [String: String]()) { map, line in
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { return }
                map[String(parts[0])] = String(parts[1])
            }

        return output.split(separator: "\n").compactMap { line in
            let text = String(line)
            guard text.hasPrefix("device for "), let colon = text.firstIndex(of: ":") else { return nil }
            let nameStart = text.index(text.startIndex, offsetBy: 11)
            let name = String(text[nameStart..<colon])
            let uri = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            return Printer(
                id: "cups-\(name)",
                name: name,
                location: uri,
                source: .cups,
                status: statuses[name] ?? "Bereit",
                uri: uri
            )
        }
    }

    nonisolated private static func run(_ executable: String, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

extension PrinterModel: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor [weak self] in
            guard let self, !self.services.contains(where: { $0.name == service.name && $0.domain == service.domain }) else { return }
            self.services.append(service)
            service.delegate = self
            service.resolve(withTimeout: 3)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let printer = Printer(
                id: "airprint-\(sender.name)-\(sender.domain)",
                name: sender.name,
                location: "\(sender.hostName ?? sender.domain):\(sender.port)",
                source: .airPrint,
                status: "Im Netzwerk gefunden",
                uri: nil
            )
            guard !self.printers.contains(where: { $0.id == printer.id }) else { return }
            self.printers.append(printer)
            self.printers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}

struct MenuView: View {
    @ObservedObject var model: PrinterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.printers.isEmpty {
                emptyState
            } else {
                ForEach(model.printers) { printer in
                    PrinterRow(printer: printer, model: model)
                }
            }
            Divider()
            footer
        }
        .frame(width: 340)
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Printquee").font(.headline)
                Text("Drucken ohne veraltete Lizenzlogik")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "printer.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Keine Drucker gefunden")
                .font(.subheadline.weight(.medium))
            Text("CUPS und AirPrint werden automatisch durchsucht.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Text("\(model.printers.count) Gerät(e)")
                Spacer()
                Button("Beenden") { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                Text("Made with ♥ in Cologne by")
                Link("ekrem.eu", destination: URL(string: "https://ekrem.eu")!)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}

struct PrinterRow: View {
    let printer: Printer
    @ObservedObject var model: PrinterModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "printer")
                .frame(width: 22)
                .foregroundStyle(printer.source == .cups ? .blue : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(printer.name)
                    .lineLimit(1)
                Text("\(printer.source.rawValue) · \(printer.status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if printer.source == .cups {
                Button {
                    model.printTestPage(to: printer)
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.borderless)
                .help("Testseite drucken")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

@main
struct PrintqueeApp: App {
    @StateObject private var model = PrinterModel()

    var body: some Scene {
        MenuBarExtra("Printquee", systemImage: "printer.fill") {
            MenuView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
