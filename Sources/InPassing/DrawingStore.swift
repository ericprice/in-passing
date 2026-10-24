import CoreGraphics
import AppKit
import InPassingCore
import SwiftUI

@MainActor final class DrawingStore: ObservableObject {
    @Published private(set) var traces: [WindowTrace] = []
    @Published var notice = ""
    private var unreadable = false
    private let folder: URL
    private var file: URL { folder.appendingPathComponent("drawing.json") }
    private struct Page: Codable { let traces: [WindowTrace] }

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("In Passing", isDirectory: true)
        load()
    }
    private func load() {
        // Carry the most recent composition through midnight and relaunches.
        // Older daily files are read only when first adopting the desktop version.
        let dailyFiles = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let previous = dailyFiles.filter { $0.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}\.json$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.first
        guard let source = FileManager.default.fileExists(atPath: file.path) ? file : previous else { return }
        do {
            let page = try JSONDecoder().decode(Page.self, from: Data(contentsOf: source))
            traces = Array(page.traces.suffix(100))
            if source != file { persist() }
        } catch { unreadable = true; notice = "The drawing could not be read. Its saved copy has been left in place." }
    }
    func record(_ frame: CGRect, desktop: CGRect) {
        guard let trace = WindowTrace(frame: frame, desktop: desktop) else { return }
        traces = Array((traces + [trace]).suffix(100))
        persist()
    }
    func clear() { traces = []; unreadable = false; notice = ""; persist() }
    private func persist() {
        guard !unreadable else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(Page(traces: traces))
            try data.write(to: file, options: .atomic)
        } catch { notice = "The desktop drawing could not be saved on this Mac." }
    }
}
