#!/usr/bin/env bash
# Resolve the latest non-prerelease pomodorough-core release at build time,
# verify its Sigstore attestation, and record provenance into
# Resources/SharedCore (tag/commit/sha256 + wasm). Fail-closed: any
# resolution, download, or attestation failure aborts the build.
set -euo pipefail

CORE_REPO="${CORE_REPO:-Pomodoro-Everywhere/pomodorough-core}"
CORE_SIGNER_WORKFLOW="${CORE_SIGNER_WORKFLOW:-Pomodoro-Everywhere/pomodorough-core/.github/workflows/release.yml}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Resources/SharedCore"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v gh >/dev/null 2>&1 || { echo "fetch_shared_core: gh CLI is required" >&2; exit 1; }

TAG="$(gh api "repos/$CORE_REPO/releases/latest" --jq .tag_name)"
if [[ ! "$TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "fetch_shared_core: unexpected core tag: $TAG" >&2
  exit 1
fi

COMMIT="$(gh api "repos/$CORE_REPO/commits/$TAG" --jq .sha)"
if [[ ! "$COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "fetch_shared_core: unexpected core commit: $COMMIT" >&2
  exit 1
fi

gh release download "$TAG" --repo "$CORE_REPO" \
  --pattern 'pomodorough_core.wasm' --pattern 'SHA256SUMS' \
  --dir "$TMP" --clobber
WASM="$TMP/pomodorough_core.wasm"
if [[ ! -s "$WASM" ]]; then
  echo "fetch_shared_core: downloaded wasm is missing" >&2
  exit 1
fi

python3 - "$WASM" <<'PY'
import sys
with open(sys.argv[1], "rb") as handle:
    magic = handle.read(4)
if magic != b"\0asm":
    raise SystemExit("fetch_shared_core: downloaded file is not a WebAssembly module")
PY

(cd "$TMP" && grep 'pomodorough_core.wasm' SHA256SUMS | shasum -a 256 --check --strict -)

gh attestation verify "$WASM" --repo "$CORE_REPO" \
  --signer-workflow "$CORE_SIGNER_WORKFLOW" \
  --source-digest "$COMMIT" \
  --source-ref "refs/tags/$TAG"

SHA="$(shasum -a 256 "$WASM" | awk '{print $1}')"
if [[ ! "$SHA" =~ ^[0-9a-f]{64}$ ]]; then
  echo "fetch_shared_core: unexpected sha256: $SHA" >&2
  exit 1
fi

cp "$WASM" "$DEST/pomodorough_core.wasm"
printf '%s' "$TAG" > "$DEST/CORE_RELEASE_TAG"
printf '%s' "$COMMIT" > "$DEST/CORE_COMMIT"
printf '%s' "$SHA" > "$DEST/CORE_SHA256"

echo "CORE_PROVENANCE tag=$TAG commit=$COMMIT sha256=$SHA"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf 'Shared core %s (%s, sha256 %s)\n' "$TAG" "$COMMIT" "$SHA" >> "$GITHUB_STEP_SUMMARY"
fi
