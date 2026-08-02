#!/usr/bin/env bash
set -e

# shellcheck source=lib/bats-core/semaphore.bash
source "$SEMAPHORE_LIBRARY"
bats_semaphore_setup

case "$1" in
wait)
  semaphore_slot=''
  bats_semaphore_acquire_slot semaphore_slot
  touch "$SEMAPHORE_MARKER_DIR/acquired-$$"
  sleep 0.05
  bats_semaphore_release_slot "$semaphore_slot"
  ;;
release)
  bats_semaphore_release_slot "$2"
  ;;
*)
  printf "unknown semaphore helper action: %s\n" "$1" >&2
  exit 2
  ;;
esac
