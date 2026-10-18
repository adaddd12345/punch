#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/punch-artwork-playback-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
# Compile the production script generator with its actual escaping helpers.
# The harness runs its resulting JavaScript in a mocked media document, so no
# browser is launched and no user's playback or permissions are changed.
python3 - "$REPO_ROOT" "$CHECK_DIR" <<'PY'
import pathlib, sys
repo, check = map(pathlib.Path, sys.argv[1:])
source = (repo / 'mac/Sources/BassShake/ArtworkPlayerTransport.swift').read_text()
operation = source[source.index('enum ArtworkPlaybackOperation:'):source.index('final class ArtworkPlayerTransport:')]
script = source[source.index('enum ArtworkPlaybackScript {'):]
helpers = (repo / 'mac/Sources/BassShake/BrowserTempoScript.swift').read_text()
output = '''
// A source closes while queued reads/commands are waiting on the script lock.
let cancellation = ArtworkPlaybackLease()
assert(cancellation.isValid)
DispatchQueue.concurrentPerform(iterations: 1_000) { index in
  if index == 100 { cancellation.invalidate() }
  _ = cancellation.isValid
}
assert(!cancellation.isValid)
cancellation.invalidate()
assert(!cancellation.isValid)
let operations: [String: ArtworkPlaybackOperation] = ["read": .read, "toggle": .toggle, "previous": .previous, "next": .next, "seek": .seek(500), "negative": .seek(-1), "nan": .seek(.nan)]
var result: [String: String] = [:]
for (name, operation) in operations { result[name] = ArtworkPlaybackScript.javascript(videoID: "abcdefghijk", operation: operation) }
print(String(decoding: try! JSONEncoder().encode(result), as: UTF8.self))
'''
(check / 'main.swift').write_text(helpers + '\n' + operation + script + output)
PY
swift -module-cache-path "$CHECK_DIR/module-cache" "$CHECK_DIR/main.swift" > "$CHECK_DIR/scripts.json"
node "$REPO_ROOT/mac/scripts/artwork-playback-check.js" "$CHECK_DIR/scripts.json"
