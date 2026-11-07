#!/usr/bin/env bash
# Build Carrel for Apple TV and (re)launch it in the tvOS simulator.
#   scripts/run-tv.sh [device name] [--fresh]
exec "$(dirname "$0")/run-sim.sh" tv "$@"
