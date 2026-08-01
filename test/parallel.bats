#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load test_helper
fixtures parallel

# shellcheck disable=SC2034
BATS_TEST_TIMEOUT=10 # only intended for the "short form ..."" test

setup() {
  (type -p "${BATS_PARALLEL_BINARY_NAME:-"parallel"}" &>/dev/null && "${BATS_PARALLEL_BINARY_NAME:-"parallel"}" --version &>/dev/null) || skip "--jobs requires GNU parallel"
}

check_parallel_tests() { # <expected maximum parallelity>
  local expected_maximum_parallelity="$1"
  local expected_number_of_lines="${2:-$((2 * expected_maximum_parallelity))}"

  max_parallel_tests=0
  started_tests=0
  read_lines=0
  while IFS= read -r line; do
    ((++read_lines))
    case "$line" in
    "start "*)
      if ((++started_tests > max_parallel_tests)); then
        max_parallel_tests="$started_tests"
      fi
      ;;
    "stop "*)
      ((started_tests--))
      ;;
    esac
  done <"$FILE_MARKER"

  echo "max_parallel_tests: $max_parallel_tests"
  [[ $max_parallel_tests -eq $expected_maximum_parallelity ]]

  echo "read_lines: $read_lines"
  [[ $read_lines -eq $expected_number_of_lines ]]
}

wait_for_file_count() { # <directory> <glob> <expected count> <attempts>
  local directory="$1"
  local file_glob="$2"
  local expected_count="$3"
  local attempts="$4"
  local attempt file_count

  for ((attempt = 0; attempt < attempts; ++attempt)); do
    file_count=$(find "$directory" -name "$file_glob" | wc -l)
    if ((file_count >= expected_count)); then
      return 0
    fi
    sleep 0.01
  done
  return 1
}

@test "parallel test execution with --jobs" {
  # shellcheck disable=SC2031,SC2030
  export FILE_MARKER
  # shellcheck disable=SC2030
  FILE_MARKER=$(mktemp "${BATS_RUN_TMPDIR}/file_marker.XXXXXX")
  # shellcheck disable=SC2030
  export PARALLELITY=3
  reentrant_run bats --jobs $PARALLELITY "$FIXTURE_ROOT/parallel.bats"

  [ "$status" -eq 0 ]
  # Make sure the lines are in-order.
  [[ "${lines[0]}" == "1..3" ]]
  for t in {1..3}; do
    [[ "${lines[$t]}" == "ok $t slow test $t" ]]
  done

  check_parallel_tests $PARALLELITY
}

@test "parallel can preserve environment variables" {
  export TEST_ENV_VARIABLE='test-value'
  reentrant_run bats --jobs 2 "$FIXTURE_ROOT/parallel-preserve-environment.bats"
  echo "$output"
  [[ "$status" -eq 0 ]]
}

@test "parallel suite execution with --jobs" {
  # shellcheck disable=SC2034
  BATS_TEST_RETRIES=2 # be more robust against flaky MacOS runners
  # shellcheck disable=SC2031,SC2030
  export FILE_MARKER
  # shellcheck disable=SC2030
  FILE_MARKER=$(mktemp "${BATS_RUN_TMPDIR}/file_marker.XXXXXX")
  # shellcheck disable=SC2031,SC2030
  export PARALLELITY=12

  # file parallelization is needed for maximum parallelity!
  # If we got over the skip (if no GNU parallel) in setup() we can re-enable it safely!
  unset BATS_NO_PARALLELIZE_ACROSS_FILES
  reentrant_run bash -c "bats --jobs $PARALLELITY \"${FIXTURE_ROOT}/suite/\" 2> >(grep -v '^parallel: Warning: ')"

  echo "$output"
  [ "$status" -eq 0 ]

  # Make sure the lines are in-order.
  [[ "${lines[0]}" == "1..$PARALLELITY" ]]
  i=0
  for _ in {1..4}; do
    for t in {1..3}; do
      ((++i))
      [[ "${lines[$i]}" == "ok $i slow test $t" ]]
    done
  done

  check_parallel_tests $PARALLELITY
}

@test "slot release wakes a waiting file executor promptly" {
  # shellcheck disable=SC2030,SC2031
  export SEMAPHORE_MARKER_DIR="$BATS_TEST_TMPDIR/semaphore-wakeup"
  local bats_output="$BATS_TEST_TMPDIR/semaphore-wakeup.tap"
  local bats_pid bats_status=0
  mkdir -p "$SEMAPHORE_MARKER_DIR"

  bats --jobs 2 "$FIXTURE_ROOT/semaphore-wakeup.bats" >"$bats_output" 2>&1 &
  bats_pid=$!

  if ! wait_for_file_count "$SEMAPHORE_MARKER_DIR" 'holder-*' 2 200; then
    touch "$SEMAPHORE_MARKER_DIR/release"
    wait "$bats_pid" || :
    cat "$bats_output"
    return 1
  fi

  touch "$SEMAPHORE_MARKER_DIR/release"
  if ! wait_for_file_count "$SEMAPHORE_MARKER_DIR" 'waiter' 1 50; then
    wait "$bats_pid" || :
    cat "$bats_output"
    return 1
  fi

  wait "$bats_pid" || bats_status=$?
  cat "$bats_output"
  [[ $bats_status -eq 0 ]]
}

@test "slot release wakes multiple registered waiters without losing capacity" {
  local semaphore_run_dir="$BATS_TEST_TMPDIR/multiple-waiters/run"
  local semaphore_dir="$semaphore_run_dir/semaphores"
  local helper="$FIXTURE_ROOT/semaphore-helper.bash"
  local stale_waiter="$semaphore_dir/waiter-stale"
  local waiter_one waiter_two waiter_status=0
  # shellcheck disable=SC2030,SC2031
  export SEMAPHORE_MARKER_DIR="$BATS_TEST_TMPDIR/multiple-waiters/acquired"
  mkdir -p "$SEMAPHORE_MARKER_DIR" "$semaphore_dir/slot-0"

  env \
    BATS_RUN_TMPDIR="$semaphore_run_dir" \
    BATS_SEMAPHORE_NUMBER_OF_SLOTS=1 \
    SEMAPHORE_LIBRARY="$BATS_ROOT/$BATS_LIBDIR/bats-core/semaphore.bash" \
    SEMAPHORE_MARKER_DIR="$SEMAPHORE_MARKER_DIR" \
    bash "$helper" wait &
  waiter_one=$!
  env \
    BATS_RUN_TMPDIR="$semaphore_run_dir" \
    BATS_SEMAPHORE_NUMBER_OF_SLOTS=1 \
    SEMAPHORE_LIBRARY="$BATS_ROOT/$BATS_LIBDIR/bats-core/semaphore.bash" \
    SEMAPHORE_MARKER_DIR="$SEMAPHORE_MARKER_DIR" \
    bash "$helper" wait &
  waiter_two=$!

  wait_for_file_count "$semaphore_dir" 'waiter-*' 2 200
  mkfifo "$stale_waiter"
  env \
    BATS_RUN_TMPDIR="$semaphore_run_dir" \
    BATS_SEMAPHORE_NUMBER_OF_SLOTS=1 \
    SEMAPHORE_LIBRARY="$BATS_ROOT/$BATS_LIBDIR/bats-core/semaphore.bash" \
    SEMAPHORE_MARKER_DIR="$SEMAPHORE_MARKER_DIR" \
    bash "$helper" release 0
  rm "$stale_waiter"

  wait "$waiter_one" || waiter_status=$?
  wait "$waiter_two" || waiter_status=$?
  [[ $waiter_status -eq 0 ]]
  [[ $(find "$SEMAPHORE_MARKER_DIR" -name 'acquired-*' | wc -l) -eq 2 ]]
  [[ $(find "$semaphore_dir" -name 'slot-*' | wc -l) -eq 0 ]]
  [[ $(find "$semaphore_dir" -name 'waiter-*' | wc -l) -eq 0 ]]
}

@test "terminating a registered waiter removes its wakeup FIFO" {
  # shellcheck disable=SC2030,SC2031
  export SEMAPHORE_MARKER_DIR="$BATS_TEST_TMPDIR/interrupted-waiter/markers"
  local nested_tmp="$BATS_TEST_TMPDIR/interrupted-waiter/tmp"
  local bats_output="$BATS_TEST_TMPDIR/interrupted-waiter.tap"
  local bats_pid bats_status=0 waiter_file waiter_pid waiter_signal_status=0
  local waiter_is_fifo=false waiter_pid_is_numeric=false
  local waiter_not_started=false waiter_cleaned=false
  mkdir -p "$SEMAPHORE_MARKER_DIR" "$nested_tmp"

  set -m
  TMPDIR="$nested_tmp" bats --jobs 2 "$FIXTURE_ROOT/semaphore-interrupt.bats" >"$bats_output" 2>&1 &
  bats_pid=$!

  if ! wait_for_file_count "$SEMAPHORE_MARKER_DIR" 'holder-*' 2 200 || \
      ! wait_for_file_count "$nested_tmp" 'waiter-*' 1 200; then
    kill -TERM -- "-$bats_pid" 2>/dev/null || :
    wait "$bats_pid" || :
    set +m
    cat "$bats_output"
    return 1
  fi

  waiter_file=$(find "$nested_tmp" -name 'waiter-*' -print -quit)
  waiter_pid=${waiter_file##*/waiter-}
  [[ -p "$waiter_file" ]] && waiter_is_fifo=true
  [[ "$waiter_pid" =~ ^[0-9]+$ ]] && waiter_pid_is_numeric=true
  [[ ! -e "$SEMAPHORE_MARKER_DIR/waiter-started" ]] && waiter_not_started=true

  # Terminate the registered file executor while both worker slots remain held.
  # Killing the whole process group first would race slot release against exit.
  if $waiter_pid_is_numeric; then
    kill -TERM "$waiter_pid" || waiter_signal_status=$?
  else
    waiter_signal_status=1
  fi
  for _ in {1..200}; do
    [[ -e "$waiter_file" ]] || break
    sleep 0.01
  done
  [[ ! -e "$waiter_file" ]] && waiter_cleaned=true

  kill -TERM -- "-$bats_pid" 2>/dev/null || :
  wait "$bats_pid" || bats_status=$?
  set +m

  $waiter_is_fifo
  $waiter_pid_is_numeric
  $waiter_not_started
  [[ $waiter_signal_status -eq 0 ]]
  $waiter_cleaned
  [[ $bats_status -ne 0 ]]
}

@test "setup_file is not over parallelized" {
  #shellcheck disable=SC2031
  export FILE_MARKER
  FILE_MARKER=$(mktemp "${BATS_RUN_TMPDIR}/file_marker.XXXXXX")
  #shellcheck disable=SC2031,SC2030
  export PARALLELITY=2

  # file parallelization is needed for this test!
  # If we got over the skip (if no GNU parallel) in setup() we can re-enable it safely!
  unset BATS_NO_PARALLELIZE_ACROSS_FILES
  # run 4 files with parallelity of 2 -> serialize 2
  reentrant_run bats --jobs $PARALLELITY "$FIXTURE_ROOT/setup_file"

  [[ $status -eq 0 ]] || (
    echo "$output"
    false
  )

  cat "$FILE_MARKER"

  [[ $(grep -c "start " "$FILE_MARKER") -eq 4 ]] # beware of grepping the filename as well!
  [[ $(grep -c "stop " "$FILE_MARKER") -eq 4 ]]

  check_parallel_tests $PARALLELITY 8
}

@test "running the same file twice runs its tests twice without errors" {
  reentrant_run bats --jobs 2 "$FIXTURE_ROOT/../bats/passing.bats" "$FIXTURE_ROOT/../bats/passing.bats"
  echo "$output"
  [[ $status -eq 0 ]]
  [[ "${lines[0]}" == "1..2" ]] # got 2x1 tests
  [[ "${lines[1]}" == "ok 1 "* ]]
  [[ "${lines[2]}" == "ok 2 "* ]]
  [[ "${#lines[@]}" -eq 3 ]]
}

@test "parallelity factor is met exactly" {
  # shellcheck disable=SC2031
  export MARKER_FILE="${BATS_TEST_TMPDIR}/marker" PARALLELITY=5 # run the 10 tests in 2 batches with 5 test each
  bats --jobs $PARALLELITY "$FIXTURE_ROOT/parallel_factor.bats"
  local current_parallel_count=0 maximum_parallel_count=0 total_count=0
  while read -r line; do
    case "$line" in
    setup*)
      ((++current_parallel_count))
      ((++total_count))
      ;;
    teardown*)
      ((current_parallel_count--))
      ;;
    esac
    if ((current_parallel_count > maximum_parallel_count)); then
      maximum_parallel_count=$current_parallel_count
    fi
  done <"$MARKER_FILE"

  cat "$MARKER_FILE" # for debugging purposes
  [[ "$maximum_parallel_count" -eq $PARALLELITY ]]
  [[ "$current_parallel_count" -eq 0 ]]
  [[ "$total_count" -eq 10 ]]
}

@test "parallel mode correctly forwards failure return code" {
  reentrant_run bats --jobs 2 "$FIXTURE_ROOT/../bats/failing.bats"
  [[ "$status" -eq 1 ]]
}

@test "--no-parallelize-across-files test file detects parallel execution" {
  # ensure that we really run parallelization across files!
  # (setup should have skipped already, if there was no GNU parallel)
  unset BATS_NO_PARALLELIZE_ACROSS_FILES
  FILE_MARKER=$(mktemp "${BATS_RUN_TMPDIR}/file_marker.XXXXXX") \
    reentrant_run ! bats --jobs 2 "$FIXTURE_ROOT/must_not_parallelize_across_files/"
}

@test "--no-parallelize-across-files prevents parallelization across files" {
  FILE_MARKER=$(mktemp "${BATS_RUN_TMPDIR}/file_marker.XXXXXX") \
    bats --jobs 2 --no-parallelize-across-files "$FIXTURE_ROOT/must_not_parallelize_across_files/"
}

@test "--no-parallelize-across-files does not prevent parallelization within files" {
  reentrant_run ! bats --jobs 2 --no-parallelize-across-files "$FIXTURE_ROOT/must_not_parallelize_within_file.bats"
}

@test "--no-parallelize-within-files test file detects parallel execution" {
  reentrant_run ! bats --jobs 2 "$FIXTURE_ROOT/must_not_parallelize_within_file.bats"
}

@test "--no-parallelize-within-files prevents parallelization within files" {
  bats --jobs 2 --no-parallelize-within-files "$FIXTURE_ROOT/must_not_parallelize_within_file.bats"
}

@test "--no-parallelize-within-files does not prevent parallelization across files" {
  # ensure that we really run parallelization across files!
  # (setup should have skipped already, if there was no GNU parallel)
  unset BATS_NO_PARALLELIZE_ACROSS_FILES
  FILEMARKER=$(mktemp "${BATS_RUN_TMPDIR}/file_marker.XXXXXX") \
    reentrant_run ! bats --jobs 2 --no-parallelize-within-files "$FIXTURE_ROOT/must_not_parallelize_across_files/"
}

@test "BATS_NO_PARALLELIZE_WITHIN_FILE works from inside setup_file()" {
  DISABLE_IN_SETUP_FILE_FUNCTION=1 bats --jobs 2 "$FIXTURE_ROOT/must_not_parallelize_within_file.bats"
}

@test "BATS_NO_PARALLELIZE_WITHIN_FILE works from outside all functions" {
  DISABLE_OUTSIDE_ALL_FUNCTIONS=1 bats --jobs 2 "$FIXTURE_ROOT/must_not_parallelize_within_file.bats"
}

@test "BATS_NO_PARALLELIZE_WITHIN_FILE does not work from inside setup()" {
  DISABLE_IN_SETUP_FUNCTION=1 reentrant_run ! bats --jobs 2 "$FIXTURE_ROOT/must_not_parallelize_within_file.bats"
}

@test "BATS_NO_PARALLELIZE_WITHIN_FILE does not work from inside test function" {
  DISABLE_IN_TEST_FUNCTION=1 reentrant_run ! bats --jobs 2 "$FIXTURE_ROOT/must_not_parallelize_within_file.bats"
}

@test "Negative jobs number does not run endlessly" {
  unset BATS_NO_PARALLELIZE_ACROSS_FILES
  run bats -j -3 "$FIXTURE_ROOT/../bats/passing.bats"
  (( SECONDS < 5 ))
  [ "${lines[1]}" = 'Invalid number of jobs: -3' ]
}
