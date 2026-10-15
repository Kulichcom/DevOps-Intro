# Lab 12 - WebAssembly Containers: a QuickNotes endpoint on Spin

## Test rig

- MacBook Air, Apple M3 (arm64), macOS, Docker Desktop (engine 29.6.1)
- All WASM tooling runs in one Linux container, `wasmlab` (`golang` image, `linux/arm64`),
  with port 3000 published to the Mac. The Lab 6 image runs as its own container with
  port 8080 published. Homebrew refused to install the tools without a newer Xcode
  Command Line Tools, so Docker kept the setup self-contained.
- Pinned versions:
  - **Spin 3.4.0** (`4f671be 2025-08-26`)
  - **TinyGo 0.41.0** (LLVM 20.1.1), using **Go 1.26.0**
  - **Spin Go SDK** `github.com/spinframework/spin-go-sdk/v2 v2.2.1` (from the scaffold)
  - hyperfine 1.15.0, wasmtime 49.0.3

**Version note:** with Go 1.24 *and* Go 1.25, `spin build` failed:

```
/usr/local/lib/tinygo/src/net/ip.go:17:2: package internal/strconv is not in std
```

TinyGo 0.41's `net` package imports `internal/strconv`, which only exists from **Go 1.26**,
and the Spin SDK pulls in `net/http` -> `net`. So for this lab, TinyGo 0.41 effectively
needs Go >= 1.26, despite "go1.24 or later" in the prerequisites.

Scripts and full logs: [`lab12/phase1.sh`](../lab12/phase1.sh) (tools + scaffold),
[`lab12/phase2.sh`](../lab12/phase2.sh) (build, run, all measurements, bonus),
[`lab12/phase3.sh`](../lab12/phase3.sh) (design-question experiment); logs `lab12/phase*.log`,
raw hyperfine data `lab12/warm.json`, `lab12/cli.json`.

## Task 1 - WASM endpoint with the Spin SDK

Scaffolded with `spin new -t http-go moscow-time --accept-defaults` inside `wasm/`.

### `wasm/moscow-time/main.go`

```go
package main

import (
	"fmt"
	"net/http"
	"time"

	spinhttp "github.com/spinframework/spin-go-sdk/v2/http"
)

// Moscow is UTC+3 all year (no DST since 2014). A fixed zone avoids
// time.LoadLocation, which needs tzdata that TinyGo/WASI doesn't ship.
var moscow = time.FixedZone("MSK", 3*60*60)

// moscowJSON builds the body with fmt + %q instead of encoding/json:
// TinyGo's reflection support makes json of map[string]any unreliable.
func moscowJSON(now time.Time) string {
	msk := now.In(moscow)
	return fmt.Sprintf(
		`{"unix":%d,"iso":%q,"hour_minute":%q,"timezone":%q,"utc_offset":%q,"utc":%q}`,
		now.Unix(),
		msk.Format(time.RFC3339),
		msk.Format("15:04"),
		"Europe/Moscow",
		"+03:00",
		now.UTC().Format(time.RFC3339),
	)
}

func init() {
	spinhttp.Handle(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			fmt.Fprint(w, `{"error":"method not allowed"}`)
			return
		}
		fmt.Fprintln(w, moscowJSON(time.Now()))
	})
}
```

### `wasm/moscow-time/spin.toml`

```toml
#:schema https://schemas.spinframework.dev/spin/manifest-v2/latest.json

spin_manifest_version = 2

[application]
name = "moscow-time"
version = "0.1.0"
authors = [""]
description = "Moscow time as JSON - QuickNotes-style endpoint on Spin (Lab 12)"

[[trigger.http]]
route = "/time"
component = "moscow-time"

[component.moscow-time]
source = "main.wasm"
allowed_outbound_hosts = []
[component.moscow-time.build]
command = "tinygo build -target=wasip1 -buildmode=c-shared -no-debug -o main.wasm ."
watch = ["**/*.go", "go.mod"]
```

Changes from the scaffold: the route (`/...` -> `/time`) and the description.
`allowed_outbound_hosts = []` and the TinyGo `wasip1` + `-buildmode=c-shared` build command
are kept exactly as generated.

### `spin build`

```
Building component moscow-time with `tinygo build -target=wasip1 -buildmode=c-shared -no-debug -o main.wasm .`
Finished building all Spin components
-rwxr-xr-x 1 root root 370314 Oct 15 19:35 main.wasm
```

**`main.wasm` = 370,314 bytes (362 KB).**

### `spin up` + `curl`

```
Serving http://0.0.0.0:3000
Available Routes:
  moscow-time: http://0.0.0.0:3000/time

$ curl -s -i http://127.0.0.1:3000/time
HTTP/1.1 200 OK
content-type: application/json
content-length: 154

{"unix":1792092936,"iso":"2026-10-15T22:35:36+03:00","hour_minute":"22:35","timezone":"Europe/Moscow","utc_offset":"+03:00","utc":"2026-10-15T19:35:36Z"}

$ curl -s http://127.0.0.1:3000/time | python3 -m json.tool
{
    "unix": 1792092936,
    "iso": "2026-10-15T22:35:36+03:00",
    "hour_minute": "22:35",
    "timezone": "Europe/Moscow",
    "utc_offset": "+03:00",
    "utc": "2026-10-15T19:35:36Z"
}

$ curl -s -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:3000/time
405
```

(22:35 Moscow = 19:35 UTC, matching the `date` header.)

### Design questions

**a) Browser WASM vs server WASM.** `GOOS=js GOARCH=wasm` targets the browser: the module
imports a JavaScript glue layer (`wasm_exec.js`, `syscall/js`) and gets all I/O through JS
- the DOM, `fetch`, timers. It can't run without a JS host. `-target=wasip1` targets WASI:
the module imports a small, standardised system interface (`wasi_snapshot_preview1` - my
module's only import namespace) for clocks, random, env, stdio, and preopened files. What's
missing in the server target is everything browser-ish: no DOM, no JS, and no ambient OS
access - no sockets by default, no filesystem unless a directory is granted. What you gain:
it runs in any WASI runtime (wasmtime, Spin, wasmCloud...) with no JS engine, starts in
milliseconds, and every capability must be granted explicitly by the host. (TinyGo also
makes it small: 362 KB here vs several MB from standard Go.)

**b) Why `-buildmode=c-shared`.** It makes TinyGo produce a **reactor** module instead of a
**command**. A command exports `_start`: the host runs `main()` once and the instance is
finished. A reactor exports `_initialize` (runs the Go runtime and `init()` - where
`spinhttp.Handle` registers the handler) and then keeps its exported functions callable;
Spin calls the exported **`handle-http-request`** for every request. I checked my module's
exports: `_initialize`, `handle-http-request`, `spin_http_handle_http_request`, no `_start`.

What I saw when I removed it ([`lab12/phase2.log`](../lab12/phase2.log), [`lab12/phase3.log`](../lab12/phase3.log)):
- With the flag simply removed, it doesn't even link: `wasm-ld: error: lto.tmp: undefined
  symbol: main.main` - a command module requires `main()`, and the Spin handler lives in `init()`.
- With an empty `func main() {}` added, it built (370,596 bytes), and with **Spin 3.4 + TinyGo
  0.41 + SDK v2.2.1 it still answered HTTP 200**, so the "HTTP 500 with empty logs" from the
  lab's pitfalls didn't reproduce on these versions - the SDK's `//export` still emits the
  handler, and Spin found it. I keep the flag anyway: it's what the template generates and
  what the SDK is designed for. A command module's contract is "run `_start` and exit", so
  calling into it afterwards relies on behaviour that isn't guaranteed.

**c) `allowed_outbound_hosts = []`.** WASM uses **capability-based security**: a module has
no ambient authority - it can only do what the host explicitly hands it (imported
functions, preopened directories, allowed hosts). Spin enforces outbound access per component
from the manifest; an empty list means any outbound HTTP/Redis/DB/socket call fails, and the
check happens in the host for each call. Docker's `--network none` is coarser: it removes the
container's network interfaces at the namespace level, all or nothing, for the whole
container. With Spin I could allow exactly `https://api.example.com` for one component and
nothing for another, in the same app; in Docker that needs egress proxies or network
policies. The WASM default is deny; Docker's default is full network access.

**d) TinyGo stdlib gaps.** I hit two and confirmed them with a probe built with TinyGo and run
under wasmtime ([`lab12/phase2.log`](../lab12/phase2.log)):
- **Time zones:** `time.LoadLocation("Europe/Moscow")` -> `unknown time zone Europe/Moscow`
  (no tzdata in the WASI sandbox). I use `time.FixedZone("MSK", 3*60*60)`, which is correct
  because Moscow has been UTC+3 with no DST since 2014.
- **The toolchain itself:** TinyGo's own `net` package required Go 1.26 (see the version note).
- `json.Marshal(map[string]any{...})` **worked** in TinyGo 0.41 (`{"iso":"x","unix":1}`), so
  reflection has improved; I still build the body with `fmt.Sprintf` + `%q` as the lab
  recommends, because it doesn't depend on reflection at all and keeps the field order fixed.

## Task 2 - Performance vs the Lab 6 container

Setup: `spin up --listen 0.0.0.0:3000` in `wasmlab`; `quicknotes:lab6` (Lab 6 Dockerfile,
Go 1.25 build from Lab 9) as container `qn6` on 8080. **Both** are reached through Docker
Desktop's port forwarding, so neither side gets a shortcut.

### 1. Warm latency

`hyperfine -N --warmup 5 --runs 50`, run inside `wasmlab` against
`host.docker.internal:3000/time` and `host.docker.internal:8080/health`; p50/p95 computed
from the exported JSON with [`lab12/stats.go`](../lab12/stats.go):

```
Benchmark 1: curl -s http://host.docker.internal:3000/time
  Time (mean ± σ):       5.4 ms ±   1.1 ms    [User: 2.1 ms, System: 1.0 ms]
  Range (min … max):     4.1 ms …   9.1 ms    50 runs
Benchmark 2: curl -s http://host.docker.internal:8080/health
  Time (mean ± σ):       3.9 ms ±   0.4 ms    [User: 1.9 ms, System: 0.7 ms]
  Range (min … max):     3.3 ms …   5.3 ms    50 runs
curl -s http://host.docker.internal:3000/time    n=50 p50=4.92ms p95=7.59ms mean=5.36ms
curl -s http://host.docker.internal:8080/health  n=50 p50=3.73ms p95=4.53ms mean=3.87ms
```

Each sample includes starting `curl` itself (~2-3 ms, same for both).

### 2. Cold start

Kill the runtime, start it again, and time until the first HTTP 200 (polling every 5 ms), measured from the Mac:
- **Docker:** `docker rm -f qn6` -> `docker run -d ... quicknotes:lab6` -> first 200 on `/health`
- **Spin:** kill `spin` -> `docker exec -d wasmlab spin up ...` -> first 200 on `/time`

Both include one Docker CLI round trip.

| Sample | Docker | Spin |
|---|---:|---:|
| 1 | 137 ms | 117 ms |
| 2 | 166 ms | 124 ms |
| 3 | 157 ms | 131 ms |
| 4 | 137 ms | 106 ms |
| 5 | 126 ms | 113 ms |
| 6 | 130 ms | 113 ms |
| **p50** | **137 ms** | **115 ms** |

### 3. Artifact size

- `main.wasm`: **370,314 bytes (0.37 MB)**
- `quicknotes:lab6`: **5,403,881 bytes content (5.4 MB)**, 22.1 MB unpacked on disk

### Table

| Dimension              | Lab 6 Docker | Lab 12 WASM/Spin |
|------------------------|-------------:|-----------------:|
| Artifact size          | 5.4 MB (22.1 MB on disk) | 0.37 MB |
| Cold start (p50)       | 137 ms | 115 ms |
| Warm latency p50       | 3.73 ms | 4.92 ms |
| Warm latency p95       | 4.53 ms | 7.59 ms |

**Reading it:** WASM wins on size by ~15x (~60x on disk) and starts ~16% faster, but loses on
warm latency here. The warm result makes sense: QuickNotes is a native Go server with
the handler already running, while Spin creates a **fresh WASM instance for every request**
(that's its isolation model) and runs TinyGo code with a simpler GC. The cold-start gap is
smaller than WASM marketing suggests, because on my rig both sides pay Docker Desktop's
VM and CLI overhead; most of Spin's ~115 ms is starting the Spin process and loading and
compiling the module, not the module itself (a whole `wasmtime run` of the CLI module takes
25 ms - see the bonus).

### Design questions

**e) What dominates each cold start.** **Docker:** creating the container - unpacking/
mounting the image layers (overlayfs), setting up namespaces, cgroups and the network
(veth + port forwarding through Docker Desktop's VM), starting the process, then the Go
runtime and QuickNotes loading `notes.json`. **Spin:** starting the Spin binary itself
(wasmtime engine, HTTP server, reading `spin.toml`), then loading and compiling
`main.wasm` to native code (Cranelift) and creating the instance pool; the per-request
instantiation after that takes microseconds to a millisecond. In my numbers both have the
Docker CLI round trip on top, which shrinks the gap.

**f) Where WASM is clearly better, and where Docker is still right.** WASM is better for
small, stateless, request-driven functions: edge/serverless handlers and webhooks that
scale to zero (fast start, KB-sized artifacts, so thousands fit on one host), plug-ins and
user-supplied code in a multi-tenant platform (sandbox and capabilities), and
"build once, run on any CPU/OS" (my arm64-built `main.wasm` runs unchanged on x86).
Docker is still right for long-running services and anything with heavy or native
dependencies: databases, ML with GPUs, apps needing full POSIX - threads, raw sockets,
`fork`, the full filesystem - code in languages or libraries that don't target WASI yet,
and when you need the mature ecosystem (Kubernetes, debugging, observability). My own
numbers show it too: for steady warm traffic the native container was faster.

**g) Multi-tenant safety.** The concrete win is against **container escape via the shared
kernel**: a tenant in a Linux container makes syscalls straight into the host kernel, so
one kernel bug (e.g. Dirty Pipe, CVE-2022-0847) or a misconfiguration can let them break
out and read other tenants' data. A WASM module can't make syscalls at all: it can only call
the functions the host imports into it, its memory is a bounds-checked linear memory, and
it can't jump to arbitrary code (no raw pointers outside that memory, validated control
flow). It also blocks **SSRF/data exfiltration** from compromised tenant code: with
`allowed_outbound_hosts = []`, malicious code simply has no network or filesystem
capability to use, even if it fully controls the module.

## Bonus - Two WASM execution models

### `wasm/wasm-cli/main.go`

```go
// Standalone WASI CLI module (CGI / WAGI-shaped): the request comes in as
// environment variables, the response goes to stdout as CGI headers + body.
// Run: wasmtime run --env REQUEST_METHOD=GET --env PATH_INFO=/time main.wasm
package main

import (
	"fmt"
	"os"
	"time"
)

var moscow = time.FixedZone("MSK", 3*60*60)

// Same logic as wasm/moscow-time/main.go.
func moscowJSON(now time.Time) string {
	msk := now.In(moscow)
	return fmt.Sprintf(
		`{"unix":%d,"iso":%q,"hour_minute":%q,"timezone":%q,"utc_offset":%q,"utc":%q}`,
		now.Unix(),
		msk.Format(time.RFC3339),
		msk.Format("15:04"),
		"Europe/Moscow",
		"+03:00",
		now.UTC().Format(time.RFC3339),
	)
}

func main() {
	method, path := os.Getenv("REQUEST_METHOD"), os.Getenv("PATH_INFO")
	fmt.Print("Content-Type: application/json\n")
	switch {
	case path != "/time":
		fmt.Print("Status: 404 Not Found\n\n{\"error\":\"not found\"}\n")
	case method != "GET":
		fmt.Print("Status: 405 Method Not Allowed\n\n{\"error\":\"method not allowed\"}\n")
	default:
		fmt.Print("Status: 200 OK\n\n" + moscowJSON(time.Now()) + "\n")
	}
}
```

### Build + run

```
$ tinygo build -o main.wasm -target=wasi -no-debug ./main.go
-rwxr-xr-x 1 root root 197037 Oct 15 19:36 main.wasm

$ wasmtime run --env REQUEST_METHOD=GET --env PATH_INFO=/time main.wasm
Content-Type: application/json
Status: 200 OK

{"unix":1792092973,"iso":"2026-10-15T22:36:13+03:00","hour_minute":"22:36","timezone":"Europe/Moscow","utc_offset":"+03:00","utc":"2026-10-15T19:36:13Z"}

$ wasmtime run --env REQUEST_METHOD=GET --env PATH_INFO=/nope main.wasm
Content-Type: application/json
Status: 404 Not Found

{"error":"not found"}
```

### Comparison

Both measured with `hyperfine -N` inside `wasmlab` (`--warmup`, 30 runs):

```
wasmtime run --env REQUEST_METHOD=GET --env PATH_INFO=/time main.wasm   n=30 p50=25.02ms p95=31.36ms mean=24.78ms
curl -s http://127.0.0.1:3000/time  (persistent Spin server)            n=30 p50=2.98ms  p95=3.19ms  mean=2.99ms
```

| | `wasmtime run` (per invocation) | Spin (persistent wasi-http server) |
|---|---:|---:|
| Module size | 197,037 bytes (192 KB) | 370,314 bytes (362 KB) |
| Cost per request | **25.0 ms** p50 (every request is a cold start) | **3.0 ms** p50 (incl. `curl`) |
| Cold start of the server | - | 115 ms once (Task 2) |

The CLI module is smaller because it doesn't link the Spin SDK, `net/http` and the
router. Per request it's ~8x slower, because every invocation starts a process, compiles
the module and instantiates it; Spin pays the start and compile once and then only
instantiates per request. Break-even is about 5 requests per Spin start.

### Design questions

**h) Why the Spin component can't run under `wasmtime run`.** `wasmtime run` executes a
command: it calls the `_start` export. My Spin module's exports are `_initialize`,
`handle-http-request` and `spin_http_handle_http_request` - **no `_start`**, while the
CLI module exports `_start`. (I read both export tables from the binaries.) Under
`wasmtime run`, the Spin module just runs `_initialize` and exits with code 0, printing
nothing: there's no host to deliver an HTTP request to the handler. It needs a host that
speaks its HTTP interface - Spin, or `wasmtime serve` for a proper wasi-http component.

**i) What Spin adds on top of wasmtime.** The HTTP server loop and the wasi-http/Spin HTTP
interface (turning a TCP request into a handler call); the manifest and routing layer
(`spin.toml`: routes -> components, multiple components per app); instance pooling and
per-request instantiation with a precompiled module; the capability policy
(`allowed_outbound_hosts`, key-value stores, variables, SQLite, etc. granted per
component); plus the developer tooling - templates, `spin build`, logs in `.spin/logs/`,
and packaging (`spin registry push` to OCI registries).

**j) When each model fits.** **Per-invocation `wasmtime run` (CGI-like):** rare,
short, independent jobs where 25 ms of start-up doesn't matter and nothing should keep
running - a CI step or git hook, a batch/cron job, or running an untrusted user-supplied
plug-in once in a sandbox. **Persistent Spin server:** request-driven HTTP services with
steady or bursty traffic, where per-request latency matters - an API endpoint like this
`/time`, webhooks, or edge functions; the start cost is paid once, and each request is a
cheap fresh instance.
