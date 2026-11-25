#!/bin/bash
# Runs the small self-contained tests (no Xcode project needed): ./tools/test.sh
set -e
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O Doddy/Checks.swift Tests/main.swift -o build/doddy-tests
./build/doddy-tests
