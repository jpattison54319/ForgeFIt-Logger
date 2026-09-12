# Previous-cycle progressive disclosure acceptance — 2026-09-08

The tracked microcycle detail now shows its latest three previous cycles, with View All beside the section heading. The browser shows twenty cycles per page with visible Newer/Older controls. Opening a cycle retains the existing read-only details; Back preserves the selected page. Preview rows show cycle number and date range, with completion details disclosed in the cycle detail.

The preview query fetches at most four records and the browser twenty-one, including one lookahead record. Filters exclude the current window, tombstones, other tracking runs, and records starting at or after the history cutoff. Browsing rows read stored metadata without reconstructing workout progress. There are no production writes, schema changes, or new data exports.

## Evidence

- `make test` with the installed Xcode-beta toolchain: 483 ForgeCore and 110 ForgeData tests passed; remaining package builds passed.
- Nine focused app tests passed on iOS 26.5: the eight existing history presentation tests and the new fresh-context query test, which seeds 1,005 records and verifies all 50 pages of 1,000 eligible cycles without duplicates or gaps.
- Three final UI tests passed on iPhone 17 Pro / iOS 26.5: progressive disclosure with 43 previous cycles, the existing single previous-cycle route, and Profile's separate tracking-run history route.
- The new flow records eight wrapped actions with screenshots and accessibility trees, covering newest/oldest page boundaries, oldest-cycle details, Back, and Newer. It is included in the source-generated acceptance inventory.
- Final iOS device build and installation passed on the connected iPhone 16 Pro Max (device ID `9501EFC7-496C-5FA9-B8D8-4E1CAF17A573`). Launch of the final touch-target correction was blocked because the phone was locked. The preceding implementation had installed and launched successfully; that does not establish final-build launch.
- `git diff --check` passed.

Final touch-target replay: `/tmp/forgefit-cycle-history-v6.xcresult`. Three-route replay bundle: `/tmp/forgefit-cycle-history-v4.xcresult`.
Focused app tests: `/tmp/forgefit-cycle-history-v2.xcresult` (its later UI phase failed during iteration; the nine unit tests passed).
Final long-history action evidence: `/tmp/forgefit-cycle-final-evidence/action-evidence/MicrocycleTrackingUITests--testPreviousCyclesProgressivelyDiscloseFullHistory/7921ab8d-a2c5-43f4-8638-39bc36f9f473/`.
Inventory: `/tmp/forgefit-cycle-inventory.json`.

## Review and limits

The replay exposed a conflict between a boolean navigation destination and the existing value route; both browser and cycle detail now use the same typed route, and the final replay passed. The View All action was moved from the footer into the heading after screenshot review.

The existing parent detail and Profile history screens still query broad history collections and reconstruct their existing progress summaries. This change bounds the previous-cycle preview/browser; it does not establish whole-screen scalability or physical frame pacing. Full app-target tests, Instruments profiling, enlarged Dynamic Type, and physical-device tap-through of this flow were not performed. Device build, installation, launch, and interaction are separate evidence states.

Independent acceptance review used `gpt-5.6-luna` (verified in the bundled model catalog). It confirmed navigation and disclosure behavior and caught small accessibility frames for the browse/paging controls. Their 44-point frames were moved inside the control labels. The final replay passed explicit minimum-height assertions; recorded AX frames are View All 60.3×44, Newer 70×44, and Older 62.7×44 points.

Verification briefly hit simulator-install and signing failures while disk space fell below 400 MB. Audited, untracked Swift package `.build` caches and the regenerable ForgeFit Xcode index were removed; source, user data, and recorded evidence were preserved. Free space recovered to approximately 1.9 GB before the successful final replay.

The independent reviewer accepted the final v6 evidence with zero failures and no remaining blocker in the changed flow.
