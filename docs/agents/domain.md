# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`docs/formato-archivio.md`**: the on-disk archive format (layout, `repo.json`, manifests, compatibility rules). Read it before touching `Sources/BackupCore`.
- **`docs/superpowers/specs/2026-11-05-backupme-backup-design.md`**: the original design, with "Differenze rispetto alla spec" at the end for what 1.0 does differently.

There is **no `GLOSSARY.md` and no `docs/adr/` yet**. Don't flag their absence and don't create them upfront: the `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved. Once they exist, read them too.

## File structure

Single-context repo. When the domain docs are created they go here:

```
/
├── GLOSSARY.md                 (not yet)
├── docs/
│   ├── formato-archivio.md
│   └── adr/                    (not yet)
└── Sources/
```

## Use the glossary's vocabulary

Once `GLOSSARY.md` exists: when your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined there. Don't drift to synonyms the glossary explicitly avoids. Until then, use the words of `docs/formato-archivio.md` and the UI (archivio, backup, indice/manifest, oggetto, kit di ripristino).

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

Once `docs/adr/` exists: if your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders), but worth reopening because…_
