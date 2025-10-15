#!/bin/bash
set -eo pipefail

GOCMD="${@:-go build github.com/bradfitz/go-tool-cache/...}"
export LATENCY="${LATENCY:-0}"
export MISS_PERCENTAGE="${MISS_PERCENTAGE:-0}"

which hyperfine > /dev/null 2>&1 || (echo "Must install hyperfine" && exit 1)
which go-cacher > /dev/null 2>&1 || go install github.com/bradfitz/go-tool-cache/cmd/go-cacher
which go-cacher-server > /dev/null 2>&1 || go install github.com/bradfitz/go-tool-cache/cmd/go-cacher-server

export RUN_DIR=$(mktemp -d)
echo "Using RUN_DIR=$RUN_DIR, LATENCY=$LATENCY, MISS_PERCENTAGE=$MISS_PERCENTAGE"

cleanup() {
    if [ -f "$RUN_DIR/server.pid" ]; then
        kill $(cat "$RUN_DIR/server.pid") 2> /dev/null || true
    fi
    rm -rf "$RUN_DIR"
}
trap cleanup EXIT

setup() {
    if [ -f "$RUN_DIR/server.pid" ]; then
        return
    fi

    echo "Starting go-cacher-server with LATENCY=$LATENCY, MISS_PERCENTAGE=$MISS_PERCENTAGE"
    go-cacher-server -inject-latency="${LATENCY}" -cache-dir="$(mktemp -d -p "$RUN_DIR" srv_cache_XXXX)" &
    echo $! > "$RUN_DIR/server.pid"
    sleep 1
}

cleanup_run() {
    if [ -f "$RUN_DIR/server.pid" ]; then
        kill $(cat "$RUN_DIR/server.pid") 2>/dev/null || true
        rm -f "$RUN_DIR/server.pid"
    fi
    rm -rf "$RUN_DIR"/srv_cache_* "$RUN_DIR"/cmd_cache_* 2>/dev/null || true
}

# Export the functions so hyperfine can use them
export -f setup
export -f cleanup_run

if [[ "${COLD:-true}" == "true" ]]; then
    echo "Testing with cold cache..."
    hyperfine \
        --runs 2 \
        --prepare 'setup' \
        --cleanup 'cleanup_run' \
        --shell bash \
        'GOCACHEPROG="go-cacher -cache-dir=$(mktemp -d -p "$RUN_DIR" cmd_cache_XXXX) -cache-server=http://localhost:31364 -miss-percentage=${MISS_PERCENTAGE}" '"$GOCMD"
fi

if [[ "${WARM:-true}" == "true" ]]; then
    export CMD_CACHE_DIR="$(mktemp -d -p "$RUN_DIR" cmd_cache_XXXX)"
    echo "Testing with warm cache..."
    hyperfine \
        --runs 3 \
        --prepare 'setup' \
        --warmup 1 \
        --shell bash \
        'GOCACHEPROG="go-cacher -cache-dir=$CMD_CACHE_DIR -cache-server=http://localhost:31364 -miss-percentage=${MISS_PERCENTAGE}" '"$GOCMD"
fi
