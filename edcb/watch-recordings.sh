#!/bin/sh
# Recordings compressor (watcher).
#
# Periodically scans /recordings and compresses each *finished* recording to HEVC via
# tsreplace + NVENC — re-encoding only the video PID and copying audio / ARIB captions /
# SDT-EIT unchanged, so KonomiTV still catalogs it (metadata + captions), ~65% smaller.
#
# A recording is "finished" when its size has been unchanged for STABLE_SECS. This fires for
# ANY completed recording — natural end OR stopped/cancelled early — unlike EDCB's post-record
# bat (which only runs on natural completion). Runs as a dedicated container from the tv-edcb
# image. Safe no-op (recordings kept raw) when no NVIDIA GPU is available.
set -u

REC_DIR="${REC_DIR:-/recordings}"
INTERVAL="${INTERVAL:-60}"          # scan period (seconds)
STABLE_SECS="${STABLE_SECS:-120}"   # a file unchanged this long is treated as finished
LOG="${REC_DIR}/_postrec.log"
log() { echo "$(date '+%F %T') watch: $*" >>"$LOG" 2>/dev/null; }

compress() {
    src="$1"
    # only touch broadcast MPEG-2; skip anything already re-encoded (idempotent)
    codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of default=nw=1:nokey=1 "$src" 2>/dev/null | head -1)
    [ "$codec" = "mpeg2video" ] || return 0

    tmp="${src%.ts}.hevc.part.ts"
    log "compressing: $src"
    # tsreplace drives ffmpeg (args after -e): decode video from the piped TS, deinterlace,
    # GPU HEVC encode, emit video-only mpegts; tsreplace swaps it in and copies the rest.
    tsreplace -i "$src" -o "$tmp" \
        -e ffmpeg -hide_banner -nostats -loglevel error -i - -an -sn -dn \
            -vf yadif=0:-1:1 \
            -c:v hevc_nvenc -preset p5 -rc vbr -cq 26 -b:v 0 -g 90 \
            -f mpegts - >>"$LOG" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ] && [ -f "$tmp" ]; then
        srcsz=$(stat -c %s "$src" 2>/dev/null || echo 0)
        dstsz=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
        if [ "$dstsz" -gt 1000000 ] && [ "$dstsz" -lt "$srcsz" ]; then
            mv "$tmp" "$src"
            log "done: $srcsz -> $dstsz bytes (HEVC; kept audio/captions/EPG): $src"
        else
            rm -f "$tmp"
            log "size check failed (src=$srcsz dst=$dstsz), kept raw: $src"
        fi
    else
        rm -f "$tmp"
        log "tsreplace/ffmpeg failed (rc=$rc), kept raw: $src"
    fi
}

# Without a GPU the whole feature is a no-op; stay alive but idle so the service is harmless.
if ! nvidia-smi >/dev/null 2>&1; then
    log "no NVIDIA GPU; compressor idle (recordings kept raw)"
    while true; do sleep 3600; done
fi

log "recordings compressor started (interval=${INTERVAL}s, stable>=${STABLE_SECS}s)"
while true; do
    now=$(date +%s)
    for f in "$REC_DIR"/*.ts; do
        [ -e "$f" ] || continue
        case "$f" in *.hevc.part.ts) continue ;; esac       # skip our own temp files
        mtime=$(stat -c %Y "$f" 2>/dev/null || echo "$now")
        # still growing (or just finished) -> not stable yet, likely still recording
        [ $((now - mtime)) -lt "$STABLE_SECS" ] && continue
        compress "$f"
    done
    sleep "$INTERVAL"
done
