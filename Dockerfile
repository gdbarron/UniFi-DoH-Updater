FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    curl \
    python3 \
    tzdata

WORKDIR /app

COPY update-doh-blocklist.sh /app/
RUN chmod +x /app/update-doh-blocklist.sh

# Create log file
RUN touch /var/log/doh-updater.log

ENTRYPOINT ["/app/update-doh-blocklist.sh"]
