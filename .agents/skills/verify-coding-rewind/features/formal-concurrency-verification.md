# Formal concurrency verification

Formal concurrency verification runs exhaustive explicit-state BFS model checking across Coding Rewind's 3 gated concurrency, crash-recovery, and retry state machines and replays 10 historical production bugs to prove each model catches its target defect.

## Sub-features

- `formal-outbox-coordinator` verifies `NoLostConfirmedClip`, `NoResurrectedDeletedClip`, `NoLostConcurrentPlaceEdit`, and liveness `EventualOutboxDrain`.
- `formal-handoff-sidecar` verifies `AtMostOnceExternalDispatch`, `NoArchiveWithoutSucceededReceipt`, `CrashDuringDispatchBecomesUnknown`, and liveness `EveryRequestReachesTerminalState`.
- `formal-enricher-state-machine` verifies `VerbatimBodyPreserved`, `NoPrematureEnrichBeforeCtxWindow`, `ClosedVocabularyPlacesOnly`, `SynthesizedNeverRegresses`, and liveness `EventualEnrichmentOfPending`.
- `formal-bug-replays` mutates each model with 10 historical bug configurations and asserts every mutant violates its exact expected invariant.

## How to get to it (user POV)

- Run the formal verification runner directly from the repository root before merging concurrency or state-machine changes.
- Run `./scripts/check` locally or let GitHub Actions `linux-formal-lint-and-real-memos-e2e` gate the pull request.

## Driving it with verification/formal/run_all.py

Preconditions:

- Python 3.12+ is available on `PATH`.
- Working directory is the repository root.

- **Run all 3 fixed models plus 10 bug replays.** Execute `python3 -B verification/formal/run_all.py --verify-bug-replays`. Exit code is `0`; stdout reports `[PASS]` for all 3 fixed models and `[CAUGHT]` for all 10 historical bug replays with shortest counterexample traces.
- **Run structural invariant lints alongside models.** Execute `python3 -B scripts/lint_invariants.py`. Exit code is `0`, verifying zero ordinary comments in `verification/formal/` and verifying `OfflineOutbox.withFileLock` locks the sidecar `.lock` file and `AppCoordinator+Places.swift` uses `resultLimit: .unbounded`.
- **Confirm full repository gate.** Execute `./scripts/check`. Step `[2/9] Formal state-machine verification` exits `0` and the full gate prints `PASS: all verification checks succeeded.`.

## Gotchas

- Never pass `--skip-bug-replays` when claiming full formal verification; a broken invariant predicate can vacuously pass the fixed model while failing to catch the historical mutant.
- Formal modeling is strictly gated to the 3 concurrency/crash-recovery subsystems documented in `.agents/skills/formal-verify-coding-rewind/SKILL.md`. Do not model ordinary sequential CRUD or SwiftUI layout code.
- Always invoke Python with `-B` so `__pycache__` artifacts are not created in the working tree.
