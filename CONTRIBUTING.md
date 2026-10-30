# Contributing

Distraction Bot is a personal project shared as is. Issues are welcome — bugs, confusing screens, a browser or app it should know about. There's no promise of support or of a timeline.

**Reporting a bug:** say which macOS and Mac you have, the app's version (in the zip's name, or Finder → Get Info), what you did and what happened. The log at `~/Library/Logs/Distraction Bot/app.log` usually shows it — check the lines for anything private before pasting them.

**Pull requests:** small, focused ones are easiest to take. Before sending one:

```bash
swift build
```

```bash
scripts/type-lint.sh
```

and run the `scripts/*-check.swift` tests that cover what you changed (each file's header has its `swiftc` line). For anything visual, a before/after render helps: `scripts/readme-shots.sh <name>` draws a screen from the demo data without touching your own.

The code stays local-first: no network calls other than Ollama on localhost and the user's own calendar address.
