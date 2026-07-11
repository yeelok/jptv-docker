#!/bin/sh
# EDCB post-record hook (native-Linux build runs a .sh with recording info as env vars).
#
# Compress the finished recording with tsreplace + GPU (NVENC): re-encode ONLY the video
# to HEVC while copying audio, ARIB captions and the SDT/EIT program metadata unchanged.
# The result stays an MPEG-TS, so KonomiTV still catalogs it fully (metadata + captions)
# while the file is much smaller. Replaces the raw .ts in place.
#
# EDCB passes the recorded file path in $FilePath. Safe by default: if no NVIDIA GPU is
# available the raw .ts is left untouched, so the same config works on any host.
set -u

LOG="/recordings/_postrec.log"
log() { echo "$(date '+%F %T') postrec: $*" >>"$LOG" 2>/dev/null; }

src="${FilePath:-}"
[ -n "$src" ] && [ -f "$src" ] || { log "no source file (FilePath='$src')"; exit 0; }
case "$src" in *.ts) ;; *) log "skip non-.ts: $src"; exit 0 ;; esac

# Require a working GPU; otherwise leave the raw recording untouched.
if ! nvidia-smi >/dev/null 2>&1; then
    log "no NVIDIA GPU, keeping raw ts: $src"
    exit 0
fi

tmp="${src%.ts}.hevc.part.ts"
log "start: $src"

# tsreplace drives ffmpeg (everything after -e is ffmpeg's args): decode the video from the
# piped TS, deinterlace (1080i broadcast), GPU HEVC encode, emit video-only mpegts on stdout;
# tsreplace swaps that in for the original video PID and copies everything else through.
tsreplace -i "$src" -o "$tmp" \
    -e ffmpeg -hide_banner -nostats -loglevel error -i - -an -sn -dn \
        -vf yadif=0:-1:1 \
        -c:v hevc_nvenc -preset p5 -rc vbr -cq 26 -b:v 0 -g 90 \
        -f mpegts - >>"$LOG" 2>&1
rc=$?

if [ "$rc" -eq 0 ] && [ -f "$tmp" ]; then
    srcsz=$(stat -c %s "$src" 2>/dev/null || echo 0)
    dstsz=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
    # sanity: output must be non-trivial and smaller than the source before replacing the raw ts
    if [ "$dstsz" -gt 1000000 ] && [ "$dstsz" -lt "$srcsz" ]; then
        mv "$tmp" "$src"
        log "done: $srcsz -> $dstsz bytes (HEVC video; kept audio/captions/EPG): $src"
    else
        rm -f "$tmp"
        log "size check failed (src=$srcsz dst=$dstsz), kept raw ts: $src"
    fi
else
    rm -f "$tmp"
    log "tsreplace/ffmpeg failed (rc=$rc), kept raw ts: $src"
fi
exit 0
