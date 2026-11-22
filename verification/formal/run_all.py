#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
from __future__ import annotations

import argparse
from pathlib import Path
import sys
import time

sys.dont_write_bytecode = True

FORMAL_DIR = Path(__file__).resolve().parent
if str(FORMAL_DIR) not in sys.path:
    sys.path.insert(0, str(FORMAL_DIR))

import enricher_state_machine_model
import handoff_state_machine_model
from model_checker import format_counterexample, verify_bug_replay
import outbox_coordinator_model


FIXED_MODELS = (
    ("outbox_coordinator", outbox_coordinator_model.run_model),
    ("handoff_state_machine", handoff_state_machine_model.run_model),
    ("enricher_state_machine", enricher_state_machine_model.run_model),
)

BUG_REPLAY_SUITES = (
    ("outbox_coordinator", outbox_coordinator_model.run_model, outbox_coordinator_model.BUG_REPLAYS),
    ("handoff_state_machine", handoff_state_machine_model.run_model, handoff_state_machine_model.BUG_REPLAYS),
    ("enricher_state_machine", enricher_state_machine_model.run_model, enricher_state_machine_model.BUG_REPLAYS),
)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run exhaustive explicit-state formal verification models."
    )
    parser.add_argument(
        "--verify-bug-replays",
        action="store_true",
        help="Also run all historical bug mutants and require each to be caught.",
    )
    args = parser.parse_args(argv)

    started = time.perf_counter()
    failures = 0

    print("Formal Verification Suite (Fixed Models)")
    for model_name, runner in FIXED_MODELS:
        t0 = time.perf_counter()
        result = runner()
        dt = time.perf_counter() - t0
        status = "PASS" if result.passed else "FAIL"
        print(
            f"  [{status}] {model_name}: "
            f"{result.states_explored} states, {result.transitions_explored} transitions ({dt:.3f}s)"
        )
        if not result.passed:
            failures += 1
            print(f"    violated: {result.violated_invariant}")
            print(format_counterexample(result))

    if args.verify_bug_replays:
        print("\nHistorical Bug Replay Verification")
        for model_name, runner, replays in BUG_REPLAY_SUITES:
            for bug_name, bug_cfg, expected_invariant in replays:
                t0 = time.perf_counter()
                result = runner(name=f"{model_name}:{bug_name}", bugs=bug_cfg)
                dt = time.perf_counter() - t0
                try:
                    verify_bug_replay(bug_name, result, expected_invariant)
                except AssertionError as exc:
                    failures += 1
                    print(f"  [MISS] {model_name}:{bug_name}: {exc}")
                    continue
                print(
                    f"  [CAUGHT] {model_name}:{bug_name} -> {result.violated_invariant} "
                    f"({len(result.counterexample)} steps, {result.states_explored} states explored, {dt:.3f}s)"
                )
                print(format_counterexample(result))

    total_dt = time.perf_counter() - started
    if failures:
        print(f"\nFAIL: {failures} formal verification check(s) failed ({total_dt:.3f}s)", file=sys.stderr)
        return 1
    print(f"\nPASS: all formal verification checks succeeded ({total_dt:.3f}s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
