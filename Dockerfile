ARG PODMAN_VERSION=v5.3.2
ARG ALPINE_VERSION=3.21
ARG GOLANG_VERSION=1.23
ARG RUST_VERSION=1.84.1
ARG RUNC_VERSION=v1.2.4
ARG CONMON_VERSION=v2.1.12
ARG NETAVARK_VERSION=v1.13.1
ARG AARDVARKDNS_VERSION=v1.13.1
ARG PASST_VERSION=2025_01_21.4f2c8e7
ARG LIBFUSE_VERSION=fuse-3.16.2
ARG FUSEOVERLAYFS_VERSION=v1.14
ARG CATATONIT_VERSION=v0.2.1
ARG CRUN_VERSION=1.18.2

# runc
FROM golang:${GOLANG_VERSION}-alpine${ALPINE_VERSION} AS runc
ARG RUNC_VERSION
# Download runc binary release since static build doesn't work with musl libc anymore since 1.1.8, see https://github.com/opencontainers/runc/issues/3950
RUN set -eux; \
    ARCH="`uname -m | sed 's!x86_64!amd64!; s!aarch64!arm64!'`"; \
    wget -O /usr/local/bin/runc https://github.com/opencontainers/runc/releases/download/$RUNC_VERSION/runc.$ARCH; \
    chmod +x /usr/local/bin/runc; \
    runc --version; \
    ! ldd /usr/local/bin/runc

# podman build base
FROM golang:${GOLANG_VERSION}-alpine${ALPINE_VERSION} AS podmanbuildbase
RUN apk add --no-cache git make gcc pkgconf musl-dev \
    btrfs-progs btrfs-progs-dev libassuan-dev lvm2-dev device-mapper \
    glib-static libc-dev gpgme-dev protobuf-dev protobuf-c-dev \
    libseccomp-dev libseccomp-static libselinux-dev ostree-dev openssl iptables ip6tables nftables \
    bash go-md2man

# podman (without systemd support)
FROM podmanbuildbase AS podman
ARG PODMAN_VERSION
RUN apk add --no-cache tzdata curl
ARG PODMAN_BUILDTAGS='seccomp selinux apparmor exclude_graphdriver_devicemapper containers_image_openpgp'
ARG PODMAN_CGO=1
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=${PODMAN_VERSION:-$(curl -s https://api.github.com/repos/containers/podman/releases/latest | grep tag_name | cut -d '"' -f 4)} https://github.com/containers/podman src/github.com/containers/podman
WORKDIR $GOPATH/src/github.com/containers/podman
RUN set -eux; \
    COMMON_VERSION=$(grep -Eom1 'github.com/containers/common [^ ]+' go.mod | sed 's!github.com/containers/common !!'); \
    mkdir -p /etc/containers; \
    curl -fsSL "https://raw.githubusercontent.com/containers/common/${COMMON_VERSION}/pkg/seccomp/seccomp.json" > /etc/containers/seccomp.json
RUN set -ex; \
    export CGO_ENABLED=$PODMAN_CGO; \
    make bin/podman LDFLAGS_PODMAN="-s -w -extldflags '-static'" BUILDTAGS='${PODMAN_BUILDTAGS}'; \
    mv bin/podman /usr/local/bin/podman; \
    podman --help >/dev/null; \
    ! ldd /usr/local/bin/podman
RUN set -ex; \
    CGO_ENABLED=0 make bin/rootlessport BUILDFLAGS=" -mod=vendor -ldflags=\"-s -w -extldflags '-static'\""; \
    mkdir -p /usr/local/lib/podman; \
    mv bin/rootlessport /usr/local/lib/podman/rootlessport; \
    ! ldd /usr/local/lib/podman/rootlessport

# conmon (without systemd support)
FROM podmanbuildbase AS conmon
ARG CONMON_VERSION
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=${CONMON_VERSION:-$(curl -s https://api.github.com/repos/containers/conmon/releases/latest | grep tag_name | cut -d '"' -f 4)} https://github.com/containers/conmon /conmon
WORKDIR /conmon
RUN set -ex; \
    make git-vars bin/conmon PKG_CONFIG='pkg-config --static' CFLAGS='-std=c99 -Os -Wall -Wextra -Werror -static' LDFLAGS='-s -w -static'; \
    bin/conmon --help >/dev/null

# rust
FROM rust:${RUST_VERSION}-alpine${ALPINE_VERSION} AS rustbase
RUN apk add --no-cache git make musl-dev

# netavark
FROM rustbase AS netavark
ARG NETAVARK_VERSION
RUN apk add --no-cache protoc
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=${NETAVARK_VERSION:-$(curl -s https://api.github.com/repos/containers/netavark/releases/latest | grep tag_name | cut -d '"' -f 4)} https://github.com/containers/netavark
WORKDIR /netavark
ENV RUSTFLAGS='-C target-feature=-crt-static -C target-cpu=native -C link-arg=-s'
RUN cargo build --release

# aardvark-dns
FROM rustbase AS aardvark-dns
ARG AARDVARKDNS_VERSION
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=${AARDVARKDNS_VERSION:-$(curl -s https://api.github.com/repos/containers/aardvark-dns/releases/latest | grep tag_name | cut -d '"' -f 4)} https://github.com/containers/aardvark-dns
WORKDIR /aardvark-dns
ENV RUSTFLAGS='-C target-feature=-crt-static -C target-cpu=native -C link-arg=-s'
RUN cargo build --release

# passt
FROM podmanbuildbase AS passt
ARG PASST_VERSION
WORKDIR /
RUN apk add --no-cache autoconf automake meson ninja linux-headers libcap-static libcap-dev clang llvm coreutils
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=${PASST_VERSION:-$(curl -s https://api.github.com/repos/passt/releases/latest | grep tag_name | cut -d '"' -f 4)} git://passt.top/passt
WORKDIR /passt
RUN set -ex; \
    make static; \
    mkdir -p bin; \
    mv pasta bin/; \
    [ ! -f pasta.avx2 ] || mv pasta.avx2 bin/; \
    ! ldd /passt/bin/pasta

# fuse-overlayfs
FROM podmanbuildbase AS fuse-overlayfs
ARG FUSEOVERLAYFS_VERSION
ARG LIBFUSE_VERSION
RUN apk add --update --no-cache autoconf automake meson ninja clang g++ eudev-dev fuse3-dev
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=${LIBFUSE_VERSION:-$(curl -s https://api.github.com/repos/libfuse/releases/latest | grep tag_name | cut -d '"' -f 4)} https://github.com/libfuse/libfuse /libfuse
WORKDIR /libfuse
RUN set -ex; \
    mkdir -p build; \
    cd build; \
    LDFLAGS="-lpthread -s -w -static" meson --prefix /usr -D default_library=static .. || (cat /libfuse/build/meson-logs/meson-log.txt; false); \
    ninja; \
    touch /dev/fuse; \
    ninja install; \
    fusermount3 -V
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=${FUSEOVERLAYFS_VERSION:-$(curl -s https://api.github.com/repos/containers/fuse-overlayfs/releases/latest | grep tag_name | cut -d '"' -f 4)} https://github.com/containers/fuse-overlayfs /fuse-overlayfs
WORKDIR /fuse-overlayfs
RUN set -ex; \
    sh autogen.sh; \
    LIBS="-ldl" LDFLAGS="-s -w -static" ./configure --prefix /usr; \
    make; \
    make install; \
    fuse-overlayfs --help >/dev/null

# catatonit
FROM podmanbuildbase AS catatonit
ARG CATATONIT_VERSION
RUN apk add --no-cache autoconf automake libtool
RUN git clone -c 'advice.detachedHead=false' --branch=${CATATONIT_VERSION:-$(curl -s https://api.github.com/repos/openSUSE/catatonit/releases/latest | grep tag_name | cut -d '"' -f 4)} https://github.com/openSUSE/catatonit /catatonit
WORKDIR /catatonit
RUN set -ex; \
    ./autogen.sh; \
    ./configure LDFLAGS="-static" --prefix=/ --bindir=/bin; \
    make; \
    ./catatonit --version

# crun
FROM alpine:${ALPINE_VERSION} AS crun
ARG CRUN_VERSION
RUN apk add --no-cache gnupg
RUN set -ex; \
    ARCH="`uname -m | sed 's!x86_64!amd64!; s!aarch64!arm64!'`"; \
    wget -O /usr/local/bin/crun https://github.com/containers/crun/releases/download/$CRUN_VERSION/crun-${CRUN_VERSION}-linux-${ARCH}-disable-systemd; \
    wget -O /tmp/crun.asc https://github.com/containers/crun/releases/download/$CRUN_VERSION/crun-${CRUN_VERSION}-linux-${ARCH}-disable-systemd.asc; \
    gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 027F3BD58594CA181BB5EC50E4730F97F60286ED; \
    gpg --batch --verify /tmp/crun.asc /usr/local/bin/crun; \
    chmod +x /usr/local/bin/crun; \
    ! ldd /usr/local/bin/crun

# Build podman base image
FROM alpine:${ALPINE_VERSION} AS podmanbase
LABEL maintainer=""
RUN apk add --no-cache tzdata ca-certificates
COPY --from=conmon /conmon/bin/conmon /usr/local/lib/podman/conmon
COPY --from=podman /usr/local/lib/podman/rootlessport /usr/local/lib/podman/rootlessport
COPY --from=podman /usr/local/bin/podman /usr/local/bin/podman
COPY --from=netavark /netavark/target/release/netavark /usr/local/lib/podman/netavark
COPY --from=passt /passt/bin/pasta /usr/local/bin/pasta
COPY --from=passt /passt/bin/ /usr/local/bin/
COPY conf/containers /etc/containers
RUN set -ex; \
    adduser -D podman -h /podman -u 1000; \
    echo 'podman:1:999' > /etc/subuid; \
    echo 'podman:1001:64535' >> /etc/subuid; \
    cp /etc/subuid /etc/subgid; \
    ln -s /usr/local/bin/podman /usr/local/bin/docker; \
    mkdir -p /podman/.local/share/containers/storage /var/lib/containers/storage; \
    chown -R podman:podman /podman; \
    mkdir -p -m1777 /.local /.config /.cache; \
    podman --help >/dev/null; \
    /usr/local/lib/podman/conmon --help >/dev/null
ENV _CONTAINERS_USERNS_CONFIGURED=""

# Build rootless podman base image (without OCI runtime)
FROM podmanbase AS rootlesspodmanbase
ENV BUILDAH_ISOLATION=chroot container=oci
RUN apk add --no-cache shadow-uidmap
COPY --from=fuse-overlayfs /usr/bin/fuse-overlayfs /usr/local/bin/fuse-overlayfs
COPY --from=fuse-overlayfs /usr/bin/fusermount3 /usr/local/bin/fusermount3
COPY --from=crun /usr/local/bin/crun /usr/local/bin/crun

# Build minimal rootless podman
FROM rootlesspodmanbase AS rootlesspodmanminimal
COPY --from=crun /usr/local/bin/crun /usr/local/bin/crun
COPY conf/crun-containers.conf /etc/containers/containers.conf

# Build podman image with rootless binaries
FROM rootlesspodmanbase AS podmanall
RUN apk add --no-cache iptables ip6tables nftables
COPY --from=catatonit /catatonit/catatonit /usr/local/lib/podman/catatonit
COPY --from=runc /usr/local/bin/runc /usr/local/bin/runc
COPY --from=aardvark-dns /aardvark-dns/target/release/aardvark-dns /usr/local/lib/podman/aardvark-dns
COPY --from=podman /etc/containers/seccomp.json /etc/containers/seccomp.json
