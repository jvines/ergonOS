# Services

Things that run in the background, **off by default**, started explicitly and
reaped when idle.

The rule comes from `bin/llama-server.sh`, and from the reason it exists: that
model is useful intermittently, not continuously, and holding ~19 GB resident
for something used a few times a day is the wrong trade. Every service here is
the same shape. A distro that idles at 4 GB because it started six daemons on
your behalf is a distro people uninstall.

    ergon svc list
    ergon svc up marimo
    ergon svc down marimo
    ergon svc reap              # what the timer calls

## Writing one

One directory, three small scripts and a meta file:

    meta        DESCRIPTION, IDLE_MIN (0 disables reaping), PORT
    up.sh       start it. Must be idempotent.
    down.sh     stop it.
    status.sh   exit 0 if running. Cheap: this runs on a timer.

`IDLE_MIN` is honoured by `reap`, which decides idleness from the service's own
log mtime where it has one -- the same trick llama-server.sh uses, because a
server that has answered nothing has written nothing.
