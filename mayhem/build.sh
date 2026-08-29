#!/usr/bin/env bash
#
# mayhem/build.sh — build Hyperledger Fabric's protobuf block/transaction decoders
# (the byte-eating surface in `protoutil`: the Unmarshal* family + the block ->
# envelope -> payload -> channel-header extraction chain) as a sanitized libFuzzer
# binary (OSS-Fuzz Go path: go-118-fuzz-build -libfuzzer archive + clang++ ASan
# link), plus a dynamically-linked KAT oracle probe for mayhem/test.sh to run.
#
# Runs inside the commit image (GO mayhem/Dockerfile) as `mayhem` in /mayhem.
# GOROOT/GOPATH/GOMODCACHE are pinned by the Dockerfile ENV under /opt/toolchains
# (absolute, $HOME-independent — so the offline PATCH re-run finds the cache).
#
# STAGING (netnew §6 Go / oxia pattern): protoutil's own directory mixes internal
# (`protoutil`) and external (`protoutil_test`) test packages, which crashes
# go-118-fuzz-build's package loader. So we stage the harness + KAT into a fresh
# single-package dir under a leading-underscore path ($SRC/_mayhem_harness/...),
# skipped by `go ./...` wildcards but loadable by an explicit path. The harness
# imports the REAL protoutil package (all entry points exported) — no source copy.
#
# VENDOR NOTE: Fabric ships a root vendor/ tree, so the default resolution mode is
# -mod=vendor. We force GOFLAGS=-mod=mod to (a) let `go get` add the go-118-fuzz
# -build /testing shim (absent from vendor/) and (b) resolve the whole graph from
# the in-image module cache. The FIRST (online) build populates $GOMODCACHE; the
# air-gapped PATCH re-run then resolves entirely from it.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (online) fills $GOMODCACHE (module graph + the shim).
#   - GOPROXY points at the in-image module cache's file proxy FIRST, network LAST,
#     so the offline re-run resolves entirely from the cache; GOFLAGS=-mod=mod +
#     GOSUMDB=off keep go.sum verification local.
set -euo pipefail

: "${SRC:=/mayhem}"

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}"
: "${CXX:=clang++}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

# Sanitizers (§6.1): the OSS-Fuzz Go path is ASan-only for the libFuzzer link.
# Honor the knob — an explicit empty SANITIZER_FLAGS yields an un-sanitized build.
: "${SANITIZER_FLAGS=-fsanitize=address}"
export SANITIZER_FLAGS
GO_SAN="-fsanitize=address"
[ -n "${SANITIZER_FLAGS}" ] || GO_SAN=""

# Debug-info contract (§6.2 item 10): gc always emits DWARF4 with no knob, so we
# force the clang-compiled cgo C shims to DWARF3 (CGO_CFLAGS/CGO_CXXFLAGS) AND
# prepend a DWARF3 anchor.o at the final clang++ link so the FIRST .debug_info CU
# (what the gate reads) is DWARF < 4. $GO_DEBUG_FLAGS threads any base pins.
export GO_DEBUG_FLAGS="${GO_DEBUG_FLAGS:--gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:-} ${GO_DEBUG_FLAGS}"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:-} ${GO_DEBUG_FLAGS}"

# Resolve modules offline-first from the in-image cache; network only as fallback.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOSUMDB="${GOSUMDB:-off}"
export GOWORK=off
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"

cd "$SRC"
go version

TARGET="fuzz_protoutil"
STAGE="$SRC/_mayhem_harness"

# ── Stage the harness + KAT into leading-underscore single-package dirs ─────────
rm -rf "$STAGE"
mkdir -p "$STAGE/protoutilfuzz" "$STAGE/kat"
cp "$SRC/mayhem/harness_protoutil.go.src" "$STAGE/protoutilfuzz/harness_protoutil.go"
cp "$SRC/mayhem/kat/main.go.src"          "$STAGE/kat/main.go"

# ── Module graph: add the go-118-fuzz-build /testing shim ──────────────────────
# Reference the shim by the PSEUDO-VERSION the Dockerfile's `go install ...@<commit>`
# already resolved + cached. A raw commit hash forces a proxy.golang.org round trip
# — fatal on the air-gapped PATCH re-run; the pseudo-version resolves from cache.
GO118_SHIM_VERSION="v0.0.0-20250520111509-a70c2aa677fa"
go get "github.com/AdamKorcz/go-118-fuzz-build/testing@${GO118_SHIM_VERSION}"

# ── Build the libFuzzer archive from the staged single-file package ────────────
# Intermediates go under /tmp (NOT /mayhem) so the large go-118-fuzz-build archive
# is never baked into the committed image layer — keeps the commit image small.
BUILD_TMP="${TMPDIR:-/tmp}/mayhem-build"
mkdir -p "$BUILD_TMP"
echo "=== go-118-fuzz-build $TARGET (func FuzzProtoutil) ==="
go-118-fuzz-build -func FuzzProtoutil -o "$BUILD_TMP/$TARGET.a" ./_mayhem_harness/protoutilfuzz

# ── DWARF3 anchor FIRST, then clang++ ASan+fuzzer link ─────────────────────────
printf 'int __mayhem_dwarf3_anchor;\n' > "$BUILD_TMP/anchor.c"
$CC $GO_DEBUG_FLAGS -c "$BUILD_TMP/anchor.c" -o "$BUILD_TMP/anchor.o"
$CXX $GO_SAN $LIB_FUZZING_ENGINE \
     "$BUILD_TMP/anchor.o" "$BUILD_TMP/$TARGET.a" -o "/mayhem/$TARGET"
echo "built /mayhem/$TARGET"

# ── KAT oracle probe: dynamically-linked (cgo) so the sabotage shim can neuter it ─
export CGO_ENABLED=1
go build -o /mayhem/fabric_protoutil_kat ./_mayhem_harness/kat
file /mayhem/fabric_protoutil_kat | grep -q 'dynamically linked' \
  || { echo "FATAL: /mayhem/fabric_protoutil_kat is not dynamically linked — oracle would be reward-hackable"; exit 1; }
echo "built /mayhem/fabric_protoutil_kat (dynamically linked)"

echo "build.sh complete"
