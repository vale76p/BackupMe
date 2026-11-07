import Foundation

/// A restore script and a readme kept beside the archives, so a backup can be restored on any Mac with
/// stock macOS 14+, without BackupMe or developer tools: JavaScript for Automation and /usr/bin/shasum only.
enum RestoreKit {
    /// Bumped whenever the script or the readme change. Two Macs sharing a destination may run different
    /// BackupMe versions: the older one must not keep overwriting the newer kit (and re-uploading it).
    static let version = 8

    /// Rewrites a file only when its content differs and it isn't from a newer kit. `base`: the BackupMe folder,
    /// opened without following links; a link under a kit file's name is replaced, never read or written through.
    static func install(in base: Int32) {
        if let existing = read("RIPRISTINO.command", in: base).flatMap({ String(data: $0, encoding: .utf8) }),
           let v = installedVersion(existing), v > version { return }
        for (name, text, mode) in [("RIPRISTINO.command", script, 0o755), ("LEGGIMI.txt", readme, 0o644)] {
            let data = Data(text.utf8)
            guard read(name, in: base) != data else { continue }
            try? Repository.atomicWrite(data, named: name, in: base, sync: .file, mode: mode_t(mode))
        }
    }

    /// A regular file's content; nil for a link, a folder or a pipe (whose read would never end).
    static func read(_ name: String, in dir: Int32) -> Data? {
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        // readToEnd() is nil for an empty file
        do { return try h.readToEnd() ?? Data() } catch { return nil }
    }

    /// The `BackupMe-kit: N` line of an installed script; nil for the first kit, which had none.
    static func installedVersion(_ script: String) -> Int? {
        script.split(separator: "\n").lazy.compactMap { line -> Int? in
            guard line.hasPrefix("// BackupMe-kit: ") else { return nil }
            return Int(line.dropFirst("// BackupMe-kit: ".count))
        }.first
    }

    static let readme = """
    BackupMe: come ripristinare un backup anche senza l'app
    Kit di ripristino versione \(version)

    Questa cartella contiene un archivio per ogni Mac salvato:

      <nome del Mac>-<id>-<utente>/  (creato da una versione precedente: <nome del Mac>-<id>/)
        snapshots/   un indice per ogni backup (nome = data e ora UTC; JSON compresso LZFSE)
        objects/     il contenuto dei file, salvato una volta sola anche se è in cento backup
                     (nome = SHA-256 del contenuto; .lzfse compressi, .raw così come sono)
        repo.json    informazioni sull'archivio

    I file non si leggono direttamente. Per riaverli usa BackupMe (Sfoglia backup…) oppure,
    su qualsiasi Mac con macOS 14 o successivo, anche senza BackupMe, lo script RIPRISTINO.command:

    1. Apri Terminale (Applicazioni › Utility).
    2. Scrivi "sh " (con lo spazio), trascina RIPRISTINO.command nella finestra e premi Invio:
       vedi i computer e i loro backup.
    3. Ripeti aggiungendo computer, backup e cartella dove ripristinare, per esempio:

       sh RIPRISTINO.command MacBook-1A2B3C4D 2026-11-05T10-00-00Z ~/Desktop/Ripristino

    Usa il nome del computer come lo mostra l'elenco: negli archivi più recenti finisce anche con
    l'utente del Mac (per esempio MacBook-1A2B3C4D-mario).

    Prima di scrivere qualsiasi cosa lo script controlla il backup e mostra un riepilogo: quali
    cartelle ricrea e dove, quanti file e quanti MB, lo spazio libero e cosa succederà. Poi chiede
    due conferme: rispondi "s" alla prima e scrivi RIPRISTINA alla seconda. Qualsiasi altra
    risposta annulla e non viene scritto nulla.
    Per usarlo in uno script, senza domande, aggiungi --si (in qualsiasi posizione):

       sh RIPRISTINO.command --si MacBook-1A2B3C4D 2026-11-05T10-00-00Z ~/Desktop/Ripristino

    Lo script ricrea nella cartella scelta ogni cartella salvata nel backup (file, cartelle,
    link simbolici, permessi, date di modifica) e controlla il contenuto di ogni file.
    Non sovrascrive mai niente: se una cartella esiste già usa un nome nuovo ("progetto 2").
    Non modifica l'archivio.
    Se il backup ha avvisi (cartella non leggibile, spazio esaurito, file saltati) il riepilogo li
    elenca e lo script termina con un errore. Per una cartella che non è nel backup scegli un
    backup precedente.

    Con OneDrive i file vengono scaricati mentre lo script li legge: serve la connessione.

    """

    static let script = #"""
#!/bin/sh
true //; exec /usr/bin/osascript -l JavaScript "$0" "$@"
// BackupMe: ripristina un backup su un Mac senza BackupMe (macOS 14 o successivo). Vedi LEGGIMI.txt.
// BackupMe-kit: \#(version)
ObjC.import('Foundation')
ObjC.import('stdlib')
var fm = $.NSFileManager.defaultManager
var utf8 = $.NSUTF8StringEncoding

function write(handle, s) { handle.writeData($(s + '\n').dataUsingEncoding(utf8)) }
function out(s) { write($.NSFileHandle.fileHandleWithStandardOutput, s) }
function fail(s) { write($.NSFileHandle.fileHandleWithStandardError, s); $.exit(1) }
function prompt(s) { $.NSFileHandle.fileHandleWithStandardOutput.writeData($(s).dataUsingEncoding(utf8)) }
// one line from the terminal (stdin), without the newline; null at end of input
var pending = ''
function readLine() {
  while (pending.indexOf('\n') < 0) {
    var data = $.NSFileHandle.fileHandleWithStandardInput.availableData
    if (!Number(data.length)) break // JXA gives length as a string: "0" at end of input
    pending += ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, utf8)) || ''
  }
  if (!pending) return null
  var i = pending.indexOf('\n'), line = i < 0 ? pending : pending.slice(0, i)
  pending = i < 0 ? '' : pending.slice(i + 1)
  return line.trim()
}
function size(n) {
  var f = (x, u) => x.toLocaleString('it-IT', { minimumFractionDigits: 1, maximumFractionDigits: 1 }) + ' ' + u
  return n >= 1e9 ? f(n / 1e9, 'GB') : f(n / 1e6, 'MB')
}
function freeSpace(p) {
  while (!exists(p)) p = ObjC.unwrap($(p).stringByDeletingLastPathComponent)
  // exFAT and FAT32 report 0 for the "important usage" capacity: the plain one then
  var keys = ['NSURLVolumeAvailableCapacityForImportantUsageKey', 'NSURLVolumeAvailableCapacityKey']
  var v = ObjC.deepUnwrap($.NSURL.fileURLWithPath(p).resourceValuesForKeysError($(keys), null)) || {}
  return v[keys[0]] > 0 ? v[keys[0]] : typeof v[keys[1]] === 'number' ? v[keys[1]] : undefined
}
function exists(p) { return fm.fileExistsAtPath(p) }
function list(p) { return (ObjC.deepUnwrap(fm.contentsOfDirectoryAtPathError(p, null)) || []).sort() }
function absolute(p) {
  p = ObjC.unwrap($(p).stringByExpandingTildeInPath)
  return ObjC.unwrap($(p[0] === '/' ? p : ObjC.unwrap(fm.currentDirectoryPath) + '/' + p).stringByStandardizingPath)
}
function snapshots(archive) {
  return list(archive + '/snapshots').filter(n => /\.json\.lzfse$/.test(n)).map(n => n.slice(0, -11))
}
function depth(e) { return e.path === '' ? 0 : e.path.split('/').length }

// The first entry of a saved folder that could write outside the destination: absolute paths, "." or "..",
// duplicates, and entries whose parent is not a folder of the backup (e.g. a symlink pointing elsewhere).
// undefined when there is none. Names that differ only by case or Unicode form are one name on APFS: not refused
// here (a Linux repository has Makefile and makefile), the writes below never go through the second one.
function validate(tree) {
  var dirs = new Set(), seen = new Set()
  for (var e of tree) {
    var p = e.path, parts = typeof p === 'string' ? p.split('/') : []
    var ok = typeof p === 'string' && !seen.has(p) && ['file', 'directory', 'symlink'].indexOf(e.kind) >= 0
      && (p === '' ? e.kind === 'directory' || e.kind === 'file' // a saved folder or a single saved file
          : !parts.some(x => x === '' || x === '.' || x === '..') && dirs.has(parts.slice(0, -1).join('/')))
      && (e.kind !== 'file' || /^[0-9a-f]{64}$/.test(e.hash))
    if (!ok) return JSON.stringify(p)
    seen.add(p)
    if (e.kind === 'directory') dirs.add(p)
  }
}

// SHA-256 of many files with one shasum call; undefined for a file it could not read.
function sha256(paths) {
  var t = $.NSTask.alloc.init, pipe = $.NSPipe.pipe
  t.launchPath = '/usr/bin/shasum'
  t.arguments = $(['-a', '256', '--'].concat(paths))
  t.standardOutput = pipe
  t.standardError = $.NSFileHandle.fileHandleWithNullDevice
  t.launch
  var text = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(pipe.fileHandleForReading.readDataToEndOfFile, utf8))
  t.waitUntilExit
  // one line per file, in order (names with newlines are escaped); a missing line shifts them: check one by one
  var hashes = text.split('\n').filter(l => l).map(l => (/^\\?([0-9a-f]{64}) /.exec(l) || [])[1])
  if (hashes.length === paths.length) return hashes
  return paths.length === 1 ? [undefined] : paths.map(p => sha256([p])[0])
}

function run(argv) {
  var args = ObjC.deepUnwrap($.NSProcessInfo.processInfo.arguments)
  var script = absolute(args[args.length - argv.length - 1])
  var base = ObjC.unwrap($(script).stringByDeletingLastPathComponent)
  var computers = list(base).filter(c => exists(base + '/' + c + '/repo.json'))
  var version = 'RIPRISTINO.command versione \#(version)'
  if (argv.indexOf('--versione') >= 0) { out(version); return }
  var yes = argv.indexOf('--si') >= 0
  argv = argv.filter(a => a !== '--si')
  var usage = version + '\n\nPer ripristinare:\n  sh "' + script + '" <computer> <backup> <cartella di destinazione>'
    + '\nPrima di scrivere mostra cosa farà e chiede due conferme. Con --si (in qualsiasi posizione) non le chiede,'
    + '\nper usarlo in uno script. Con --versione mostra solo la versione.'
  if (argv.length === 0) {
    if (!computers.length) fail('Nessun archivio di BackupMe in ' + base)
    computers.forEach(c => {
      out('Computer: ' + c)
      snapshots(base + '/' + c).forEach(id => out('  ' + id))
    })
    out('\n' + usage)
    return
  }
  if (argv.length !== 3) fail(usage)
  var computer = argv[0], id = argv[1], dest = absolute(argv[2])
  if (computers.indexOf(computer) < 0) fail('Computer non trovato: ' + computer)
  var archive = base + '/' + computer
  // an archive written by a newer BackupMe may be laid out differently: refuse instead of guessing
  var info = $.NSData.dataWithContentsOfFile(archive + '/repo.json')
  var format = info.isNil() ? 1 : (JSON.parse(ObjC.unwrap($.NSString.alloc.initWithDataEncoding(info, utf8))).format || 1)
  if (format > \#(Repository.format)) fail('Archivio di formato ' + format + ', più recente di questo script: '
    + 'usa il RIPRISTINO.command scritto dalla versione di BackupMe che lo ha creato, o aggiorna BackupMe')
  if (snapshots(archive).indexOf(id) < 0) fail('Backup non trovato: ' + id)
  var raw = $.NSData.dataWithContentsOfFile(archive + '/snapshots/' + id + '.json.lzfse')
  var json = raw.isNil() ? raw : raw.decompressedDataUsingAlgorithmError(0, null) // 0 = LZFSE
  if (json.isNil()) fail('Indice del backup illeggibile: ' + id)
  var text = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(json, utf8))
  // BackupMe 0.9.2 and later put a checksum first: one byte flipped in the compressed file can still decode,
  // into other hashes and names. It covers the bytes after {"check":"<64 hex>",
  if (text.indexOf('{"check":"') === 0) {
    var body = ObjC.unwrap($.NSTemporaryDirectory()) + 'backupme-indice-' + ObjC.unwrap($.NSUUID.UUID.UUIDString)
    json.subdataWithRange($.NSMakeRange(76, json.length - 76)).writeToFileAtomically(body, false)
    var intact = sha256([body])[0] === text.slice(10, 74)
    fm.removeItemAtPathError(body, null)
    if (!intact) fail('Indice del backup danneggiato, niente è stato scritto: ' + id + '. Prova con un altro backup.')
  }
  var snapshot = JSON.parse(text)

  // check everything before writing anything
  // names are compared as APFS does (case and Unicode form ignored): "App" and "app" are the same folder
  var plans = [], taken = new Set(), key = s => s.normalize('NFD').toLowerCase(), missing = [], refused = []
  snapshot.sources.forEach(source => {
    var tree = snapshot.entries.filter(e => e.source === source).sort((a, b) => depth(a) - depth(b))
    // a folder the backup couldn't read (see the warnings): an older backup may have it
    if (!tree.length) { missing.push(source); return }
    // only this saved folder is skipped: the others are still restored
    var bad = validate(tree)
    if (bad !== undefined) { refused.push(source + ' (voce non valida: ' + bad + ')'); return }
    var folded = new Set(), collisions = 0
    tree.forEach(e => { if (folded.has(key(e.path))) collisions++; folded.add(key(e.path)) })
    var name = source.split('/').filter(x => x).pop() || 'Backup'
    if (name === '.' || name === '..') name = 'Backup'
    var target = dest + '/' + name
    for (var n = 2; exists(target) || taken.has(key(target)); n++) target = dest + '/' + name + ' ' + n
    taken.add(key(target))
    var sizes = tree.filter(e => e.kind === 'file').map(e => e.size || 0)
    plans.push({ source: source, name: name, target: target, tree: tree, collisions: collisions,
                 files: sizes.length, bytes: sizes.reduce((a, b) => a + b, 0) })
  })
  var notes = missing.map(s => 'NON è in questo backup: ' + s + ', scegli un backup precedente')
    .concat(refused.map(s => 'Backup non valido per questa cartella, non viene scritta: ' + s))
  if (!plans.length) fail((notes.length ? notes.join('\n') + '\n' : '') + 'Il backup ' + id + ' non contiene cartelle né file da ripristinare')

  // say what will happen, then ask twice: nothing is written before both answers
  var count = plans.reduce((a, p) => a + p.files, 0), bytes = plans.reduce((a, p) => a + p.bytes, 0)
  var free = freeSpace(dest)
  var when = new Date(snapshot.date * 1000).toLocaleString('it-IT', { dateStyle: 'long', timeStyle: 'medium' })
  out(version + '\n')
  out('Ripristino del computer "' + computer + '", backup del ' + when + ' (ora locale)\n')
  out('Cartelle e file che verranno ricreati:')
  plans.forEach(p => {
    out('  ' + p.source + '\n    → ' + p.target)
    if (p.target !== dest + '/' + p.name) out('      (esiste già "' + p.name + '": quello esistente non viene toccato)')
    out('      ' + p.files + ' file, ' + size(p.bytes))
    if (p.collisions) out('      ' + p.collisions + (p.collisions === 1 ? ' nome differisce' : ' nomi differiscono')
      + ' solo per maiuscole o accenti da un altro: su un disco che non li distingue non viene ripristinato')
  })
  if (notes.length) out('\n' + notes.join('\n'))
  var warnings = Array.isArray(snapshot.warnings) ? snapshot.warnings : []
  if (warnings.length) out('\nAvvisi del backup (' + warnings.length + '):\n  ' + warnings.join('\n  '))
  out('\nIn tutto: ' + count + ' file, ' + size(bytes) + '. Spazio libero nella destinazione: '
    + (free === undefined ? 'sconosciuto' : size(free)) + '.')
  if (free !== undefined && free < bytes) out('ATTENZIONE: lo spazio libero non basta, il ripristino si fermerebbe a metà.')
  out('\nCosa succede:\n'
    + '  - Niente di quello che esiste già viene sovrascritto o cancellato; l\'archivio non viene modificato.\n'
    + '  - Il contenuto viene letto dall\'archivio: se è su OneDrive o Dropbox con i file su richiesta, viene\n'
    + '    prima scaricato (serve la connessione, può richiedere tempo e altro spazio sul disco).\n'
    + '  - Ogni file viene controllato: se il contenuto non corrisponde viene rinominato ".danneggiato"\n'
    + '    e lo script termina con un errore.\n'
    + '  - Vengono ripristinati permessi e date di modifica.\n')
  if (!yes) {
    var cancel = () => { out('Ripristino annullato, non è stato scritto nulla.'); $.exit(2) }
    prompt('Procedere con il ripristino? [s/N] ')
    var answer = readLine()
    if (answer === null) {
      write($.NSFileHandle.fileHandleWithStandardError, '\nNessuna risposta: lo script non è in un Terminale. Non è stato scritto nulla.\n'
        + 'Per ripristinare senza domande, per esempio da uno script, aggiungi --si:\n'
        + '  sh "' + script + '" --si <computer> <backup> <cartella di destinazione>')
      $.exit(2)
    }
    if (!/^s[iì]?$/i.test(answer)) cancel()
    prompt('Per confermare scrivi RIPRISTINA: ')
    if ((readLine() || '').toUpperCase() !== 'RIPRISTINA') cancel()
  }

  if (!fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(dest, true, $(), null)) {
    fail('Non riesco a creare ' + dest)
  }

  // never overwrites: every call below fails if the item already exists. An item goes only into a folder this
  // run created itself: if a folder fails (it appeared meanwhile, or a name collides) nothing goes inside it
  var problems = [], files = [], made = new Set([dest])
  plans.forEach(plan => plan.tree.forEach(e => {
    var p = e.path === '' ? plan.target : plan.target + '/' + e.path
    var parent = p.slice(0, p.lastIndexOf('/'))
    if (!made.has(parent)) { problems.push('saltato, la cartella che lo contiene non è stata creata: ' + p); return }
    var ok
    if (e.kind === 'directory') ok = fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(p, false, $(), null)
    else if (e.kind === 'symlink') ok = fm.createSymbolicLinkAtPathWithDestinationPathError(p, e.linkTarget || '', null)
    else {
      var object = archive + '/objects/' + e.hash.slice(0, 2) + '/' + e.hash
      if (exists(object + '.lzfse')) {
        var data = $.NSData.dataWithContentsOfFile(object + '.lzfse')
        data = data.isNil() ? data : data.decompressedDataUsingAlgorithmError(0, null)
        ok = !data.isNil() && data.writeToFileOptionsError(p, 2, null) // 2 = senza sovrascrivere
      } else ok = fm.copyItemAtPathToPathError(object + '.raw', p, null)
      if (ok) files.push(e)
    }
    if (ok) e.dest = p
    else problems.push('non ripristinato: ' + p)
    if (ok && e.kind === 'directory') made.add(p)
  }))

  // Foundation writes names decomposed ("u" + "¨"); the saved ones are most likely composed ("ü"): the same for the
  // Finder, another name for git, rsync or a Linux server. perl's rename keeps the bytes it reads from stdin
  // (arguments would be decomposed too). Through a temporary name: on case-sensitive APFS a rename between two
  // forms of one name does nothing; never onto another item, put back if the second step fails
  var renames = []
  plans.forEach(plan => plan.tree.forEach(e => {
    if (!e.dest) return
    var name = e.path === '' ? plan.target.slice(plan.target.lastIndexOf('/') + 1) : e.path.slice(e.path.lastIndexOf('/') + 1)
    if (name !== name.normalize('NFD')) renames.push(e.dest.slice(0, e.dest.length - name.length) + name.normalize('NFD'), e.dest)
  }))
  if (renames.length) {
    var t = $.NSTask.alloc.init, input = $.NSPipe.pipe
    t.launchPath = '/usr/bin/perl'
    t.arguments = $(['-e', 'local $/ = "\\0"; my @p = <STDIN>; chomp @p; while (@p) { my ($a, $b) = splice(@p, 0, 2); '
      + 'my $t = "$a.backupme-nome"; next if -l $t || -e $t || !rename($a, $t); rename($t, $a) if -l $b || -e $b || !rename($t, $b) }'])
    t.standardInput = input
    t.launch
    input.fileHandleForWriting.writeData($(renames.join('\0') + '\0').dataUsingEncoding($.NSUTF8StringEncoding))
    input.fileHandleForWriting.closeFile
    t.waitUntilExit
  }

  for (var i = 0; i < files.length; i += 200) {
    var batch = files.slice(i, i + 200), hashes = sha256(batch.map(e => e.dest))
    batch.forEach((e, j) => {
      if (hashes[j] === e.hash) return
      problems.push('contenuto danneggiato, rinominato in .danneggiato: ' + e.dest)
      fm.moveItemAtPathToPathError(e.dest, e.dest + '.danneggiato', null)
      e.kind = 'damaged'
    })
  }

  // files first, then folders deepest first: a read-only folder is locked only after its content is written
  function finish(e) {
    var attrs = $.NSMutableDictionary.alloc.init
    attrs.setObjectForKey($(e.mode), $.NSFilePosixPermissions)
    attrs.setObjectForKey($.NSDate.dateWithTimeIntervalSince1970(e.mtime), $.NSFileModificationDate)
    if (!fm.setAttributesOfItemAtPathError(attrs, e.dest, null)) problems.push('permessi o data non ripristinati: ' + e.dest)
  }
  var all = [].concat.apply([], plans.map(p => p.tree)).filter(e => e.dest)
  all.filter(e => e.kind === 'file').forEach(finish)
  all.filter(e => e.kind === 'directory').reverse().forEach(finish)

  plans.forEach(p => out('Ripristinato: ' + p.target))
  // folders missing or warnings in the backup are no success: said again at the end, and in the exit status for a script
  problems = problems.concat(notes, warnings.length ? ['il backup ha ' + warnings.length + (warnings.length === 1 ? ' avviso' : ' avvisi') + ', vedi sopra'] : [])
  if (problems.length) fail('\nProblemi (' + problems.length + '):\n' + problems.join('\n'))
}
"""#
}
