import Foundation
@testable import BackupCore

func tmp() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "BackupMeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func write(_ text: String, to url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
}

func objectFile(_ r: Repository, _ h: String) -> URL? {
    ["lzfse", "raw"].map { r.root.appending(path: "objects/\(h.prefix(2))/\(h).\($0)") }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}
