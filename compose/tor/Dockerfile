FROM alpine:3.19
RUN apk add --no-cache tor curl && \
    mkdir -p /var/lib/tor /var/run/tor && \
    chown -R tor:tor /var/lib/tor /var/run/tor && \
    chmod 700 /var/lib/tor
RUN printf "SocksPort 0.0.0.0:9050\nDataDirectory /var/lib/tor\nLog notice stdout\n" > /etc/tor/torrc
USER tor
EXPOSE 9050
CMD ["tor", "-f", "/etc/tor/torrc"]
