#!/usr/bin/env bash
# The llm bundle (ERGON-148) against stubs: the backend package follows the GPU
# bin/ergon-gpu finds, the ledger records exactly what went in so remove takes
# it, and `ergon llm` downloads nothing on its own. Seconds, no root, no network.
# DOES NOT COVER: that ollama runs on the card; that needs the hardware.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { local w="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "   ok   $w"; else FAIL=$((FAIL+1)); echo "   FAIL $w"; fi; }
hasx() { grep -qxF -- "$2" "$1" 2>/dev/null; }
has()  { grep -qF -- "$2" "$1" 2>/dev/null; }
not()  { ! "$@"; }

E=$T/ergon
mkdir -p "$E/bin" "$E/packages/bundles" "$E/hosts/testhost" "$T/stub" "$T/log" "$T/home"
cp "$REPO/bin/ergon-bundle" "$REPO/bin/ergon-gpu" "$REPO/bin/ergon-llm" "$E/bin/"
cp -r "$REPO/packages/bundles/llm" "$E/packages/bundles/"
cp -r "$REPO/packages/pacman" "$REPO/packages/aur" "$REPO/packages/python" "$E/packages/"
cp -r "$REPO/hardware" "$E/"; cp "$REPO/hosts/_template/host.env" "$E/hosts/testhost/"
printf '#!/usr/bin/env bash\necho "  nvidia: no"\n' > "$E/bin/ergon-hardware"
printf '#!/usr/bin/env bash\n[ "$1" != path ] || echo "$TEST_ROOT/venv"\n' > "$E/bin/pyfleet"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$T/stub/sudo"
printf '#!/usr/bin/env bash\necho testhost\n' > "$T/stub/hostname"
cat > "$T/stub/pacman" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/pacman"
[ "$*" != -Qq ] || { cat "$TEST_ROOT/pacdb"; exit 0; }
op=$1; shift; names=(); seen=0
for a in "$@"; do if [ "$seen" = 1 ]; then names+=("$a"); elif [ "$a" = -- ]; then seen=1; fi; done
case $op in
  -S)   for p in "${names[@]}"; do grep -qxF -- "$p" "$TEST_ROOT/pacdb" || echo "$p" >> "$TEST_ROOT/pacdb"; done ;;
  -Rns) for p in "${names[@]}"; do grep -vxF -- "$p" "$TEST_ROOT/pacdb" > "$TEST_ROOT/pacdb.n"; mv "$TEST_ROOT/pacdb.n" "$TEST_ROOT/pacdb"; done ;;
  -Qi|-Qq) for p in "${names[@]}"; do grep -qxF -- "$p" "$TEST_ROOT/pacdb" || exit 1; done ;;
esac
EOS
for c in ollama systemctl; do printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$TEST_ROOT/log/%s"\n' "$c" "$c" > "$T/stub/$c"; done
chmod +x "$T/stub"/* "$E/bin"/*
export TEST_ROOT=$T HOME=$T/home XDG_STATE_HOME=$T/state XDG_CACHE_HOME=$T/cache ERGON=$E PATH="$T/stub:$PATH"

# a sysfs with one display controller of the given PCI vendor (more: pass many)
gpus() {  # gpus VENDOR...
  rm -rf "$T/root"; local i=0 v
  for v in "$@"; do
    d=$T/root/sys/bus/pci/devices/0000:0$i:00.0; mkdir -p "$d"
    printf '0x030000\n' > "$d/class"; printf '%s\n' "$v" > "$d/vendor"; printf '0x1111\n' > "$d/device"; i=$((i+1))
  done
  export ERGON_SYSROOT=$T/root
}
fresh() { cp "$REPO/hosts/_template/host.env" "$E/hosts/testhost/"; : > "$T/pacdb"; : > "$T/log/pacman"; rm -rf "$T/state"; }
add() { "$E/bin/ergon-bundle" add --yes llm >/dev/null 2>&1; }

check "--vendors: AMD" bash -c "$(declare -f gpus); T=$T; gpus 0x1002; [ \"\$($E/bin/ergon-gpu --vendors)\" = amd ]"
gpus 0x10de; fresh; add
check "NVIDIA: ollama and ollama-cuda" hasx "$T/log/pacman" "-S --needed --noconfirm -- ollama ollama-cuda"
check "  and no ROCm" not has "$T/log/pacman" ollama-rocm
check "  the ledger records both" bash -c "grep -qx 'llm pacman ollama-cuda' '$T/state/ergon/bundle-ledger' && grep -qx 'llm pacman ollama' '$T/state/ergon/bundle-ledger'"
"$E/bin/ergon-bundle" remove --yes llm >/dev/null 2>&1
check "remove takes the backend too" bash -c "! grep -qx ollama-cuda '$T/pacdb' && ! grep -qx ollama '$T/pacdb'"
gpus 0x1002; fresh; add
check "AMD: ollama and ollama-rocm" hasx "$T/log/pacman" "-S --needed --noconfirm -- ollama ollama-rocm"
gpus 0x8086; fresh; add
check "Intel only: the CPU build, nothing else" hasx "$T/log/pacman" "-S --needed --noconfirm -- ollama"
gpus; fresh; add
check "no GPU: the CPU build" hasx "$T/log/pacman" "-S --needed --noconfirm -- ollama"
gpus 0x1002 0x10de; fresh; add
check "AMD iGPU beside NVIDIA: CUDA only" bash -c "grep -q ollama-cuda '$T/log/pacman' && ! grep -q ollama-rocm '$T/log/pacman'"

echo ollama > "$T/pacdb"
"$E/bin/ergon-llm" status >/dev/null 2>&1
check "status starts nothing" not has "$T/log/systemctl" start
"$E/bin/ergon-llm" start >/dev/null 2>&1
check "start uses the service, never enable" bash -c "grep -q 'start ollama.service' '$T/log/systemctl' && ! grep -q enable '$T/log/systemctl'"
"$E/bin/ergon-llm" run llama3.2 hi >/dev/null 2>&1
check "run passes the model to ollama" hasx "$T/log/ollama" "run llama3.2 hi"
check "  and nothing was pulled by us" not has "$T/log/ollama" pull
check "run without a model is refused" bash -c "! '$E/bin/ergon-llm' run >/dev/null 2>&1"
echo "$PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
