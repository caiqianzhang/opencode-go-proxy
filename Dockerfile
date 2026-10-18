FROM golang:1.26-alpine AS build

WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/opencode-go-proxy .

FROM alpine:3.24

RUN apk add --no-cache ca-certificates \
    && addgroup -S proxy \
    && adduser -S -G proxy proxy

COPY --from=build /out/opencode-go-proxy /usr/local/bin/opencode-go-proxy

USER proxy
EXPOSE 8787
ENTRYPOINT ["/usr/local/bin/opencode-go-proxy"]
