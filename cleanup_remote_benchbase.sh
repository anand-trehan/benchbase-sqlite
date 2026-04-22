#!/usr/bin/env bash
set -euo pipefail

# Cleans up the remote directory used for BenchBase runs.
#
# Edit the variables in the "USER CONFIG" section below, then run:
#   ./cleanup_remote_benchbase.sh

#
# -----------------------------
# USER CONFIG (edit these)
# -----------------------------
experimentName="anand-test"
clusterType="emulab"          # emulab or cloudlab
projectName="l-free-machine"
hostPrefix="client"
remoteUser="at6404"

# Leave empty to remove $HOME/benchbase-sqlite on the remote.
remoteDir=""

# Set to 1 only if you also want to uninstall Java 21.
# This is intentionally off by default because it can break other workflows.
uninstallJava=0

#
# -----------------------------
# Advanced (rarely needed)
# -----------------------------
REMOTE=""                     # can be set to "user@host" to bypass host construction
REMOTE_DIR=""                 # can be set to override remoteDir above

usage() {
  cat <<'EOF'
Usage:
  cleanup_remote_benchbase.sh
  cleanup_remote_benchbase.sh [--remote <user@host>] [--user <username>] [--remote-dir <path>] [--uninstall-java]

By default:
  - deletes the remote directory (default: $HOME/benchbase-sqlite)
  - does NOT uninstall Java
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required local command: $1" >&2
    exit 1
  }
}

need_cmd ssh

USER_ARG="${remoteUser}"
if [[ -n "${REMOTE_DIR}" ]]; then
  remoteDir="${REMOTE_DIR}"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)
      REMOTE="${2:-}"; shift 2;;
    --user)
      USER_ARG="${2:-}"; shift 2;;
    --remote-dir)
      remoteDir="${2:-}"; shift 2;;
    --uninstall-java)
      uninstallJava=1; shift 1;;
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

echo "==> Deleting remote directory: ${REMOTE}:${REMOTE_DIR}"
ssh -o BatchMode=yes "${REMOTE}" "bash -lc '
  set -euo pipefail
  if [[ -z \"${REMOTE_DIR}\" || \"${REMOTE_DIR}\" == \"/\" ]]; then
    echo \"Refusing to delete an empty or root directory.\" >&2
    exit 1
  fi
  rm -rf \"${REMOTE_DIR}\"
  echo \"Deleted ${REMOTE_DIR}\"
'"

if [[ "${uninstallJava}" -eq 1 ]]; then
  echo "==> Uninstalling Java 21 (openjdk-21-jre-headless) on remote"
  ssh -o BatchMode=yes "${REMOTE}" "bash -lc '
    set -euo pipefail
    sudo -n true 2>/dev/null || { echo \"Remote user lacks passwordless sudo; cannot uninstall packages.\" >&2; exit 1; }
    sudo apt-get remove -y openjdk-21-jre-headless || true
    sudo apt-get autoremove -y || true
  '"
fi

echo "==> Cleanup complete"

