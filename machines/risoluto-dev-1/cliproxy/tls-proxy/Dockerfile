# Caddy with the Cloudflare DNS provider, for the DNS-01 challenge of CLIPROXY_PUBLIC_HOST.
FROM docker.io/library/caddy:2-builder AS builder
LABEL dev.risoluto.cliproxy.build-stage=tls-proxy
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM docker.io/library/caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
