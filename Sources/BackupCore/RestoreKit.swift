import Foundation

/// A restore script and a readme kept beside the archives, so a backup can be restored on any Mac with
/// stock macOS 14+, without BackupMe or developer tools: JavaScript for Automation and /usr/bin/shasum only.
enum RestoreKit {
    /// Bumped whenever the script or the readme change. Two Macs sharing a destination may run different
    /// BackupMe versions: the older one must not keep overwriting the newer kit (and re-uploading it).
    static let version = 3

    /// Rewrites a file only when its content differs and it isn't from a newer kit.
    static func install(in base: URL) {
        if let existing = try? String(contentsOf: base.appending(path: "RIPRISTINO.command"), encoding: .utf8),
           let v = installedVersion(existing), v > version { return }
        for (name, text, mode) in [("RIPRISTINO.command", script, 0o755), ("LEGGIMI.txt", readme, 0o644)] {
            let url = base.appending(path: name)
            let data = Data(text.utf8)
            guard (try? Data(contentsOf: url)) != data else { continue }
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
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

    Questa cartella contiene un archivio per ogni Mac salvato:

      <nome del Mac>-<id>/
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

       sh RIPRISTINO.command MacBook-1A2B3C 2026-11-05T10-00-00Z ~/Desktop/Ripristino

    Prima di scrivere qualsiasi cosa lo script controlla il backup e mostra un riepilogo: quali
    cartelle ricrea e dove, quanti file e quanti MB, lo spazio libero e cosa succederà. Poi chiede
    due conferme: rispondi "s" alla prima e scrivi RIPRISTINA alla seconda. Qualsiasi altra
    risposta annulla e non viene scritto nulla.
    Per usarlo in uno script, senza domande, aggiungi --si (in qualsiasi posizione):

       sh RIPRISTINO.command --si MacBook-1A2B3C 2026-11-05T10-00-00Z ~/Desktop/Ripristino

    Lo script ricrea nella cartella scelta ogni cartella salvata nel backup (file, cartelle,
    link simbolici, permessi, date di modifica) e controlla il contenuto di ogni file.
    Non sovrascrive mai niente: se una cartella esiste già usa un nome nuovo ("progetto 2").
    Non modifica l'archivio.

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
    if (data.length === 0) break
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
  var key = 'NSURLVolumeAvailableCapacityForImportantUsageKey'
  var v = ObjC.deepUnwrap($.NSURL.fileURLWithPath(p).resourceValuesForKeysError($([key]), null))
  return v && typeof v[key] === 'number' ? v[key] : undefined
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

// Refuses anything that could write outside the destination: absolute paths, "." or "..", duplicates,
// and entries whose parent is not a folder of the backup (e.g. a symlink pointing elsewhere).
function validate(tree) {
  var dirs = new Set(), seen = new Set()
  tree.forEach(e => {
    var p = e.path, parts = p.split('/')
    var ok = typeof p === 'string' && !seen.has(p) && ['file', 'directory', 'symlink'].indexOf(e.kind) >= 0
      && (p === '' ? e.kind === 'directory'
          : !parts.some(x => x === '' || x === '.' || x === '..') && dirs.has(parts.slice(0, -1).join('/')))
      && (e.kind !== 'file' || /^[0-9a-f]{64}$/.test(e.hash))
    if (!ok) fail('Backup non valido, niente è stato scritto. Voce rifiutata: ' + JSON.stringify(p))
    seen.add(p)
    if (e.kind === 'directory') dirs.add(p)
  })
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
  var yes = argv.indexOf('--si') >= 0
  argv = argv.filter(a => a !== '--si')
  var usage = 'Per ripristinare:\n  sh "' + script + '" <computer> <backup> <cartella di destinazione>'
    + '\nPrima di scrivere mostra cosa farà e chiede due conferme. Con --si (in qualsiasi posizione) non le chiede,'
    + '\nper usarlo in uno script.'
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
  if (snapshots(archive).indexOf(id) < 0) fail('Backup non trovato: ' + id)
  var raw = $.NSData.dataWithContentsOfFile(archive + '/snapshots/' + id + '.json.lzfse')
  var json = raw.isNil() ? raw : raw.decompressedDataUsingAlgorithmError(0, null) // 0 = LZFSE
  if (json.isNil()) fail('Indice del backup illeggibile: ' + id)
  var snapshot = JSON.parse(ObjC.unwrap($.NSString.alloc.initWithDataEncoding(json, utf8)))

  // check everything before writing anything
  var plans = [], taken = new Set()
  snapshot.sources.forEach(source => {
    var tree = snapshot.entries.filter(e => e.source === source).sort((a, b) => depth(a) - depth(b))
    if (!tree.length) return
    validate(tree)
    var name = source.split('/').filter(x => x).pop() || 'Backup'
    if (name === '.' || name === '..') name = 'Backup'
    var target = dest + '/' + name
    for (var n = 2; exists(target) || taken.has(target); n++) target = dest + '/' + name + ' ' + n
    taken.add(target)
    var sizes = tree.filter(e => e.kind === 'file').map(e => e.size || 0)
    plans.push({ source: source, name: name, target: target, tree: tree,
                 files: sizes.length, bytes: sizes.reduce((a, b) => a + b, 0) })
  })
  if (!plans.length) fail('Il backup ' + id + ' non contiene cartelle')

  // say what will happen, then ask twice: nothing is written before both answers
  var count = plans.reduce((a, p) => a + p.files, 0), bytes = plans.reduce((a, p) => a + p.bytes, 0)
  var free = freeSpace(dest)
  var when = new Date(snapshot.date * 1000).toLocaleString('it-IT', { dateStyle: 'long', timeStyle: 'medium' })
  out('Ripristino del computer "' + computer + '", backup del ' + when + ' (ora locale)\n')
  out('Cartelle che verranno ricreate:')
  plans.forEach(p => {
    out('  ' + p.source + '\n    → ' + p.target)
    if (p.target !== dest + '/' + p.name) out('      (esiste già "' + p.name + '": la cartella esistente non viene toccata)')
    out('      ' + p.files + ' file, ' + size(p.bytes))
  })
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

  // never overwrites: every call below fails if the item already exists
  var problems = [], files = []
  plans.forEach(plan => plan.tree.forEach(e => {
    var p = e.path === '' ? plan.target : plan.target + '/' + e.path
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
  }))

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
  if (problems.length) fail('\nProblemi (' + problems.length + '):\n' + problems.join('\n'))
}
"""#
}
