import Foundation

extension Repository {
    /// Makes this archive `owner`'s (a uid and the account's short name), or throws `otherOwner` when another
    /// account of this Mac owns it: two accounts writing one archive delete each other's backups at cleanup.
    /// An archive from before the owner was recorded goes to the first account that claims it. Call it inside
    /// `withLock`, so two claims can't both win.
    public func claim(owner: UInt32, name: String = NSUserName()) throws {
        let info = root.appending(path: "repo.json")
        // unreadable (an offline cloud file): not a reason to stop a backup, the next one claims it
        guard let data = try? Data(contentsOf: info),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let found = json["owner"] as? Int {
            // the same account with a new uid (Migration Assistant, 501 already taken) keeps its archive by name
            let foundName = json["ownerName"] as? String
            guard found == Int(owner) || foundName == name else { throw RepositoryError.otherOwner }
            if found == Int(owner), foundName == name { return }
        }
        json["owner"] = Int(owner)
        json["ownerName"] = name
        // best effort: a full or read-only destination must still reach the backup and the cleanup that frees space
        guard let updated = try? JSONSerialization.data(withJSONObject: json, options: .sortedKeys) else { return }
        try? atomicWrite(updated, to: info, sync: .file)
    }
}
