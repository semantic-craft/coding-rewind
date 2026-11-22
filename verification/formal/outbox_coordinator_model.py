#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Iterator

from model_checker import ModelCheckResult, check_model

CLIP_1 = "c1"
CLIP_2 = "c2"
PLACE_1 = "p1"
PLACE_2 = "p2"


@dataclass(frozen=True)
class OutboxCoordinatorBugConfig:
    bug_1d36ca0_blind_outbox_overwrite: bool = False
    bug_pr9_unversioned_refresh_overwrite: bool = False
    bug_pr51_unserialized_place_patch: bool = False
    bug_pr51_delete_misses_library_revision: bool = False


@dataclass(frozen=True)
class OutboxCoordinatorState:
    outbox: frozenset[str]
    server: frozenset[str]
    confirmed: frozenset[str]
    deleted: frozenset[str]
    hot_cards: frozenset[str]
    library_records: frozenset[str]
    server_places: frozenset[str]
    library_places: frozenset[str]
    committed_places: frozenset[str]
    c2_captured: bool
    flush_phase: str
    flush_snapshot: frozenset[str]
    flush_uploaded: frozenset[str]
    refresh_phase: str
    refresh_snapshot: frozenset[str]
    refresh_stale: bool
    lib_refresh_phase: str
    lib_refresh_records: frozenset[str]
    lib_refresh_places: frozenset[str]
    lib_refresh_stale: bool
    active_patch_actor: int | None
    patch1_phase: str
    patch1_fetched: frozenset[str]
    patch2_phase: str
    patch2_fetched: frozenset[str]


def format_state(s: OutboxCoordinatorState) -> str:
    def fmt_set(items: frozenset[str]) -> str:
        return "{" + ",".join(sorted(items)) + "}"

    parts = [
        f"outbox={fmt_set(s.outbox)}",
        f"server={fmt_set(s.server)}",
        f"hot={fmt_set(s.hot_cards)}",
        f"lib={fmt_set(s.library_records)}",
        f"del={fmt_set(s.deleted)}",
        f"srvP={fmt_set(s.server_places)}",
        f"libP={fmt_set(s.library_places)}",
        f"ackP={fmt_set(s.committed_places)}",
        f"flush={s.flush_phase}",
        f"ref={s.refresh_phase}{'*' if s.refresh_stale else ''}",
        f"libRef={s.lib_refresh_phase}{'*' if s.lib_refresh_stale else ''}",
        f"p1={s.patch1_phase}",
        f"p2={s.patch2_phase}",
    ]
    return "State(" + " ".join(parts) + ")"


def initial_state() -> OutboxCoordinatorState:
    return OutboxCoordinatorState(
        outbox=frozenset({CLIP_1}),
        server=frozenset(),
        confirmed=frozenset({CLIP_1}),
        deleted=frozenset(),
        hot_cards=frozenset({CLIP_1}),
        library_records=frozenset(),
        server_places=frozenset(),
        library_places=frozenset(),
        committed_places=frozenset(),
        c2_captured=False,
        flush_phase="idle",
        flush_snapshot=frozenset(),
        flush_uploaded=frozenset(),
        refresh_phase="idle",
        refresh_snapshot=frozenset(),
        refresh_stale=False,
        lib_refresh_phase="idle",
        lib_refresh_records=frozenset(),
        lib_refresh_places=frozenset(),
        lib_refresh_stale=False,
        active_patch_actor=None,
        patch1_phase="idle",
        patch1_fetched=frozenset(),
        patch2_phase="idle",
        patch2_fetched=frozenset(),
    )


def _mark_local_mutation(s: OutboxCoordinatorState) -> dict[str, object]:
    if s.refresh_phase != "idle":
        return {"refresh_stale": True}
    return {}


def _mark_library_mutation(s: OutboxCoordinatorState) -> dict[str, object]:
    if s.lib_refresh_phase != "idle":
        return {"lib_refresh_stale": True}
    return {}


def make_next_states(bugs: OutboxCoordinatorBugConfig):
    def next_states(s: OutboxCoordinatorState) -> Iterator[tuple[str, OutboxCoordinatorState]]:
        if not s.c2_captured:
            yield (
                "capture_offline(c2)",
                replace(
                    s,
                    c2_captured=True,
                    outbox=s.outbox | {CLIP_2},
                    confirmed=s.confirmed | {CLIP_2},
                    hot_cards=s.hot_cards | {CLIP_2},
                    **_mark_local_mutation(s),
                ),
            )
            yield (
                "capture_online(c2)",
                replace(
                    s,
                    c2_captured=True,
                    server=s.server | {CLIP_2},
                    confirmed=s.confirmed | {CLIP_2},
                    hot_cards=s.hot_cards | {CLIP_2},
                    **_mark_local_mutation(s),
                ),
            )

        if s.flush_phase == "idle" and s.outbox:
            yield (
                "outbox_flush_snapshot",
                replace(
                    s,
                    flush_phase="snapshotted",
                    flush_snapshot=s.outbox,
                    flush_uploaded=frozenset(),
                ),
            )
        elif s.flush_phase == "snapshotted":
            yield (
                "outbox_flush_upload",
                replace(
                    s,
                    flush_phase="uploaded",
                    server=s.server | s.flush_snapshot,
                    flush_uploaded=s.flush_snapshot,
                ),
            )
        elif s.flush_phase == "uploaded":
            if bugs.bug_1d36ca0_blind_outbox_overwrite:
                next_outbox = s.flush_snapshot - s.flush_uploaded
            else:
                next_outbox = s.outbox - s.flush_uploaded
            stale_deleted = s.flush_uploaded & s.deleted
            live_flushed = s.flush_uploaded - s.deleted
            next_server = s.server - stale_deleted
            next_hot = (s.hot_cards | live_flushed) - s.deleted
            local_bump = _mark_local_mutation(s) if s.flush_uploaded else {}
            yield (
                "outbox_flush_commit",
                replace(
                    s,
                    flush_phase="idle",
                    flush_snapshot=frozenset(),
                    flush_uploaded=frozenset(),
                    outbox=next_outbox,
                    server=next_server,
                    hot_cards=next_hot,
                    **local_bump,
                ),
            )

        if s.refresh_phase == "idle":
            yield (
                "refresh_capture_ticket",
                replace(
                    s,
                    refresh_phase="ticketed",
                    refresh_snapshot=frozenset(),
                    refresh_stale=False,
                ),
            )
        elif s.refresh_phase == "ticketed":
            yield (
                "refresh_remote_list",
                replace(
                    s,
                    refresh_phase="listed",
                    refresh_snapshot=s.server,
                ),
            )
        elif s.refresh_phase == "listed":
            if bugs.bug_pr9_unversioned_refresh_overwrite or not s.refresh_stale:
                next_hot = (s.refresh_snapshot | s.outbox) - s.deleted
                yield (
                    "refresh_commit",
                    replace(
                        s,
                        hot_cards=next_hot,
                        refresh_phase="idle",
                        refresh_snapshot=frozenset(),
                        refresh_stale=False,
                    ),
                )
            else:
                yield (
                    "refresh_discard_stale",
                    replace(
                        s,
                        refresh_phase="idle",
                        refresh_snapshot=frozenset(),
                        refresh_stale=False,
                    ),
                )

        if s.lib_refresh_phase == "idle":
            yield (
                "lib_refresh_capture_revision",
                replace(
                    s,
                    lib_refresh_phase="ticketed",
                    lib_refresh_records=frozenset(),
                    lib_refresh_places=frozenset(),
                    lib_refresh_stale=False,
                ),
            )
        elif s.lib_refresh_phase == "ticketed":
            yield (
                "lib_refresh_list",
                replace(
                    s,
                    lib_refresh_phase="listed",
                    lib_refresh_records=s.server,
                    lib_refresh_places=s.server_places,
                ),
            )
        elif s.lib_refresh_phase == "listed":
            if not s.lib_refresh_stale:
                yield (
                    "lib_refresh_commit",
                    replace(
                        s,
                        library_records=s.lib_refresh_records,
                        library_places=s.lib_refresh_places,
                        lib_refresh_phase="idle",
                        lib_refresh_records=frozenset(),
                        lib_refresh_places=frozenset(),
                        lib_refresh_stale=False,
                    ),
                )
            else:
                yield (
                    "lib_refresh_discard_stale",
                    replace(
                        s,
                        lib_refresh_phase="idle",
                        lib_refresh_records=frozenset(),
                        lib_refresh_places=frozenset(),
                        lib_refresh_stale=False,
                    ),
                )

        if (
            CLIP_1 not in s.deleted
            and (CLIP_1 in s.hot_cards or CLIP_1 in s.library_records)
            and CLIP_1 not in s.flush_snapshot
        ):
            lib_bump = (
                {}
                if bugs.bug_pr51_delete_misses_library_revision
                else _mark_library_mutation(s)
            )
            yield (
                "delete(c1)",
                replace(
                    s,
                    deleted=s.deleted | {CLIP_1},
                    outbox=s.outbox - {CLIP_1},
                    server=s.server - {CLIP_1},
                    hot_cards=s.hot_cards - {CLIP_1},
                    library_records=s.library_records - {CLIP_1},
                    server_places=frozenset(),
                    library_places=frozenset(),
                    **_mark_local_mutation(s),
                    **lib_bump,
                ),
            )

        c1_live_on_server = CLIP_1 in s.server and CLIP_1 not in s.deleted

        if s.patch1_phase == "idle" and c1_live_on_server:
            if bugs.bug_pr51_unserialized_place_patch or s.active_patch_actor is None:
                yield (
                    "place_patch_get(actor1,p1)",
                    replace(
                        s,
                        patch1_phase="fetched",
                        patch1_fetched=s.server_places,
                        active_patch_actor=1 if not bugs.bug_pr51_unserialized_place_patch else s.active_patch_actor,
                    ),
                )
        elif s.patch1_phase == "fetched":
            next_active = None if s.active_patch_actor == 1 else s.active_patch_actor
            if c1_live_on_server:
                patched = s.patch1_fetched | {PLACE_1}
                next_lib_places = patched if CLIP_1 in s.library_records else s.library_places
                yield (
                    "place_patch_commit(actor1,p1)",
                    replace(
                        s,
                        patch1_phase="done",
                        patch1_fetched=frozenset(),
                        active_patch_actor=next_active,
                        server_places=patched,
                        library_places=next_lib_places,
                        committed_places=s.committed_places | {PLACE_1},
                        **_mark_local_mutation(s),
                        **_mark_library_mutation(s),
                    ),
                )
            else:
                yield (
                    "place_patch_abort_deleted(actor1)",
                    replace(
                        s,
                        patch1_phase="done",
                        patch1_fetched=frozenset(),
                        active_patch_actor=next_active,
                    ),
                )

        if s.patch2_phase == "idle" and c1_live_on_server:
            if bugs.bug_pr51_unserialized_place_patch or s.active_patch_actor is None:
                yield (
                    "place_patch_get(actor2,p2)",
                    replace(
                        s,
                        patch2_phase="fetched",
                        patch2_fetched=s.server_places,
                        active_patch_actor=2 if not bugs.bug_pr51_unserialized_place_patch else s.active_patch_actor,
                    ),
                )
        elif s.patch2_phase == "fetched":
            next_active = None if s.active_patch_actor == 2 else s.active_patch_actor
            if c1_live_on_server:
                patched = s.patch2_fetched | {PLACE_2}
                next_lib_places = patched if CLIP_1 in s.library_records else s.library_places
                yield (
                    "place_patch_commit(actor2,p2)",
                    replace(
                        s,
                        patch2_phase="done",
                        patch2_fetched=frozenset(),
                        active_patch_actor=next_active,
                        server_places=patched,
                        library_places=next_lib_places,
                        committed_places=s.committed_places | {PLACE_2},
                        **_mark_local_mutation(s),
                        **_mark_library_mutation(s),
                    ),
                )
            else:
                yield (
                    "place_patch_abort_deleted(actor2)",
                    replace(
                        s,
                        patch2_phase="done",
                        patch2_fetched=frozenset(),
                        active_patch_actor=next_active,
                    ),
                )

    return next_states


def inv_no_lost_confirmed_clip(s: OutboxCoordinatorState) -> bool:
    for clip in s.confirmed - s.deleted:
        durable = clip in s.server or clip in s.outbox
        visible = clip in s.hot_cards
        if not (durable and visible):
            return False
    return True


def inv_no_resurrected_deleted_clip(s: OutboxCoordinatorState) -> bool:
    for clip in s.deleted:
        if clip in s.hot_cards or clip in s.library_records:
            return False
    return True


def inv_no_lost_concurrent_place_edit(s: OutboxCoordinatorState) -> bool:
    if CLIP_1 in s.deleted:
        return True
    if not s.committed_places.issubset(s.server_places):
        return False
    if CLIP_1 in s.library_records and not s.committed_places.issubset(s.library_places):
        return False
    return True


def goal_eventual_outbox_drain(s: OutboxCoordinatorState) -> bool:
    if s.outbox:
        return False
    if s.flush_phase != "idle":
        return False
    if s.refresh_phase != "idle" or s.lib_refresh_phase != "idle":
        return False
    if s.patch1_phase == "fetched" or s.patch2_phase == "fetched":
        return False
    live = s.confirmed - s.deleted
    if s.server != live or s.hot_cards != live or s.library_records != live:
        return False
    if CLIP_1 in live and (
        not s.committed_places.issubset(s.server_places)
        or s.library_places != s.server_places
    ):
        return False
    return True


SAFETY_INVARIANTS = (
    ("NoLostConfirmedClip", inv_no_lost_confirmed_clip),
    ("NoResurrectedDeletedClip", inv_no_resurrected_deleted_clip),
    ("NoLostConcurrentPlaceEdit", inv_no_lost_concurrent_place_edit),
)

LIVENESS_GOAL = ("EventualOutboxDrain", goal_eventual_outbox_drain)


def run_model(
    name: str = "outbox_coordinator",
    bugs: OutboxCoordinatorBugConfig | None = None,
    max_states: int = 100_000,
) -> ModelCheckResult:
    cfg = bugs or OutboxCoordinatorBugConfig()
    return check_model(
        name=name,
        initial_states=(initial_state(),),
        next_states=make_next_states(cfg),
        safety_invariants=SAFETY_INVARIANTS,
        liveness_goal=LIVENESS_GOAL,
        max_states=max_states,
        format_state=format_state,
    )


BUG_REPLAYS: tuple[tuple[str, OutboxCoordinatorBugConfig, str], ...] = (
    (
        "bug_1d36ca0_blind_outbox_overwrite",
        OutboxCoordinatorBugConfig(bug_1d36ca0_blind_outbox_overwrite=True),
        "NoLostConfirmedClip",
    ),
    (
        "bug_pr9_unversioned_refresh_overwrite",
        OutboxCoordinatorBugConfig(bug_pr9_unversioned_refresh_overwrite=True),
        "NoLostConfirmedClip",
    ),
    (
        "bug_pr51_unserialized_place_patch",
        OutboxCoordinatorBugConfig(bug_pr51_unserialized_place_patch=True),
        "NoLostConcurrentPlaceEdit",
    ),
    (
        "bug_pr51_delete_misses_library_revision",
        OutboxCoordinatorBugConfig(bug_pr51_delete_misses_library_revision=True),
        "NoResurrectedDeletedClip",
    ),
)
