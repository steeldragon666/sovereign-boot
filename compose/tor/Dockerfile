FROM alpine:3.19
RUN apk add --no-cache tor && mkdir -p /var/lib/tor /var/run/tor && chown -R tor:tor /var/lib/tor /var/run/tor && chmod 700 /var/lib/tor
RUN echo "SocksPort 0.0.0.0:9050" > /etc/tor/torrc && echo "DataDirectory /var/lib/tor" >> /etc/tor/torrc && echo "Log notice stdout" >> /etc/tor/torrc
USER tor
EXPOSE 9050
CMD ["tor", "-f", "/etc/tor/torrc"]
