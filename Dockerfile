FROM alpine:3.19

WORKDIR /app

# Install dependencies
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

# Create directories for logs and certificates (within the container)
RUN mkdir -p /var/log/xray /app/certs

# Copy the configuration file into the image
# COPY server/config.json /app/config.json

# Set ownership of app and log directories to the non-root user
RUN chown -R xray:xray /app /var/log/xray

# Use non-root user
USER xray

# Expose the internal port Xray listens on (VLESS)
EXPOSE 8000
# Expose the internal port for health checks
EXPOSE 80

# Run xray
CMD ["xray", "run", "-config", "/app/config.json"] 