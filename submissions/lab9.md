# Lab 9 - DevSecOps: Trivy + ZAP on QuickNotes

Pinned tools: Trivy `aquasec/trivy:0.59.1`, ZAP `ghcr.io/zaproxy/zaproxy:2.16.1`. Image under test: `quicknotes:lab6`. Full outputs are in `scans/`.

## Task 1 - Trivy

### 1.1 Scan outputs (top of each file)

**Image scan (before fix)** - `scans/trivy-image.txt`
~~~

quicknotes:lab6 (debian 13.7)
=============================
Total: 0 (HIGH: 0, CRITICAL: 0)


app/healthcheck (gobinary)
==========================
Total: 19 (HIGH: 19, CRITICAL: 0)

┌─────────┬────────────────┬──────────┬────────┬───────────────────┬──────────────────────────────┬──────────────────────────────────────────────────────────────┐
│ Library │ Vulnerability  │ Severity │ Status │ Installed Version │        Fixed Version         │                            Title                             │
├─────────┼────────────────┼──────────┼────────┼───────────────────┼──────────────────────────────┼──────────────────────────────────────────────────────────────┤
│ stdlib  │ CVE-2026-25679 │ HIGH     │ fixed  │ v1.24.13          │ 1.25.8, 1.26.1               │ net/url: Incorrect parsing of IPv6 host literals in net/url  │
│         │                │          │        │                   │                              │ https://avd.aquasec.com/nvd/cve-2026-25679                   │
│         ├────────────────┤          │        │                   ├──────────────────────────────┼──────────────────────────────────────────────────────────────┤
│         │ CVE-2026-27145 │          │        │                   │ 1.25.11, 1.26.4              │ crypto/x509: golang: golang crypto/x509: Denial of Service   │
│         │                │          │        │                   │                              │ via excessive processing of DNS...                           │
│         │                │          │        │                   │                              │ https://avd.aquasec.com/nvd/cve-2026-27145                   │
│         ├────────────────┤          │        │                   ├──────────────────────────────┼──────────────────────────────────────────────────────────────┤
│         │ CVE-2026-32280 │          │        │                   │ 1.25.9, 1.26.2               │ crypto/x509: crypto/tls: golang: Go: Denial of Service       │
│         │                │          │        │                   │                              │ vulnerability in certificate chain building...               │
│         │                │          │        │                   │                              │ https://avd.aquasec.com/nvd/cve-2026-32280                   │
│         ├────────────────┤          │        │                   │                              ├──────────────────────────────────────────────────────────────┤
│         │ CVE-2026-32281 │          │        │                   │                              │ crypto/x509: golang: Go crypto/x509: Denial of Service via   │
~~~

**Filesystem scan** - `scans/trivy-fs.txt`
~~~

.vagrant/machines/default/virtualbox/private_key (secrets)
==========================================================
Total: 1 (HIGH: 1, CRITICAL: 0)

HIGH: AsymmetricPrivateKey (private-key)
════════════════════════════════════════
Asymmetric Private Key
────────────────────────────────────────
 .vagrant/machines/default/virtualbox/private_key:1
────────────────────────────────────────
   1 [ BEGIN OPENSSH PRIVATE KEY-----*******************************************************************************************************************************************************************************************************************************************************************************************************************************************-----END OPENSSH PRI
~~~

**Config scan** - `scans/trivy-config.txt`
~~~

app/Dockerfile (dockerfile)
===========================
Tests: 28 (SUCCESSES: 27, FAILURES: 1)
Failures: 1 (UNKNOWN: 0, LOW: 1, MEDIUM: 0, HIGH: 0, CRITICAL: 0)

AVD-DS-0026 (LOW): Add HEALTHCHECK instruction in your Dockerfile
════════════════════════════════════════
You should add HEALTHCHECK instruction in your docker container images to perform the health check on running containers.

See https://avd.aquasec.com/misconfig/ds026
────────────────────────────────────────
~~~

**CycloneDX SBOM (first 30 lines)** - `scans/sbom.cdx.json`
~~~
{
  "$schema": "http://cyclonedx.org/schema/bom-1.6.schema.json",
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  "serialNumber": "urn:uuid:b7c0d5c5-efc6-404c-985e-7c2c80f1ab07",
  "version": 1,
  "metadata": {
    "timestamp": "2026-10-08T16:17:10+00:00",
    "tools": {
      "components": [
        {
          "type": "application",
          "group": "aquasecurity",
          "name": "trivy",
          "version": "0.59.1"
        }
      ]
    },
    "component": {
      "bom-ref": "pkg:oci/quicknotes@sha256%3A2d593d9c6dcb665822169d6abe4f4a9bd12c131ce79bc9d0058e97f08ebb01b0?arch=arm64&repository_url=index.docker.io%2Flibrary%2Fquicknotes",
      "type": "container",
      "name": "quicknotes:lab6",
      "purl": "pkg:oci/quicknotes@sha256%3A2d593d9c6dcb665822169d6abe4f4a9bd12c131ce79bc9d0058e97f08ebb01b0?arch=arm64&repository_url=index.docker.io%2Flibrary%2Fquicknotes",
      "properties": [
        {
          "name": "aquasecurity:trivy:DiffID",
          "value": "sha256:187cfc6d1e3e8a40a5e64653bcd3239c140807dcf1c09e48021178705a5a6139"
        },
        {
          "name": "aquasecurity:trivy:DiffID",
~~~

**Image scan (after fix)** - `scans/trivy-image-after.txt`
~~~

quicknotes:lab6 (debian 13.7)
=============================
Total: 0 (HIGH: 0, CRITICAL: 0)

~~~

### 1.2 Triage of every HIGH/CRITICAL

Image scan: Debian base layer 0 findings. Both Go binaries (`app/quicknotes`, `app/healthcheck`) had the same 19 HIGH findings, all in `stdlib v1.24.13`. Root cause: the Go 1.24 builder image. All are fixed in Go 1.25.13 or later.

| # | Finding | Component | Severity | Disposition | Reason / evidence |
|---|---------|-----------|----------|-------------|-------------------|
| 1 | CVE-2026-25679 | Go stdlib (both binaries) | HIGH | FIX | Commit 45dbd3b: builder bumped to golang:1.25-alpine |
| 2 | CVE-2026-27145 | Go stdlib | HIGH | FIX | same commit |
| 3 | CVE-2026-32280 | Go stdlib | HIGH | FIX | same commit |
| 4 | CVE-2026-32281 | Go stdlib | HIGH | FIX | same commit |
| 5 | CVE-2026-32283 | Go stdlib | HIGH | FIX | same commit |
| 6 | CVE-2026-33811 | Go stdlib | HIGH | FIX | same commit |
| 7 | CVE-2026-33814 | Go stdlib | HIGH | FIX | same commit |
| 8 | CVE-2026-33818 | Go stdlib | HIGH | FIX | same commit |
| 9 | CVE-2026-39820 | Go stdlib | HIGH | FIX | same commit |
| 10 | CVE-2026-39821 | Go stdlib | HIGH | FIX | same commit |
| 11 | CVE-2026-39822 | Go stdlib | HIGH | FIX | same commit |
| 12 | CVE-2026-39836 | Go stdlib | HIGH | FIX | same commit |
| 13 | CVE-2026-42499 | Go stdlib | HIGH | FIX | same commit |
| 14 | CVE-2026-42504 | Go stdlib | HIGH | FIX | same commit |
| 15 | CVE-2026-56853 | Go stdlib | HIGH | FIX | same commit |
| 16 | CVE-2026-56858 | Go stdlib | HIGH | FIX | same commit |
| 17 | CVE-2026-56859 | Go stdlib | HIGH | FIX | same commit |
| 18 | CVE-2026-56860 | Go stdlib | HIGH | FIX | same commit |
| 19 | CVE-2026-56862 | Go stdlib | HIGH | FIX | same commit |

Re-scan after the fix: `Total: 0 (HIGH: 0, CRITICAL: 0)` (see "Image scan (after fix)" above).

Filesystem scan:

| Finding | Location | Severity | Disposition | Reason |
|---------|----------|----------|-------------|--------|
| AsymmetricPrivateKey | `.vagrant/machines/default/virtualbox/private_key` | HIGH | ACCEPT | Throwaway SSH key that Vagrant generates for the local Lab 5 VM. Not tracked by Git (`git ls-files` is empty) and ignored via `.gitignore:27`. It never leaves my machine. Re-evaluate by 2027-03-01 |

Config scan: only one LOW finding (AVD-DS-0026, no HEALTHCHECK in the Dockerfile). It is below the HIGH/CRITICAL threshold, so no required disposition; ACCEPT for now, re-evaluate by 2027-03-01.

### 1.3 Design questions

**a) What else matters besides CVE severity?** Reachability (do we call the vulnerable code?), whether an exploit exists or is used in the wild, exposure (internet-facing or internal), what the process can access if compromised, whether a fix exists, and compensating controls. A HIGH in code we never call is less urgent than a MEDIUM on an exposed endpoint.

**b) Why is a minimal base the strongest control?** Fewer packages means fewer possible CVEs and a smaller attack surface. Distroless has no shell and no package manager, so an attacker who gets in has almost nothing to use. Here the Debian layer had 0 findings, and every finding was in our own Go binaries.

**c) When is `.trivyignore` right?** Right when the finding is a documented false positive or not reachable, with a written reason and an expiry date. Security theater when it is used to turn CI green without a decision, or with no reason and no review date.

**d) What does the SBOM solve?** When a new CVE like Log4Shell appears, we can answer "are we affected?" by searching a list of components in minutes, including transitive dependencies, instead of rescanning or guessing across every service.

## Task 2 - OWASP ZAP baseline + fix

### 2.1 Run
Baseline (passive) scan only, against `http://host.docker.internal:8080/health`. The first run against `/` returned 404 and tested only 3 URLs, so I re-ran against `/health` (a real 200 endpoint). Reports: `scans/zap-before.html/json`, `scans/zap-after.html/json`.

### 2.2 Triage (before)

| ID | Name | Risk | URL | Disposition | Reason |
|----|------|------|-----|-------------|--------|
| 10021 | X-Content-Type-Options Header Missing | Low (Medium) | `/health` | FIX | Middleware sets `nosniff` (commit 801c489) |
| 90004 | Insufficient Site Isolation Against Spectre | Low (Medium) | `/health` | FIX | Middleware sets `Cross-Origin-Resource-Policy: same-origin` |
| 10049 | Storable and Cacheable Content | Informational (Medium) | `/`, `/health`, `/robots.txt`, `/sitemap.xml` | FIX | Middleware sets `Cache-Control: no-store` |
| 10116 | ZAP is Out of Date | Low (High) | `/sitemap.xml` | ACCEPT | About the scanner, not QuickNotes. The version is pinned on purpose for reproducibility. Re-check by 2027-01-08 |

### 2.3 Fix (middleware + test)
Commit 801c489. `securityHeaders` wraps the whole router inside `Routes()`, so every route gets the headers, including 404s. Code:

~~~go
package main

import "net/http"

// securityHeaders wraps a handler and sets baseline security headers on
// every response, including errors and 404s.
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Cache-Control", "no-store")
		h.Set("Cross-Origin-Resource-Policy", "same-origin")
		h.Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		next.ServeHTTP(w, r)
	})
}
~~~

`Routes()` now returns `securityHeaders(mux)`. Test: `TestSecurityHeaders_PresentOnAllRoutes` checks four headers on `/health`, `/notes` and a 404 path.

Proof that the test guards the fix. Before wiring the middleware in, the test failed (all four headers missing on all three routes):

~~~
--- FAIL: TestSecurityHeaders_PresentOnAllRoutes (0.00s)
    security_test.go:20: /health: header Content-Security-Policy = "", want "default-src 'none'; frame-ancestors 'none'"
    security_test.go:20: /health: header X-Content-Type-Options = "", want "nosniff"
    security_test.go:20: /health: header Cache-Control = "", want "no-store"
    security_test.go:20: /health: header Cross-Origin-Resource-Policy = "", want "same-origin"
    (same four headers missing on /notes and /does-not-exist)
FAIL	quicknotes	0.801s
~~~

After wiring it in: `ok  quicknotes  0.866s`.

### 2.4 Before / after

Response headers before (no security headers):

~~~
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 26
~~~

Response headers after:

~~~
HTTP/1.1 200 OK
Cache-Control: no-store
Content-Security-Policy: default-src 'none'; frame-ancestors 'none'
Content-Type: application/json
Cross-Origin-Resource-Policy: same-origin
X-Content-Type-Options: nosniff
~~~

ZAP before: `WARN-NEW: 4` (10021, 10049, 10116, 90004), `PASS: 63`.
ZAP after: `WARN-NEW: 2`, `PASS: 65`. Remaining: 10116 (accepted above) and 10049, which changed from "Storable and Cacheable Content" to "Non-Storable Content" (Informational). That is ZAP confirming `no-store` works. 10021 and 90004 are gone.

### 2.5 Design questions

**e) Why a middleware and not per-handler headers?** One place covers every route, including 404s and handlers added later, so nobody can forget a header. It is also tested once, instead of in every handler.

**f) What does `default-src 'none'` break, and why is it OK for QuickNotes?** It blocks loading of anything: scripts, styles, images, fonts, frames and fetch connections. A website needs those, so it must allowlist what it uses. QuickNotes only returns JSON and loads no sub-resources, so nothing can break.

**g) What is the cost of marking every informational finding "accepted" without reading it?** Real issues get buried in noise, the team stops trusting the report, and "accepted" without a reason or a review date becomes a permanent blind spot. Informational items can also be early hints of a real problem, so each needs a short decision.

## Bonus - govulncheck CI gate
Not attempted.
