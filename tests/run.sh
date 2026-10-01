#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
test_dir="$(mktemp -d -t agent-beacon-tests)"
trap '[[ ! -f "$test_dir/ActivityStoreTests" ]] || unlink "$test_dir/ActivityStoreTests"; rmdir "$test_dir"' EXIT
swiftc -parse-as-library -O -D AGENT_BEACON_TEST -framework AppKit -framework SwiftUI -framework CoreServices \
  "$project_dir/AgentBeacon.swift" "$project_dir/ActivityStore.swift" "$project_dir/tests/ActivityStoreTests.swift" \
  -o "$test_dir/ActivityStoreTests"
"$test_dir/ActivityStoreTests" "$@"
