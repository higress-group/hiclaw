#!/bin/bash
# start-element-web.sh - Generate Element Web config and start Nginx

MATRIX_DOMAIN="${HICLAW_MATRIX_DOMAIN:-matrix-local.hiclaw.io:8080}"
# Brand name for Element Web (defaults to "Element" if not set)
ELEMENT_BRAND="${HICLAW_ELEMENT_BRAND:-Element}"

# Generate Element Web config.json pointing to local Matrix Homeserver
cat > /opt/element-web/config.json << EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "http://${MATRIX_DOMAIN}"
        }
    },
    "brand": "${ELEMENT_BRAND}",
    "disable_guests": true,
    "disable_custom_urls": false
}
EOF

# Configure nginx worker processes (default is auto, which uses CPU core count)
sed -i 's/worker_processes.*auto;/worker_processes 2;/' /etc/nginx/nginx.conf 2>/dev/null || \
sed -i 's/^worker_processes [0-9]*;/worker_processes 2;/' /etc/nginx/nginx.conf 2>/dev/null || \
grep -q '^worker_processes' /etc/nginx/nginx.conf || \
sed -i '1i worker_processes 2;' /etc/nginx/nginx.conf

# Generate Nginx config for Element Web
# Note: We inject a script to automatically accept unsupported browsers
# This bypasses the browser compatibility check in Element Web's SupportedBrowser.ts
cat > /etc/nginx/conf.d/element-web.conf << 'NGINX'
server {
    listen 8088;
    root /opt/element-web;
    index index.html;

    # Inject script to bypass browser compatibility check
    # Sets localStorage.mx_accepts_unsupported_browser = true before app loads
    sub_filter '</head>' '<script>window.localStorage.setItem("mx_accepts_unsupported_browser","true");</script></head>';
    sub_filter_once on;
    sub_filter_types text/html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location ~* ^/(config.*\.json|index\.html|i18n|version)$ {
        add_header Cache-Control "no-cache";
    }
}
NGINX

# Generate Nginx config for OpenClaw Console reverse proxy.
# Injects the gateway token into the HTML via sub_filter so the Control UI
# auto-authenticates without requiring the user to enter a token manually.
# localStorage key: "openclaw.control.settings.v1" → { token: "<key>" }
OPENCLAW_TOKEN="${HICLAW_MANAGER_GATEWAY_KEY:-}"
cat > /etc/nginx/conf.d/openclaw-console.conf << NGINX
# OpenClaw Console — reverse proxy to gateway loopback with auto-token injection
server {
    listen 18888;

    location / {
        proxy_pass http://127.0.0.1:18799;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        # Disable upstream compression so sub_filter can modify HTML responses
        proxy_set_header Accept-Encoding "";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        # Auto-inject gateway token into localStorage so Control UI connects without manual auth
        sub_filter_types text/html;
        sub_filter_once on;
        sub_filter '</head>' '<script>(function(){var K="openclaw.control.settings.v1",T="${OPENCLAW_TOKEN}";if(!T)return;try{var r=localStorage.getItem(K),s=r?JSON.parse(r):{};s.token=T;localStorage.setItem(K,JSON.stringify(s))}catch(e){}})();</script></head>';
    }
}
NGINX

# Remove default nginx site if exists
rm -f /etc/nginx/sites-enabled/default

exec nginx -g 'daemon off;'
