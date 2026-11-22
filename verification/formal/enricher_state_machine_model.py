#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Iterator

from model_checker import ModelCheckResult, check_model

PLACE_VOCABULARY = frozenset({"project/alpha", "topic/perf"})
AI_PLACE_PROPOSALS: tuple[tuple[str, ...], ...] = (
    ("project/alpha",),
    ("project/alpha", "project/hallucinated"),
)


@dataclass(frozen=True)
class EnricherBugConfig:
    bug_missing_ctx_wait_window: bool = False
    bug_single_page_scan_skips_page2: bool = False
    bug_full_body_tag_replace_corrupts_verbatim: bool = False


@dataclass(frozen=True)
class MemoState:
    memo_id: str
    page: int
    status: str
    has_ctx: bool
    ctx_comment_posted: bool
    verbatim_contains_pending_tag: bool
    verbatim_intact: bool
    places: tuple[str, ...]
    premature_enrich: bool
    was_synthesized: bool


@dataclass(frozen=True)
class EnricherState:
    memos: tuple[MemoState, ...]
    clock_past_ctx_window: bool
    scan_phase: str
    snapshot_queue: tuple[str, ...]


def format_state(s: EnricherState) -> str:
    memo_strs = []
    for m in s.memos:
        flags = []
        if m.has_ctx:
            flags.append(f"ctx={'yes' if m.ctx_comment_posted else 'wait'}")
        if not m.verbatim_intact:
            flags.append("VERBATIM_CORRUPTED")
        if m.premature_enrich:
            flags.append("PREMATURE")
        if m.places:
            flags.append("places=" + ",".join(m.places))
        flag_str = "(" + " ".join(flags) + ")" if flags else ""
        memo_strs.append(f"{m.memo_id}@p{m.page}:{m.status}{flag_str}")
    return (
        f"State(clk>15s={int(s.clock_past_ctx_window)} phase={s.scan_phase} "
        f"q={list(s.snapshot_queue)} memos=[{'; '.join(memo_strs)}])"
    )


def initial_state() -> EnricherState:
    return EnricherState(
        memos=(
            MemoState(
                memo_id="m1",
                page=1,
                status="pending",
                has_ctx=True,
                ctx_comment_posted=False,
                verbatim_contains_pending_tag=True,
                verbatim_intact=True,
                places=(),
                premature_enrich=False,
                was_synthesized=False,
            ),
            MemoState(
                memo_id="m2",
                page=2,
                status="pending",
                has_ctx=False,
                ctx_comment_posted=False,
                verbatim_contains_pending_tag=False,
                verbatim_intact=True,
                places=(),
                premature_enrich=False,
                was_synthesized=False,
            ),
            MemoState(
                memo_id="m3",
                page=1,
                status="synthesized",
                has_ctx=False,
                ctx_comment_posted=False,
                verbatim_contains_pending_tag=False,
                verbatim_intact=True,
                places=("project/alpha",),
                premature_enrich=False,
                was_synthesized=True,
            ),
        ),
        clock_past_ctx_window=False,
        scan_phase="idle",
        snapshot_queue=(),
    )


def _select_closed_vocabulary_places(proposed: tuple[str, ...]) -> tuple[str, ...]:
    selected: list[str] = []
    for ref in proposed:
        if ref in PLACE_VOCABULARY and ref not in selected:
            selected.append(ref)
    return tuple(selected)


def _replace_memo(memos: tuple[MemoState, ...], updated: MemoState) -> tuple[MemoState, ...]:
    return tuple(updated if m.memo_id == updated.memo_id else m for m in memos)


def make_next_states(bugs: EnricherBugConfig):
    def next_states(s: EnricherState) -> Iterator[tuple[str, EnricherState]]:
        for m in s.memos:
            if m.has_ctx and not m.ctx_comment_posted:
                yield (
                    f"client_post_ctx_comment({m.memo_id})",
                    replace(s, memos=_replace_memo(s.memos, replace(m, ctx_comment_posted=True))),
                )
            if m.status == "ready" and not m.was_synthesized:
                yield (
                    f"user_archive_to_synthesized({m.memo_id})",
                    replace(
                        s,
                        memos=_replace_memo(
                            s.memos,
                            replace(m, status="synthesized", was_synthesized=True),
                        ),
                    ),
                )

        if not s.clock_past_ctx_window:
            yield ("clock_advance_past_15s", replace(s, clock_past_ctx_window=True))

        if s.scan_phase == "idle":
            p1_candidates = tuple(
                m.memo_id for m in s.memos if m.page == 1 and m.status == "pending"
            )
            if bugs.bug_single_page_scan_skips_page2:
                next_phase = "processing" if p1_candidates else "idle"
                yield (
                    "reconcile_scan_page1_only",
                    replace(s, scan_phase=next_phase, snapshot_queue=p1_candidates),
                )
            else:
                yield (
                    "reconcile_scan_page1",
                    replace(s, scan_phase="scanned_page1", snapshot_queue=p1_candidates),
                )
        elif s.scan_phase == "scanned_page1":
            p2_candidates = tuple(
                m.memo_id for m in s.memos if m.page == 2 and m.status == "pending"
            )
            combined = s.snapshot_queue + p2_candidates
            next_phase = "processing" if combined else "idle"
            yield (
                "reconcile_scan_page2",
                replace(s, scan_phase=next_phase, snapshot_queue=combined),
            )
        elif s.scan_phase == "processing":
            if not s.snapshot_queue:
                yield ("reconcile_finish", replace(s, scan_phase="idle"))
                return
            head_id = s.snapshot_queue[0]
            tail = s.snapshot_queue[1:]
            next_phase = "processing" if tail else "idle"
            memo = next(m for m in s.memos if m.memo_id == head_id)
            if memo.status != "pending":
                yield (
                    f"process_skip_non_pending({head_id})",
                    replace(s, scan_phase=next_phase, snapshot_queue=tail),
                )
                return
            if memo.has_ctx and not memo.ctx_comment_posted and not s.clock_past_ctx_window:
                if not bugs.bug_missing_ctx_wait_window:
                    yield (
                        f"process_defer_ctx_wait({head_id})",
                        replace(s, scan_phase=next_phase, snapshot_queue=tail),
                    )
                    return

            premature = (
                memo.has_ctx
                and not memo.ctx_comment_posted
                and not s.clock_past_ctx_window
            )
            verbatim_intact = memo.verbatim_intact and not (
                bugs.bug_full_body_tag_replace_corrupts_verbatim
                and memo.verbatim_contains_pending_tag
            )
            for proposal in AI_PLACE_PROPOSALS:
                chosen_places = _select_closed_vocabulary_places(proposal)
                updated_memo = replace(
                    memo,
                    status="ready",
                    places=chosen_places,
                    verbatim_intact=verbatim_intact,
                    premature_enrich=memo.premature_enrich or premature,
                )
                yield (
                    f"process_patch_ready({head_id},ai={list(proposal)})",
                    replace(
                        s,
                        memos=_replace_memo(s.memos, updated_memo),
                        scan_phase=next_phase,
                        snapshot_queue=tail,
                    ),
                )

    return next_states


def inv_verbatim_body_preserved(s: EnricherState) -> bool:
    return all(m.verbatim_intact for m in s.memos)


def inv_no_premature_enrich_before_ctx_window(s: EnricherState) -> bool:
    return not any(m.premature_enrich for m in s.memos)


def inv_closed_vocabulary_places_only(s: EnricherState) -> bool:
    return all(set(m.places).issubset(PLACE_VOCABULARY) for m in s.memos)


def inv_synthesized_never_regresses(s: EnricherState) -> bool:
    return all((not m.was_synthesized) or m.status == "synthesized" for m in s.memos)


def goal_eventual_enrichment_of_pending(s: EnricherState) -> bool:
    if s.scan_phase != "idle":
        return False
    return all(m.status in ("ready", "synthesized") for m in s.memos)


SAFETY_INVARIANTS = (
    ("VerbatimBodyPreserved", inv_verbatim_body_preserved),
    ("NoPrematureEnrichBeforeCtxWindow", inv_no_premature_enrich_before_ctx_window),
    ("ClosedVocabularyPlacesOnly", inv_closed_vocabulary_places_only),
    ("SynthesizedNeverRegresses", inv_synthesized_never_regresses),
)

LIVENESS_GOAL = ("EventualEnrichmentOfPending", goal_eventual_enrichment_of_pending)


def run_model(
    name: str = "enricher_state_machine",
    bugs: EnricherBugConfig | None = None,
    max_states: int = 100_000,
) -> ModelCheckResult:
    cfg = bugs or EnricherBugConfig()
    return check_model(
        name=name,
        initial_states=(initial_state(),),
        next_states=make_next_states(cfg),
        safety_invariants=SAFETY_INVARIANTS,
        liveness_goal=LIVENESS_GOAL,
        max_states=max_states,
        format_state=format_state,
    )


BUG_REPLAYS: tuple[tuple[str, EnricherBugConfig, str], ...] = (
    (
        "bug_missing_ctx_wait_window",
        EnricherBugConfig(bug_missing_ctx_wait_window=True),
        "NoPrematureEnrichBeforeCtxWindow",
    ),
    (
        "bug_single_page_scan_skips_page2",
        EnricherBugConfig(bug_single_page_scan_skips_page2=True),
        "Liveness:EventualEnrichmentOfPending",
    ),
    (
        "bug_full_body_tag_replace_corrupts_verbatim",
        EnricherBugConfig(bug_full_body_tag_replace_corrupts_verbatim=True),
        "VerbatimBodyPreserved",
    ),
)
