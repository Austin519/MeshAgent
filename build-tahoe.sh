#!/bin/bash
# Build + sign meshagent for macOS Tahoe Apple Silicon with the
# audit-session-isolation fix.
#
# Signing posture:
#   - Developer ID Application (preferred): TCC csreq pins to the
#     team identifier (8Z9254T85U), so rebuilds don't re-prompt.
#     Needs login keychain access. Tahoe's keychain partition-list
#     ACL is session-scoped — first run after a reboot has to be
#     from an interactive (Splashtop / Screen Sharing) Terminal so
#     "Always Allow" can be clicked on the prompt. Subsequent runs
#     until next reboot work over SSH too.
#   - Ad-hoc fallback: if the Developer ID identity is unavailable
#     (e.g. keychain locked over SSH), pass --adhoc. Binary still
#     loads and runs, but TCC csreq pins to CDHash, so every
#     rebuild needs Privacy & Security re-grants.
#
# Hardened runtime (--options runtime):
#   The earlier "v20 had hardened runtime, v21 didn't" framing in
#   meshcentral.md was wrong (verified 2026-05-06: both prior
#   builds were ad-hoc, no runtime bit). Hardened runtime is now
#   off by default; opt in with --runtime if explicitly testing
#   that variable. With --runtime you'll likely also need an
#   entitlements file (see --entitlements).
#
# Usage:
#   ./build-tahoe.sh                        # Developer ID, no runtime
#   ./build-tahoe.sh --adhoc                # ad-hoc, no runtime
#   ./build-tahoe.sh --runtime              # Developer ID + hardened runtime
#   ./build-tahoe.sh --runtime --entitlements /path/to/ent.plist
#   ./build-tahoe.sh --commit <git-ref>     # build a specific source state
#
# Output: ./meshagent_osx-arm-64 (signed per the chosen posture).
# Deploy procedure: see homelab-stack/meshcentral.md "Deploying".

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: build-tahoe.sh must run on macOS (need Apple Silicon toolchain)"
    exit 1
fi

USE_ADHOC=0
USE_RUNTIME=0
ENTITLEMENTS=""
COMMIT_REF=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --adhoc)        USE_ADHOC=1; shift ;;
        --runtime)      USE_RUNTIME=1; shift ;;
        --entitlements) ENTITLEMENTS="$2"; shift 2 ;;
        --commit)       COMMIT_REF="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

DEVELOPER_ID="${MESHAGENT_DEVELOPER_ID:-Developer ID Application: Gavon Renfroe (8Z9254T85U)}"

# Prefer the dedicated build keychain (created by setup-build-keychain.sh,
# imports the Dev ID identity with -A flag = no per-key ACL gating, so
# SSH-driven codesign works without GUI prompts). Fall back to the login
# keychain if the build keychain isn't set up yet.
KEYCHAIN="$HOME/Library/Keychains/meshagent-build.keychain-db"
BUILD_KC_PWD="meshagentbuild"  # matches setup-build-keychain.sh; not sensitive
if [[ -f "$KEYCHAIN" ]]; then
    # Unlock the build keychain (no-op if already unlocked; required after
    # boot since macOS doesn't auto-unlock arbitrary keychains).
    security unlock-keychain -p "$BUILD_KC_PWD" "$KEYCHAIN" 2>/dev/null || true
else
    KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
fi

if [[ -n "$COMMIT_REF" ]]; then
    echo "=== checking out $COMMIT_REF ==="
    git checkout "$COMMIT_REF"
fi

CODESIGN_OPTS=()
if [[ "$USE_RUNTIME" == "1" ]]; then
    CODESIGN_OPTS+=("--options" "runtime")
fi
if [[ -n "$ENTITLEMENTS" ]]; then
    CODESIGN_OPTS+=("--entitlements" "$ENTITLEMENTS")
fi

echo "=== make clean + build ==="
make clean >/dev/null 2>&1 || true
make macos ARCHID=29 \
    CEXTRA="-Wno-error=incompatible-function-pointer-types -Wno-error -Wno-deprecated-declarations" \
    -j"$(sysctl -n hw.ncpu)"

if [[ "$USE_ADHOC" == "1" ]]; then
    echo "=== sign (ad-hoc) ==="
    codesign --force ${CODESIGN_OPTS[@]+"${CODESIGN_OPTS[@]}"} --sign - \
        --identifier MeshAgent \
        ./meshagent_osx-arm-64
else
    echo "=== sign (Developer ID) ==="
    echo "    using keychain: $KEYCHAIN"
    if ! codesign --force ${CODESIGN_OPTS[@]+"${CODESIGN_OPTS[@]}"} \
        --sign "$DEVELOPER_ID" \
        --identifier MeshAgent \
        --keychain "$KEYCHAIN" \
        ./meshagent_osx-arm-64; then
        echo
        echo "Developer ID sign failed. If you ran this over SSH after a"
        echo "reboot, run it from a Splashtop terminal once and click"
        echo "Always Allow on the keychain prompt. Or pass --adhoc."
        exit 3
    fi
fi

echo "=== verify ==="
codesign -dv ./meshagent_osx-arm-64 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|flags"

echo "=== sha384 hash (for hashagents.json on the server) ==="
shasum -a 384 ./meshagent_osx-arm-64 | awk '{print toupper($1)}'

echo
echo "Build complete. Deploy: see homelab-stack/meshcentral.md 'Deploying'."
