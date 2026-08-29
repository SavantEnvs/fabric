#!/usr/bin/env bash
#
# mayhem/test.sh — BEHAVIORAL oracle for Hyperledger Fabric's protobuf block/tx
# decoders. Runs the dynamically-linked KAT probe (/mayhem/fabric_protoutil_kat,
# built by build.sh) that encodes a fixed block carrying channel id "katchan",
# drives the real byte-in decode path (GetChannelIDFromBlockBytes / UnmarshalBlock
# / ComputeBlockDataHash), and prints the decoded fields; this script asserts the
# EXACT values.
#
# Why not `go test` alone (netnew §4): a Go test binary is statically linked, so
# the gate's LD_PRELOAD sabotage shim cannot neuter it — the suite would survive
# sabotage while proving nothing (the cosign/notary false-green). The KAT probe is
# cgo-linked (dynamic), so when the program is neutered to _exit(0) it prints
# nothing, every assertion below misses, and test.sh FAILS — which is the point
# (§6.3).
#
# Emits a CTRF summary; exits non-zero iff failed>0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-${SRC:-/mayhem}/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PROBE=/mayhem/fabric_protoutil_kat
passed=0; failed=0

# Unconditional: a missing probe is a build.sh bug — FAIL loudly, never skip.
if [ ! -x "$PROBE" ]; then
  echo "FAIL: KAT probe $PROBE missing or not executable (build.sh should have produced it)" >&2
  emit_ctrf "fabric-protoutil-kat" 0 1
  exit 1
fi

OUT="$("$PROBE" 2>/dev/null)"
echo "--- KAT probe output ---"; printf '%s\n' "$OUT"; echo "------------------------"

# Fixed input: a marshaled Block whose single Envelope carries a ChannelHeader with
# ChannelId "katchan" and header Number 42. Assert every decoded field against the
# known answer. KAT_DATAHASH is SHA256("abc"), a fixed well-known constant.
assert() { # <desc> <expected-line>
  if printf '%s\n' "$OUT" | grep -qxF "$2"; then
    echo "PASS: $1"; passed=$((passed+1))
  else
    echo "FAIL: $1 (expected exact line: $2)"; failed=$((failed+1))
  fi
}

assert "channel id decodes to 'katchan'"          "KAT_CHANNELID=katchan"
assert "block header number round-trips as 42"    "KAT_BLOCKNUM=42"
assert "ComputeBlockDataHash('abc') == SHA256('abc')" \
       "KAT_DATAHASH=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
assert "empty (data-less) block is rejected"      "KAT_EMPTYERR=true"

emit_ctrf "fabric-protoutil-kat" "$passed" "$failed"
