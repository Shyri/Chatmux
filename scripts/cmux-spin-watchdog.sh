#!/bin/zsh
# Watches a cmux app for a sustained main-thread spin and, when caught, captures
# the evidence — so a wedged app announces itself with a diagnosis instead of
# waiting for a human to notice the beachball.
#
#   cmux-spin-watchdog.sh --tag <tag> [--timeout <s>] [--kill]
#   cmux-spin-watchdog.sh --app <name-or-path> [--timeout <s>] [--kill]
#   cmux-spin-watchdog.sh <tag> [timeout-seconds]        # legacy positional form
#
# Fires when the app's CPU stays >= $CMUX_SPIN_CPU (default 90%) for
# $CMUX_SPIN_SAMPLES consecutive 5s checks (default 3). On detection it writes
# a stack sample, a memory summary and a heap class census to
# /tmp/cmux-spin-<label>-<time>.*, runs scripts/profile-swiftui-layout.py over
# the sample to print a verdict, and exits 1.
#
# Two defaults are deliberate, and both come from a real 3.5-hour livelock of
# the installed app that this script — as originally written — could not have
# caught:
#
#   * The threshold is 90%, not 150%. A SwiftUI layout livelock pegs ONE
#     thread; it never reaches 150% and the old default never fired.
#   * `--app` exists because the old script only matched `cmux DEV <tag>`
#     bundles, and the hang happened in /Applications.
#
# It also no longer kills by default. During that investigation every useful
# fact — the undrained autorelease pool that proved the main thread never
# returned to the run loop, the 95.9M live allocations — came from the process
# being *alive* when it was examined. Pass --kill for unattended CI soaks where
# stopping the burn matters more than the specimen.
#
# Run it unsandboxed (sample(1) needs to attach). Its exit IS the alert.
set -u

SCRIPT_DIR="${0:A:h}"
TAG=""
APP=""
TIMEOUT=0            # 0 == run until a spin is caught (resident mode)
KILL_ON_DETECT=0
THRESH="${CMUX_SPIN_CPU:-90}"
NEED="${CMUX_SPIN_SAMPLES:-3}"
SAMPLE_SECONDS="${CMUX_SPIN_SAMPLE_SECONDS:-15}"

usage() {
  sed -n '2,32p' "$0" >&2
  exit 2
}

# Legacy positional form: <tag> [timeout]
if [[ $# -gt 0 && "$1" != -* ]]; then
  TAG="$1"; shift
  if [[ $# -gt 0 && "$1" != -* ]]; then TIMEOUT="$1"; shift; fi
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:?--tag needs a value}"; shift 2 ;;
    --app) APP="${2:?--app needs a value}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --kill) KILL_ON_DETECT=1; shift ;;
    --cpu) THRESH="${2:?--cpu needs a value}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
done

if [[ -z "$TAG" && -z "$APP" ]]; then
  echo "error: pass --tag <tag> or --app <name-or-path>" >&2
  usage
fi

if [[ -n "$APP" ]]; then
  # Match the executable path of an installed/release bundle. Accepts either a
  # bundle name ("Chatmux") or a full path.
  PATTERN="$APP"
  [[ "$APP" == *.app* || "$APP" == /* ]] || PATTERN="/${APP}.app/Contents/MacOS/"
  LABEL="${APP:t:r}"
else
  PATTERN="cmux DEV $TAG.app/Contents/MacOS"
  LABEL="$TAG"
fi

# Deliberately `ps | grep` rather than `pgrep -f`.
#
# macOS refuses to hand out the argv of a hardened-runtime, Developer-ID-signed
# process, and `pgrep -f` silently skips every process whose argv it cannot
# read. Locally verified: with the release app running as pid 25024,
# `pgrep -f cmux` returns the ad-hoc-signed DEV build and omits the release one
# entirely, while `ps -Ao args` lists both. So the original `pgrep -f` matcher
# could never have seen an installed build — which is precisely the build that
# livelocked. Fixing the CPU threshold alone would not have been enough.
find_pid() {
  ps -Ao pid= -o args= | grep -F "$PATTERN" | grep -v grep | awk '{print $1}' | head -1
}

echo "==> watching '$PATTERN' (cpu>=${THRESH}% for ${NEED}x5s; kill=$KILL_ON_DETECT)"
INITIAL_PID=$(find_pid)
if [[ -n "$INITIAL_PID" ]]; then
  echo "==> matched pid $INITIAL_PID"
else
  # Not fatal — the app may start later — but say so, because a watchdog that
  # matches nothing looks identical to a watchdog reporting all is well.
  echo "==> no process matches yet; will keep looking"
fi

hits=0
elapsed=0
while :; do
  if [[ "$TIMEOUT" -gt 0 && "$elapsed" -ge "$TIMEOUT" ]]; then
    echo "no spin detected for '$PATTERN' in ${TIMEOUT}s"
    exit 0
  fi
  PID=$(find_pid)
  if [[ -n "${PID:-}" ]]; then
    CPU=$(ps -o %cpu= -p "$PID" 2>/dev/null | tr -d ' ' | cut -d. -f1)
    if [[ "${CPU:-0}" -ge "$THRESH" ]]; then
      hits=$((hits + 1))
    else
      hits=0
    fi
    if [[ "$hits" -ge "$NEED" ]]; then
      STAMP=$(date +%H%M%S)
      BASE="/tmp/cmux-spin-$LABEL-$STAMP"
      RSS=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ')
      echo "SPIN DETECTED pid=$PID cpu=${CPU}% rss=$((${RSS:-0} / 1024))MB time=$(date +%T)"

      # Stack first: it is the only capture that is useless if the process
      # moves on, and 15s of samples beats 2s for a stable distribution.
      sample "$PID" "$SAMPLE_SECONDS" -file "$BASE.sample" 2>/dev/null \
        && echo "stack sample:  $BASE.sample"
      # Footprint by region. An autorelease-pool region in the gigabytes means
      # the main thread has not returned to the run loop at all.
      vmmap -summary "$PID" > "$BASE.vmmap" 2>/dev/null \
        && echo "memory summary: $BASE.vmmap"
      # Class census. Which objects are piling up names the subsystem.
      heap "$PID" -s > "$BASE.heap" 2>/dev/null \
        && echo "heap census:   $BASE.heap"

      ANALYZER="$SCRIPT_DIR/profile-swiftui-layout.py"
      if [[ -f "$BASE.sample" && -x "$ANALYZER" ]]; then
        echo
        python3 "$ANALYZER" "$BASE.sample" || true
      fi

      if [[ "$KILL_ON_DETECT" -eq 1 ]]; then
        kill "$PID" 2>/dev/null && echo "killed pid $PID"
      else
        echo
        echo "left pid $PID running (pass --kill to stop the burn automatically)."
      fi
      exit 1
    fi
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done
