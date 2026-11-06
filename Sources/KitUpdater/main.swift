import BackupCore
import Foundation

// Reads the destination from BackupMe's own settings and updates RIPRISTINO.command / LEGGIMI.txt there.
// Only output and exit code 0: an install must never fail because of the kit.
guard let data = UserDefaults(suiteName: "com.vale76p.BackupMe")?.data(forKey: "settings"),
      let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let destination = settings["destination"] as? String else {
    print("Kit di ripristino: nessuna destinazione configurata, niente da aggiornare")
    exit(0)
}
switch Repository.updateRestoreKit(destination: URL(fileURLWithPath: destination)) {
case .installed(let from, let to):
    print("Kit di ripristino aggiornato \(from.map { "dalla versione \($0) " } ?? "")alla versione \(to) in \(destination)/BackupMe")
case .current(let v):
    print("Kit di ripristino già alla versione \(v)")
case .newerKept(let v):
    print("Kit di ripristino lasciato alla versione \(v), più recente di questa app (scritto da un altro Mac)")
case .noArchive:
    print("Kit di ripristino: nessun archivio ancora in \(destination), verrà creato con il primo backup")
}
