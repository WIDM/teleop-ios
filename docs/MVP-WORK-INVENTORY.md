# Local work inventory

Snapshot date: 2026-11-19. These are recovery checkpoints, not release claims.

| Work area | Existing changes | Treatment |
| --- | --- | --- |
| Active App worktree | 69 tracked modifications and 25 new paths, including tests | Preserve together before height integration |
| Earlier fixes worktree (`f11a`) | 23 tracked modifications and one new test | Preserve as its own checkpoint; do not merge blindly |
| Earlier alternate worktree (`f11b`) | Clean at `0d5508d` | Leave unchanged |
| Isolated Python server candidate | Previously validated tool and coordinated-height control, transport and tests | Preserve in a separate local-only repository |

## Included work

- Camera/tracking recovery, feedback freshness and rejected-action/slow-link handling.
- Tool-point movement, blocked feedback, stop-confirmation resynchronization and session diagnostics.
- Assistance diagrams, tap height/retarget work and precision controls, plus their existing regression/UI coverage.
- On-device voice axis/action prototypes and experiment timing instrumentation. These remain preserved experiments; this MVP adds no speech capability.
- Documentation, localized resources and existing safety-check fixes.

## Release distinction

The checkpoint retains the exact combined working state rather than claiming that every experiment is accepted. Voice actions are not part of this MVP. Experimental data collection is not a reason to block manual-control acceptance or add functionality. The frozen scope and acceptance gates are in `MVP-1.1.1.md`.

The installed phone build at checkpoint time is 26. Coordinated-height physics has passed isolated validation but is not yet selected per hold by the App. The integration must preserve ordinary XYZ behavior and use a separately advertised capability; a generic tool-point capability is insufficient.
