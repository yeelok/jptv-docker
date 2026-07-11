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
RUN git clone --filter=blob:none -b work-plus-s-251101 \
    https://github.com/xtne6f/EDCB.git && \
    git -C EDCB checkout d21fa8a8
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

COPY --from=builder /usr/local/bin/ /usr/local/bin/
COPY --from=builder /usr/local/lib/edcb/ /usr/local/lib/edcb/
RUN mkdir -p /var/local/edcb && chmod 777 /var/local/edcb
COPY --from=builder /var/local/edcb/ /var/local/edcb/

WORKDIR /var/local/edcb

# デフォルトでは録画予約サービス (EpgTimerSrv) を起動する。
# チャンネルスキャンは compose 側の edcb_chscan サービスで command を上書きして実行する。
CMD ["/usr/local/bin/EpgTimerSrv"]
