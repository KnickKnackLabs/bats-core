#!/usr/bin/env bats

@test "holder one" {
  touch "$SEMAPHORE_MARKER_DIR/holder-1"
  while [[ ! -e "$SEMAPHORE_MARKER_DIR/release" ]]; do
    sleep 0.01
  done
}

@test "holder two" {
  touch "$SEMAPHORE_MARKER_DIR/holder-2"
  while [[ ! -e "$SEMAPHORE_MARKER_DIR/release" ]]; do
    sleep 0.01
  done
}

@test "waiter" {
  touch "$SEMAPHORE_MARKER_DIR/waiter"
}
