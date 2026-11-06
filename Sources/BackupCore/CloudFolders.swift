import Foundation

/// A folder a cloud client keeps in sync on this Mac: a possible destination, and a folder the backup leaves out.
public struct CloudFolder: Sendable, Hashable {
    /// "OneDrive", "Dropbox", "Google Drive", "iCloud Drive"…
    public var service: String
    /// The account or the organization, when the client says it ("Personal", "name@example.com").
    public var account: String?
    public var url: URL

    public var title: String { account.map { "\(service) (\($0))" } ?? service }

    /// The cloud folders present in `home`: Library/CloudStorage (File Provider clients), iCloud Drive, and the
    /// home folders of older clients. Archives a client leaves behind when it is removed or reinstalled
    /// ("Dropbox (28-12-22 10:05) Archive") aren't synced any more and are left out.
    public static func installed(home: String = NSHomeDirectory()) -> [CloudFolder] {
        let fm = FileManager.default
        func isDir(_ path: String) -> Bool {
            var d: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &d) && d.boolValue
        }
        var found: [CloudFolder] = []
        let storage = home + "/Library/CloudStorage"
        for name in ((try? fm.contentsOfDirectory(atPath: storage)) ?? []).sorted()
        where !name.hasPrefix(".") && !name.contains(" (") && isDir(storage + "/" + name) {
            // "OneDrive-Personal", "GoogleDrive-name@example.com", "Dropbox": the service, then the account
            let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
            // iCloud Drive is listed below, from its real folder
            guard parts[0] != "iCloudDrive" else { continue }
            found.append(CloudFolder(service: serviceName(parts[0]), account: parts.count > 1 ? parts[1] : nil,
                                     url: URL(fileURLWithPath: storage + "/" + name)))
        }
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if isDir(iCloud) { found.append(CloudFolder(service: "iCloud Drive", account: nil, url: URL(fileURLWithPath: iCloud))) }
        // older clients sync a folder in the home; skipped when the same service is already in CloudStorage
        for f in homeFolders(home: home) where !found.contains(where: { $0.service == f.service }) { found.append(f) }
        return found
    }

    /// The folders older clients keep in the home ("Dropbox", "OneDrive", "OneDrive - Company", "Google Drive"),
    /// real folders only: a link into CloudStorage is left out by the CloudStorage rule already.
    public static func homeFolders(home: String = NSHomeDirectory()) -> [CloudFolder] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: home)) ?? []).sorted()
        return names.compactMap { name in
            let service = name == "Dropbox" ? "Dropbox" : name == "Google Drive" ? "Google Drive"
                : name == "OneDrive" || name.hasPrefix("OneDrive - ") ? "OneDrive" : nil
            guard let service, let attrs = try? fm.attributesOfItem(atPath: home + "/" + name),
                  attrs[.type] as? FileAttributeType == .typeDirectory else { return nil }
            return CloudFolder(service: service, account: name.hasPrefix("OneDrive - ") ? String(name.dropFirst(11)) : nil,
                               url: URL(fileURLWithPath: home + "/" + name))
        }
    }

    /// The services present, each once, in Italian: "OneDrive, Dropbox e Google Drive". nil when there are none.
    public static func serviceList(_ folders: [CloudFolder]) -> String? {
        var names: [String] = []
        for f in folders where !names.contains(f.service) { names.append(f.service) }
        guard let last = names.popLast() else { return nil }
        return names.isEmpty ? last : names.joined(separator: ", ") + " e " + last
    }

    private static func serviceName(_ raw: String) -> String {
        switch raw {
        case "GoogleDrive": "Google Drive"
        case "pCloudDrive", "pCloud": "pCloud"
        default: raw
        }
    }
}
