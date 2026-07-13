# demo/agent.pp — M6 devops-complete demo: the per-host agent.
#
# BYTE-IDENTICAL on every host (that is the whole point — a member's
# identity comes entirely from its CLI invocation, never from the
# program text): loads the domain libraries, registers write authority
# for its own fs root and for process, and registers a report-only
# health probe over its own greeter's status file. Run under
# `--desired-object <hash> <shared-root> --member-name <host>`, so this
# file's OWN return value is irrelevant — the dispatcher's published
# slice overrides it entirely (tests/051's dispatcher/agent split). This
# file exists purely to register authority + probes before
# Domains.run_all converges the pulled slice.
#
# argv (after `--`): ROOT STATUS-PATH
# ROOT        — this host's fs-domain-managed root (bin/, etc/); must
# match the HOSTS-ROOT/<host> deploy.pp computed
# STATUS-PATH — this host's greeter status file (RUN-ROOT/<host>/status,
# deliberately OUTSIDE root — see deploy.pp's header)
#
# Invocation shape (per host, differing only in --member-name/--grant/
# the two argv strings — never in this file's bytes):
# pp --watch --member-name <HOST> --desired-object <HASH> <SHARED> \
# --grant fs:<ROOT>:rw --grant fs:<STATUS-PATH>:ro --grant process \
# demo/agent.pp -- <ROOT> <STATUS-PATH>

load("stdlib/list.pp")
load("stdlib/map.pp")
load("stdlib/string.pp")
load("stdlib/domain-fs.pp")
load("stdlib/domain-proc.pp")

let (root = nth(0, argv()), status-path = nth(1, argv())) {
  register-fs-domain(root, cap-restrict(current-capabilities(), root, :wo))
  register-proc-domain(current-capabilities())
  register-probe("greeter-health",
# register-proc-domain's write-cap: `cap-restrict` with a path scope
# against a bare CapProcess is a documented no-op — capabilities.ml's
# check_process has no CapRestrict arm, so a cap-restrict'd CapProcess
# would be silently unusable. Pass (current-capabilities) UNNARROWED,
# per the plan's own caveat.


fn() { string-trim(slurp(status-path)) }, cap-restrict(current-capabilities(), status-path, :ro))
  nil
}
