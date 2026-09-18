# Lab 4 — OS & Networking

## Task 1 — Trace a Request End-to-End

### 1.1-1.2: Capture + decode

Full annotated capture: see `lab4-trace.txt`. Summary of what was
identified (all traffic over IPv6 loopback, `::1`, since `localhost`
resolved to IPv6 first on this Mac):

| Step | Timestamp | Detail |
|---|---|---|
| SYN | 09:20:40.868044 | `Flags [S]` — client opens handshake |
| SYN/ACK | 09:20:40.868136 | `Flags [S.]` — server acknowledges + opens |
| ACK | 09:20:40.868159 | `Flags [.]` — handshake complete |
| HTTP request | 09:20:40.868313 | `POST /notes HTTP/1.1` + JSON body |
| HTTP response | 09:20:40.880747 | `HTTP/1.1 201 Created` + JSON body (note id 6) |
| Close | 09:20:40.880823-881028 | 4-way close: client FIN, server ACK, server FIN, client ACK |

App processing time (request received → response sent): ~11.5ms.

### 1.3: Five debugging commands

**1. What's listening?** (macOS: `lsof` substituted for `ss`, which
doesn't exist on macOS)

    $ sudo lsof -iTCP:8080 -sTCP:LISTEN -nP
    COMMAND     PID           USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    quicknote 55552 iliakulichenko    5u  IPv6 0xea5ecd6bfcd6e31b      0t0  TCP *:8080 (LISTEN)

Notable: listening on `*:8080` (all interfaces), not just loopback.

**2. Routes** (macOS: `netstat -rn` substituted for `ip route show`)

    default            link#26            UCSg                utun4
    default            192.168.1.1        UGScIg                en0
    127.0.0.1          127.0.0.1          UH                    lo0
    ::1                ::1                UHL                   lo0

Notable: an active VPN (`utun4`) holds a default route alongside the
normal LAN gateway — doesn't affect loopback traffic either way.

**3. Reachability**

    $ sudo mtr -rwc 5 localhost
    HOST: MacBook-Air-Ilia.local Loss%   Snt   Last   Avg  Best  Wrst StDev
      1.|-- localhost               0.0%     5    0.5   0.9   0.4   2.8   1.0

0% loss, single hop, sub-millisecond — as expected for loopback.

**4. DNS**

    $ dig +short example.com @1.1.1.1
    104.20.23.154
    172.66.147.243

Resolves correctly; two IPs returned (Cloudflare anycast).

**5. Logs**

    $ journalctl --user -u quicknotes -n 20 || true
    zsh: command not found: journalctl

Expected — `journalctl` is systemd-specific and doesn't exist on macOS.

### 1.4: 502 reflection

If QuickNotes returned a 502, the first thing I'd check is whether the
process is even alive (`ps aux | grep quicknotes` or `lsof
-iTCP:8080 -sTCP:LISTEN`), since a 502 means something in front of the
app got no usable response from it — often the process crashed or never
started. If it's running and listening, I'd check reachability directly
next, then DNS if a hostname's involved, then logs for the actual error.
The five commands above are exactly this order: running, listening,
reachable, DNS, logs — each rules out one layer before moving to the next.

## Task 2 — Outside-In Debugging on a Broken Deploy

### 2.1: Reproduce

The original QuickNotes instance from Task 1 (PID 55552) was already
running on :8080. A second instance was started against the same port:

    $ ADDR=:8080 go run . 2>&1 | tee /tmp/qn-broken.log
    2026/09/18 09:27:41 quicknotes listening on :8080 (notes loaded: 6)
    2026/09/18 09:27:41 listen: listen tcp :8080: bind: address already in use
    exit status 1

The second instance failed to bind and exited cleanly with status 1 —
it never displaced the first, healthy instance.

### 2.2: Outside-in chain

**1. Is it running?**

    $ ps -ef | grep quicknotes
    501 55552 55533   0  9:10AM ttys000    0:00.03 .../quicknotes

Decision: exactly one instance is running — the original. The failed
second attempt never appears here, confirming it never started.

**2. Is it listening?** (macOS: `lsof` substituted for `ss`)

    $ sudo lsof -iTCP:8080 -sTCP:LISTEN -nP
    quicknote 55552 iliakulichenko 5u IPv6 ... TCP *:8080 (LISTEN)

Decision: same PID (55552) holds the port — unaffected by the bind failure.

**3. Reachable from host?**

    $ curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/health
    200

Decision: fully healthy and reachable.

**4. Firewall blocking?** (macOS: `pfctl` substituted for `iptables`/`nft`)

    $ sudo pfctl -sr
    scrub-anchor "com.apple/*" all fragment reassemble
    anchor "com.apple/*" all

Decision: only default Apple system anchors active, no custom rule
blocking port 8080 — firewall ruled out.

**5. DNS?**

    $ dig +short localhost
    (empty)
    $ cat /etc/hosts | grep localhost
    127.0.0.1	localhost
    ::1             localhost

Decision: `dig` correctly returns nothing — `localhost` is resolved via
`/etc/hosts`, not DNS, so an empty `dig` result here is expected and
correct, not a problem. Worth distinguishing "name resolution" (which
worked, via hosts file) from "DNS resolution" (not applicable to this
hostname).

### 2.3: Repair + re-verify

The original process was healthy throughout; only the second, redundant
attempt failed. Re-verified health after the failed second attempt:

    $ curl -s http://localhost:8080/health
    {"notes":6,"status":"ok"}

### 2.4: Root cause + mini-postmortem

**Root cause:** `bind: address already in use` — a second process
attempted to claim a TCP port already held by a running process.

**Mini-postmortem (blameless):**
This class of failure is systemic, not personal: any deploy process that
doesn't check port availability before starting a new instance is exposed
to it — restarts, redeploys, or crash-loops that don't fully release a
port before the next attempt can all trigger it. The failure mode here
was actually well-behaved: the OS refused the second bind outright and
the process exited with a clear error and status code, rather than
silently corrupting state or partially starting. Tooling that would
prevent surprise from this: a pre-flight port check in deploy scripts,
process supervisors (systemd, a container orchestrator) that guarantee
exactly one instance per port via restart policies instead of manual
`go run` invocations, and health-check-gated deploys that only route
traffic to a new instance once it's confirmed actually listening.
