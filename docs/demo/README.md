# Demo data

Everything the README's screenshots show is invented: a student called Sam, four courses
(CS 150 Data Structures, MATH 221 Linear Algebra, BIO 210 Cell Biology, HIST 140 Modern Europe),
five weeks of sessions, and a class timetable.

- `calendar.ics` — the weekly timetable, laid under the sessions on the Calendar page.
- `scripts/demo-data.swift` — writes the catalogue (`catalog.json`) and the log (`log.sqlite`) into a folder you name,
  relative to today and from a fixed seed, so the streak and "this week" always look current.

```bash
swiftc -o /tmp/demo-data scripts/demo-data.swift && /tmp/demo-data /tmp/dbot-demo
swift build
DBOT_NAME=Sam DBOT_CATALOG_PATH=/tmp/dbot-demo/catalog.json DBOT_LOG_PATH=/tmp/dbot-demo/log.sqlite \
  DBOT_SESSION_PATH=/tmp/dbot-demo/session.json DBOT_QUEUE_PATH=/tmp/dbot-demo/queue.json \
  DBOT_SNAPSHOT_ICS=docs/demo/calendar.ics DBOT_SNAPSHOT=/tmp/home.png DBOT_SNAPSHOT_TAB=home .build/debug/DistractionBot
```

A render with `DBOT_SNAPSHOT` set reads your rules (`settings.json`) and preferences but writes nothing to
`~/Library/Application Support/Distraction Bot/`.
