#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Iterator

from model_checker import ModelCheckResult, check_model

TERMINAL_RECEIPTS = frozenset({"succeeded", "rejected", "expired", "unknown"})


@dataclass(frozen=True)
class HandoffBugConfig:
    bug_invoke_before_dispatching_receipt: bool = False
    bug_retry_on_unknown_receipt: bool = False
    bug_archive_before_succeeded: bool = False


@dataclass(frozen=True)
class HandoffState:
    has_current: bool
    has_request: bool
    receipt: str
    dispatch_count: int
    archived: bool
    clock_expired: bool
    app_phase: str
    worker_phase: str
    crashed_during_dispatch: bool


def format_state(s: HandoffState) -> str:
    return (
        f"State(current={int(s.has_current)} req={int(s.has_request)} "
        f"receipt={s.receipt} dispatches={s.dispatch_count} "
        f"archived={int(s.archived)} exp={int(s.clock_expired)} "
        f"app={s.app_phase} worker={s.worker_phase} "
        f"dispatchCrash={int(s.crashed_during_dispatch)})"
    )


def initial_state() -> HandoffState:
    return HandoffState(
        has_current=False,
        has_request=False,
        receipt="none",
        dispatch_count=0,
        archived=False,
        clock_expired=False,
        app_phase="idle",
        worker_phase="idle",
        crashed_during_dispatch=False,
    )


def make_next_states(bugs: HandoffBugConfig):
    def next_states(s: HandoffState) -> Iterator[tuple[str, HandoffState]]:
        if not s.clock_expired and (s.has_current or s.has_request):
            yield ("clock_expire_ttl", replace(s, clock_expired=True))

        if s.app_phase == "idle":
            yield (
                "app_write_current",
                replace(s, has_current=True, app_phase="wrote_current"),
            )
        elif s.app_phase == "wrote_current":
            yield (
                "app_write_request",
                replace(s, has_request=True, app_phase="submitted"),
            )
            yield (
                "app_crash_after_current",
                replace(s, app_phase="crashed"),
            )
        elif s.app_phase == "submitted":
            if bugs.bug_archive_before_succeeded and not s.archived:
                yield (
                    "app_archive_prematurely",
                    replace(s, archived=True),
                )
            if s.receipt == "succeeded" and not s.archived:
                yield (
                    "app_archive_after_succeeded",
                    replace(s, archived=True),
                )
            elif s.receipt == "succeeded" and s.archived and s.has_current:
                yield (
                    "app_clear_current_succeeded",
                    replace(s, has_current=False, app_phase="done"),
                )
            elif s.receipt in ("rejected", "expired") and s.has_current:
                yield (
                    f"app_clear_current_{s.receipt}",
                    replace(s, has_current=False, app_phase="done"),
                )
            elif s.receipt == "unknown" and s.has_current:
                yield (
                    "app_end_unconfirmed",
                    replace(s, has_current=False, app_phase="done"),
                )
            yield (
                "app_crash_while_submitted",
                replace(s, app_phase="crashed"),
            )
        elif s.app_phase == "crashed":
            if s.has_current:
                yield ("app_restart", replace(s, app_phase="submitted"))
            else:
                yield ("app_restart_done", replace(s, app_phase="done"))

        if s.worker_phase == "idle":
            if s.has_current and not s.has_request and s.receipt == "none" and s.clock_expired:
                yield (
                    "worker_expire_unpublished_current",
                    replace(s, receipt="expired"),
                )
            if s.has_request:
                if s.receipt in ("succeeded", "rejected", "expired"):
                    yield (
                        "worker_remove_terminal_request",
                        replace(s, has_request=False),
                    )
                elif s.receipt == "unknown":
                    if bugs.bug_retry_on_unknown_receipt and s.dispatch_count < 2:
                        yield (
                            "worker_retry_unknown_begin_dispatch",
                            replace(
                                s,
                                receipt="dispatching",
                                worker_phase="ready_to_invoke",
                            ),
                        )
                    else:
                        yield (
                            "worker_remove_unknown_request",
                            replace(s, has_request=False),
                        )
                elif s.receipt == "none":
                    if s.clock_expired:
                        yield (
                            "worker_mark_expired",
                            replace(
                                s,
                                receipt="expired",
                                worker_phase="removing_request",
                            ),
                        )
                    elif bugs.bug_invoke_before_dispatching_receipt and s.dispatch_count < 2:
                        for outcome in ("succeeded", "rejected", "unknown"):
                            yield (
                                f"worker_invoke_before_receipt({outcome})",
                                replace(
                                    s,
                                    dispatch_count=s.dispatch_count + 1,
                                    worker_phase=f"invoked:{outcome}",
                                ),
                            )
                    else:
                        yield (
                            "worker_write_dispatching_receipt",
                            replace(
                                s,
                                receipt="dispatching",
                                worker_phase="ready_to_invoke",
                            ),
                        )
        elif s.worker_phase == "ready_to_invoke":
            if s.dispatch_count < 2:
                for outcome in ("succeeded", "rejected", "unknown"):
                    yield (
                        f"worker_invoke({outcome})",
                        replace(
                            s,
                            dispatch_count=s.dispatch_count + 1,
                            worker_phase=f"invoked:{outcome}",
                        ),
                    )
            yield (
                "worker_crash_before_invoke",
                replace(
                    s,
                    worker_phase="crashed",
                    crashed_during_dispatch=(s.crashed_during_dispatch or s.receipt == "dispatching"),
                ),
            )
        elif s.worker_phase.startswith("invoked:"):
            outcome = s.worker_phase.split(":", 1)[1]
            yield (
                f"worker_write_final_receipt({outcome})",
                replace(
                    s,
                    receipt=outcome,
                    worker_phase="removing_request",
                ),
            )
            yield (
                "worker_crash_after_invoke_before_receipt",
                replace(
                    s,
                    worker_phase="crashed",
                    crashed_during_dispatch=(s.crashed_during_dispatch or s.receipt == "dispatching"),
                ),
            )
        elif s.worker_phase == "removing_request":
            if not (bugs.bug_retry_on_unknown_receipt and s.receipt == "unknown"):
                yield (
                    "worker_remove_request",
                    replace(s, has_request=False, worker_phase="idle"),
                )
            else:
                yield (
                    "worker_keep_unknown_request_for_retry",
                    replace(s, worker_phase="idle"),
                )
            yield (
                "worker_crash_before_remove_request",
                replace(s, worker_phase="crashed"),
            )
        elif s.worker_phase == "crashed":
            if s.receipt == "dispatching":
                yield (
                    "worker_recover_dispatching_to_unknown",
                    replace(
                        s,
                        receipt="unknown",
                        has_request=(
                            s.has_request
                            if bugs.bug_retry_on_unknown_receipt
                            else False
                        ),
                        worker_phase="idle",
                    ),
                )
                yield (
                    "worker_recover_write_unknown_then_crash",
                    replace(
                        s,
                        receipt="unknown",
                        worker_phase="crashed",
                    ),
                )
            elif s.receipt in TERMINAL_RECEIPTS:
                yield (
                    "worker_recover_cleanup_terminal_request",
                    replace(
                        s,
                        has_request=(
                            s.has_request
                            if (bugs.bug_retry_on_unknown_receipt and s.receipt == "unknown")
                            else False
                        ),
                        worker_phase="idle",
                    ),
                )
            elif s.has_current and not s.has_request and s.receipt == "none" and s.clock_expired:
                yield (
                    "worker_recover_expire_unpublished",
                    replace(
                        s,
                        receipt="expired",
                        worker_phase="idle",
                    ),
                )
            else:
                yield (
                    "worker_recover_idle",
                    replace(s, worker_phase="idle"),
                )

    return next_states


def inv_at_most_once_external_dispatch(s: HandoffState) -> bool:
    return s.dispatch_count <= 1


def inv_no_archive_without_succeeded_receipt(s: HandoffState) -> bool:
    return (not s.archived) or s.receipt == "succeeded"


def inv_crash_during_dispatch_becomes_unknown(s: HandoffState) -> bool:
    if s.worker_phase == "idle" and s.receipt == "dispatching":
        return False
    if s.crashed_during_dispatch and s.worker_phase == "idle":
        return s.receipt == "unknown"
    return True


def goal_every_request_reaches_terminal_state(s: HandoffState) -> bool:
    return (
        s.receipt in TERMINAL_RECEIPTS
        and not s.has_request
        and not s.has_current
        and s.worker_phase == "idle"
        and s.app_phase == "done"
    )


SAFETY_INVARIANTS = (
    ("AtMostOnceExternalDispatch", inv_at_most_once_external_dispatch),
    ("NoArchiveWithoutSucceededReceipt", inv_no_archive_without_succeeded_receipt),
    ("CrashDuringDispatchBecomesUnknown", inv_crash_during_dispatch_becomes_unknown),
)

LIVENESS_GOAL = ("EveryRequestReachesTerminalState", goal_every_request_reaches_terminal_state)


def run_model(
    name: str = "handoff_state_machine",
    bugs: HandoffBugConfig | None = None,
    max_states: int = 100_000,
) -> ModelCheckResult:
    cfg = bugs or HandoffBugConfig()
    return check_model(
        name=name,
        initial_states=(initial_state(),),
        next_states=make_next_states(cfg),
        safety_invariants=SAFETY_INVARIANTS,
        liveness_goal=LIVENESS_GOAL,
        max_states=max_states,
        format_state=format_state,
    )


BUG_REPLAYS: tuple[tuple[str, HandoffBugConfig, str], ...] = (
    (
        "bug_invoke_before_dispatching_receipt",
        HandoffBugConfig(bug_invoke_before_dispatching_receipt=True),
        "AtMostOnceExternalDispatch",
    ),
    (
        "bug_retry_on_unknown_receipt",
        HandoffBugConfig(bug_retry_on_unknown_receipt=True),
        "AtMostOnceExternalDispatch",
    ),
    (
        "bug_archive_before_succeeded",
        HandoffBugConfig(bug_archive_before_succeeded=True),
        "NoArchiveWithoutSucceededReceipt",
    ),
)
