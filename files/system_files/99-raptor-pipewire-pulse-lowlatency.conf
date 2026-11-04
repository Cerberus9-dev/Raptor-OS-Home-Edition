# Raptor OS: pipewire-pulse low-latency config
#
# WHY THIS FILE EXISTS:
# Electron and Chromium-based apps (Vesktop/Discord, Spotify's desktop client)
# do not talk to PipeWire's native graph directly on Linux — they use the
# PulseAudio compatibility layer, a separate daemon called pipewire-pulse
# with its OWN independent context, config, and latency negotiation settings.
#
# 99-raptor-pipewire-lowlatency.conf (installed to pipewire.conf.d/) only
# tunes the native PipeWire graph. It has zero effect on pipewire-pulse,
# which was running on PipeWire's stock defaults the entire time — explaining
# static specifically in Electron/Chromium apps while native clients (games,
# mpv) were already fixed by the earlier headroom/quantum changes.
#
# pipewire-pulse uses "pulse.*" namespaced properties for latency, NOT
# default.clock.quantum — these are a different property set entirely and
# must be configured separately here.

context.properties = {
    log.level = 2
}

context.modules = [
    # Same real-time scheduling boost as the native PipeWire graph.
    # Without this, pipewire-pulse runs at normal priority and can be
    # scheduled late under any CPU contention (a game running, a build
    # compiling), causing exactly the kind of buffer underrun that sounds
    # like static or crackling — worse under load, which lines up with it
    # being intermittent rather than constant.
    { name  = libpipewire-module-rt
      args  = {
          nice.level   = -11
          rt.prio      = 88
          rt.time.soft = 200000
          rt.time.hard = 400000
      }
      flags = [ ifexists nofail ]
    }
]

pulse.properties = {
    # Request sizes: 512 samples at 48kHz ≈ 10.7ms, matching the native
    # PipeWire quantum in 99-raptor-pipewire-lowlatency.conf so both layers
    # negotiate the same buffer size instead of fighting each other.
    pulse.min.req       = 256/48000
    pulse.default.req   = 512/48000
    pulse.max.req       = 2048/48000

    pulse.min.quantum     = 256/48000
    pulse.default.quantum = 512/48000
    pulse.max.quantum     = 2048/48000

    # How long an idle stream stays allocated before pipewire-pulse tears it
    # down. Too short causes an audible re-negotiation glitch every time
    # Spotify pauses between tracks or Discord goes quiet during a call —
    # each of those can sound exactly like a brief crackle or static burst
    # as the stream restarts. 5s covers normal pauses without holding
    # resources open indefinitely.
    pulse.idle.timeout = 5
}
