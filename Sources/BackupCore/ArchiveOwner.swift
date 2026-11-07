import Foundation

extension Repository {
    /// Makes this archive `owner`'s (a uid), or throws `otherOwner` when another account of this Mac owns it: two
    /// accounts writing one archive delete each other's backups at cleanup. An archive from before the owner was
    /// recorded goes to the first account that claims it. Call it inside `withLock`, so two claims can't both win.
    public func claim(owner: UInt32) throws {
        let info = root.appending(path: "repo.json")
        // unreadable (an offline cloud file): not a reason to stop a backup, the next one claims it
        guard let data = try? Data(contentsOf: info),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let found = json["owner"] as? Int {
            guard found == Int(owner) else { throw RepositoryError.otherOwner }
            return
        }
        json["owner"] = Int(owner)
        try atomicWrite(try JSONSerialization.data(withJSONObject: json, options: .sortedKeys), to: info, sync: .file)
    }
}
