# HANDOFF - the two-app split

## CURRENT STATE (read this first)

**Date:** 2026-08-23
**The split is done. Everything is green. Nothing has been pushed.**

| Check | Result |
|---|---|
| `swift build` | clean |
| `swift test` | 56 tests, 0 failures |
| `go test ./...` (Tools/kubectl-lgtm) | 6 packages ok |
| `./scripts/check-sources.sh` | OK |

`origin` is untouched: **29 commits unpushed here** (18 authored in this work, the
rest arriving with the subtree merge that carries the Go repo history), and **7
unpushed** in `~/GitHub/kubectl-lgtm`. Both are clean fast-forwards.

**Pushing needs credentials this machine does not have** - no `gh`, no GitHub SSH
key, nothing in the keychain for github.com, and a global `insteadOf` rewrite
forcing HTTPS. Ondrej has to authenticate once.

**The design lives here:** https://claude.ai/code/artifact/4f483667-6f3e-4359-a06e-a769ede5e7e8

---

## What the repo looks like now

```
Sources/
  KubeModel/     14 files  pure data, Foundation only - no I/O, no SwiftUI
  KubeClient/     3        all cluster I/O, Foundation only - a CLI could link it
  KubeUI/         6        shared SwiftUI chrome, used by both apps
  KubeViewKit/   34        cluster-browser app logic
  KubeView/       1        @main shell, 10 lines
  LgtmViewKit/    8        LGTM inspector logic
  LgtmView/       1        @main shell, 10 lines
Tests/           8 files   56 tests across 4 targets
Tools/
  kubectl-lgtm/            the Go analyser, absorbed via git subtree, history intact
```

Dependencies run strictly one way:
`KubeModel <- KubeClient <- KubeUI <- {KubeViewKit, LgtmViewKit} <- {KubeView, LgtmView}`.

A third app that needs no GUI depends on `KubeModel` and `KubeClient` and never
links SwiftUI. That is what the third layer is for.

**The two apps share no types and no state.** KubeView has no LGTM references at
all; LgtmViewKit has no live reference to a KubeViewKit type.

---

## Decisions Ondrej made (settled, do not reopen)

1. Second app is **`LgtmView`**, `com.omaksi.lgtmview`, cask `lgtm-view`.
2. The analyser is a **Homebrew prerequisite**, not embedded.
3. The Go repo is **absorbed** into `Tools/kubectl-lgtm/`.
4. KubeView keeps **no LGTM entry point** - all eight sites cut.

---

## What is left

1. **Push.** 29 commits here, 7 in `~/GitHub/kubectl-lgtm`. Blocked on GitHub
   credentials, not on permission - Ondrej has authorised the push.
2. **Release `kubectl-lgtm` with `--json`.** Its published `v0.1.0` (Aug 7)
   predates the flag. The new `lgtm-view` cask declares
   `depends_on formula: "omaksi/tap/kubectl-lgtm"`, so **the app is unusable from
   a clean install until that release exists.** This is the one true blocker.
3. **Archive `omaksi/kubectl-lgtm`** and repoint the tap formula at the monorepo.
   Ondrej's sequencing: only after tests are green. They now are.
4. **Remove the stale worktree.** `~/GitHub/kubeview-lgtm` on branch `lgtm-view`.
   Verified safe - every file in it is a strict subset of `main`, and the branch
   is already merged. The permission classifier denied this in-session; Ondrej
   runs it:
   `git -C ~/GitHub/kubeview worktree remove --force ~/GitHub/kubeview-lgtm && git -C ~/GitHub/kubeview branch -D lgtm-view`

---

## Standing rules

- **Commit periodically without asking.** Push, tag and release need Ondrej's
  explicit confirmation.
- Single-line commit messages, no `Co-Authored-By`.
- Plain hyphens, not em dashes, in new code, comments, commits and output.
- Report findings and give ranked options before fixing.
- `~/GitHub/` repos push directly to `main`.

---

## Traps - each cost real investigation

**1. Clamping in the producer.** Raw ratios travel to the renderer; only geometry
clamps, never text. Appeared four times in the LGTM view, each time producing a
plausible wrong number rather than a visible failure.

**2. SwiftPM silently drops files no target covers.** No warning, nothing.
`scripts/check-sources.sh` guards it and runs in CI. It scans `Sources/` **and**
`Tests/` - it originally missed `Tests/`, which was the same trap one directory
over.

**3. A synthesized memberwise init on a `public` struct is still `internal`.**
Synthesized `Decodable.init(from:)` *is* public, so decoded models need no init
work. But **a hand-written witness for a public protocol requirement must itself
be `public`**, even when only called from inside the module -
`StringOrInt.init(from:)` hard-errors otherwise.

**4. Model type names collide with SwiftUI once they go public.** `Namespace` vs
SwiftUI's `@Namespace` cascaded into 49 errors across `KubeViewKit`, because the
ambiguity broke `ClusterStore.swift` and everything downstream of it. Renamed
`KubeNamespace`, matching `KubeJob`/`KubeEvent`/`KubeContext`, which exist for
exactly this reason. **Check any new public `KubeModel` type name against
SwiftUI and Foundation before exporting it.**

**5. Most `Namespace` occurrences in this tree are UI string literals** -
`TableColumn("Namespace")`. A blind word-boundary rename compiles perfectly and
silently retitles every column header. Only four were type positions.

**6. Never construct `KubectlService()` without a context.**
`init(context: String? = nil)` only injects `--context` when non-nil, so the nil
default silently runs against the ambient `kubectl config current-context`
instead of the cluster on screen. This was a live bug in pod logs, describe and
events; every loader now takes a non-optional `String`.

**7. A view whose parent keeps SwiftUI identity across a cluster switch shows
the previous cluster's data under the new cluster's name.** `LgtmRootView` must
stay keyed `.id(context)` at its call site in `LgtmViewScenes.swift`. This
shipped once already.

**8. Three duplications in the LGTM view are deliberate.** `LgtmFactBar` (not
`UsageBar`, which grades at fixed thresholds), `LgtmPodUsageCardBody` (not
`PodCardBody`, which lacks a metrics bar), `LgtmGraphLayout` (not
`ResourceGraph`, which assumes typed kinds). Do not unify them.

**9. One Mimir, five clusters.** Mimir/Loki/Tempo/Grafana rows are clean - only
`inno-shared-eks` runs them. All three Alloy rows blend: the `alloy` DaemonSet
shows 171 pods when 41 are this cluster's, and `alloy-metrics` is worse because
pod names collide across clusters (`alloy-metrics-0` exists five times), so it
*looks* exact at 3 replicas while every value is a five-cluster max. **Unfixed** -
scoping to `cluster="..."` is still an open decision.

**10. `release.yml` cannot be tested locally.** It only runs against a real tag,
and codesign/notarize/`gh release create`/tap push all need real credentials.
Prefer loud failure over graceful degradation in it: this repo shipped a broken
feature for months because a bundling step skipped quietly in CI.

---

## Known gaps, deliberately left

- **`TabStore.open(context:)` is untested.** Its only side-effect-free
  constructor is `private init(fresh:)`, which stays private even under
  `@testable import`. Covering it needs a source change.
- **`grafanaUrl` is dead wire-format surface** - no rule sets it, it appears in
  zero real captures. Swift models it as optional, so nothing breaks.
- **The tab-navigation feature is undocumented** in `CLAUDE.md`, and the
  "current-context is read in exactly one place" claim there is inaccurate -
  there is a second read in `KubeViewScenes.swift`. Both predate this refactor.
