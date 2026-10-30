# syntax=docker/dockerfile:1
# remotedesk 中继服务器镜像（纯 Go + 纯 Go SQLite，无需 CGO）
FROM golang:1.23-alpine AS build
WORKDIR /src
RUN apk add --no-cache git
COPY . .
RUN go mod tidy && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/remotedesk .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY --from=build /out/remotedesk /app/remotedesk
ENV RD_LISTEN=:8443 \
    RD_DB=/data/remotedesk.db \
    RD_TURN_LISTEN=:3478
VOLUME ["/data"]
EXPOSE 8443/tcp 3478/udp
ENTRYPOINT ["/app/remotedesk"]
