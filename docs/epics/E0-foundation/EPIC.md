# E0 — Project Foundation & Tooling 🟡

**Phase:** MVP · **Status:** 🟡 In Progress

Scaffold the workspace (iOS + watchOS + shared Swift packages), SwiftData container,
CloudKit sync, design tokens, app shell, and CI.

## Acceptance criteria
- [x] Repo + version control initialized; `.gitignore` in place
- [x] `Packages/` layout established; all current packages build via `make test`
- [x] Both apps (iOS + watchOS) launch to an app shell
- [ ] `swift test` / unit tests pass in CI *(local pass ✅ via Xcode toolchain; CI not yet wired)*
- [x] CloudKit sync configured (`cloudKitDatabase: .automatic` + entitlements — FF-003)

## Stories
| Card | Title | Status |
|---|---|---|
| [FF-001](FF-001.md) | Workspace + package layout | 🟢 |
| [FF-002](FF-002.md) | SwiftData container + app shell + design tokens | 🟢 |
| [FF-003](FF-003.md) | CloudKit sync configured | 🟢 |
| [FF-004](FF-004.md) | CI: build both targets + run tests | 🟡 |

## Notes
- Local environment has Swift 6.3.2 + full Xcode at `/Applications/Xcode.app`. The
  CommandLineTools toolchain lacks XCTest, so tests run via `DEVELOPER_DIR` (see `Makefile`).
- CloudKit sync is enabled via SwiftData's `cloudKitDatabase: .automatic`. Private database
  only; identity is the user's iCloud account (no auth UI). Supabase backend has been removed.
