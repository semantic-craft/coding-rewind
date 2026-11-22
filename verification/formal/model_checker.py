#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
from __future__ import annotations

from collections import defaultdict, deque
from dataclasses import dataclass
from typing import Callable, Hashable, Iterable, Sequence, TypeVar

S = TypeVar("S", bound=Hashable)


@dataclass(frozen=True)
class ModelCheckResult:
    name: str
    passed: bool
    states_explored: int
    transitions_explored: int
    violated_invariant: str | None = None
    counterexample: tuple[tuple[str, str], ...] = ()
    truncated: bool = False


def _reconstruct_path(
    target: S,
    parent: dict[S, tuple[S | None, str]],
    format_state: Callable[[S], str],
) -> tuple[tuple[str, str], ...]:
    steps: list[tuple[str, str]] = []
    cursor: S | None = target
    while cursor is not None:
        prev, action = parent[cursor]
        steps.append((action, format_state(cursor)))
        cursor = prev
    steps.reverse()
    return tuple(steps)


def check_model(
    name: str,
    initial_states: Iterable[S],
    next_states: Callable[[S], Iterable[tuple[str, S]]],
    safety_invariants: Sequence[tuple[str, Callable[[S], bool]]],
    liveness_goal: tuple[str, Callable[[S], bool]] | None = None,
    max_states: int = 100_000,
    format_state: Callable[[S], str] = repr,
) -> ModelCheckResult:
    queue: deque[S] = deque()
    parent: dict[S, tuple[S | None, str]] = {}
    reverse_edges: dict[S, list[S]] = defaultdict(list)
    transitions = 0

    for init_state in initial_states:
        if init_state in parent:
            continue
        parent[init_state] = (None, "INIT")
        for inv_name, predicate in safety_invariants:
            if not predicate(init_state):
                return ModelCheckResult(
                    name=name,
                    passed=False,
                    states_explored=len(parent),
                    transitions_explored=transitions,
                    violated_invariant=inv_name,
                    counterexample=_reconstruct_path(init_state, parent, format_state),
                )
        queue.append(init_state)

    while queue:
        state = queue.popleft()
        for action, nxt in next_states(state):
            transitions += 1
            reverse_edges[nxt].append(state)
            if nxt in parent:
                continue
            if len(parent) >= max_states:
                prefix = _reconstruct_path(state, parent, format_state)
                return ModelCheckResult(
                    name=name,
                    passed=False,
                    states_explored=len(parent),
                    transitions_explored=transitions,
                    violated_invariant="StateSpaceLimitExceeded",
                    counterexample=prefix + ((action, format_state(nxt)),),
                    truncated=True,
                )
            parent[nxt] = (state, action)
            for inv_name, predicate in safety_invariants:
                if not predicate(nxt):
                    return ModelCheckResult(
                        name=name,
                        passed=False,
                        states_explored=len(parent),
                        transitions_explored=transitions,
                        violated_invariant=inv_name,
                        counterexample=_reconstruct_path(nxt, parent, format_state),
                    )
            queue.append(nxt)

    if liveness_goal is not None:
        goal_name, goal_predicate = liveness_goal
        can_reach_goal: set[S] = {state for state in parent if goal_predicate(state)}
        back_queue: deque[S] = deque(can_reach_goal)
        while back_queue:
            current = back_queue.popleft()
            for predecessor in reverse_edges.get(current, ()):
                if predecessor not in can_reach_goal:
                    can_reach_goal.add(predecessor)
                    back_queue.append(predecessor)

        if len(can_reach_goal) < len(parent):
            for candidate in parent:
                if candidate not in can_reach_goal:
                    return ModelCheckResult(
                        name=name,
                        passed=False,
                        states_explored=len(parent),
                        transitions_explored=transitions,
                        violated_invariant=f"Liveness:{goal_name}",
                        counterexample=_reconstruct_path(candidate, parent, format_state),
                    )

    return ModelCheckResult(
        name=name,
        passed=True,
        states_explored=len(parent),
        transitions_explored=transitions,
    )


def verify_bug_replay(
    bug_name: str,
    result: ModelCheckResult,
    expected_invariant: str,
) -> ModelCheckResult:
    if result.passed:
        raise AssertionError(
            f"Bug replay '{bug_name}' unexpectedly passed; expected '{expected_invariant}'"
        )
    if result.violated_invariant != expected_invariant:
        raise AssertionError(
            f"Bug replay '{bug_name}' violated '{result.violated_invariant}', expected '{expected_invariant}'"
        )
    if not result.counterexample:
        raise AssertionError(f"Bug replay '{bug_name}' returned an empty counterexample")
    return result


def format_counterexample(result: ModelCheckResult, indent: str = "    ") -> str:
    lines: list[str] = []
    for idx, (action, state_repr) in enumerate(result.counterexample):
        lines.append(f"{indent}{idx}. {action} -> {state_repr}")
    return "\n".join(lines)
