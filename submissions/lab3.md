# Lab 3 — CI/CD

**Path chosen:** GitHub Actions (already set up with signed commits from Labs 1-2).

**Green CI run:** https://github.com/Kulichcom/DevOps-Intro/pull/1

## 1.5 — Proof the gate blocks a failure

Commit `11b71fb` deliberately changed the expected note count in
`TestHealth_ReportsCount` from 1 to 2, which does not match the app's real
behavior. The `test` check failed red while `vet` and `lint` stayed green,
confirming the three jobs run independently. Commit `a5315ae` reverted the
change and all checks passed again.

## 1.6 — Branch protection

A ruleset on `main` requires the `lint` and `ci-ok` status checks to pass
and requires branches to be up to date before merging.

## Design Questions — Task 1

**a) Why pin `ubuntu-24.04` instead of `ubuntu-latest`?**
`ubuntu-latest` is a moving target — GitHub can repoint it to a newer Ubuntu
version at any time without warning, which can silently change installed
tool versions (compilers, libc, apt packages) and break a pipeline that
worked yesterday for reasons unrelated to your code. Pinning to
`ubuntu-24.04` guarantees the same OS image every run.

**b) Why split vet + test + lint into separate jobs?**
Each job gets its own fresh runner and reports its own pass/fail status
independently. If they were one combined job, a `go vet` failure would stop
the script before `go test` or lint ever ran (in a typical shell script,
one failing step aborts the rest), so you'd only ever learn about the
first problem instead of the full picture. Separate jobs also run in
parallel, which is faster.

**c) What real attack does SHA pinning prevent?**
The `tj-actions/changed-files` supply-chain compromise (CVE-2025-30066),
discovered March 14, 2025. Attackers retroactively repointed the action's
version tags (e.g. `@v45`) to a malicious commit that dumped CI/CD secrets
into public build logs. Any workflow trusting the tag `@v45` automatically
pulled the malicious code on its next run with no code change of its own.
A full 40-character SHA can't be silently reassigned like a tag can.

**d) What is `permissions:` and what's the principle?**
It's least privilege: by default, a workflow's `GITHUB_TOKEN` has broad
repo permissions. Declaring `permissions: contents: read` explicitly limits
this workflow to only reading repo contents, so even if a step were
compromised, it couldn't push code, open issues, or modify releases.

## Design Questions — Task 2

**f) Why cache `go.sum`-keyed inputs and not build outputs?**
`go.sum` pins exact dependency versions and hashes, so it's deterministic —
the same `go.sum` always means the same downloaded modules, making it a
safe cache key. Build outputs can vary subtly between runs (different Go
patch versions, timestamps, non-deterministic compilation), so caching
them risks serving stale or incorrect artifacts silently.

**g) What does `fail-fast: false` change, and when do you want `true`?**
By default (`fail-fast: true`), GitHub Actions cancels every other matrix
job the moment one fails. With `fail-fast: false`, all matrix combinations
run to completion regardless, so you can see exactly which Go version(s)
broke instead of just the first one. `true` makes sense when a failure in
any combination means the whole result is invalid and you want to save CI
minutes by stopping early (e.g. a very expensive matrix where partial
results aren't useful).

**h) Risk of a malicious PR poisoning the cache?**
A PR from an untrusted fork could intentionally write a poisoned cache
entry (e.g. tampered build artifacts) under a predictable key, which a
later run on a protected branch might then restore and use. GitHub's
mitigation: caches created in a pull request from a fork are isolated and
cannot be accessed by workflow runs on the base branch — cache scope is
tied to the branch/ref that created it, not shared across fork boundaries.

## Timing (2.4)

| Scenario | Wall-clock |
|---|---|
| Baseline (no cache, single Go version, no path filter) | 34s |
| With cache + matrix + path filter (combined in one commit) | 45s total workflow; 21s for a single `vet (1.24)` job |

QuickNotes has zero third-party dependencies (`app/go.mod` has no `require`
block, no `go.sum`), so the Go module cache has nothing to restore — the
`setup-go` step itself took just 1s either way. The total workflow time
increased with the matrix not because of caching overhead, but because
doubling `vet` and `test` into two Go versions means more jobs competing
for runners concurrently, and the new `ci-ok` job waits on all of them to
finish. Cache and matrix were added in the same commit due to time
constraints, so cache-only timing wasn't isolated separately — but the
per-step `setup-go` duration (1s, unchanged) already shows caching made no
measurable difference on this particular repo, exactly as expected for a
dependency-free module.

## Bonus

Not attempted — prioritized completing Task 1 and Task 2 fully.
