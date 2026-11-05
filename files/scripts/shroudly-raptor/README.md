# Raptor Shroudly (v0.1.0)

**Status: incomplete prototype; not a functional proxy.**

The current daemon binds to `127.0.0.1:10808` and prints a terminal status
summary. Its request handler does not forward traffic: ordinary HTTP requests
receive `501 Not Implemented`, and `CONNECT` is acknowledged without opening
an upstream tunnel. The dashboard's active mode and monitored-app count are
placeholder values. The current source contains no desktop GUI.

Advanced packet mode is deliberately disabled. The former cleanup path used
`nft flush ruleset`, which could delete firewall rules belonging to the host,
containers, VPNs, and unrelated applications. Do not add global firewall
cleanup back; any future packet-mode implementation must use an isolated,
Shroudly-owned nftables table and remove only that table.

The current prototype must not be configured as an application's proxy. A
functional, documented proxy implementation and the desktop UI are still
outstanding. It must support only ordinary, authorized network use and must
not be presented as a way to evade managed-network restrictions.

## Build and test

```sh
cargo build --workspace
cargo test --workspace
```
