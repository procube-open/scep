FROM alpine:3

COPY ./scepserver-linux-arm64 /usr/bin/scepserver

EXPOSE 8080

VOLUME ["/depot"]

ENTRYPOINT ["scepserver"]
