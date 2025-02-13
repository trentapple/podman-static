# podman binaries and container images ![GitHub workflow badge](https://github.com/trentapple/podman-static/workflows/Release/badge.svg)

This project provides alpine-based (musl) podman container images and statically linked (rootless) podman binaries for linux/amd64 and linux/arm64/v8 machines along with its dependencies _(without systemd support)_:
* [podman](https://github.com/containers/podman)
* [runc](https://github.com/opencontainers/runc/) or [crun](https://github.com/containers/crun)
* [conmon](https://github.com/containers/conmon)
* [fuse-overlayfs](https://github.com/containers/fuse-overlayfs) and [libfuse](https://github.com/libfuse/libfuse)
* [slirp4netns](https://github.com/rootless-containers/slirp4netns) (with [libslirp](https://gitlab.freedesktop.org/slirp/libslirp))
* [Netavark](https://github.com/containers/netavark): container network stack (default in podman 5 or later)
* [aardvark-dns](https://github.com/containers/aardvark-dns): Authoritative DNS server for A/AAAA container records _([forwards other queries to host's /etc/resolv.conf](https://github.com/containers/aardvark-dns#aardvark-dns))_
* [pasta / passt](https://passt.top/): Pack A Subtle Tap Abstraction (same binary as passt (Plug A Simple Socket Transport), different command) offers equivalent functionality, for network namespaces: traffic is forwarded using a tap interface inside the namespace
* [catatonit](https://github.com/openSUSE/catatonit)

CNI has been replaced as the default. See also: [Podman Networking Docs](https://docs.podman.io/en/latest/markdown/podman-network.1.html)

## Container image

The following image tags are supported:

| Tag | Description |
| --- | ----------- |
| `latest`, `<VERSION>` | podman with both rootless and rootful dependencies: runc, conmon, fuse-overlayfs, slirp4netns, netavark, ~CNI plugins~, catatonit. |
| `minimal`, `<VERSION>-minimal` | podman, crun, fuse-overlayfs and conmon binaries, configured to use the host's existing namespaces (low isolation level). |
| `remote`, `<VERSION>-remote` | the podman remote binary. |

By default containers run with user `root`. However, in a standard configuration, `podman` user (uid/gid 1000) may be utilized. The subuid/gid mapping is configured with the image (described within the [binary installation section below](#Binary-installation-on-a-host)).

Please note that, when running non-remote podman within a docker container, the docker container will need `--privileged` flag.

### Container usage example

Run podman in docker:
```sh
docker run --privileged -u podman:podman ghcr.io/trentapple/podman:minimal docker run alpine:latest echo hello from nested container
```
_`docker` is linked to `podman` within the container to support applications that may rely on the `docker` command._

## Binary installation on a host

_If using an arm64 (aarch64) machine (e.g. a Raspberry Pi 4 or later) then substitute "amd64" with "arm64" in the commands below to ensure the installation is compatible with your machine's architecture._

Download the statically linked binaries of podman and its dependencies:
```sh
curl -fsSL -o podman-linux-amd64.tar.gz https://github.com/trentapple/podman-static/releases/latest/download/podman-linux-amd64.tar.gz
```

Verify the archive's signature (_optional, but recommended_):
```sh
curl -fsSL -o podman-linux-amd64.tar.gz.asc https://github.com/trentapple/podman-static/releases/latest/download/podman-linux-amd64.tar.gz.asc
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys F21FFB49829AC71EEDC6AD1E7D6456922DAE0D70
gpg --batch --verify podman-linux-amd64.tar.gz.asc podman-linux-amd64.tar.gz
```
_It is possible for this to fail due to desync/unavailable key servers. If that is the case then please retry._

Download a specific version:
```sh
VERSION=<VERSION>
curl -fsSL -o podman-linux-amd64.tar.gz https://github.com/trentapple/podman-static/releases/download/$VERSION/podman-linux-amd64.tar.gz
```

Install the binaries and configuration on your host after you've inspected the archive:
```sh
tar -xzf podman-linux-amd64.tar.gz
sudo cp -r podman-linux-amd64/usr podman-linux-amd64/etc /
```

_If you have docker installed on the same host it might be broken until you remove the newly installed `/usr/local/bin/runc` binary since older docker versions are not compatible with the latest runc version provided here while podman is also compatible with the older runc version that comes e.g. with docker 1.19 on Ubuntu._

To install podman on a host without having any root privileges, you need to copy the binaries and configuration into your home directory and adjust the binary paths within the configuration correspondingly.
For more information see [podman's rootless installation instructions](https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md).

### Host configuration

The following binaries should be installed on your host:
* `iptables`
* `nsenter`
* `uidmap` (for rootless mode)

[nftables](https://netfilter.org/projects/nftables/) ([with or without optional iptables-nft wrapper](https://github.com/containers/netavark/pull/883))

In order to run rootless containers that use multiple uids/gids you may want to set up a uid/gid mapping for your user on your host:
```
sudo sh -c "echo $(id -un):100000:200000 >> /etc/subuid"
sudo sh -c "echo $(id -gn):100000:200000 >> /etc/subgid"
```
_Please esure you only successfully run these mapping commands one time. If you run them multiple times you will have extra mappings that will not be used and the system may not operate as expected._

For support applications / scripts that rely on the `docker` command one quick option is to link `podman` as follows:
```sh
sudo ln -s /usr/local/bin/podman /usr/local/bin/docker
```

_There is also an equivalent docker socket that can be used by podman for applications that leverage the docker API._

Before updating binaries on your host please terminate all corresponding processes.  

### Restart containers on boot

To restart containers with restart-policy=always on boot, enable the `podman-restart` systemd service:
```sh
systemctl enable podman-restart
```

### Binary usage example

```sh
podman run alpine:latest echo hello from podman
```

## Default persistent storage location

The default storage location depends on the user (may vary based on `STORAGE_DRIVER` environment variable or `--storage-driver` flag)
* root: For `root` storage is located at `/var/lib/containers/storage`.
* rootless: For an _unprivileged user_ storage is located at `~/.local/share/containers/storage`.

* Default configuration (depending on if `CONTAINERS_CONF` environment variable or `--config` flag is set)
	* rootless: `~/.config/containers/contains.conf` (user-specific)
	* root: `/etc/containers/containers.conf` (system-wide)

## Local build & test

```sh
make images test
```
