#!/bin/bash

# This script is just a helper to save you typing, and allows you to
# reconfigure the lxd reverse-proxy for email and web traffic. This can be used
# if your IP address has changed (e.g. moving ISP, or being allocated a new IP
# by your existing ISP).

# It can also be used to remove proxying for web traffic. For example, I
# decided to use an HTTP reverse proxy so that I could run other web services
# besides webmail, so I commented out the add_proxy_port lines for http/s and
# ran this script, and I was left with just smtp and esmtp being handled by
# lxc.


. "functions"
. "config"

lxc config device remove "${CONTAINER_NAME}" http
lxc config device remove "${CONTAINER_NAME}" https
lxc config device remove "${CONTAINER_NAME}" smtp
lxc config device remove "${CONTAINER_NAME}" esmtp

CONTAINER_IP=$(lxc config device get ${CONTAINER_NAME} eth0 ipv4.address)

add_proxy_port "${CONTAINER_NAME}" "http" "${HOST_IPv4}:80" "${CONTAINER_IP}:80"
add_proxy_port "${CONTAINER_NAME}" "https" "${HOST_IPv4}:443" "${CONTAINER_IP}:443"
add_proxy_port "${CONTAINER_NAME}" "smtp" "${HOST_IPv4}:25" "${CONTAINER_IP}:25"
add_proxy_port "${CONTAINER_NAME}" "esmtp" "${HOST_IPv4}:587" "${CONTAINER_IP}:587"
