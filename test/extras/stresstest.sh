#!/bin/bash
export PATH="$GOPATH/bin:$PATH"

# /tmp isn't moutned exec on most systems, so we can't actually start
# containers that are created there.
SRC_DIR="$(pwd)"
INCUS_DIR="$(mktemp -d -p "$(pwd)")"
chmod 777 "${INCUS_DIR}"
INCUS_CONF="$(mktemp -d)"
export SRC_DIR INCUS_DIR INCUS_CONF
export INCUS_FUIDMAP_DIR="${INCUS_DIR}/fuidmap"
mkdir -p "${INCUS_FUIDMAP_DIR}"
BASEURL=https://127.0.0.1:18443
RESULT=failure

set -e
if [ -n "$INCUS_DEBUG" ]; then
    set -x
    debug=--debug
fi

echo "==> Running the Incus testsuite"

BASEURL=https://127.0.0.1:18443
my_curl() {
  curl -k -s --cert "${INCUS_CONF}/client.crt" --key "${INCUS_CONF}/client.key" "${@}"
}

wait_for() {
  op="$("${@}" | jq -r .operation)"
  my_curl "$BASEURL$op/wait"
}

inc() {
    INJECTED=0
    CMD="$(command -v inc)"
    for arg in "${@}"; do
        if [ "$arg" = "--" ]; then
            INJECTED=1
            CMD="$CMD $debug"
            CMD="$CMD --"
        else
            CMD="$CMD \"$arg\""
        fi
    done

    if [ "$INJECTED" = "0" ]; then
        CMD="$CMD $debug"
    fi

    eval "$CMD"
}

cleanup() {
    read -rp "Tests Completed ($RESULT): hit enter to continue" _
    echo "==> Cleaning up"

    # Try to stop all the containers
    my_curl "$BASEURL/1.0/containers" | jq -r .metadata[] 2>/dev/null | while read -r line; do
        wait_for my_curl -X PUT "$BASEURL$line/state" -d "{\"action\":\"stop\",\"force\":true}"
    done

    # kill the daemons which share our pgrp as parent
    mygrp="$(awk '{ print $5 }' /proc/self/stat)"
    for p in $(pidof incus); do
        pgrp="$(awk '{ print $5 }' "/proc/$p/stat")"
        if [ "$pgrp" = "$mygrp" ]; then
          do_kill_incus "$p"
        fi
    done

    # Apparently we need to wait a while for everything to die
    sleep 3
    rm -Rf "${INCUS_DIR}"
    rm -Rf "${INCUS_CONF}"

    echo ""
    echo ""
    echo "==> Test result: $RESULT"
}

trap cleanup EXIT HUP INT TERM

if ! command -v inc > /dev/null; then
    echo "==> Couldn't find inc" && false
fi

spawn_incus() {
  # INCUS_DIR is local here because since `inc` is actually a function, it
  # overwrites the environment and we would lose INCUS_DIR's value otherwise.
  local INCUS_DIR

  addr=$1
  incusdir=$2
  shift
  shift
  echo "==> Spawning incus on $addr in $incusdir"
  INCUS_DIR="$incusdir" incus "${debug}" "${@}" > "$incusdir/incus.log" 2>&1 &

  echo "==> Confirming incus on $addr is responsive"
  INCUS_DIR="$incusdir" incus waitready

  echo "==> Binding to network"
  INCUS_DIR="$incusdir" inc config set core.https_address "$addr"

  echo "==> Setting trust password"
  INCUS_DIR="$incusdir" inc config set core.trust_password foo
}

spawn_incus 127.0.0.1:18443 "$INCUS_DIR"

## tests go here
if [ ! -e "$INCUS_TEST_IMAGE" ]; then
    echo "Please define INCUS_TEST_IMAGE"
    false
fi
inc image import "$INCUS_TEST_IMAGE" --alias busybox

inc image list
inc list

NUMCREATES=5
createthread() {
    echo "createthread: I am $$"
    for i in $(seq "$NUMCREATES"); do
        echo "createthread: starting loop $i out of $NUMCREATES"
        declare -a pids
        for j in $(seq 20); do
            inc launch busybox "b.$i.$j" &
            pids[j]=$!
        done
        for j in $(seq 20); do
            # ignore errors if the task has already exited
            wait "${pids[j]}" 2>/dev/null || true
        done
        echo "createthread: deleting..."
        for j in $(seq 20); do
            inc delete "b.$i.$j" &
            pids[j]=$!
        done
        for j in $(seq 20); do
            # ignore errors if the task has already exited
            wait "${pids[j]}" 2>/dev/null || true
        done
    done
    exit 0
}

listthread() {
    echo "listthread: I am $$"
    while true; do
        inc list
        sleep 2s
    done
    exit 0
}

configthread() {
    echo "configthread: I am $$"
    for i in $(seq 20); do
        inc profile create "p$i"
        inc profile set "p$i" limits.memory 100MiB
        inc profile delete "p$i"
    done
    exit 0
}

disturbthread() {
    echo "disturbthread: I am $$"
    while true; do
        inc profile create empty
        inc init busybox disturb1
        inc profile assign disturb1 empty
        inc start disturb1
        inc exec disturb1 -- ps -ef
        inc stop disturb1 --force
        inc delete disturb1
        inc profile delete empty
    done
    exit 0
}

echo "Starting create thread"
createthread 2>&1 | tee "$INCUS_DIR/createthread.out" &
p1=$!

echo "starting the disturb thread"
disturbthread 2>&1 | tee "$INCUS_DIR/disturbthread.out" &
pdisturb=$!

echo "Starting list thread"
listthread 2>&1 | tee "$INCUS_DIR/listthread.out" &
p2=$!
echo "Starting config thread"
configthread 2>&1 | tee "$INCUS_DIR/configthread.out" &
p3=$!

# wait for listthread to finish
wait "$p1"
# and configthread, it should be quick
wait "$p3"

echo "The creation loop is done, killing the list and disturb threads"

kill "$p2"
wait "$p2" || true

kill "$pdisturb"
wait "$pdisturb" || true

RESULT=success
