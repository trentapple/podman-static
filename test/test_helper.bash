#!/bin/bash

# ARGS: DOCKER_RUN_OPTS
testPortMapping() {
	$DOCKER run --rm -i --privileged --entrypoint /bin/sh --pull=never $@ - <<-EOF
		set -ex
		podman pull nginxinc/nginx-unprivileged:mainline-alpine-slim
		podman run -p 8182:8080 --entrypoint=/bin/sh nginxinc/nginx-unprivileged:mainline-alpine-slim -c 'timeout 15 nginx -g "daemon off;"' &
		sleep 5
		wget -O - localhost:8182
	EOF
}
