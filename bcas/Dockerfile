FROM alpine AS ifd-build
RUN apk add --no-cache build-base git pcsc-lite-dev
RUN git clone --depth=1 https://github.com/yyya-nico/px4_drv /src
RUN make -C /src/userland/ifd-px4

FROM alpine
COPY ./main.sh /
# px4_drv 用の PC/SC IFD ハンドラーを bundle として配置する
# (標準の ccid ドライバでは /dev/pxmlt8card0 を扱えないため必須)
COPY --from=ifd-build /src/userland/ifd-px4/libpx4ifd.so \
     /usr/lib/pcsc/drivers/ifd-px4.bundle/Contents/Linux/libpx4ifd.so
COPY --from=ifd-build /src/userland/ifd-px4/Info.plist \
     /usr/lib/pcsc/drivers/ifd-px4.bundle/Contents/Info.plist
# reader.conf は敢えて配置しない。
# コンテナは /sys 経由で USB デバイス (VID 0x0511) を列挙できるため、pcscd の USB
# ホットプラグが Info.plist の bundle をもとに自動でリーダーを /dev/pxmlt8card0 に紐付ける。
# reader.conf で静的リーダーも定義すると、排他オープンの同デバイスをホットプラグ側と奪い合い、
# ATR 取得に失敗する (PX4CARD_GET_ATR failed) ため、ホットプラグ単独に統一する。
RUN apk add --no-cache ccid musl pcsc-lite pcsc-lite-libs socat tzdata
EXPOSE 40774
ENTRYPOINT ["/bin/sh", "/main.sh"]
