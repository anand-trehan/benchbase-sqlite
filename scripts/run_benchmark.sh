#!/usr/bin/env bash
#
# Run a full BenchBase SmallBank benchmark with dummy brokers.
#
# Usage:
#   ./scripts/run_benchmark.sh --brokers=N --terminals=T --time=S --rate=R [--base-port=P] [--wait=W]
#
# Example:
#   ./scripts/run_benchmark.sh --brokers=4 --terminals=8 --time=120 --rate=5000
#
# Output structure:
#   transactions_<brokers>_<rate>/
#     broker-1/
#       loading.txt
#       execute.txt
#     broker-2/
#       ...
#
# Phases:
#   1. LOAD  : start brokers → run benchbase --create=true --load=true --execute=false
#              → wait W seconds → kill brokers
#   2. EXECUTE: start brokers → run benchbase --create=false --load=false --execute=true
#              → wait W seconds → kill brokers
#
set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
BROKERS=2
TERMINALS=4
TIME=60
RATE=2000
BASE_PORT=8080
WAIT_AFTER=60

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
for arg in "$@"; do
  case $arg in
    --brokers=*)   BROKERS="${arg#*=}" ;;
    --terminals=*) TERMINALS="${arg#*=}" ;;
    --time=*)      TIME="${arg#*=}" ;;
    --rate=*)      RATE="${arg#*=}" ;;
    --base-port=*) BASE_PORT="${arg#*=}" ;;
    --wait=*)      WAIT_AFTER="${arg#*=}" ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TX_ROOT="$ROOT/transactions_${BROKERS}_${RATE}"
BROKER_DIR="$ROOT/dummy-broker"
CONFIG_TEMPLATE="$ROOT/config/lockfreedb/sample_smallbank_config.xml"
CONFIG_GEN="$ROOT/config/lockfreedb/generated_smallbank_config.xml"
BENCHBASE_JAR="$ROOT/benchbase.jar"

echo "========================================"
echo "Benchmark Parameters"
echo "========================================"
echo "  Brokers   : $BROKERS"
echo "  Terminals : $TERMINALS"
echo "  Time      : $TIME s"
echo "  Rate      : $RATE txn/s"
echo "  Base Port : $BASE_PORT"
echo "  Wait After: $WAIT_AFTER s"
echo "  Output Dir: $TX_ROOT"
echo "========================================"

# -----------------------------------------------------------------------------
# Kill any existing processes on the broker ports
# -----------------------------------------------------------------------------
kill_existing_on_ports() {
  echo "Checking for existing processes on ports ${BASE_PORT}...$((BASE_PORT + BROKERS - 1))..."
  local killed=0

  for i in $(seq 1 "$BROKERS"); do
    local port=$((BASE_PORT + i - 1))
    local pids
    pids=$(lsof -ti ":$port" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
      for pid in $pids; do
        if kill -9 "$pid" 2>/dev/null; then
          echo "  killed pid=$pid on port $port"
          ((killed++)) || true
        fi
      done
    fi
  done

  if [[ $killed -eq 0 ]]; then
    echo "  (no existing processes found)"
  else
    echo "  killed $killed process(es)"
    sleep 1
  fi
}

# -----------------------------------------------------------------------------
# Generate config XML with correct broker entries
# -----------------------------------------------------------------------------
generate_config() {
  # Build broker entries in a temp file to avoid awk newline issues
  local broker_file
  broker_file=$(mktemp)
  for i in $(seq 1 "$BROKERS"); do
    local port=$((BASE_PORT + i - 1))
    echo "        <broker><host>localhost</host><port>${port}</port></broker>" >> "$broker_file"
  done

  # Process template: replace brokers block, terminals, time, rate
  awk -v terminals="$TERMINALS" \
      -v time="$TIME" \
      -v rate="$RATE" \
      -v broker_file="$broker_file" '
    /<brokers>/ {
      print
      while ((getline line < broker_file) > 0) print line
      close(broker_file)
      in_brokers = 1
      next
    }
    /<\/brokers>/ {
      in_brokers = 0
    }
    in_brokers { next }
    /<terminals>/ {
      sub(/<terminals>[^<]*<\/terminals>/, "<terminals>" terminals "</terminals>")
    }
    /<time>/ {
      sub(/<time>[^<]*<\/time>/, "<time>" time "</time>")
    }
    /<rate>/ {
      sub(/<rate>[^<]*<\/rate>/, "<rate>" rate "</rate>")
    }
    { print }
  ' "$CONFIG_TEMPLATE" > "$CONFIG_GEN"

  rm -f "$broker_file"
  echo "Generated config: $CONFIG_GEN"
}

# -----------------------------------------------------------------------------
# Start N brokers with output to specified phase file
# Args: $1 = phase name ("loading" or "execute")
# -----------------------------------------------------------------------------
start_brokers() {
  local phase="$1"
  echo "Starting $BROKERS broker(s) for phase: $phase"

  for i in $(seq 1 "$BROKERS"); do
    local dir="$TX_ROOT/broker-$i"
    mkdir -p "$dir"
    local port=$((BASE_PORT + i - 1))
    local outfile="$dir/${phase}.txt"
    local logfile="$dir/${phase}.log"
    local pidfile="$dir/${phase}.pid"

    (
      cd "$BROKER_DIR" || exit 1
      nohup go run . \
        -listen ":$port" \
        -broker-id "$i" \
        -out "$outfile" \
        >>"$logfile" 2>&1 &
      echo $! >"$pidfile"
    )
    echo "  broker-$i pid=$(cat "$pidfile") :$port -> $outfile"
  done

  # Give brokers time to start
  sleep 3
}

# -----------------------------------------------------------------------------
# Kill brokers by phase name
# Args: $1 = phase name ("loading" or "execute")
# -----------------------------------------------------------------------------
kill_brokers() {
  local phase="$1"
  echo "Stopping brokers (phase: $phase)..."

  for i in $(seq 1 "$BROKERS"); do
    local pidfile="$TX_ROOT/broker-$i/${phase}.pid"
    if [[ -f "$pidfile" ]]; then
      local pid
      pid=$(cat "$pidfile")
      if kill "$pid" 2>/dev/null; then
        echo "  killed broker-$i (pid=$pid)"
      else
        echo "  broker-$i (pid=$pid) already stopped"
      fi
      rm -f "$pidfile"
    fi
  done
}

# -----------------------------------------------------------------------------
# Run benchbase
# Args: $1 = create (true/false), $2 = load (true/false), $3 = execute (true/false)
# -----------------------------------------------------------------------------
run_benchbase() {
  local create="$1"
  local load="$2"
  local execute="$3"

  echo "Running: java -jar benchbase.jar -b smallbank -c $CONFIG_GEN --create=$create --load=$load --execute=$execute"
  java -jar "$BENCHBASE_JAR" \
    -b smallbank \
    -c "$CONFIG_GEN" \
    --create="$create" \
    --load="$load" \
    --execute="$execute"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  # Check benchbase.jar exists
  if [[ ! -f "$BENCHBASE_JAR" ]]; then
    echo "ERROR: benchbase.jar not found at $BENCHBASE_JAR" >&2
    exit 1
  fi

  # Clean up any leftover transactions for this config
  rm -rf "$TX_ROOT"
  mkdir -p "$TX_ROOT"

  # Generate config
  generate_config

  echo ""
  echo "========================================"
  echo "PHASE 1: LOADING"
  echo "========================================"
  kill_existing_on_ports
  start_brokers "loading"
  run_benchbase true true false
  echo "Waiting $WAIT_AFTER seconds for transactions to settle..."
  sleep "$WAIT_AFTER"
  kill_brokers "loading"

  echo ""
  echo "========================================"
  echo "PHASE 2: EXECUTE"
  echo "========================================"
  kill_existing_on_ports
  start_brokers "execute"
  run_benchbase false false true
  echo "Waiting $WAIT_AFTER seconds for transactions to settle..."
  sleep "$WAIT_AFTER"
  kill_brokers "execute"

  echo ""
  echo "========================================"
  echo "COMPLETE"
  echo "========================================"
  echo "Output directory: $TX_ROOT"
  echo ""
  echo "Directory structure:"
  find "$TX_ROOT" -type f -name "*.txt" | sort
  echo ""
  echo "Line counts:"
  find "$TX_ROOT" -type f -name "*.txt" -exec wc -l {} + 2>/dev/null || echo "  (no transaction files found)"
}

main
