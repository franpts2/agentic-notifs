#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

test -r "$ROOT/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$ROOT/Resources/Info.plist" >/dev/null
swift build --package-path "$ROOT"
"$ROOT/.build/debug/agentic-notify" self-test
node --check "$ROOT/Adapters/opencode.js"
node "$ROOT/Adapters/opencode.test.mjs"

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agentic-notifs-tests.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM
"$ROOT/.build/debug/agentic-notify" install-adapters \
    --opencode-plugin "$ROOT/Adapters/opencode.js" \
    --home "$TEST_ROOT/home" \
    --config-root "$TEST_ROOT/config" >/dev/null
cp "$TEST_ROOT/home/.claude/settings.json" "$TEST_ROOT/claude-first.json"
cp "$TEST_ROOT/home/.codex/hooks.json" "$TEST_ROOT/codex-first.json"
"$ROOT/.build/debug/agentic-notify" install-adapters \
    --opencode-plugin "$ROOT/Adapters/opencode.js" \
    --home "$TEST_ROOT/home" \
    --config-root "$TEST_ROOT/config" >/dev/null
cmp "$TEST_ROOT/claude-first.json" "$TEST_ROOT/home/.claude/settings.json"
cmp "$TEST_ROOT/codex-first.json" "$TEST_ROOT/home/.codex/hooks.json"
cmp "$ROOT/Adapters/opencode.js" "$TEST_ROOT/config/opencode/plugins/agentic-notifs.js"

printf '%s\n' "Build and self-tests passed."
