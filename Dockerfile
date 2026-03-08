# Multi-stage Dockerfile for all-in-one Slurm container on Rocky Linux 10
# Stage 1: Build gosu from source with latest Go
# Stage 2: Build Slurm RPMs
# Stage 3: Runtime image with bash entrypoint

ARG SLURM_VERSION
ARG GOSU_VERSION=1.19

# ============================================================================
# Stage 1: Build gosu from source
# (pre-built binaries use an old Go version that triggers CVEs)
# https://github.com/tianon/gosu/issues/136
# ============================================================================
FROM golang:1.26-bookworm AS gosu-builder

ARG GOSU_VERSION
ARG TARGETOS
ARG TARGETARCH

RUN set -ex \
    && git clone --branch ${GOSU_VERSION} --depth 1 \
       https://github.com/tianon/gosu.git /go/src/github.com/tianon/gosu \
    && cd /go/src/github.com/tianon/gosu \
    && go mod download \
    && CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
       go build -v -trimpath -ldflags '-d -w' \
       -o /go/bin/gosu . \
    && chmod +x /go/bin/gosu

# ============================================================================
# Stage 2: Build RPMs
# ============================================================================
FROM rockylinux/rockylinux:10 AS builder

ARG SLURM_VERSION
ARG TARGETARCH

# Enable CRB and EPEL, install build dependencies
# http-parser: temporarily using RL9 packages (https://support.schedmd.com/show_bug.cgi?id=21801)
RUN set -ex \
    && echo -e "retries=10\ntimeout=60" >> /etc/dnf/dnf.conf \
    && RPM_ARCH=$(case "${TARGETARCH}" in \
         amd64) echo "x86_64" ;; \
         arm64) echo "aarch64" ;; \
         *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
       esac) \
    && dnf makecache \
    && dnf -y install dnf-plugins-core epel-release wget \
    && dnf config-manager --set-enabled crb \
    && dnf makecache \
    && dnf -y install \
       https://download.rockylinux.org/pub/rocky/9/AppStream/${RPM_ARCH}/os/Packages/h/http-parser-2.9.4-6.el9.${RPM_ARCH}.rpm \
       https://download.rockylinux.org/pub/rocky/9/CRB/${RPM_ARCH}/os/Packages/h/http-parser-devel-2.9.4-6.el9.${RPM_ARCH}.rpm \
    && dnf -y install \
       autoconf \
       automake \
       bzip2 \
       dbus-devel \
       freeipmi-devel \
       gcc \
       gcc-c++ \
       git \
       gtk2-devel \
       hdf5-devel \
       hwloc-devel \
       json-c-devel \
       libcurl-devel \
       libyaml-devel \
       lua-devel \
       lz4-devel \
       make \
       man2html \
       mariadb-devel \
       munge \
       munge-devel \
       ncurses-devel \
       numactl-devel \
       openssl-devel \
       pam-devel \
       perl \
       python3 \
       python3-devel \
       readline-devel \
       rpm-build \
       rpmdevtools \
       rrdtool-devel \
       libjwt-devel \
    && dnf clean all \
    && rm -rf /var/cache/dnf

RUN rpmdev-setuptree
COPY rpmbuild/slurm.rpmmacros /root/.rpmmacros

# Download and build Slurm RPMs
# Architecture: Docker TARGETARCH (amd64, arm64) -> RPM arch (x86_64, aarch64)
RUN set -ex \
    && RPM_ARCH=$(case "${TARGETARCH}" in \
         amd64) echo "x86_64" ;; \
         arm64) echo "aarch64" ;; \
         *) echo "Unsupported: ${TARGETARCH}" && exit 1 ;; \
       esac) \
    && wget -O /root/rpmbuild/SOURCES/slurm-${SLURM_VERSION}.tar.bz2 \
       https://download.schedmd.com/slurm/slurm-${SLURM_VERSION}.tar.bz2 \
    && rpmbuild -ta /root/rpmbuild/SOURCES/slurm-${SLURM_VERSION}.tar.bz2 \
    && ls -lh /root/rpmbuild/RPMS/${RPM_ARCH}/

# ============================================================================
# Stage 3: Runtime image
# ============================================================================
FROM rockylinux/rockylinux:10

LABEL org.opencontainers.image.source="https://github.com/giovtorres/slurm-docker" \
      org.opencontainers.image.title="slurm-docker" \
      org.opencontainers.image.description="All-in-one Slurm Docker container on Rocky Linux 10" \
      maintainer="Giovanni Torres"

ARG SLURM_VERSION
ARG TARGETARCH

# Install runtime dependencies
# http-parser: temporarily using RL9 package (https://support.schedmd.com/show_bug.cgi?id=21801)
RUN set -ex \
    && echo -e "retries=10\ntimeout=60" >> /etc/dnf/dnf.conf \
    && RPM_ARCH=$(case "${TARGETARCH}" in \
         amd64) echo "x86_64" ;; \
         arm64) echo "aarch64" ;; \
         *) echo "Unsupported: ${TARGETARCH}" && exit 1 ;; \
       esac) \
    && dnf makecache \
    && dnf -y update \
    && dnf -y install dnf-plugins-core epel-release wget \
    && dnf config-manager --set-enabled crb \
    && dnf makecache \
    && dnf -y install \
       https://download.rockylinux.org/pub/rocky/9/AppStream/${RPM_ARCH}/os/Packages/h/http-parser-2.9.4-6.el9.${RPM_ARCH}.rpm \
    && dnf -y install \
       bash \
       bash-completion \
       bzip2 \
       gettext \
       hdf5 \
       hwloc \
       json-c \
       jq \
       libaec \
       libyaml \
       lua \
       lz4 \
       mariadb \
       mariadb-server \
       munge \
       numactl \
       perl \
       procps-ng \
       psmisc \
       python3 \
       readline \
       vim-enhanced \
       libjwt \
       openssh-server \
       openssh-clients \
       google-authenticator \
       passwd \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Install gosu (built from source in stage 1)
COPY --from=gosu-builder /go/bin/gosu /usr/local/bin/gosu
RUN gosu --version && gosu nobody true

# Install uv (Python package manager)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Install Slurm RPMs
COPY --from=builder /root/rpmbuild/RPMS/*/*.rpm /tmp/rpms/
RUN set -ex \
    && dnf -y install \
       /tmp/rpms/slurm-[0-9]*.rpm \
       /tmp/rpms/slurm-perlapi-*.rpm \
       /tmp/rpms/slurm-slurmctld-*.rpm \
       /tmp/rpms/slurm-slurmd-*.rpm \
       /tmp/rpms/slurm-slurmdbd-*.rpm \
       /tmp/rpms/slurm-slurmrestd-*.rpm \
       /tmp/rpms/slurm-contribs-*.rpm \
    && rm -rf /tmp/rpms \
    && dnf clean all

# Create users, munge key, and directories
RUN set -x \
    && groupadd -r --gid=990 slurm \
    && useradd -r -g slurm --uid=990 slurm \
    && groupadd -r --gid=991 slurmrest \
    && useradd -r -g slurmrest --uid=991 slurmrest \
    && chmod 0755 /etc \
    && /sbin/mungekey --create \
    && chown munge:munge /etc/munge/munge.key \
    && chmod 0400 /etc/munge/munge.key \
    && mkdir -m 0755 -p \
        /var/run/slurm \
        /var/spool/slurm \
        /var/lib/slurm \
        /var/log/slurm \
        /etc/slurm \
        /data \
    && chown slurm:slurm \
        /var/run/slurm \
        /var/spool/slurm \
        /var/lib/slurm \
        /var/log/slurm \
        /etc/slurm

# Copy Slurm configuration files (version-specific selection)
COPY config/ /tmp/slurm-config/
RUN set -ex \
    && MAJOR_MINOR=$(echo ${SLURM_VERSION} | cut -d. -f1,2) \
    && echo "Slurm version: ${MAJOR_MINOR}" \
    && if [ -f "/tmp/slurm-config/${MAJOR_MINOR}/slurm.conf" ]; then \
         echo "Using config for ${MAJOR_MINOR}"; \
         cp /tmp/slurm-config/${MAJOR_MINOR}/slurm.conf /etc/slurm/slurm.conf; \
       else \
         echo "No config for ${MAJOR_MINOR}, falling back to 25.11"; \
         cp /tmp/slurm-config/25.11/slurm.conf /etc/slurm/slurm.conf; \
       fi \
    && cp /tmp/slurm-config/common/slurmdbd.conf /etc/slurm/slurmdbd.conf \
    && cp /tmp/slurm-config/common/cgroup.conf /etc/slurm/cgroup.conf \
    && chown slurm:slurm /etc/slurm/slurm.conf /etc/slurm/cgroup.conf /etc/slurm/slurmdbd.conf \
    && chmod 644 /etc/slurm/slurm.conf /etc/slurm/cgroup.conf \
    && chmod 600 /etc/slurm/slurmdbd.conf \
    && rm -rf /tmp/slurm-config

# SSH: generate host keys, install default passwordless config, remove root password
COPY config/common/sshd_config /etc/ssh/sshd_config
RUN set -ex \
    && ssh-keygen -A \
    && mkdir -p /run/sshd /root/.ssh \
    && chmod 700 /root/.ssh

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 22 6817 6819 6820

WORKDIR /data

VOLUME ["/var/lib/mysql", "/var/log/slurm", "/data"]

# Multi-arch build:
#   docker buildx build --platform linux/amd64,linux/arm64 .

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
