FROM alpine:3.19

WORKDIR /app

# Install dependencies (No curl needed)
RUN apk add --no-cache ca-certificates tzdata wget unzip openssl

# Create non-root user for security
RUN addgroup -S xray && adduser -S xray -G xray

# Download and install xray
RUN XRAY_VERSION=1.8.10 && \
    mkdir -p /usr/local/share/xray && \
    wget -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip && \
    unzip /tmp/xray.zip -d /usr/local/share/xray && \
    rm /tmp/xray.zip && \
    chmod +x /usr/local/share/xray/xray && \
    ln -s /usr/local/share/xray/xray /usr/local/bin/xray

# Create directory for logs within container
RUN mkdir -p /var/log/xray
# Config and certs will be mounted by docker run

# Set ownership of log directory to the non-root user
# /app ownership doesn't strictly matter if nothing is copied there
RUN chown -R xray:xray /var/log/xray

# Use non-root user
USER xray

# Expose the internal port Xray listens on (VLESS)
EXPOSE 8000
# Expose the internal port for health checks
EXPOSE 80

# Run xray, expecting config to be mounted at /app/config.json
CMD ["xray", "run", "-config", "/app/config.json"] 