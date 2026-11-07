#!/usr/bin/env bash
# Build Carrel for iPhone and (re)launch it in the iOS simulator.
#   scripts/run-phone.sh [device name] [--fresh]
exec "$(dirname "$0")/run-sim.sh" phone "$@"
