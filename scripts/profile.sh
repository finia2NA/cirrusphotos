#!/bin/bash
# Records an Instruments trace of the optimized app with a live countdown, then shows
# processing progress until the trace is written. Usage: scripts/profile.sh SECONDS TEMPLATE
set -uo pipefail
cd "$(dirname "$0")/.."

seconds="${1:-40}"
template="${2:-Time Profiler}"
if ! [[ $seconds =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: $0 SECONDS [TEMPLATE] (SECONDS must be a positive integer)" >&2
    exit 2
fi
app="$PWD/.build/Synology Photos Dev.app/Contents/MacOS/CirrusPhotos"
mkdir -p .build/profiles
trace=".build/profiles/$(date +%Y%m%d-%H%M%S)-${template// /-}.trace"
log="$(mktemp -t cirrus-profile)"

if pgrep -f 'xctrace record' >/dev/null; then
    echo "Another xctrace recording is still running or processing; wait for it to finish." >&2
    exit 1
fi
free_gb=$(df -g . | awk 'NR == 2 { print $4 }')
if [[ ${free_gb:-0} -lt 25 ]]; then
    echo "Warning: only ${free_gb} GB free. Traces can be very large (Animation Hitches especially)." >&2
fi

# Instruments such as SwiftUI need a debuggable target; only the profiling bundle gets this.
# The same identity as run.sh keeps Keychain access across builds. Only the app itself is
# re-signed; run.sh already signed the embedded Sparkle code.
source scripts/signing.sh
identity="$(signing_identity)"
codesign --force --sign "${identity:--}" --entitlements scripts/Profiling.entitlements \
    "$PWD/.build/Synology Photos Dev.app" || exit 1

echo "Template: $template (+ os_signpost), ${seconds}s. Output: $trace"
# os_signpost records the app's performance.browser intervals alongside any template.
xcrun xctrace record --template "$template" --instrument os_signpost --time-limit "${seconds}s" \
    --output "$trace" --launch -- "$app" >"$log" 2>&1 &
recorder=$!

# One Control-C asks xctrace to stop early and still save the trace.
trap 'echo; echo "Stopping early; the trace is still saved."; kill -INT "$recorder" 2>/dev/null' INT

bar() { # bar FILLED WIDTH
    local filled=$1 width=$2 out="" i
    for ((i = 0; i < width; i++)); do
        if ((i < filled)); then out+="#"; else out+="-"; fi
    done
    printf '%s' "$out"
}

phase=launching
started=0
processing_started=0
spinner='|/-\'
tick=0
while kill -0 "$recorder" 2>/dev/null; do
    now=$(date +%s)
    # xctrace prints these lines when the recording starts and when it ends.
    if [[ $phase == launching ]] && grep -q 'Ctrl-C to stop the recording' "$log"; then
        phase=recording
        started=$now
    fi
    if [[ $phase != processing ]] && grep -q 'ending recording\|Stopping recording\|Recording completed' "$log"; then
        phase=processing
        processing_started=$now
    fi
    case $phase in
        launching)
            printf '\r\033[KLaunching app %s' "${spinner:tick%4:1}" ;;
        recording)
            elapsed=$((now - started))
            ((elapsed > seconds)) && elapsed=$seconds
            printf '\r\033[KRecording [%s] %3ds left' "$(bar $((elapsed * 30 / seconds)) 30)" "$((seconds - elapsed))" ;;
        processing)
            size=$(du -sh "$trace" 2>/dev/null | awk '{ print $1 }')
            printf '\r\033[KProcessing trace %s %ds, %s written. Quit the app if it is still open.' \
                "${spinner:tick%4:1}" "$((now - processing_started))" "${size:-0B}" ;;
    esac
    tick=$((tick + 1))
    sleep 0.5
done
wait "$recorder"
status=$?
trap - INT
printf '\r\033[K'

# xctrace exits non-zero (for example 54) when it kills the launched app at the time
# limit, even though the trace is complete; a saved trace is the success criterion.
if [[ -d $trace ]] && grep -q 'Output file saved as' "$log"; then
    echo "Trace saved: $PWD/$trace ($(du -sh "$trace" | awk '{ print $1 }'))"
    rm -f "$log"
    open "$trace"
else
    echo "xctrace exited with status $status. Its output:" >&2
    cat "$log" >&2
    rm -f "$log"
    exit "$status"
fi
