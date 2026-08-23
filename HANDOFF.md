# HANDOFF - splitting KubeView into two apps

## CURRENT STATE (read this first)

**Date:** 2026-08-23
**Both repos are committed, clean and building. Nothing has been pushed.**

| Repo | HEAD | State |
|---|---|---|
| `~/GitHub/kubeview` | `1b392dd` | clean, `swift build` green |
| `~/GitHub/kubectl-lgtm` | `16528d5` | clean, `go build` + `go test ./...` green |

`origin` is untouched for both. Every commit listed above is local only.

**The plan lives here:** https://claude.ai/code/artifact/4f483667-6f3e-4359-a06e-a769ede5e7e8
Read it before starting. This file covers state and traps; the artifact covers the design.

**Next action:** Phase 1 (unify bundling). Phase 0 is done except for removing the stale
worktree - see "First actions".

---

## What just landed

Four days of unbanked work from two Claude sessions, plus a body of analyser work, all
committed:

- **kubeview `1b392dd`** - tab-based navigation (`TabStore`, `TabStripView`), AWS profiles
  (`AwsStore`, `AwsView`), the resource graph (`ResourceGraph`, `NamespaceGraphView`), and
  the whole LGTM view (five `Lgtm*.swift` files, `LgtmService`, `Subprocess`).
- **kubectl-lgtm `4cc2673..16528d5`** - port-forward discovery, `--json` output mode over a
  shared analysis pipeline, per-pod measurement, unique component titles, and the removal of
  shell commands from findings.

The kubeview work went in as **one commit on purpose**. The two sessions' work is mutually
dependent at HEAD - `ContentView` routes to `LgtmView`, and `LgtmView.swift` holds
`@EnvironmentObject var tabs: TabStore` - so any per-author split would have produced
non-building intermediates. One honest snapshot beat fake-clean history.

The session that wrote the tab layout has ended. Its work is in that commit and it was not
able to review the sweep.

---

## Standing rules for this work

- **Commit periodically without asking.** Push, tag and release need explicit confirmation
  from Ondrej. This changed on 2026-08-23; older notes saying "never commit" are superseded.
- Single-line commit messages, no `Co-Authored-By`.
- Plain hyphens, not em dashes, in code, UI strings, commits and output.
- Report findings and give ranked options before fixing; don't fix-then-report.
- `~/GitHub/` repos push directly to `main` - no branches or PRs.

---

## First actions

1. **Remove the stale worktree.** `~/GitHub/kubeview-lgtm` on branch `lgtm-view` holds three
   LGTM files frozen at an old state and is missing two others entirely. It is redundant and
   actively misleading. `git worktree remove` it and delete the branch.
2. **Phase 1 - unify bundling.** See "Trap 5" below. This is the prerequisite that stops the
   split forking existing drift into four copies.
3. **Then Phase 2** - sever, split the models, move, `public` sweep. In that order.

Repo cleanup (archiving `omaksi/kubectl-lgtm`) happens **after** the monorepo's tests are
green, not before. There must be a working state to fall back to.

---

## Traps - each of these cost real investigation

**1. Clamping in the producer.** Raw ratios travel to the renderer; only geometry clamps,
never text. This bug class appeared four times in the LGTM view and every instance produced
a plausible-looking number rather than a visible failure - a component at 198% of its limit
displaying "100%". A doc comment reading "0...1 fill" is what caused it. Details in
`CLAUDE.md` under "Raw measurements travel to the renderer".

**2. `ContentView` keeps SwiftUI identity across cluster switches.** `LgtmView` must stay
keyed with `.id(store.context)` at the call site or it shows the previous cluster's data
under the new cluster's name. This shipped once.

**3. SwiftPM silently drops files no target's source set covers.** No warning. An
unreferenced orphan vanishes with zero signal. After every move batch in Phase 2, diff
`find Sources -name '*.swift' | sort` against the declared sources.

**4. A synthesized memberwise init on a `public` struct is always `internal`.** Verified by
compiling a throwaway package. Seven view structs will need hand-written `public init`s.
Synthesized `Decodable.init(from:)` *is* public, so the models need no init work.

**5. Bundling is implemented twice and has drifted three ways.** `release.yml` never calls
`bundle.sh`; it hand-rolls its own bundle at lines 57-61. Consequences, both live today:
- **The shipped app has no LGTM helper.** `bundle.sh:29-36` builds `kubectl-lgtm` from a
  sibling `../kubectl-lgtm` checkout that CI never makes, and skips silently. The feature is
  dev-only in practice. `LgtmService.swift:136` resolves it via
  `Bundle.main.url(forAuxiliaryExecutable:)`, which just returns `nil` - no error, no log.
- **Dev and release builds disagree on bundle id.** `com.ondrej.kubeview` vs
  `com.omaksi.kubeview`. macOS keys `UserDefaults` off it, so they keep separate preferences.

**6. `--json` is committed but not released.** `kubectl-lgtm`'s published `v0.1.0` (Aug 7)
predates the `--json` flag entirely. Anyone who `brew install`s the analyser today gets a
binary the app cannot talk to. A release is required before "document it as a prerequisite"
becomes a real answer.

**7. Two navigation mechanisms leave LGTM, not one.** `showPods()` at `LgtmView.swift`
writes four stores directly. But `LgtmClusterView.swift:263` and `:632` also wrap every pod
card in `NavigationLink(value: AppRoute.pod(...))`, resolved by `ContentView.swift:254`. A
grep for state writes does not find the second one. Both break on a process boundary; the
replacement is a Logs/Describe sheet inside the LGTM app.

**8. Three duplications in the LGTM view are deliberate.** `LgtmFactBar` (not `UsageBar`,
which grades at fixed thresholds), `LgtmPodUsageCardBody` (not `PodCardBody`, which lacks a
metrics bar), `LgtmGraphLayout` (not `ResourceGraph`, which assumes typed kinds). Do not
"unify" them during the migration.

**9. `Subprocess.run` calls `LogStore.record` directly.** LGTM code never names `LogStore`,
so no grep of the LGTM files finds it, but it is a transitive dependency and must move down
with `Subprocess`.

**10. One Mimir, five clusters.** The reference store holds metrics for five EKS clusters.
Mimir/Loki/Tempo/Grafana rows are clean - only `inno-shared-eks` runs them. But all three
Alloy rows blend: the `alloy` DaemonSet shows 171 pods when 41 are this cluster's, and
`alloy-metrics` is worse because pod names collide across clusters (`alloy-metrics-0` exists
five times), so it *looks* exact at 3 replicas while every value is a five-cluster max.
Unfixed - scoping to `cluster="..."` is an open decision.

---

## Open decisions (Ondrej's, not yet made)

1. **Name for the second app.** Lean: `LgtmInspector`, `com.omaksi.lgtminspector`, cask
   `lgtm-inspector`.
2. **Embed the analyser or require it via brew.** Lean: brew prerequisite, after a release
   carrying `--json`.
3. **Absorb `kubectl-lgtm` into the monorepo.** Lean: yes, into `Tools/kubectl-lgtm/`, via
   `git subtree` so its history survives.
4. **Does KubeView keep an LGTM entry point.** Lean: remove entirely - the cut is eight
   sites in `ContentView.swift`.

---

## Verification state

- `swift build` green; `go build ./...` and `go test ./...` green.
- The LGTM view was verified end to end against `inno-shared-eks` at a 1d window: all 30
  components carry per-pod arrays, and `max(pods) == top-level scalar` holds for every one.
- **CI runs no tests at all.** `release.yml` is the only workflow and contains no
  `swift test` and no `go test`. Ten `selfCheck` functions exist in Swift and the Go suites
  pass, but nothing executes them except a human opening the right view in a debug build.
  Adding `ci.yml` is part of the plan.
