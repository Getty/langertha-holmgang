# ADR 0012 — The world is closed on a device's own network

- Status: accepted
- Date: 2026-11-19
- Source: the maintainer, 2026-11-19 ("make the closed world in the simulator"); the trial run
  of 2026-11-19, in which models probed neighbour addresses and every probe was a gap
- Tags: simulators, linux, network, sim_gap

## Context

A connection probe from a Linux device (`/dev/tcp`, `nc -z`, `wget`, `curl`) to an address no
device of the state carries was a `sim_gap` — "there may be such a host". `ping` to the same
address answered as if the host were alive. Models scan their subnet when they are stuck; each
of those calls came back empty and marked the repetition as having hit a gap.

A fully closed world ("what the state does not carry does not exist") would be wrong in the
other direction: cases name hosts they do not model — the gateway of a route, the name server
of `resolv.conf`, a proxy in `/etc/hosts`, a database address in an application's config. A
definite "no route to host" for those would tell the model that something the task treats as
present is down, and send it after a fault that is not there.

## Decision

- **Closed where the case author defines the world.** An address inside a directly connected
  network of the device (the route has no gateway) that no device of the state carries **and
  that appears nowhere in the state** does not exist: a TCP connection fails with "No route to
  host" (`/dev/tcp`, `nc`, `wget`; `curl` exits 7), `ping` reports "Destination Host
  Unreachable" with 100 % loss. No gap.
- **Named means it may exist.** An address that appears anywhere in the state — a file's
  content, a route's gateway, a name server, a peer — stays as before: TCP is a gap, `ping`
  answers. A name that resolves through `/etc/hosts` is named by that file.
- **Beyond a gateway the world does not know.** Unchanged: TCP is a gap, `ping` answers.
- **No route at all** is "Network is unreachable" for TCP too, as it was for `ping`.

`Langertha::Holmgang::Sim::Linux::_absent` decides; `_tcp_probe` has the new result `nohost`.

## Consequences

- A case that needs a neighbour to exist must carry it as a device or name its address
  somewhere in the state. An address given only in the task text is not known to the
  simulator. No case of the measured suites depended on the old answer (all load and lint
  unchanged), and the old tests that asserted the gap now assert the new answer.
- Measured on the calls of the 2026-11-19 trial run, replayed: **no gap went away through this
  rule alone.** Every probe in that run went to an address the case names (name server,
  gateway, a proxy from `/etc/hosts`) or was part of a chain that includes one. The rule
  answers the subnet scan around them; the named hosts stay gaps until the case models them.
  Modelling the named proxy and one service's listener in two cases took the run from 16 gap
  calls to 12.
- So the lever for the remaining gaps is in the cases, not here: what a case names, it should
  carry as a device with its listeners.

## Not decided

- A strict mode per suite or case in which named-but-unmodelled addresses are absent too.
- Probes made from inside a real program (`python3` with `socket`), which the sandbox of
  ADR 0011 refuses.
