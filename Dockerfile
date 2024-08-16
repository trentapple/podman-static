# Download gpg
FROM alpine:3.20 AS gpg
RUN apk add --no-cache gnupg


# runc
FROM golang:1.22-alpine3.20 AS runc
ARG RUNC_VERSION=v1.1.13
# Download runc binary release since static build doesn't work with musl libc anymore since 1.1.8, see https://github.com/opencontainers/runc/issues/3950
RUN set -eux; \
	ARCH="`uname -m | sed 's!x86_64!amd64!; s!aarch64!arm64!'`"; \
	wget -O /usr/local/bin/runc https://github.com/opencontainers/runc/releases/download/$RUNC_VERSION/runc.$ARCH; \
	chmod +x /usr/local/bin/runc; \
	runc --version; \
	! ldd /usr/local/bin/runc


# podman build base
FROM golang:1.22-alpine3.20 AS podmanbuildbase
RUN apk add --update --no-cache git make gcc pkgconf musl-dev \
	btrfs-progs btrfs-progs-dev libassuan-dev lvm2-dev device-mapper \
	glib-static libc-dev gpgme-dev protobuf-dev protobuf-c-dev \
	libseccomp-dev libseccomp-static libselinux-dev ostree-dev openssl nftables \
	bash go-md2man


# podman (without systemd support)
FROM podmanbuildbase AS podman
RUN apk add --update --no-cache tzdata curl

ARG PODMAN_VERSION=v5.2.1
ARG PODMAN_BUILDTAGS='seccomp selinux apparmor exclude_graphdriver_devicemapper containers_image_openpgp'
ARG PODMAN_CGO=1
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=${PODMAN_VERSION} https://github.com/containers/podman src/github.com/containers/podman
#RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=${PODMAN_VERSION:-$(curl -s https://api.github.com/repos/containers/podman/releases/latest | grep tag_name | cut -d '"' -f 4)} https://github.com/containers/podman src/github.com/containers/podman
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


# rust
FROM rust:1.80-alpine3.20 AS rustbase
RUN apk add --update --no-cache git make musl-dev


# aardvark-dns
FROM rustbase AS aardvark-dns
ARG AARDVARKDNS_VERSION=v1.12.1
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=$AARDVARKDNS_VERSION https://github.com/containers/aardvark-dns
WORKDIR /aardvark-dns
ENV RUSTFLAGS='-C link-arg=-s'
RUN cargo build --release


# passt
FROM podmanbuildbase AS passt
WORKDIR /
RUN apk add --update --no-cache autoconf automake meson ninja linux-headers libcap-static libcap-dev clang llvm coreutils
# https://passt.top/passt/
ARG PASST_VERSION=2024_08_06.ee36266
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=$PASST_VERSION git://passt.top/passt
WORKDIR /passt
RUN set -ex; \
	make static; \
	mkdir bin; \
	cp pasta bin/; \
	[ ! -f pasta.avx2 ] || cp pasta.avx2 bin/; \
	! ldd /passt/bin/pasta


# conmon (without systemd support)
FROM podmanbuildbase AS conmon
#RUN apk add --update --no-cache tzdata curl

ARG CONMON_VERSION=v2.1.12
#RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=${CONMON_VERSION} https://github.com/containers/conmon.git /conmon
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=${CONMON_VERSION} https://github.com/containers/conmon /conmon
#RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=${CONMON_VERSION:-$(curl -s https://api.github.com/repos/containers/conmon/releases/latest | grep tag_name | cut -d '"' -f 4)} https://github.com/containers/conmon.git /conmon
WORKDIR /conmon
RUN set -ex; \
	make git-vars bin/conmon PKG_CONFIG='pkg-config --static' CFLAGS='-std=c99 -Os -Wall -Wextra -Werror -static' LDFLAGS='-s -w -static'; \
	bin/conmon --help >/dev/null


# netavark
## build using rustbase
FROM rustbase AS netavark
RUN apk add --update --no-cache protoc
ARG NETAVARK_VERSION=v1.12.1
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=$NETAVARK_VERSION https://github.com/containers/netavark
WORKDIR /netavark
ENV RUSTFLAGS='-C link-arg=-s'
RUN cargo build --release


# netavark
## build using podmanbuildbase
#FROM podmanbuildbase AS netavark
##RUN apk add --update --no-cache tzdata curl rust cargo
#RUN apk add --update --no-cache rust cargo
#ARG NETAVARK_VERSION=v1.12.1
#RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=${NETAVARK_VERSION} https://github.com/containers/netavark /netavark
##RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=${NETAVARK_VERSION:-$(curl -s https://api.github.com/repos/containers/netavark/releases/latest | grep tag_name | cut -d '"' -f 4)} https://github.com/containers/netavark /netavark
#WORKDIR /netavark
#RUN set -ex; \
#	make build_netavark


# slirp4netns
FROM podmanbuildbase AS slirp4netns
WORKDIR /
RUN apk add --update --no-cache autoconf automake meson ninja linux-headers libcap-static libcap-dev clang llvm
# Build libslirp
ARG LIBSLIRP_VERSION=v4.8.0
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=${LIBSLIRP_VERSION} https://gitlab.freedesktop.org/slirp/libslirp.git
WORKDIR /libslirp
RUN set -ex; \
	rm -rf /usr/lib/libglib-2.0.so /usr/lib/libintl.so; \
	ln -s /usr/bin/clang /go/bin/clang; \
	LDFLAGS="-s -w -static" meson --prefix /usr -D default_library=static build; \
	ninja -C build install
# Build slirp4netns
WORKDIR /
ARG SLIRP4NETNS_VERSION=v1.3.1
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch ${SLIRP4NETNS_VERSION} https://github.com/rootless-containers/slirp4netns
#RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch ${SLIRP4NETNS_VERSION} https://github.com/rootless-containers/slirp4netns.git
#RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=${SLIRP4NETNS_VERSION:-$(curl -s https://api.github.com/repos/rootless-containers/slirp4netns/releases/latest | grep tag_name | cut -d '"' -f 4)} https://github.com/rootless-containers/slirp4netns.git
WORKDIR /slirp4netns
RUN set -ex; \
	./autogen.sh; \
	LDFLAGS=-static ./configure --prefix=/usr; \
	make


# fuse-overlayfs (derived from https://github.com/containers/fuse-overlayfs/blob/master/Dockerfile.static)
FROM podmanbuildbase AS fuse-overlayfs
RUN apk add --update --no-cache autoconf automake meson ninja clang g++ eudev-dev fuse3-dev
ARG LIBFUSE_VERSION=fuse-3.16.2
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=$LIBFUSE_VERSION https://github.com/libfuse/libfuse /libfuse
WORKDIR /libfuse
RUN set -ex; \
	mkdir build; \
	cd build; \
	LDFLAGS="-lpthread -s -w -static" meson --prefix /usr -D default_library=static .. || (cat /libfuse/build/meson-logs/meson-log.txt; false); \
	ninja; \
	touch /dev/fuse; \
	ninja install; \
	fusermount3 -V
ARG FUSEOVERLAYFS_VERSION=v1.14
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=$FUSEOVERLAYFS_VERSION https://github.com/containers/fuse-overlayfs /fuse-overlayfs
WORKDIR /fuse-overlayfs
RUN set -ex; \
	sh autogen.sh; \
	LIBS="-ldl" LDFLAGS="-s -w -static" ./configure --prefix /usr; \
	make; \
	make install; \
	fuse-overlayfs --help >/dev/null


# catatonit
FROM podmanbuildbase AS catatonit
RUN apk add --update --no-cache autoconf automake libtool
ARG CATATONIT_VERSION=v0.2.0
RUN git clone -c 'advice.detachedHead=false' --branch=$CATATONIT_VERSION https://github.com/openSUSE/catatonit /catatonit
#RUN git clone -c 'advice.detachedHead=false' --branch=$CATATONIT_VERSION https://github.com/openSUSE/catatonit.git /catatonit
WORKDIR /catatonit
RUN set -ex; \
	./autogen.sh; \
	./configure LDFLAGS="-static" --prefix=/ --bindir=/bin; \
	make; \
	./catatonit --version


# Download crun
# (switched keyserver from sks to ubuntu since sks is offline now 
# and gpg refuses to import keys from keys.openpgp.org because it does not provide a user ID with the key.)
FROM gpg AS crun
ARG CRUN_VERSION=1.16.1
RUN set -ex; \
	ARCH="`uname -m | sed 's!x86_64!amd64!; s!aarch64!arm64!'`"; \
	wget -O /usr/local/bin/crun https://github.com/containers/crun/releases/download/$CRUN_VERSION/crun-${CRUN_VERSION}-linux-${ARCH}-disable-systemd; \
	wget -O /tmp/crun.asc https://github.com/containers/crun/releases/download/$CRUN_VERSION/crun-${CRUN_VERSION}-linux-${ARCH}-disable-systemd.asc; \
	gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 027F3BD58594CA181BB5EC50E4730F97F60286ED; \
	gpg --batch --verify /tmp/crun.asc /usr/local/bin/crun; \
	chmod +x /usr/local/bin/crun; \
	! ldd /usr/local/bin/crun


# Build podman base image
FROM alpine:3.20 AS podmanbase
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
	ln -s /usr/local/bin/podman /usr/bin/docker; \
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


# Build rootless podman base image with runc
FROM rootlesspodmanbase AS rootlesspodmanrunc
COPY --from=runc   /usr/local/bin/runc   /usr/local/bin/runc


# Build minimal rootless podman
FROM rootlesspodmanbase AS rootlesspodmanminimal
COPY --from=crun /usr/local/bin/crun /usr/local/bin/crun
COPY conf/crun-containers.conf /etc/containers/containers.conf


# Build podman image with rootless binaries and CNI plugins
#FROM rootlesspodmanrunc AS podmanall
FROM rootlesspodmanbase AS podmanall
RUN apk add --no-cache iptables ip6tables nftables
COPY --from=slirp4netns /slirp4netns/slirp4netns /usr/local/bin/slirp4netns
#COPY --from=netavark /netavark/target/release/netavark /usr/local/lib/podman/netavark
COPY --from=catatonit /catatonit/catatonit /usr/local/lib/podman/catatonit
COPY --from=runc   /usr/local/bin/runc   /usr/local/bin/runc
COPY --from=aardvark-dns /aardvark-dns/target/release/aardvark-dns /usr/local/lib/podman/aardvark-dns
COPY --from=podman /etc/containers/seccomp.json /etc/containers/seccomp.json
