# HANDOFF - the two-app split

## CURRENT STATE (read this first)

**Date:** 2026-08-24
**The split is done, pushed and released. Credentials are fixed. What remains is
tap and archival housekeeping.**

| Check | Result |
|---|---|
| `swift build` | clean |
| `swift test` | 56 tests, 0 failures |
| `go test ./...` (Tools/kubectl-lgtm) | 6 packages ok |
| `./scripts/check-sources.sh` | OK |
| CI on `main` | green, on macos-26 |
| working tree | clean |

- `~/GitHub/kubeview` HEAD `4c01d86`, pushed. Tags `v0.4.0` and
  `kubectl-lgtm-v0.2.0` pushed, both on that commit.
- `~/GitHub/kubectl-lgtm` HEAD `933043b`, pushed, archive notice in README.

**The design lives here:** https://claude.ai/code/artifact/4f483667-6f3e-4359-a06e-a769ede5e7e8

---

## CREDENTIALS - solved, do not redo

The GitHub PAT lives in the macOS **login keychain** as an **internet password**
(`https://github.com`, account `omaksi`). Git's `osxkeychain` helper reads it.
No token sits in any `.git/config` any more.

Two traps worth keeping:

- **`git ls-remote` against a PUBLIC repo proves nothing about auth** - it needs
  no credentials at all. Verify against a PRIVATE repo (`inno-writing`) or the
  check is vacuous. This cost the original token: three `.git/config` URLs were
  stripped on the strength of a check that could not fail, and the PAT existed
  nowhere else. No shell history, no snapshots, no Time Machine.
- **Keychain Access's "New Password Item" creates a GENERIC password**, which
  git never looks at. Naming the item with a full URL (`https://github.com`)
  makes it an INTERNET password instead, which is what the helper searches.
  Confirm via the item's "Kind" field.

**Still outstanding:** 31 repos under `~/GitLab/` carry a GitLab token in
plaintext in `.git/config`. Same pattern, different token, not yet cleaned up.

---

## IDENTITY - personal vs work

`~/.gitconfig` now defaults to `ondrej.maksi@gmail.com`, with
`includeIf "gitdir:~/GitLab/"` pointing at `~/.gitconfig-work` for the
Innovatrics address. Verified resolving correctly on both sides.

All four GitHub repos were rewritten to gmail (kubeview 55, kubectl-lgtm 10,
writing 8, inno-writing 47). Zero work-email commits remain on any remote, and
kubeview's six `v*` tags kept their original SHAs.

**Trap:** `writing` was first rewritten against a STALE remote-tracking ref, and
the queued force-push would have destroyed 5 unfetched commits. **Always
`git fetch` before rewriting history**, and inspect `main..origin/main` before
any force-push. Pre-rewrite bundles of all four repos are in the session
scratchpad, plus `refs/original/` in each repo.

---

## What the repo looks like now

```
Sources/
  KubeModel/     14 files  pure data, Foundation only - no I/O, no SwiftUI
  KubeClient/     3        all cluster I/O, Foundation only - a CLI could link it
  KubeUI/         6        shared SwiftUI chrome, used by both apps
  KubeViewKit/   34        cluster-browser app logic
  KubeView/       1        @main shell, 10 lines
  LgtmViewKit/    9        LGTM inspector logic
  LgtmView/       1        @main shell, 10 lines
Tests/           8 files   56 tests across 4 targets (no KubeUITests, on purpose)
Tools/
  kubectl-lgtm/            the Go analyser, absorbed via git subtree, history intact
```

Dependencies run strictly one way:
`KubeModel <- KubeClient <- KubeUI <- {KubeViewKit, LgtmViewKit} <- {KubeView, LgtmView}`.
A future non-GUI app depends on `KubeModel` + `KubeClient` and never links
SwiftUI. That is what the third layer buys.

**The two apps share no types and no state.** KubeView has zero LGTM references;
LgtmViewKit has no live reference to a KubeViewKit type. Both verified by grep,
not asserted.

---

## Decisions Ondrej made (settled, do not reopen)

1. Second app is **`LgtmView`**, `com.omaksi.lgtmview`, cask `lgtm-view`.
2. The analyser is a **Homebrew prerequisite**, not embedded.
3. The Go repo is **absorbed** into `Tools/kubectl-lgtm/`.
4. KubeView keeps **no LGTM entry point** - all eight sites cut.

---

## What is left, in order

1. **Push both repos.** See the blocker above.
2. **Tag `kubectl-lgtm-v0.2.0`** - `release-lgtm.yml` runs the Go suite and cuts
   the release. This is the one that matters: `Casks/lgtm-view.rb` declares
   `depends_on formula: "omaksi/tap/kubectl-lgtm"`, and the published `v0.1.0`
   (Aug 7) predates `--json` entirely, so **LgtmView is unusable from a clean
   install until this exists.**
3. **Bump `Formula/kubectl-lgtm.rb`** in `omaksi/homebrew-tap` by hand - nothing
   automates it. It builds from source, so it needs only the new tag and
   `curl -sL <tarball> | shasum -a 256`. The tarball is the whole monorepo at
   that tag; wrap `install` in `cd "Tools/kubectl-lgtm" do ... end`.
4. **Verify `brew install` end to end from clean** - `brew untap omaksi/tap`,
   re-tap, install the formula, then `brew install --cask lgtm-view` and confirm
   the dependency resolves.
5. **Push the Go repo's 7 commits, add a "moved to" pointer to its README, then
   archive `omaksi/kubectl-lgtm`.** In that order - an archived repo is fully
   read-only, so a bad formula afterwards means unarchiving.
6. **Remove the stale worktree** (`~/GitHub/kubeview-lgtm`, branch `lgtm-view`).
   Verified safe: every file in it is a strict subset of `main` and the branch is
   already merged. The permission classifier denied this in-session:
   `git -C ~/GitHub/kubeview worktree remove --force ~/GitHub/kubeview-lgtm && git -C ~/GitHub/kubeview branch -D lgtm-view`

**Unverified and worth checking before tagging:** whether `TAP_TOKEN` and
`DEV_ID_CERT_P12` are actually set on `omaksi/kubeview`. `gh` is not installed,
so nobody could confirm it. If absent, signing and the tap update skip or fail.

---

## Verification state

Everything below was run, not reasoned about:

- Both apps build; `swift build --product LgtmView` succeeds.
- `scripts/bundle.sh --app-name LgtmView --bundle-id com.omaksi.lgtmview` produces
  a real `LgtmView.app` with the right identifier and an arm64 Mach-O.
- The two apps have **visually distinct icons** (teal binoculars / amber gauge),
  and KubeView's regenerated icon is SHA256-identical to the committed one.
- `LgtmView.app` **launches**, runs without crashing, produces no diagnostic
  report, resolves the analyser, invokes it, and renders the correct degrade
  state when it is missing.
- All ten `selfCheck()` functions pass - the first time they have ever run
  outside a human opening a debug build.

**Not verified: a real report rendering against a live cluster.** The AWS SSO
token is expired (`aws sso login` to fix). The analyser was run exactly as the
app runs it and returned a clean error, so the failure path is proven; the
success path is not.

`kubectl-lgtm` was built from `Tools/` and installed to `~/go/bin/` so the app
could find it. Remove it if unwanted.

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

**6. Never construct `KubectlService()` without a context.** The nil default
skips `--context` and silently runs against the ambient
`kubectl config current-context`. This was a live bug in pod logs, describe and
events. The ambient context may **seed an initial choice** (three bootstrap
sites do) but must never route a request.

**7. A view whose parent keeps SwiftUI identity across a cluster switch shows
the previous cluster's data under the new cluster's name.** `LgtmRootView` must
stay keyed `.id(context)` at its call site in `LgtmViewScenes.swift`. Shipped
once already.

**8. Tag namespaces must stay disjoint.** `release.yml` fires on `v*` and builds,
signs and notarizes **both** apps. The analyser uses `kubectl-lgtm-v*` so a
Go-only fix does not re-notarize two macOS apps. Verified disjoint in both
directions with `git tag -l`.

**9. The tap push is serialized on purpose.** Two parallel matrix legs each
cloning, committing and pushing to `omaksi/homebrew-tap` race, and the second is
rejected non-fast-forward. The `release` job fans in and writes both casks before
a single push. Do not move it back into the matrix.

**10. Three duplications in the LGTM view are deliberate.** `LgtmFactBar` (not
`UsageBar`, which grades at fixed thresholds), `LgtmPodUsageCardBody` (not
`PodCardBody`, which lacks a metrics bar), `LgtmGraphLayout` (not
`ResourceGraph`, which assumes typed kinds). Do not unify them.

**11. One Mimir, five clusters.** Mimir/Loki/Tempo/Grafana rows are clean - only
`inno-shared-eks` runs them. All three Alloy rows blend: the `alloy` DaemonSet
shows 171 pods when 41 are this cluster's, and `alloy-metrics` is worse because
pod names collide across clusters (`alloy-metrics-0` exists five times), so it
*looks* exact at 3 replicas while every value is a five-cluster max. **Unfixed** -
scoping to `cluster="..."` is still an open decision.

**12. `release.yml` and `release-lgtm.yml` cannot be tested locally.** They only
run against real tags, and codesign/notarize/`gh release create`/tap push all
need real credentials. Prefer loud failure over graceful degradation: this repo
shipped a broken feature for months because a bundling step skipped quietly.

---

## Known gaps, deliberately left

- **`TabStore.open(context:)` is untested.** Its only side-effect-free
  constructor is `private init(fresh:)`, which stays private even under
  `@testable import`. Covering it needs a source change.
- **`grafanaUrl` is dead wire-format surface** - no rule sets it, it appears in
  zero real captures. Swift models it as optional, so nothing breaks.
- **No `KubeUITests`.** The only pure function in `KubeUI` is a four-branch
  `String -> Color` switch. An empty target would make CI look like it covers
  something it does not.

---

## Working note for whoever picks this up

Several agents in this session batched all their writes at the end. **A clean
`git status` a few minutes after assigning work means nothing has been written
yet, not that nothing is happening.** Reading it as a stall caused one lane to be
reassigned needlessly and one task to be done twice. Wait for the agent's report
rather than inferring progress from the filesystem.
