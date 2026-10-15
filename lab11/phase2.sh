#!/usr/bin/env bash
# Lab 11 phase 2 - push the flake, rebuild in a FRESH environment B (new
# container, fresh git clone from GitHub), compare with A, and compare
# against the Lab 6 Dockerfile build. Log: lab11/phase2.log
cd "$(dirname "$0")/.." || exit 1

echo "== commit + push flake (GPG may ask for your passphrase)"
git add flake.nix flake.lock
git commit -S -m "Add Nix flake: reproducible QuickNotes build + OCI image (Lab 11)" || exit 1
git push -u origin feature/lab11 || exit 1

LOG=lab11/phase2.log
exec > >(tee "$LOG") 2>&1
echo "== $(date) phase 2 start, commit $(git rev-parse --short HEAD)"
open -a Docker
for i in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 3; done

echo "== environment B: brand-new container, fresh clone"
docker rm -f nixB >/dev/null 2>&1
docker run -d --name nixB nixos/nix:latest sleep infinity
docker exec nixB bash -c '
set -e
export NIX_CONFIG="experimental-features = nix-command flakes
sandbox = false
filter-syscalls = false"
git clone -q --branch feature/lab11 https://github.com/Kulichcom/DevOps-Intro.git /qn-fresh
cd /qn-fresh && echo "cloned at $(git rev-parse --short HEAD)"
nix build .#quicknotes --out-link /tmp/qn 2>&1 | tail -3
echo "STORE_PATH_B $(readlink /tmp/qn)"
echo "STORE_HASH_B $(nix-store --query --hash $(readlink /tmp/qn))"
nix build .#docker --out-link /tmp/img 2>&1 | tail -3
cp -L /tmp/img /tmp/quicknotes-nix-B.tar.gz
echo "IMAGE_SHA256_B $(sha256sum /tmp/img | cut -d" " -f1)"
'
docker cp nixB:/tmp/quicknotes-nix-B.tar.gz lab11/out/

echo "== environment A again (same container as phase 1)"
docker exec nixA bash -c 'echo "STORE_HASH_A $(nix-store --query --hash $(readlink /tmp/qn))"; echo "IMAGE_SHA256_A $(sha256sum /tmp/img | cut -d" " -f1)"'
echo "== sha256sum of both tarballs on the Mac"
shasum -a 256 lab11/out/quicknotes-nix-*.tar.gz

echo "== load + run the Nix image"
docker rm -f qn-nix >/dev/null 2>&1
docker load -i lab11/out/quicknotes-nix-A.tar.gz
docker run -d --name qn-nix -p 18081:8080 quicknotes:nix
sleep 3
curl -s -i localhost:18081/health
echo
docker inspect quicknotes:nix --format 'User={{.Config.User}} Entrypoint={{.Config.Entrypoint}} Ports={{.Config.ExposedPorts}} Created={{.Created}}'
docker rm -f qn-nix >/dev/null

echo "== Lab 6 Dockerfile, built twice with --no-cache"
docker build --no-cache -q -t qn-lab6:run1 ./app
docker build --no-cache -q -t qn-lab6:run2 ./app
docker images --no-trunc qn-lab6
docker inspect qn-lab6:run1 qn-lab6:run2 --format '{{.RepoTags}} created={{.Created}}'

echo "== sizes"
docker images quicknotes:nix
docker images qn-lab6
ls -la lab11/out/
echo "== $(date) phase 2 done"
