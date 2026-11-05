# Shroudly Raptor — experimental prototype

Shroudly is not currently a working proxy. The Rust executable prints a status
message and exits. It does not open a local listener, forward traffic, launch
applications through a proxy, or provide a desktop GUI.

The previous listener incorrectly acknowledged HTTP CONNECT requests without
creating an upstream tunnel. That listener has been removed so clients cannot
mistake a successful handshake for working network access. Application
launch-through-proxy is disabled until a real, tested implementation exists.

Advanced packet mode is deliberately disabled and makes no nftables changes.
Do not configure applications to use Shroudly or rely on it for network access.

A successful CI compile only validates the prototype's Rust code; it does not
mean proxy functionality is implemented.

## Upstream attribution

The original **Shroudly** project was created by **umutxyp** and is a
**Codeshare Technology Ltd** product:
https://github.com/umutxyp/Shroudly

The upstream project is licensed under the MIT License. This Raptor prototype
is an independent integration and does not include or claim to reproduce the
upstream packet engine. It is not an official release or an endorsed build of
the original project. This credit identifies the original creator and project;
it does not imply that the upstream implementation is present here.
