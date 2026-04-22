#!/usr/bin/env bash
# Spin up N dummy HTTP brokers. Each broker appends one JSON line per accepted
# POST /transaction into transactions/broker-<i>/transactions.txt
#
# Usage: ./scripts/run_dummy_brokers.sh <N> [BASE_PORT]
# Example: ./scripts/run_dummy_brokers.sh 4 8080
#   -> brokers on :8080 .. :8083
#
# Script exits immediately; brokers keep running. Stop with:
#   kill $(cat transactions/broker-*/pid.txt)

set -euo pipefail

N="${1:?usage: $0 <N> [BASE_PORT]}"
BASE_PORT="${2:-8080}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TX_ROOT="$ROOT/transactions"
BROKER_DIR="$ROOT/dummy-broker"

mkdir -p "$TX_ROOT"

echo "Starting $N dummy broker(s); logs under $TX_ROOT/broker-*/transactions.txt"

for i in $(seq 1 "$N"); do
  dir="$TX_ROOT/broker-$i"
  mkdir -p "$dir"
  port=$((BASE_PORT + i - 1))
  (
    cd "$BROKER_DIR" || exit 1
    nohup go run . \
      -listen ":$port" \
      -broker-id "$i" \
      -out "$dir/transactions.txt" \
      >>"$dir/broker.log" 2>&1 &
    echo $! >"$dir/pid.txt"
  )
  echo "broker-$i pid $(cat "$dir/pid.txt") http://127.0.0.1:$port/transaction -> $dir/transactions.txt"
done

echo "Stop with: kill \$(cat $TX_ROOT/broker-*/pid.txt)"
