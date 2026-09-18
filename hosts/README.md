# Per-host overrides

Generalises a pattern this repo already used three times — `zsh/hosts/`,
`sysctl/hosts/` and `env-overrides/` — into one directory, because the Arch
laptop is the first machine whose monitor layout, scaling and battery settings
are genuinely its own rather than fleet defaults.

```
hosts/<hostname>/
  host.env        sourced by install.sh first; declares GRAPHICAL, PROFILE
  hyprland.lua    linked to ~/.config/hypr/hosts/<hostname>.lua; monitors, scale
  ssh.conf        linked to ~/.ssh/config.d/10-host.conf (Include wins: OpenSSH
                  keeps the FIRST value, and ssh/config Includes config.d first)
  systemd/*       copied into ~/.config/systemd/user/
```

Costs the other machines nothing. `install.sh`'s `link()` opens with
`[ -e "$src" ] || return 0`, so every host-scoped link is a silent no-op on a
host with no directory here — which today is all of them.

`zsh/hosts/` and `sysctl/hosts/` are deliberately **not** migrated into this.
Converge them later, on purpose, while watching: moving `sysctl/hosts/mochi.conf`
wrong means mochi quietly loses its panic-on-RCU-stall drop-in, and that is the
one host where that file is doing real work.

The hostname is set at install time by `bin/arch-bootstrap.sh`, which prompts
for it and writes `/etc/hostname`. `bin/provision-arch.sh` then scaffolds
`hosts/$(hostname -s)/` from `hosts/_template/` if it does not exist yet.
