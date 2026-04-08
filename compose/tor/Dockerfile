FROM alpine:3.19
RUN apk add --no-cache tor curl
RUN echo "SocksPort 0.0.0.0:9050" > /etc/tor/torrc && \
    echo "Log notice stdout" >> /etc/tor/torrc
USER tor
EXPOSE 9050
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -sf --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip || exit 1
CMD ["tor", "-f", "/etc/tor/torrc"]
