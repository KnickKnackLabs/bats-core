#!/usr/bin/env bash

# setup the semaphore environment for the loading file
bats_semaphore_setup() {
  export BATS_SEMAPHORE_DIR="$BATS_RUN_TMPDIR/semaphores"
}

# $1 - output directory for stdout/stderr
# $@ - command to run
# run the given command in a semaphore
# block when there is no free slot for the semaphore
# when there is a free slot, run the command in background
# gather the output of the command in files in the given directory
bats_semaphore_run() {
  local output_dir=$1
  shift
  local semaphore_slot
  bats_semaphore_acquire_slot semaphore_slot
  bats_semaphore_release_wrapper "$output_dir" "$semaphore_slot" "$@" &
  printf "%d\n" "$!"
}

# $1 - output directory for stdout/stderr
# $@ - command to run
# this wraps the actual function call to install some traps on exiting
bats_semaphore_release_wrapper() {
  local output_dir="$1"
  local semaphore_name="$2"
  shift 2 # all other parameters will be use for the command to execute

  # shellcheck disable=SC2064 # we want to expand the semaphore_name right now!
  trap "status=$?; bats_semaphore_release_slot '$semaphore_name'; exit $status" EXIT

  mkdir -p "$output_dir"
  "$@" 2>"$output_dir/stderr" >"$output_dir/stdout"
  local status=$?

  # bash bug: the exit trap is not called for the background process
  bats_semaphore_release_slot "$semaphore_name"
  trap - EXIT # avoid calling release twice
  return $status
}

bats_semaphore_try_acquire_slot() {
  local result_variable="$1"
  local slot

  for ((slot = 0; slot < BATS_SEMAPHORE_NUMBER_OF_SLOTS; ++slot)); do
    if mkdir "$BATS_SEMAPHORE_DIR/slot-$slot" 2>/dev/null; then
      printf -v "$result_variable" "%d" "$slot"
      return 0
    fi
  done
  return 1
}

# File descriptors 8 and 9 are internal scheduler channels. They are closed
# before a test starts or a slot release returns.
bats_semaphore_cleanup_waiter() {
  if [[ -n "${BATS_SEMAPHORE_WAITER_FILE:-}" ]]; then
    exec 9>&-
    rm -f "$BATS_SEMAPHORE_WAITER_FILE"
    unset BATS_SEMAPHORE_WAITER_FILE
  fi
}

bats_semaphore_register_waiter() {
  BATS_SEMAPHORE_WAITER_FILE="$BATS_SEMAPHORE_DIR/waiter-$$"
  rm -f "$BATS_SEMAPHORE_WAITER_FILE"
  mkfifo "$BATS_SEMAPHORE_WAITER_FILE"
  exec 9<>"$BATS_SEMAPHORE_WAITER_FILE"
}

bats_semaphore_wait_for_wakeup() {
  IFS= read -r _ <&9
}

# block until a semaphore slot becomes free
# $1 - variable name that receives the acquired slot number
bats_semaphore_acquire_slot() {
  local result_variable="$1"
  local acquired_slot=''

  mkdir -p "$BATS_SEMAPHORE_DIR"
  if bats_semaphore_try_acquire_slot acquired_slot; then
    printf -v "$result_variable" "%s" "$acquired_slot"
    return 0
  fi

  bats_semaphore_register_waiter
  while true; do
    acquired_slot=''
    # A slot can be released between the first acquisition attempt and waiter
    # registration. Try once more after registration to close that lost-wakeup
    # window. A wakeup written before this attempt remains buffered in the FIFO.
    if bats_semaphore_try_acquire_slot acquired_slot; then
      bats_semaphore_cleanup_waiter
      printf -v "$result_variable" "%s" "$acquired_slot"
      return 0
    fi
    bats_semaphore_wait_for_wakeup
  done
}

bats_semaphore_release_slot() {
  local semaphore_slot="$1"
  local waiter_file

  rmdir "$BATS_SEMAPHORE_DIR/slot-$semaphore_slot" || return

  # Wake all registered waiters. Atomic slot directories preserve the worker
  # cap; waking all avoids stranding capacity behind a stale waiter process.
  # Opening each FIFO read-write keeps stale registrations from blocking release.
  for waiter_file in "$BATS_SEMAPHORE_DIR"/waiter-*; do
    [[ -p "$waiter_file" ]] || continue
    if exec 8<>"$waiter_file"; then
      printf '\n' >&8 || :
      exec 8>&-
    fi
  done
}
