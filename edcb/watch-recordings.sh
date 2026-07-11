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
# Log to stdout so the output is captured by `docker logs postrec` (no log file in /recordings).
log() { echo "$(date '+%F %T') watch: $*"; }

compress() {
    src="$1"
    # only touch broadcast MPEG-2; skip anything already re-encoded (idempotent)
    codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of default=nw=1:nokey=1 "$src" 2>/dev/null | head -1)
    [ "$codec" = "mpeg2video" ] || return 0

    tmp="${src%.ts}.hevc.part.ts"
    log "compressing: $src"
    # tsreplace drives NVEncC (args after -e): NVEncC reads the ARIB TS from stdin with the
    # NVDEC hardware reader (--avhw), deinterlaces the 1080i field pairs, GPU HEVC-encodes at
    # a constant-quality target, and emits an mpegts video elementary stream on stdout; tsreplace
    # swaps that in for the original video PID and copies audio / captions / PSI / PCR unchanged.
    # NVEncC (not ffmpeg) is used because it preserves the source PTS/DTS, which lets tsreplace
    # interleave the passthrough streams evenly — required for KonomiTV's mid-file seek playback.
    # The encoder is verbose (per-frame progress); keep it out of the normal log and only surface
    # it (on stderr) when the encode fails, so `docker logs` stays readable but stays debuggable.
    enc_out="/tmp/postrec-enc.log"
    tsreplace -i "$src" -o "$tmp" \
        -e nvencc --avhw --input - --interlace tff --vpp-deinterlace normal \
            --codec hevc --qvbr 26 --preset quality --gop-len 90 \
            --output-format mpegts --output - >"$enc_out" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ] && [ -f "$tmp" ]; then
        srcsz=$(stat -c %s "$src" 2>/dev/null || echo 0)
        dstsz=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
        if [ "$dstsz" -gt 1000000 ] && [ "$dstsz" -lt "$srcsz" ]; then
            mv "$tmp" "$src"
            rm -f "$enc_out"
            log "done: $srcsz -> $dstsz bytes (HEVC; kept audio/captions/EPG): $src"
        else
            rm -f "$tmp"
            log "size check failed (src=$srcsz dst=$dstsz), kept raw: $src"
            rm -f "$enc_out"
        fi
    else
        rm -f "$tmp"
        log "tsreplace/NVEncC failed (rc=$rc), kept raw: $src"
        # dump the encoder output to stderr for diagnosis, then discard the temp log
        sed 's/^/  nvencc: /' "$enc_out" >&2 2>/dev/null
        rm -f "$enc_out"
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
