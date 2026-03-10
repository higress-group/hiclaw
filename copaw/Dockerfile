# ============================================================
# HiClaw CoPaw Worker Agent - Python-based Container
# ============================================================
# Lightweight Python container for running CoPaw-based Worker Agents.
# Uses the same MinIO-backed config/sync model as OpenClaw workers.
#
# Build args:
#   HIGRESS_REGISTRY - base image registry for mc (MinIO Client)
#   APT_MIRROR       - Debian mirror (default: mirrors.aliyun.com)
#   PIP_INDEX_URL    - PyPI mirror (default: Aliyun)
# ============================================================

ARG HIGRESS_REGISTRY=higress-registry.cn-hangzhou.cr.aliyuncs.com

# ============ Stage 1: mc (MinIO Client) ============
FROM ${HIGRESS_REGISTRY}/higress/mc:20260216 AS mc

# ============ Final Image ============
FROM python:3.11-slim

ARG APT_MIRROR=mirrors.aliyun.com
ARG PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/

# python:3.11-slim is Debian-based, uses /etc/apt/sources.list.d/debian.sources
RUN if [ -n "${APT_MIRROR}" ]; then \
        sed -i "s|deb.debian.org|${APT_MIRROR}|g" \
            /etc/apt/sources.list.d/debian.sources 2>/dev/null || true; \
    fi && \
    apt-get update && apt-get install -y --no-install-recommends \
        libolm-dev \
        curl \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# mc (MinIO Client)
COPY --from=mc /usr/bin/mc /usr/local/bin/mc

# Install copaw-worker from local source
COPY pyproject.toml README.md /tmp/copaw-worker/
COPY src/ /tmp/copaw-worker/src/
RUN pip install --no-cache-dir \
        --index-url "${PIP_INDEX_URL}" \
        --trusted-host "$(echo ${PIP_INDEX_URL} | sed 's|https\?://||;s|/.*||')" \
        /tmp/copaw-worker/ \
    && rm -rf /tmp/copaw-worker/

# Entrypoint script
COPY scripts/copaw-worker-entrypoint.sh /opt/hiclaw/scripts/copaw-worker-entrypoint.sh
RUN chmod +x /opt/hiclaw/scripts/copaw-worker-entrypoint.sh

# Create workspace directory
RUN mkdir -p /root/.copaw-worker

WORKDIR /root/.copaw-worker

ENTRYPOINT ["/opt/hiclaw/scripts/copaw-worker-entrypoint.sh"]
