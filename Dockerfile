FROM debian:bookworm-slim

ARG ZIG_VERSION=0.16.0
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
  curl \
  ca-certificates \
  xz-utils \
  && rm -rf /var/lib/apt/lists/*

# Zig menamai arsitektur berbeda dari nilai TARGETARCH Docker (amd64 -> x86_64, arm64 -> aarch64)
RUN case "${TARGETARCH}" in \
  "amd64") ZIG_ARCH="x86_64" ;; \
  "arm64") ZIG_ARCH="aarch64" ;; \
  *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
  esac && \
  curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz && \
  mkdir -p /opt/zig && \
  tar -xf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && \
  rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"

WORKDIR /workspace

CMD ["bash"]
