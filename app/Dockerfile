# Multi-stage build. Produces a ~20MB static image with no shell and no libc,
# which means a tiny attack surface - and also that you cannot `kubectl exec`
# into it to poke around. That tradeoff is deliberate and worth knowing about.

FROM golang:1.26-alpine AS build
WORKDIR /src

# Copy manifests first so dependency download is cached across source edits.
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# CGO disabled -> a fully static binary that runs on `scratch`.
ARG TARGETOS=linux
ARG TARGETARCH=arm64
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/api    ./cmd/api && \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/worker ./cmd/worker

# Grab CA certificates and a passwd file for the non-root user.
FROM alpine:3.22 AS certs
RUN apk add --no-cache ca-certificates

FROM scratch
COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=certs /etc/passwd /etc/passwd
COPY --from=build /out/api    /api
COPY --from=build /out/worker /worker
COPY --from=build /src/migrations /migrations

USER 65534:65534
EXPOSE 8080
ENTRYPOINT ["/api"]
