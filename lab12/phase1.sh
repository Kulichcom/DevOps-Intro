#!/usr/bin/env bash
# Lab 12 phase 1 - tool container + scaffold. Log: lab12/phase1.log
cd "$(dirname "$0")/.." || exit 1
LOG=lab12/phase1.log
exec > >(tee "$LOG") 2>&1
echo "== $(date) phase 1 start, branch $(git branch --show-current)"
open -a Docker
for i in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 3; done
docker info 2>&1 | grep "Server Version" || { echo "FAIL: Docker did not start"; exit 1; }

echo "== tool container 'wasmlab' (golang:1.24-bookworm, port 3000 published)"
docker rm -f wasmlab >/dev/null 2>&1
docker run -d --name wasmlab -p 3000:3000 -v "$PWD:/repo" -w /repo golang:1.24-bookworm sleep infinity

docker exec wasmlab bash -c '
set -e
ARCH=$(dpkg --print-architecture)
echo "== arch $ARCH"
apt-get update -qq && apt-get install -y -qq hyperfine curl xz-utils git >/dev/null
echo "== TinyGo 0.41.0"
curl -fsSL -o /tmp/tinygo.deb "https://github.com/tinygo-org/tinygo/releases/download/v0.41.0/tinygo_0.41.0_${ARCH}.deb"
dpkg -i /tmp/tinygo.deb >/dev/null
echo "== Spin 3.4"
cd /usr/local/bin
(curl -fsSL https://spinframework.dev/downloads/install.sh | bash -s -- -v v3.4.0) 2>&1 | tail -3 \
 || (curl -fsSL https://developer.fermyon.com/downloads/install.sh | bash -s -- -v v3.4.0) 2>&1 | tail -3
echo "== wasmtime"
curl -fsSL https://wasmtime.dev/install.sh | bash >/dev/null 2>&1
ln -sf /root/.wasmtime/bin/wasmtime /usr/local/bin/wasmtime
echo "== versions"
spin --version; tinygo version; go version; hyperfine --version; wasmtime --version
echo "== templates"
spin templates list 2>&1 | grep -i "http-go" || {
  spin templates install --git https://github.com/spinframework/spin-go-sdk --upgrade 2>&1 | tail -2
  spin templates list 2>&1 | grep -qi "http-go" || spin templates install --git https://github.com/spinframework/spin --upgrade 2>&1 | tail -2
}
spin templates list 2>&1 | grep -i "http-go"
echo "== scaffold"
mkdir -p /repo/wasm && cd /repo/wasm
[ -d moscow-time ] || spin new -t http-go moscow-time --accept-defaults
ls -la moscow-time
for f in moscow-time/spin.toml moscow-time/go.mod moscow-time/main.go; do echo "----- $f"; cat "$f"; done
'
echo "== $(date) phase 1 done"
