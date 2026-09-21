# Sourced by guest-desktop.sh after provisioning: uses its ok/bad/note, $U, $H.
#
# The off-disk backup, end to end on the installed system: provisioning put
# restic and the timers in, a repository is created, /home is backed up from a
# btrfs snapshot, a file is deleted and comes back byte-identical, and doctor
# says what state it is in. Against a local path always; against the NAS as
# well when BACKUP_NAS names an NFS export -- that is the restore rehearsed
# from the NAS, the same standard the rollback is held to.

echo "--- off-disk backup ---"
B="$H/ergonOS/bin/ergon-backup"
backup_reset() { rm -rf /etc/ergon/backup.conf /etc/ergon/backup.key /var/lib/ergon/backup; }
backup_reset   # this disk is reused across runs

pacman -Q restic >/dev/null 2>&1 && ok "restic installed by provisioning" || bad "restic is not installed"
systemctl is-enabled ergon-backup.timer >/dev/null 2>&1 \
  && ok "ergon-backup.timer enabled by provisioning" || bad "ergon-backup.timer is not enabled"
systemctl is-enabled ergon-backup-check.timer >/dev/null 2>&1 \
  && ok "ergon-backup-check.timer enabled" || bad "ergon-backup-check.timer is not enabled"
# Unconfigured, the service must be skipped by its condition, not fail daily.
systemctl start ergon-backup.service 2>/dev/null
[ "$(systemctl show -p Result --value ergon-backup.service)" = success ] \
  && ok "unconfigured, the daily run is a no-op rather than a failure" \
  || bad "the unconfigured service failed: $(systemctl show -p Result --value ergon-backup.service)"
d=$(su - "$U" -c "$H/ergonOS/bin/ergon-doctor" 2>&1 | grep -E ' backup ')
printf '%s\n' "$d" | grep -q 'nothing leaves this disk' \
  && ok "doctor: an unconfigured machine is told nothing leaves the disk" || bad "doctor unconfigured: $d"

backup_roundtrip() {  # backup_roundtrip LABEL REPO [ALLOW_LOCAL]
  local label=$1 repo=$2 allow=${3:-} canary="$H/ergon-backup-canary.txt" sum out
  backup_reset
  head -c 4096 /dev/urandom | base64 > "$canary"; chown "$U:$U" "$canary"
  sum=$(sha256sum "$canary" | cut -d' ' -f1)
  out=$(ERGON_BACKUP_ALLOW_LOCAL=$allow "$B" init "$repo" 2>&1) && ok "$label: repository created" || { bad "$label: init failed"; printf '%s\n' "$out" | tail -5; return; }
  # Through the unit, as the timer would run it -- not the script by hand.
  if systemctl start ergon-backup.service \
     && [ "$(systemctl show -p Result --value ergon-backup.service)" = success ]; then
    ok "$label: ergon-backup.service backed up /home"
  else
    bad "$label: the service failed"; tail -5 /var/lib/ergon/backup/last-run.log 2>/dev/null; return
  fi
  "$B" restic snapshots --json 2>/dev/null | grep -q '"/home"' \
    && ok "$label: the snapshot records /home, not the btrfs snapshot's path" || bad "$label: snapshot paths wrong"
  grep -q "^ergon-backup: from snapshot" /var/lib/ergon/backup/last-run.log \
    && ok "$label: backed up from a read-only btrfs snapshot" || bad "$label: backed up the live tree, not a snapshot"
  btrfs subvolume list / 2>/dev/null | grep -q 'ergon-backup' \
    && bad "$label: the btrfs snapshot was left behind" || ok "$label: the btrfs snapshot was removed"
  rm -f "$canary"
  out=$("$B" restore "$canary" --to "/var/tmp/restore-$label" 2>&1) || { bad "$label: restore failed"; printf '%s\n' "$out" | tail -5; }
  [ "$(su - "$U" -c "sha256sum '/var/tmp/restore-$label$canary'" 2>/dev/null | cut -d' ' -f1)" = "$sum" ] \
    && ok "$label: the deleted file came back byte-identical, readable by $U" || bad "$label: restored file missing or different"
  d=$(su - "$U" -c "$H/ergonOS/bin/ergon-doctor" 2>&1 | grep -E ' backup ')
  printf '%s\n' "$d" | grep -qE 'ok +backup +last good backup' \
    && ok "$label: doctor reports the backup as fresh" || bad "$label: doctor: $d"
  "$B" check >/dev/null 2>&1 && grep -q "^last_check=[0-9]* ok" /var/lib/ergon/backup/status \
    && ok "$label: prune + read-back check passed" || bad "$label: check failed or was skipped"
  rm -rf "/var/tmp/restore-$label"
}

# A path that is not a mounted share is this disk: init must refuse it, or an
# unmounted NAS becomes a green "off-disk" backup on the SSD it should survive.
backup_reset
out=$("$B" init /nas-not-mounted/ergon-backup 2>&1) \
  && bad "init accepted a repository on the same disk as /home" \
  || { printf '%s\n' "$out" | grep -q "same disk" && ok "init refuses a repository on the same disk as /home" || bad "init refused, but not for the right reason: $out"; }
[ ! -f /etc/ergon/backup.conf ] && ok "a refused init leaves no config" || bad "config written despite the refusal"

backup_roundtrip local /var/tmp/ergon-backup-repo 1   # same disk on purpose: the suite must not need the NAS
rm -rf /var/tmp/ergon-backup-repo

if [ -n "${BACKUP_NAS:-}" ]; then
  mkdir -p /nas
  if mount -t nfs4 -o soft,timeo=100,retrans=2 "$BACKUP_NAS" /nas 2>/tmp/nfs.err; then
    rehearsal="/nas/ergonOS/backup-rehearsal/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$rehearsal"
    backup_roundtrip nas "$rehearsal"
    rm -rf "$rehearsal"; umount /nas
  else
    bad "could not mount $BACKUP_NAS: $(tail -1 /tmp/nfs.err)"
  fi
else
  note "no BACKUP_NAS given; the restore from the NAS was not rehearsed this run"
fi
backup_reset
