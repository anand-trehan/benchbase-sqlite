#!/usr/bin/env bash
set -euo pipefail

# Runs BenchBase remotely on an Ubuntu/Debian node over SSH.
#
# Edit the variables in the "USER CONFIG" section below, then run:
#   ./run_remote_benchbase.sh
#
# Optional CLI overrides exist (run with --help), but you don't need them for
# the default workflow (install + sync, then you SSH and run manually).

#
# -----------------------------
# USER CONFIG (edit these)
# -----------------------------
experimentName="anand-test"
clusterType="emulab"          # emulab or cloudlab
projectName="l-free-machine"
hostPrefix="client"
remoteUser="at6404"

# Optional overrides; leave empty to auto-pick defaults.
remoteDir=""                 # default: $HOME/benchbase-sqlite on remote
configPath="config/lockfreedb/sample_smallbank_config.xml"

# Set to 1 if you want this script to run BenchBase automatically after install.
runBenchBase=0

#
# -----------------------------
# Advanced (rarely needed)
# -----------------------------
REMOTE=""                     # can be set to "user@host" to bypass host construction
REMOTE_DIR=""                 # can be set to override remoteDir above
CONFIG_PATH=""                # can be set to override configPath above
DO_RUN=""                     # can be set to override runBenchBase above

BENCHMARK="${BENCHMARK:-smallbank}"
JAR="${JAR:-benchbase.jar}"
EXTRA_ARGS="${EXTRA_ARGS:---create=true --load=true --execute=true}"

LOCAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  run_remote_benchbase.sh
  run_remote_benchbase.sh [--user <username>] [--remote <user@host>] [--remote-dir <path>] [--config <path>] [--run]

Host construction (when not using --remote and REMOTE is empty):
  host = ${hostPrefix}.${experimentName}.${projectName}.emulab.${suffix}

By default, this script:
  - syncs the local BenchBase folder to the remote
  - installs required runtime dependencies (Java 21, rsync, ca-certs)
It does NOT run the benchmark unless you pass --run (or set runBenchBase=1).
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required local command: $1" >&2
    exit 1
  }
}

need_cmd ssh
need_cmd rsync

USER_ARG="${remoteUser}"
if [[ -n "${REMOTE_DIR}" ]]; then
  remoteDir="${REMOTE_DIR}"
fi
if [[ -n "${CONFIG_PATH}" ]]; then
  configPath="${CONFIG_PATH}"
fi
if [[ -n "${DO_RUN}" ]]; then
  runBenchBase="${DO_RUN}"
fi

REMOTE_DIR=""
CONFIG_PATH="${configPath}"
DO_RUN="${runBenchBase}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)
      REMOTE="${2:-}"; shift 2;;
    --user)
      USER_ARG="${2:-}"; shift 2;;
    --remote-dir)
      remoteDir="${2:-}"; shift 2;;
    --config)
      CONFIG_PATH="${2:-}"; shift 2;;
    --run)
      DO_RUN=1; shift 1;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2;;
  esac
done

if [[ -z "${REMOTE}" ]]; then
  if [[ -z "${USER_ARG}" ]]; then
    echo "remoteUser is empty; set it in USER CONFIG or pass --user." >&2
    usage
    exit 2
  fi

  if [[ "${clusterType}" == "emulab" ]]; then
    suffix="net"
  else
    suffix="cloudlab.us"
  fi

  host="${hostPrefix}.${experimentName}.${projectName}.emulab.${suffix}"
  REMOTE="${USER_ARG}@${host}"
fi

if [[ -z "${remoteDir}" ]]; then
  REMOTE_HOME="$(ssh -o BatchMode=yes "${REMOTE}" 'printf %s "$HOME"')"
  REMOTE_DIR="${REMOTE_HOME}/benchbase-sqlite"
else
  REMOTE_DIR="${remoteDir}"
fi

echo "==> Syncing local project to ${REMOTE}:${REMOTE_DIR}"
ssh -o BatchMode=yes "${REMOTE}" "mkdir -p '${REMOTE_DIR}'"
rsync -az --delete \
  --exclude '.git/' \
  --exclude 'target/' \
  --exclude '*.log' \
  "${LOCAL_ROOT}/" \
  "${REMOTE}:${REMOTE_DIR}/"

echo "==> Installing runtime dependencies on remote (Java, rsync, ca-certs)"
ssh -o BatchMode=yes "${REMOTE}" "bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  sudo -n true 2>/dev/null || { echo \"Remote user lacks passwordless sudo; install Java manually or grant sudo.\" >&2; exit 1; }
  sudo apt-get update -y

  need_java21=1
  if command -v java >/dev/null 2>&1; then
    # "openjdk version \"21.0.x\"" or "openjdk version \"17.0.x\""
    major=\$(java -version 2>&1 | sed -n \"s/.*version \\\"\\([0-9][0-9]*\\).*/\\1/p\" | head -n1)
    if [[ -n \"\${major}\" && \"\${major}\" -ge 21 ]]; then
      need_java21=0
    fi
  fi

  if [[ \"\${need_java21}\" -eq 1 ]]; then
    sudo apt-get install -y --no-install-recommends openjdk-21-jre-headless ca-certificates rsync
  else
    sudo apt-get install -y --no-install-recommends ca-certificates rsync
  fi

  java -version
'"

echo "==> Running BenchBase on remote"
if [[ "${DO_RUN}" -eq 1 ]]; then
  ssh -o BatchMode=yes "${REMOTE}" "bash -lc '
    set -euo pipefail
    cd \"${REMOTE_DIR}\"
    test -f \"${JAR}\" || { echo \"Missing ${JAR} in ${REMOTE_DIR}\" >&2; exit 1; }
    test -d \"lib\" || { echo \"Missing lib/ directory in ${REMOTE_DIR} (BenchBase expects distribution layout)\" >&2; exit 1; }
    test -f \"${CONFIG_PATH}\" || { echo \"Missing config file: ${CONFIG_PATH}\" >&2; exit 1; }
    java -jar \"${JAR}\" -b \"${BENCHMARK}\" -c \"${CONFIG_PATH}\" ${EXTRA_ARGS}
  '"
else
  echo "==> Install-only complete. SSH into the node and run BenchBase manually when ready."
  echo "    Remote: ${REMOTE}"
  echo "    Dir:    ${REMOTE_DIR}"
fi

