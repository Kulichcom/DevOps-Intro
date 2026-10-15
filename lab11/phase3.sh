#!/usr/bin/env bash
# Lab 11 bonus - pin the Nix installer action, push a deliberately broken run
# (must go red), then the fixed one (must go green). Log: lab11/phase3.log
cd "$(dirname "$0")/.." || exit 1
LOG=lab11/phase3.log
WF=.github/workflows/nix-repro.yml
REPO=Kulichcom/DevOps-Intro

echo "== resolving the latest nix-installer-action tag to a commit SHA" | tee "$LOG"
REMOTE=https://github.com/DeterminateSystems/nix-installer-action
TAG=$(git ls-remote --tags --refs "$REMOTE" | awk -F/ '{print $3}' | grep -E '^v[0-9]+$' | sort -V | tail -1)
SHA=$(git ls-remote "$REMOTE" "refs/tags/$TAG^{}" | cut -f1)
[ -z "$SHA" ] && SHA=$(git ls-remote "$REMOTE" "refs/tags/$TAG" | cut -f1)
echo "tag=$TAG sha=$SHA" | tee -a "$LOG"
[ ${#SHA} -eq 40 ] || { echo "FAIL: could not resolve SHA" | tee -a "$LOG"; exit 1; }
sed -i '' "s/__SHA__/$SHA/g; s/__TAG__/$TAG/g" "$WF"

run_and_wait() {
  local C ID=""; C=$(git rev-parse HEAD)
  for i in $(seq 1 20); do
    sleep 6
    ID=$(gh run list -R "$REPO" --workflow nix-repro.yml --commit "$C" --limit 1 --json databaseId -q '.[0].databaseId')
    [ -n "$ID" ] && break
  done
  echo "run: https://github.com/$REPO/actions/runs/$ID" | tee -a "$LOG"
  gh run watch "$ID" -R "$REPO" --exit-status >/dev/null 2>&1
  echo "conclusion: $(gh run view "$ID" -R "$REPO" --json conclusion -q .conclusion)" | tee -a "$LOG"
  gh run view "$ID" -R "$REPO" --log 2>/dev/null | grep -E "job [AB] digest:|^compare.*(A=|B=|Reproducible|Not reproducible)" | sed 's/^[^\t]*\t[^\t]*\t//' | tee -a "$LOG"
}

echo "== 1) RED: job A changes the source" | tee -a "$LOG"
sed -i '' 's/BREAK_REPRO: "__BREAK__"/BREAK_REPRO: "1"/' "$WF"
git add "$WF" && git commit -S -q -m "CI: two-job Nix reproducibility gate, deliberately broken in job A (Lab 11 bonus)" || exit 1
git push -q origin feature/lab11 || exit 1
run_and_wait

echo "== 2) GREEN: divergence removed" | tee -a "$LOG"
sed -i '' 's/BREAK_REPRO: "1"/BREAK_REPRO: "0"/' "$WF"
git add "$WF" && git commit -S -q -m "CI: remove deliberate divergence, gate goes green (Lab 11 bonus)" || exit 1
git push -q origin feature/lab11 || exit 1
run_and_wait
echo "== done" | tee -a "$LOG"
