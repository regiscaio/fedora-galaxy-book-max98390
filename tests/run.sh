#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
failures=0

for test_script in \
    "$TEST_DIR/test_i2c_setup.sh" \
    "$TEST_DIR/test_packaging.sh"; do
    printf '# %s\n' "$(basename -- "$test_script")"
    if ! "$test_script"; then
        failures=$((failures + 1))
    fi
done

(( failures == 0 )) || exit 1
