#!/usr/bin/env bash
# Lab 12 phase 3 - design questions b and h, follow-up. Log: lab12/phase3.log
cd "$(dirname "$0")/.." || exit 1
exec > >(tee lab12/phase3.log) 2>&1
docker start wasmlab >/dev/null 2>&1
docker exec wasmlab bash -c '
echo "== b) no -buildmode=c-shared, with an empty func main() added so it links"
rm -rf /tmp/nocs && cp -r /repo/wasm/moscow-time /tmp/nocs && cd /tmp/nocs && rm -rf .spin main.wasm
printf "\nfunc main() {}\n" >> main.go
tinygo build -target=wasip1 -no-debug -o main.wasm . && ls -l main.wasm
spin up --listen 127.0.0.1:3001 > /tmp/nocs.log 2>&1 &
sleep 3
curl -s -i http://127.0.0.1:3001/time | head -6; echo
echo "-- spin output:"; cat /tmp/nocs.log
echo "-- component logs:"; cat .spin/logs/* 2>/dev/null | tail -5
pkill -f "listen 127.0.0.1:3001"
echo "== h) Spin component under bare wasmtime run"
cd /repo/wasm/moscow-time && wasmtime run main.wasm; echo "exit=$?"
wasmtime run --invoke _start main.wasm 2>&1 | head -3
'
