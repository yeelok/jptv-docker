# EDCB (xtne6f fork, native Linux build) + BonDriver_LinuxMirakc + Material WebUI
# BonDriver_LinuxMirakc talks to mirakc over its Mirakurun-compatible HTTP API and
# (with DECODE_B25=1) requests already-descrambled TS, so this container needs no
# B-CAS card of its own — descrambling stays in the mirakc + b25/bcas chain.
# Reference: https://github.com/nunawa/docker-dtv-server/blob/main/EDCB/Dockerfile

FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    make \
    gcc \
    g++ \
    liblua5.2-dev \
    lua-zlib \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# EDCB 本体のビルド
WORKDIR /tmp
RUN git clone --filter=blob:none -b work-plus-s-260703 \
    https://github.com/xtne6f/EDCB.git && \
    git -C EDCB checkout 9770536e9f04
WORKDIR /tmp/EDCB/Document/Unix
RUN make -j "$(nproc)" && \
    make install && \
    make extra -j "$(nproc)" && \
    make install_extra && \
    mkdir -p /var/local/edcb && \
    make setup_ini && \
    sed -i -e 's/^ALLOW_SETTING=.*/ALLOW_SETTING=true/' \
        /var/local/edcb/HttpPublic/legacy/util.lua

# EDCB Material WebUI のインストール
WORKDIR /tmp
RUN git clone --filter=blob:none https://github.com/EMWUI/EDCB_Material_WebUI.git && \
    git -C EDCB_Material_WebUI checkout 68854a2a
WORKDIR /tmp/EDCB_Material_WebUI
RUN cp -r HttpPublic /var/local/edcb/ && \
    cp -r Setting /var/local/edcb/

# BonDriver_LinuxMirakc のビルド (mirakc 専用 BonDriver)
WORKDIR /tmp
RUN git clone --filter=blob:none --recurse-submodules \
    https://github.com/matching/BonDriver_LinuxMirakc.git && \
    git -C BonDriver_LinuxMirakc checkout cfbefc6d && \
    git -C BonDriver_LinuxMirakc submodule update --init --recursive
WORKDIR /tmp/BonDriver_LinuxMirakc
RUN make -j "$(nproc)" && \
    cp BonDriver_LinuxMirakc.so /usr/local/lib/edcb/ && \
    cp BonDriver_LinuxMirakc.so.ini_sample \
        /usr/local/lib/edcb/BonDriver_LinuxMirakc.so.ini

FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    liblua5.2-dev \
    lua-zlib \
    ffmpeg \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# tsreplace (rigaya): re-encodes only the video PID of a TS, copying audio / ARIB captions /
# SDT/EIT unchanged. Used by the post-record compression watcher (edcb/watch-recordings.sh) so
# compressed recordings keep their program metadata + captions and stay fully catalogued by KonomiTV.
# Prebuilt .deb depends only on libc6/libgcc-s1 (both present in bookworm).
ADD https://github.com/rigaya/tsreplace/releases/download/0.19/tsreplace_0.19_amd64.deb /tmp/tsreplace.deb
RUN dpkg -i /tmp/tsreplace.deb && rm -f /tmp/tsreplace.deb

# NVEncC (rigaya): the encoder tsreplace drives for the actual HEVC re-encode. It reads the ARIB
# MPEG-TS natively and preserves its PTS/DTS, so tsreplace can interleave the passthrough streams
# (audio / captions / PSI / PCR) evenly across the output. This matters because KonomiTV plays
# recordings by seeking to a mid-file keyframe and re-encoding forward — an encoder that clustered
# PSI/PCR (as ffmpeg-piped output does) would leave mid-file segments with no PAT/PMT and no audio.
# Prebuilt .deb depends only on libc6 (present in bookworm). Requires the NVIDIA runtime only at
# run time (docker-compose.nvidia.yaml); the build itself needs no GPU.
ADD https://github.com/rigaya/NVEnc/releases/download/9.24/nvencc_9.24_amd64.deb /tmp/nvencc.deb
RUN dpkg -i /tmp/nvencc.deb && rm -f /tmp/nvencc.deb

COPY --from=builder /usr/local/bin/ /usr/local/bin/
COPY --from=builder /usr/local/lib/edcb/ /usr/local/lib/edcb/
RUN mkdir -p /var/local/edcb && chmod 777 /var/local/edcb
COPY --from=builder /var/local/edcb/ /var/local/edcb/

WORKDIR /var/local/edcb

# デフォルトでは録画予約サービス (EpgTimerSrv) を起動する。
# チャンネルスキャンは compose 側の edcb_chscan サービスで command を上書きして実行する。
CMD ["/usr/local/bin/EpgTimerSrv"]
