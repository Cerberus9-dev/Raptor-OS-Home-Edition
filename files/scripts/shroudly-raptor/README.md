# Shroudly Raptor

Raptor's Shroudly integration is being rebuilt in stages around the upstream
Shroudly project by **umutxyp**, a Codeshare Technology Ltd product.

Upstream project: https://github.com/umutxyp/Shroudly

## Current implementation status

The current Raptor binary is an early local-monitoring build. It can detect
selected running Linux game clients and display an honest status summary. It
does **not** currently provide the upstream desktop UI, proxy engine, DNS
forwarding, VPN routing, or packet-processing modes. No traffic is redirected,
and no proxy listener is opened. The application must not be treated as a
working network proxy.

The dashboard intentionally reports only information it can observe. It does
not display simulated running states, fake port numbers, or placeholder app
counts.

## Raptor integration work

The intended integration preserves upstream attribution and compatible
non-circumvention application functionality while adding Raptor-specific
reliability, local application monitoring, and GameMode integration. The
network-circumvention engine and packet-filter evasion functionality are not
part of this Raptor integration.

Planned work is staged and must be marked implemented only after it is built
and tested:

- Desktop interface and settings adapted for Raptor.
- Real application lifecycle and local process monitoring.
- Raptor GameMode integration for local performance profiles.
- Diagnostics, logs, error reporting, and safe shutdown.
- Honest capability reporting for each supported platform.

## Upstream license and attribution

The original Shroudly project is maintained by **umutxyp** and is a
**Codeshare Technology Ltd** product. The upstream repository is licensed
under the MIT License. Its copyright and license notice are preserved in
[UPSTREAM-LICENSE](UPSTREAM-LICENSE).

This repository's Raptor-specific code is an independent integration. It is
not an official upstream release and is not endorsed by Codeshare Technology
Ltd.
