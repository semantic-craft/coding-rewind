---
name: formal-verify-coding-rewind
description: "Run and extend Coding Rewind's explicit-state BFS formal verification suite (`verification/formal/`) for its 3 strictly gated concurrency, crash-recovery, and retry state machines."
---

# Formal Verification for Coding Rewind

Run exhaustive explicit-state breadth-first model checking over the 3 concurrency, crash-recovery, and retry state machines in Coding Rewind. All models use pure Python 3 standard library (`verification/formal/model_checker.py`) and verify both safety invariants and backward-reachability liveness properties.

## Applicability Gating

Formal verification carries high modeling and maintenance cost. Apply it **only** to the 3 gated subsystems below (or a new concurrency protocol, distributed coordination mechanism, crash-recovery state machine, or critical parser that satisfies `create-formal-verification-skill`).

### Strictly Gated Targets

| Subsystem | Production Files | Formal Model | Safety Invariants | Liveness Goal |
| --- | --- | --- | --- | --- |
| Offline Outbox + Coordinator Sync | `Sources/CodingRewindCore/PlatformStorage.swift`, `AppCoordinator.swift`, `AppCoordinator+Places.swift`, `AppCoordinator+Library.swift` | `verification/formal/outbox_coordinator_model.py` | `NoLostConfirmedClip`, `NoResurrectedDeletedClip`, `NoLostConcurrentPlaceEdit` | `EventualOutboxDrain` |
| Conversation Handoff + Sidecar Crash Recovery | `Sources/CodingRewindCore/ConversationHandoff.swift`, `AppCoordinator.swift`, `Sources/ConversationSidecar/main.swift` | `verification/formal/handoff_state_machine_model.py` | `AtMostOnceExternalDispatch`, `NoArchiveWithoutSucceededReceipt`, `CrashDuringDispatchBecomesUnknown` | `EveryRequestReachesTerminalState` |
| VPS AI Enricher Polling & Tag Rewriting | `deploy/vps/enricher/enricher.py` | `verification/formal/enricher_state_machine_model.py` | `VerbatimBodyPreserved`, `NoPrematureEnrichBeforeCtxWindow`, `ClosedVocabularyPlacesOnly`, `SynthesizedNeverRegresses` | `EventualEnrichmentOfPending` |

### Reject Non-Applicable Targets

Reject requests to add formal models for any of the following and redirect to unit tests, integration tests, or `./scripts/check`:

- Ordinary CRUD endpoints and simple sequential request-response handlers.
- SwiftUI or AppKit views, layouts, styling, appearance preferences, icons, and render loops.
- Copy, localization strings (`AppStrings.swift`, `HUDInspectorStrings.swift`, `LibraryStrings.swift`), and UI labels.
- Routine configuration loading, environment parsing, and CLI flag parsing.

## Running the Verification Suite

Run all 3 fixed models plus all 10 historical bug replays (wired into `./scripts/check`):

```bash
python3 -B verification/formal/run_all.py --verify-bug-replays
```

Run only the 3 fixed models without bug replays:

```bash
python3 -B verification/formal/run_all.py
```

The runner exits non-zero if any fixed model violates a safety or liveness property, hits `max_states`, or if any historical bug mutant fails to trigger its exact expected invariant violation.

### Historical Bug Replays Covered

1. `outbox_coordinator:bug_1d36ca0_blind_outbox_overwrite` -> `NoLostConfirmedClip`
2. `outbox_coordinator:bug_pr9_unversioned_refresh_overwrite` -> `NoLostConfirmedClip`
3. `outbox_coordinator:bug_pr51_unserialized_place_patch` -> `NoLostConcurrentPlaceEdit`
4. `outbox_coordinator:bug_pr51_delete_misses_library_revision` -> `NoResurrectedDeletedClip`
5. `handoff_state_machine:bug_invoke_before_dispatching_receipt` -> `AtMostOnceExternalDispatch`
6. `handoff_state_machine:bug_retry_on_unknown_receipt` -> `AtMostOnceExternalDispatch`
7. `handoff_state_machine:bug_archive_before_succeeded` -> `NoArchiveWithoutSucceededReceipt`
8. `enricher_state_machine:bug_missing_ctx_wait_window` -> `NoPrematureEnrichBeforeCtxWindow`
9. `enricher_state_machine:bug_single_page_scan_skips_page2` -> `Liveness:EventualEnrichmentOfPending`
10. `enricher_state_machine:bug_full_body_tag_replace_corrupts_verbatim` -> `VerbatimBodyPreserved`

## Adding a Bug Replay Before Fixing a Defect

Before patching a concurrency, crash-recovery, or retry defect in one of the 3 gated subsystems:

1. Add a boolean flag (`bug_<ref>_<short_name>: bool = False`) to the subsystem's `*BugConfig` dataclass.
2. Encode the buggy transition in `make_next_states` gated by that flag while keeping the fixed transition as default.
3. Add a safety invariant or strengthen the liveness goal if the defect violates a previously unmodeled property.
4. Register `(bug_name, BugConfig(bug_...=True), expected_invariant)` in the module's `BUG_REPLAYS` tuple.
5. Run `python3 -B verification/formal/run_all.py --verify-bug-replays` and confirm:
   - The bug replay prints `[CAUGHT]` with the expected invariant and shortest counterexample trace.
   - The fixed model prints `[PASS]` across the entire reachable state space.
   - Total suite runtime stays well under 5 seconds and all Python files contain zero ordinary comments (`#!/usr/bin/env python3` and `# SPDX-License-Identifier: MIT` only).

## Translating Counterexamples into Regression Tests

Each counterexample step `(action, state)` maps directly to a deterministic interleaving in Swift or Python tests:

1. **Outbox / Coordinator traces** (`outbox_coordinator_model.py`):
   - Map split network actions (`outbox_flush_snapshot` / `outbox_flush_upload`, `refresh_remote_list`, `lib_refresh_list`, `place_patch_get`) to suspended `URLProtocol` or mock-transport continuations in `Tests/CodingRewindCoreTests/LibraryConcurrencyAndBoundsTests.swift` and `CodingRewindCoreTests.swift`.
   - Trigger the interleaved local action (`capture_offline`, `capture_online`, `delete`, second `applyPlacePatch`) while the first continuation is paused, then resume the paused response in trace order and assert the violated safety property holds.
2. **Handoff crash traces** (`handoff_state_machine_model.py`):
   - Map `app_write_current`, `worker_write_dispatching_receipt`, and `worker_crash_*` to on-disk fixture states (`current.json`, `requests/<id>.json`, `receipts/<id>.json`) in `Tests/CodingRewindCoreTests/ConversationHandoffTests.swift`.
   - Instantiate a fresh `ConversationSidecarWorker` (which calls `store.recover()`) and assert `dispatch_count <= 1`, `receipt.state == .unknown`, and zero premature archives.
3. **Enricher traces** (`enricher_state_machine_model.py`):
   - Map `client_post_ctx_comment`, `clock_advance_past_15s`, `reconcile_scan_page1`, `reconcile_scan_page2`, and `process_patch_ready` to fake HTTP handlers and an injectable `clock` in `deploy/vps/enricher/test_enricher.py`.
   - Assert exact verbatim body bytes, deferred enrichment before 15 seconds, page-2 processing, and closed-vocabulary place filtering.
