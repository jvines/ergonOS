#!/usr/bin/env bash
# Framework 13 AMD. Runs under provisioning, with sudo available. Idempotent.
#
# Only what is true of this model and cannot be detected. Lid handling, the ABM
# block, power profiles and auto-brightness used to live here too; they are
# capabilities now (bin/ergon-hardware), and apply to any machine that has them.
set -uo pipefail
ok()   { printf '   ok  %s\n' "$*"; }
skip() { printf '   ·   %s\n' "$*"; }

# The internal mic does not come up on the right UCM profile. One pactl call,
# lifted from Omarchy's hardware tree. Needs a running PipeWire, so this is a
# no-op under provisioning from a TTY and applies on the next graphical login.
CARD=$(pactl list cards short 2>/dev/null | awk '/acp|Family/ {print $2; exit}' || true)
if [ -n "$CARD" ]; then
  pactl set-card-profile "$CARD" "HiFi (Mic1, Mic2, Speaker)" 2>/dev/null \
    && ok "mic profile set on $CARD" || skip "mic profile not applicable to $CARD"
else
  skip "no acp audio card visible (no session, or not this hardware)"
fi
