#!/usr/bin/env bash
# Lab 11 phase 1 - environment A: build QuickNotes + OCI image with Nix inside
# a nixos/nix container (aarch64-linux). Log: lab11/phase1.log
cd "$(dirname "$0")/.." || exit 1
LOG=lab11/phase1.log
exec > >(tee "$LOG") 2>&1
echo "== $(date) phase 1 start"

echo "== starting Docker"
open -a Docker
for i in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 3; done
docker info 2>&1 | grep "Server Version" || { echo "FAIL: Docker did not start"; exit 1; }

echo "== flake must be tracked by git for nix to see it"
git add flake.nix

echo "== environment A container"
docker rm -f nixA >/dev/null 2>&1
docker pull nixos/nix:latest | tail -2
docker run -d --name nixA -v "$PWD:/repo" -w /repo nixos/nix:latest sleep infinity

docker exec nixA bash -c '
set -e
export NIX_CONFIG="experimental-features = nix-command flakes
sandbox = false
filter-syscalls = false"
git config --global --add safe.directory "*"
echo "== nix version: $(nix --version), system: $(nix eval --impure --raw --expr builtins.currentSystem)"
echo "== cache reachability"
curl -sS -o /dev/null -w "cache.nixos.org HTTP %{http_code}\n" https://cache.nixos.org/nix-cache-info

echo "== nix build .#quicknotes"
nix build .#quicknotes -L --out-link /tmp/qn 2>&1 | tail -25
echo "STORE_PATH_A $(readlink /tmp/qn)"
echo "STORE_HASH_A $(nix-store --query --hash $(readlink /tmp/qn))"
ls -la /tmp/qn/bin

echo "== run it"
mkdir -p /tmp/qd
ADDR=:8080 DATA_PATH=/tmp/qd/notes.json SEED_PATH=/repo/app/seed.json /tmp/qn/bin/quicknotes > /tmp/qn.log 2>&1 &
sleep 2
cat /tmp/qn.log
nix shell nixpkgs#curl -c curl -s -i localhost:8080/health
echo

echo "== nix build .#docker"
nix build .#docker -L --out-link /tmp/img 2>&1 | tail -10
mkdir -p /repo/lab11/out
cp -L /tmp/img /repo/lab11/out/quicknotes-nix-A.tar.gz
echo "IMAGE_SHA256_A $(sha256sum /tmp/img | cut -d" " -f1)"
'
echo "== flake.lock"
ls -la flake.lock && head -20 flake.lock
echo "== $(date) phase 1 done"
