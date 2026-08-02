#!/usr/bin/env bats

@test "holder one" {
  touch "$SEMAPHORE_MARKER_DIR/holder-1"
  sleep 30
}

@test "holder two" {
  touch "$SEMAPHORE_MARKER_DIR/holder-2"
  sleep 30
}

@test "waiter must not start" {
  touch "$SEMAPHORE_MARKER_DIR/waiter-started"
}
