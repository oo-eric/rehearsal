#!/bin/bash
# Build and run the command-line tests (chords, synth, navigation, timeline, sync).
#   ./Tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc -O -o build/tests/rehearsal-tests Shared/*.swift Tests/main.swift
build/tests/rehearsal-tests "$PWD"
