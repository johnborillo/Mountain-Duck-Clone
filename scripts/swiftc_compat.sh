#!/bin/bash
set -e

REAL_SWIFTC="${OPENDUCK_REAL_SWIFTC:-$(xcrun --find swiftc)}"
if [ -n "${OPENDUCK_INTERFACE_COMPILER_VERSION:-}" ]; then
    exec "$REAL_SWIFTC" \
        -Xfrontend -interface-compiler-version \
        -Xfrontend "$OPENDUCK_INTERFACE_COMPILER_VERSION" \
        "$@"
fi

exec "$REAL_SWIFTC" "$@"
