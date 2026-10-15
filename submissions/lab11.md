# Lab 11 - Reproducible Builds of QuickNotes with Nix

## Environments

Both builds ran on my MacBook Air (Apple M3) inside Docker, in **two separate
`nixos/nix` containers** (Nix 2.35.3, `aarch64-linux`), each with its own empty `/nix` store:

- **Environment A** - container `nixA`, repo bind-mounted from the Mac ([`lab11/phase1.sh`](../lab11/phase1.sh), log [`lab11/phase1.log`](../lab11/phase1.log))
- **Environment B** - brand-new container `nixB`, **fresh `git clone`** of `feature/lab11` from GitHub at commit `a3157f9` ([`lab11/phase2.sh`](../lab11/phase2.sh), log [`lab11/phase2.log`](../lab11/phase2.log))

I built inside Linux containers rather than with Nix on macOS: a macOS build produces
an `aarch64-darwin` binary (different hash by definition), and an OCI image needs a
Linux binary anyway.

## Task 1 - Reproducible Go build via Nix flake

### `flake.nix`

```nix
{
  description = "QuickNotes - reproducible build (Lab 11)";

  inputs = {
    # Pinned channel; flake.lock pins the exact revision.
    # nixos-25.11 ships Go >= 1.24, which app/go.mod requires.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs:
        let
          quicknotes = pkgs.buildGoModule {
            pname = "quicknotes";
            version = "0.1.0";
            src = ./app;

            # QuickNotes has zero third-party dependencies (no go.sum), so there
            # is nothing to vendor: null tells buildGoModule to skip the vendor
            # derivation. With a dependency added, Nix fails with the real hash
            # ("got: sha256-...") to paste here.
            vendorHash = null;

            env.CGO_ENABLED = 0;                 # static binary
            ldflags = [ "-s" "-w" ];             # strip symbols / DWARF
            subPackages = [ "." "healthcheck" ]; # quicknotes + healthcheck
          };

          docker = pkgs.dockerTools.buildImage {
            name = "quicknotes";
            tag = "nix";
            # No `created` override: it defaults to 1970-01-01, which keeps the
            # image digest independent of when it was built.
            extraCommands = ''
              mkdir -p app data
              cp ${./app/seed.json} app/seed.json
              chmod 0777 data   # writable by the nonroot user without chown
            '';
            config = {
              Entrypoint = [ "${quicknotes}/bin/quicknotes" ];
              ExposedPorts = { "8080/tcp" = { }; };
              User = "65532:65532";   # distroless "nonroot", as in Lab 6
              WorkingDir = "/app";
              Env = [
                "ADDR=:8080"
                "DATA_PATH=/data/notes.json"
                "SEED_PATH=/app/seed.json"
              ];
            };
          };
        in
        {
          inherit quicknotes docker;
          default = quicknotes;
        });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.go pkgs.gopls pkgs.golangci-lint ];
        };
      });
    };
}
```

`flake.lock` ([link](../flake.lock)) pins `nixos-25.11` to revision
`b6018f87da91d19d0ab4cf979885689b469cdd41`
(`narHash sha256-twXPFqFsrrY5r28Zh7Homgcp2gUMBgQ6WDS98Q/3xFI=`).

Requirement checklist: pinned nixpkgs (25.11, Go >= 1.24) / `quicknotes` + `default`
packages from `app/` / `buildGoModule` / `CGO_ENABLED = 0` / `vendorHash` pinned (see
question b - QuickNotes has no dependencies, so the correct value is `null`) /
`ldflags = [ "-s" "-w" ]` / `devShell` with `go`, `gopls`, `golangci-lint` / `flake.lock` committed.

### Build log excerpt (environment A)

```
$ nix build .#quicknotes -L
building '/nix/store/zis084gjavj0jg2mcvpkc0hn3g0wb3fq-quicknotes-0.1.0.drv'...
quicknotes> unpacking source archive /nix/store/0axahfgcc3b02jpvh1nkjh5bk4ispafm-app
quicknotes> Running phase: buildPhase
quicknotes> Building subPackage ./.
quicknotes> Building subPackage ./healthcheck
quicknotes> Running phase: checkPhase
quicknotes> ok          quicknotes      0.004s
quicknotes> Running phase: installPhase
quicknotes> Running phase: fixupPhase
quicknotes> patchelf: cannot find section '.dynamic'. The input file is most likely statically linked
quicknotes> stripping (with command strip and flags -S -p) in /nix/store/xv7pzl87lglb1wgkrf4lc60dbdwz1ca8-quicknotes-0.1.0/bin
```

`patchelf` confirms the binaries are static (`CGO_ENABLED = 0`), and the tests ran in the build.

### Two independent builds - identical

| | Environment A | Environment B (fresh clone) |
|---|---|---|
| Store path | `/nix/store/xv7pzl87lglb1wgkrf4lc60dbdwz1ca8-quicknotes-0.1.0` | `/nix/store/xv7pzl87lglb1wgkrf4lc60dbdwz1ca8-quicknotes-0.1.0` |
| `nix-store --query --hash` | `sha256:0sklj830zl6ci4gmk6wir6hszp9pig8yv5rvcbdia2k7hxs5vr0c` | `sha256:0sklj830zl6ci4gmk6wir6hszp9pig8yv5rvcbdia2k7hxs5vr0c` |

Environment B really built from source (`building '...quicknotes-0.1.0.drv'` in its log)
rather than fetching a cached result, so the match proves the output bits are identical.

### It runs

```
$ ADDR=:8080 DATA_PATH=/tmp/qd/notes.json SEED_PATH=/repo/app/seed.json ./result/bin/quicknotes &
2026/10/15 18:06:21 quicknotes listening on :8080 (notes loaded: 4)
$ curl -i localhost:8080/health
HTTP/1.1 200 OK
Content-Type: application/json

{"notes":4,"status":"ok"}
```

### Design questions

**a) Why `go build` is not bit-identical across machines.** By default it embeds
machine-specific data: the absolute source and module-cache paths (unless `-trimpath`),
a build ID derived from those inputs, VCS stamps (commit, dirty flag and **commit time**
via `-buildvcs`), and the exact Go toolchain version, `GOOS/GOARCH` and CGO toolchain
(a different C compiler or libc changes the binary). Dependency resolution can also
differ if `go.sum`/`GOPROXY`/`GOFLAGS` differ. Nix removes all of this: the toolchain is
pinned by `flake.lock`, the build runs in a fixed path with `-trimpath`, no VCS info, and
fixed timestamps (everything in the store is dated 1970).

**b) `vendorHash`.** It's the SHA-256 (NAR hash) of the **vendored dependency tree**
- the `vendor/` directory produced by `go mod vendor` in a separate fixed-output
derivation. Because that step downloads from the network, Nix only allows it if the
result matches a hash declared in advance; a changed dependency or a tampered proxy
fails the build with `hash mismatch ... got: sha256-...`. `vendorHash = null;` means
"there is no vendor derivation": Nix doesn't download anything and builds with what's
in the source. That's correct for QuickNotes, which has **zero third-party dependencies**
(no `go.sum`). For a module with dependencies, `null` would make the build fail
(missing modules, no network in the sandbox) unless a `vendor/` directory is committed.

**c) `flake.lock`.** `flake.nix` only says `nixos-25.11`, a moving branch; the lock
file records the exact commit (`b6018f8`) and its content hash. That revision fixes the
whole toolchain - Go version, stdenv, `strip`, `dockerTools` - so it decides every hash
downstream. Delete it before the second build and Nix re-resolves `nixos-25.11` to
whatever the branch points at *now*; if any input changed (a Go point release, a
patch), the store path and the image digest change and the "reproducible" claim
breaks. (The flake also wouldn't be pure-evaluable without it in CI.)

**d) `buildGoModule` vs `buildGoApplication`.** `buildGoModule` is in nixpkgs: it
vendors all dependencies as one fixed-output derivation identified by a single
`vendorHash`. `buildGoApplication` comes from the separate `gomod2nix` project: a
`gomod2nix.toml` lists every module with its own hash, so each dependency is its own
derivation (better caching and sharing between projects, no single opaque hash), but it
needs an extra tool and generated file to keep in sync. I picked **`buildGoModule`**:
QuickNotes has no dependencies, so per-module granularity buys nothing, and it needs no
extra input beyond nixpkgs.

## Task 2 - Deterministic OCI image

### Image output

The `docker` output in the flake above uses `pkgs.dockerTools.buildImage`:
`Entrypoint` is the Nix-built binary (exec form), `ExposedPorts` has `8080/tcp`, it runs
as `65532:65532` (distroless "nonroot"), and it was built with Nix only - no Docker
daemon involved. Since there is no `chown` without root/fakeroot, `/data` is created
with mode `0777` so the nonroot user can write `notes.json`.

### Two independent builds - identical digests

```
IMAGE_SHA256_A 9c8f3979ad75a8552599875f11ace3674a310a6b4aca8ed9494db3c1fa4b66cb
IMAGE_SHA256_B 9c8f3979ad75a8552599875f11ace3674a310a6b4aca8ed9494db3c1fa4b66cb

$ shasum -a 256 lab11/out/quicknotes-nix-*.tar.gz
9c8f3979ad75a8552599875f11ace3674a310a6b4aca8ed9494db3c1fa4b66cb  lab11/out/quicknotes-nix-A.tar.gz
9c8f3979ad75a8552599875f11ace3674a310a6b4aca8ed9494db3c1fa4b66cb  lab11/out/quicknotes-nix-B.tar.gz
```

### Loads and runs

```
$ docker load -i lab11/out/quicknotes-nix-A.tar.gz
Loaded image: quicknotes:nix
$ docker run -d --name qn-nix -p 18081:8080 quicknotes:nix
$ curl -i localhost:18081/health
HTTP/1.1 200 OK
Content-Type: application/json

{"notes":4,"status":"ok"}
$ docker inspect quicknotes:nix --format 'User={{.Config.User}} Entrypoint={{.Config.Entrypoint}} Ports={{.Config.ExposedPorts}} Created={{.Created}}'
User=65532:65532 Entrypoint=[/nix/store/xv7pzl87lglb1wgkrf4lc60dbdwz1ca8-quicknotes-0.1.0/bin/quicknotes] Ports=map[8080/tcp:{}] Created=1970-01-01T00:00:01Z
```

### Lab 6 Dockerfile, built twice with `--no-cache`

```
$ docker build --no-cache -t qn-lab6:run1 ./app
$ docker build --no-cache -t qn-lab6:run2 ./app
$ docker images --no-trunc qn-lab6
REPOSITORY   TAG       IMAGE ID                                                                  CREATED                  SIZE
qn-lab6      run2      sha256:1fe7c6ae83602158bdfaff9277cdb94232e71109109898d80430714b05dfb6c7   Less than a second ago   22.1MB
qn-lab6      run1      sha256:6bdfa5167e45bb5270485e27cc36bca3d874a06c5f5782065e106d63dc33d9c4   6 seconds ago            22.1MB
[qn-lab6:run1] created=2026-10-15T19:05:22.033041805Z
[qn-lab6:run2] created=2026-10-15T19:05:28.219453002Z
```

Same Dockerfile, same commit, a few seconds apart - **different digests**, and the
`created` timestamps alone are enough to explain it.

### Size comparison

| Image | Content size | Disk usage | Tarball |
|---|---:|---:|---:|
| `quicknotes:nix` (Nix, `dockerTools.buildImage`) | 14.5 MB | 31.4 MB | 5.1 MB (`.tar.gz`) |
| `qn-lab6` (Dockerfile, distroless) | 5.4 MB | 22.1 MB | - |

The Nix image is a bit larger: it is a single uncompressed-layer image holding the
QuickNotes **and** healthcheck binaries from the store path (~10.8 MB uncompressed),
while Lab 6's content size is measured compressed. Both have no shell or package manager.

### Design questions

**e) Non-determinism in `docker build`.** Every image and layer gets a `created`
timestamp of the build time, and the config records the build history with times; files
written by `RUN` get the current mtime (and `apt`/`apk` leave logs and caches with
times); `FROM golang:1.25-alpine` and `distroless:nonroot` are moving tags, so a later
build may use a different base; package installs resolve "latest" from a mirror; and
`go build` inside it can embed VCS stamps. BuildKit can be pushed towards
reproducibility (`SOURCE_DATE_EPOCH`, pinned base digests, `rewrite-timestamp`), but
it isn't the default - as run1 vs run2 shows.

**f) What an auditor can prove.** A signature proves **who** published the image and
that it wasn't modified afterwards - not **what source** it came from. If the CI runner
or a build dependency was compromised, the backdoored image gets signed just the same.
A reproducible image lets anyone independently rebuild from the public commit +
`flake.lock` and get the **same digest**, which proves the binary corresponds exactly to
the reviewed source, with nothing injected at build time. You verify the artifact
instead of trusting the builder (the SolarWinds-style attack is exactly what this catches).

**g) The trade-off.** Nix has a steep learning curve (its own functional language,
derivations, store, flakes), and errors are hard to read. Everything must be declared
- no network during builds, every dependency pinned with hashes - so "just `apt-get
install` it" no longer works. The store and first builds use a lot of disk and
bandwidth, and fast builds really want a binary cache (Cachix). macOS needs a Linux
builder for images, and tooling/IDE support is thinner. `docker build` is
already known by everyone, works with a 10-line Dockerfile, and is "reproducible
enough" for most teams, who mostly need repeatable deploys, not bit-for-bit provenance.

## Bonus - CI-verified reproducibility

### Workflow: [`.github/workflows/nix-repro.yml`](../.github/workflows/nix-repro.yml)

```yaml
name: nix-repro

# Builds the Nix OCI image in two independent jobs (fresh runners each) and
# fails if the two image digests differ. Lab 11 bonus.
on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  build-a:
    runs-on: ubuntu-24.04
    outputs:
      digest: ${{ steps.d.outputs.digest }}
    env:
      BREAK_REPRO: "0"   # "1" = deliberately change the source in job A only
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - uses: DeterminateSystems/nix-installer-action@3138316df39ed29be04236d7ffc686fa525866aa # v23
      - name: Deliberate divergence (only when BREAK_REPRO=1)
        if: env.BREAK_REPRO == '1'
        run: echo " " >> app/seed.json
      - run: nix build .#docker -L
      - id: d
        run: |
          d=$(sha256sum result | awk '{print $1}')
          echo "digest=$d" >> "$GITHUB_OUTPUT"
          echo "job A digest: $d"

  build-b:
    runs-on: ubuntu-24.04
    outputs:
      digest: ${{ steps.d.outputs.digest }}
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - uses: DeterminateSystems/nix-installer-action@3138316df39ed29be04236d7ffc686fa525866aa # v23
      - run: nix build .#docker -L
      - id: d
        run: |
          d=$(sha256sum result | awk '{print $1}')
          echo "digest=$d" >> "$GITHUB_OUTPUT"
          echo "job B digest: $d"

  compare:
    runs-on: ubuntu-24.04
    needs: [build-a, build-b]
    steps:
      - env:
          A: ${{ needs.build-a.outputs.digest }}
          B: ${{ needs.build-b.outputs.digest }}
        run: |
          echo "A=$A"
          echo "B=$B"
          if [ -z "$A" ] || [ "$A" != "$B" ]; then
            echo "::error::Not reproducible: digests differ"
            exit 1
          fi
          echo "Reproducible: both jobs produced $A"
```

- Triggers on every push and pull request
- `build-a` and `build-b` run in parallel on separate fresh `ubuntu-24.04` runners; each
  exposes its image digest as a job output
- `compare` needs both and fails if the digests differ (or one is missing)
- `DeterminateSystems/nix-installer-action` pinned to
  `3138316df39ed29be04236d7ffc686fa525866aa` (tag `v23`, resolved with
  `git ls-remote`); `actions/checkout` pinned as in Lab 3
- Only `contents: read`

### Red run - deliberate divergence caught

https://github.com/Kulichcom/DevOps-Intro/actions/runs/38791205479 (commit `28d2dee`,
`BREAK_REPRO: "1"`: job A appends a space to `app/seed.json` before building)

```
A=40f26c9637c043901da7070c78eec9cb3036ff4f8d49b78a31b695e68ee71032
B=daee01092c38fd0e4a3f4a3953d624640885d896cbe21b8280d24de55b228c3c
Error: Not reproducible: digests differ
Error: Process completed with exit code 1.
```

### Green run - fixed

https://github.com/Kulichcom/DevOps-Intro/actions/runs/38791491995 (commit `ada0abc`, `BREAK_REPRO: "0"`)

```
A=daee01092c38fd0e4a3f4a3953d624640885d896cbe21b8280d24de55b228c3c
B=daee01092c38fd0e4a3f4a3953d624640885d896cbe21b8280d24de55b228c3c
Reproducible: both jobs produced daee01092c38fd0e4a3f4a3953d624640885d896cbe21b8280d24de55b228c3c
```

The CI digest (`daee0109...`) differs from my laptop's (`9c8f3979...`) because GitHub's
runners are `x86_64-linux` and my containers are `aarch64-linux` - a different target
system means a different binary. Within one system, every build matches.

**Why not `SOURCE_DATE_EPOCH` for the break?** The lab suggests setting it only in job A.
I didn't use it because it would most likely **not** go red: Nix builds don't inherit
the caller's environment, so an env var set on the runner never reaches the derivation. I changed
an input file instead, which is a real divergence Nix must notice. (See question j.)

### Design questions

**h) "Reproducible on my laptop" vs "in CI".** On my laptop the proof rests on my word,
my machine and my environment: a local cache, an extra overlay or a manual step could
make two builds match for the wrong reason, and nobody else can see it. CI is a public,
logged, repeatable process from a clean runner, tied to an exact commit: anyone can
open the run and see two independent machines produce the same digest, and it is
re-checked automatically on every push, so a regression is caught the moment it lands
instead of months later. For an auditor that turns a claim into evidence.

**i) Why two parallel jobs.** Two builds inside one job share the same machine, the
same `/nix/store`, the same kernel, clock, filesystem and environment. The second
`nix build` would usually just return the cached store path from the first, so it would
"match" without building anything - it can't catch non-determinism that depends on time,
hostname, CPU, filesystem ordering, or anything leaking from that runner. Two fresh
runners with empty stores each really build from scratch, which is what independent
verification means.

**j) `SOURCE_DATE_EPOCH`.** It would normally leak in as file mtimes and the image's
`created`/history timestamps, plus anything a build tool stamps (Go's VCS commit time,
archive mtimes). In Nix: every store path is normalised to mtime 1 (1970) when it's
added to the store, and stdenv exports `SOURCE_DATE_EPOCH=315532800` (1980) inside every
build, so tools that honour it are already fixed. `dockerTools.buildImage` has a
`created` argument that defaults to `"1970-01-01T00:00:01Z"` - visible in my
`docker inspect` output - and it builds layer tars with fixed mtimes and ownership, so
no wall-clock time reaches the image. Setting `created = "now"` would be the way
to break that on purpose, since it makes the image depend on the build time.
