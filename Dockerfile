# syno-letsencrypt — Let's Encrypt for Synology DSM via Cloudflare DNS-01.
#
# The container is an ordinary network client. It reaches Cloudflare and Let's
# Encrypt outbound, and DSM's own Web API inbound. It mounts nothing from the
# host, holds no host capabilities and never runs as root on the NAS. Every
# privileged operation is performed by DSM itself, in response to an
# authenticated API call — exactly as if you had uploaded the certificate in
# Control Panel.

FROM alpine:3.20 AS lego
ARG LEGO_VERSION=4.35.2
ARG TARGETARCH=amd64
RUN apk add --no-cache curl tar \
 && curl -fsSL "https://github.com/go-acme/lego/releases/download/v${LEGO_VERSION}/lego_v${LEGO_VERSION}_linux_${TARGETARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin lego \
 && chmod 755 /usr/local/bin/lego

FROM alpine:3.20

RUN apk add --no-cache bash curl jq openssl ca-certificates tzdata \
 && rm -rf /var/cache/apk/*

COPY --from=lego /usr/local/bin/lego /usr/local/bin/lego
COPY src/lib/  /app/lib/
COPY src/bin/  /app/bin/
COPY docker/entrypoint.sh /app/entrypoint.sh
RUN chmod 755 /app/entrypoint.sh /app/bin/*

# Certificates and the ACME account key live here. Mount a named volume so a
# container rebuild does not force re-registration with Let's Encrypt or,
# worse, re-issuance into a rate limit.
VOLUME ["/data"]
ENV SYNOLE_DATA=/data

# Runs unprivileged. Nothing here needs root, inside the container or out.
RUN adduser -D -u 1000 -h /data syno
USER syno

HEALTHCHECK --interval=6h --timeout=30s --start-period=60s \
    CMD /app/bin/syno-letsencrypt status >/dev/null || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
