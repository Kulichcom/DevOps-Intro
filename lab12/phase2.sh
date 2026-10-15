#!/usr/bin/env bash
# Lab 12 phase 2 - build, run, measure, bonus. Log: lab12/phase2.log
cd "$(dirname "$0")/.." || exit 1
LOG=lab12/phase2.log
exec > >(tee "$LOG") 2>&1
echo "== $(date) phase 2 start"
open -a Docker
for i in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 3; done
docker start wasmlab >/dev/null 2>&1
X() { docker exec wasmlab bash -c "$1"; }
ms() { perl -MTime::HiRes=time -e 'printf "%.0f\n", time*1000'; }
X 'apt-get install -y -qq procps >/dev/null 2>&1; true'
X 'pkill -x spin; true'

echo "== Go toolchain for TinyGo 0.41 (its net package imports internal/strconv)"
X 'head -20 /usr/local/lib/tinygo/src/net/ip.go | grep -nE "go:build|strconv"'
X 'for v in 1.26.0 1.25.3; do
     go version | grep -q "go$v " && break
     rm -rf /usr/local/go-new && mkdir /usr/local/go-new
     curl -fsSL https://go.dev/dl/go$v.linux-$(dpkg --print-architecture).tar.gz | tar -C /usr/local/go-new --strip-components=1 -xzf - || continue
     rm -rf /usr/local/go && mv /usr/local/go-new /usr/local/go
     ls /usr/local/go/src/internal/strconv >/dev/null 2>&1 && { echo "go$v has internal/strconv"; break; }
   done; go version; tinygo version'
echo "== Task 1: spin build"
X 'cd /repo/wasm/moscow-time && spin build 2>&1 | tail -5 && ls -l main.wasm' || { echo "FAIL: spin build"; exit 1; }

echo "== spin up (0.0.0.0:3000 in wasmlab, published to the Mac)"
X 'pkill -x spin; true'
docker exec -d -w /repo/wasm/moscow-time wasmlab bash -c 'spin up --listen 0.0.0.0:3000 > /tmp/spin.log 2>&1'
for i in $(seq 1 50); do curl -s -o /dev/null localhost:3000/time && break; sleep 0.2; done
X 'cat /tmp/spin.log'
echo "-- curl -i /time"
curl -s -i http://127.0.0.1:3000/time
echo "-- pretty"
curl -s http://127.0.0.1:3000/time | python3 -m json.tool
echo "-- POST /time (expect 405)"
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:3000/time

echo "== Lab 6 container"
docker build -q -t quicknotes:lab6 ./app
docker rm -f qn6 >/dev/null 2>&1
docker run -d --name qn6 -p 8080:8080 quicknotes:lab6
sleep 2; curl -s localhost:8080/health; echo

echo "== Task 2.1 (1) warm latency, hyperfine from inside wasmlab, both via host port forwarding"
X 'cd /tmp && hyperfine -N --warmup 5 --runs 50 --export-json warm.json \
  "curl -s http://host.docker.internal:3000/time" \
  "curl -s http://host.docker.internal:8080/health" 2>&1 | grep -E "Benchmark|Time|Range"'
X 'go run /repo/lab12/stats.go /tmp/warm.json'
X 'cp /tmp/warm.json /repo/lab12/warm.json'

echo "== Task 2.1 (2) cold start: kill runtime, restart, time to first 200 (6 samples, from the Mac)"
for i in 1 2 3 4 5 6; do
  docker rm -f qn6 >/dev/null 2>&1
  t0=$(ms); docker run -d --name qn6 -p 8080:8080 quicknotes:lab6 >/dev/null
  n=0; until [ "$(curl -s -o /dev/null -w '%{http_code}' localhost:8080/health)" = 200 ]; do sleep 0.005; n=$((n+1)); [ $n -gt 3000 ] && { echo "TIMEOUT docker"; break; }; done
  echo "COLD docker #$i $(( $(ms) - t0 )) ms"
done
for i in 1 2 3 4 5 6; do
  X 'pkill -x spin; while pgrep -x spin >/dev/null; do sleep 0.05; done'
  t0=$(ms); docker exec -d -w /repo/wasm/moscow-time wasmlab spin up --listen 0.0.0.0:3000
  n=0; until [ "$(curl -s -o /dev/null -w '%{http_code}' localhost:3000/time)" = 200 ]; do sleep 0.005; n=$((n+1)); [ $n -gt 3000 ] && { echo "TIMEOUT spin"; break; }; done
  echo "COLD spin #$i $(( $(ms) - t0 )) ms"
done

echo "== Task 2.1 (3) artifact size"
X 'ls -l /repo/wasm/moscow-time/main.wasm'
docker images quicknotes:lab6
docker image inspect quicknotes:lab6 --format 'quicknotes:lab6 Size={{.Size}} bytes'

echo "== design b: build WITHOUT -buildmode=c-shared, serve on :3001"
X 'rm -rf /tmp/nocs && cp -r /repo/wasm/moscow-time /tmp/nocs && cd /tmp/nocs && rm -rf .spin main.wasm \
  && tinygo build -target=wasip1 -no-debug -o main.wasm . && ls -l main.wasm \
  && (timeout 8 spin up --listen 127.0.0.1:3001 > /tmp/nocs.log 2>&1 &) ; sleep 3; \
  curl -s -i http://127.0.0.1:3001/time | head -5; echo; echo "-- spin log:"; cat /tmp/nocs.log'

echo "== design d: TinyGo stdlib probes (LoadLocation, json of map[string]any)"
X 'mkdir -p /tmp/probe && cd /tmp/probe && cat > main.go <<GO
package main

import (
	"encoding/json"
	"fmt"
	"time"
)

func main() {
	_, err := time.LoadLocation("Europe/Moscow")
	fmt.Println("LoadLocation(Europe/Moscow) error:", err)
	b, err := json.Marshal(map[string]any{"unix": 1, "iso": "x"})
	fmt.Printf("json.Marshal(map[string]any): %s err=%v\n", b, err)
}
GO
tinygo build -target=wasip1 -o probe.wasm main.go 2>&1 | tail -3 && wasmtime run probe.wasm'

echo "== Bonus: standalone WASI CLI module"
X 'cd /repo/wasm/wasm-cli && tinygo build -o main.wasm -target=wasi -no-debug ./main.go && ls -l main.wasm'
X 'cd /repo/wasm/wasm-cli && wasmtime run --env REQUEST_METHOD=GET --env PATH_INFO=/time main.wasm'
X 'cd /repo/wasm/wasm-cli && wasmtime run --env REQUEST_METHOD=GET --env PATH_INFO=/nope main.wasm'
echo "-- per-invocation cold start: wasmtime run (each run = new process + module compile + instantiate)"
X 'cd /repo/wasm/wasm-cli && hyperfine -N --warmup 3 --runs 30 --export-json /tmp/cli.json \
  "wasmtime run --env REQUEST_METHOD=GET --env PATH_INFO=/time main.wasm" 2>&1 | grep -E "Time|Range"'
X 'go run /repo/lab12/stats.go /tmp/cli.json; cp /tmp/cli.json /repo/lab12/cli.json'
echo "-- same request to the persistent Spin server, measured the same way (inside wasmlab)"
X 'hyperfine -N --warmup 5 --runs 30 --export-json /tmp/spinlocal.json "curl -s http://127.0.0.1:3000/time" 2>&1 | grep -E "Time|Range"'
X 'go run /repo/lab12/stats.go /tmp/spinlocal.json'
echo "-- design h: the Spin component under bare wasmtime run"
X 'cd /repo/wasm/moscow-time && wasmtime run main.wasm 2>&1 | head -5; echo "exit=$?"'
X 'wasm-tools --version 2>/dev/null; true'

echo "== cleanup"
docker rm -f qn6 >/dev/null 2>&1
X 'pkill -x spin; true'
echo "== $(date) phase 2 done"
