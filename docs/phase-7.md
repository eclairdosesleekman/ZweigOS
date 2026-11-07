# Phase 7: transactional process lifecycle

## Goal

Phase 7 composes the process metadata from Phase 4, ELF resource planning from
Phase 6, and the Phase 6 object-authority ledger into one explicit lifecycle.
The coordinator makes resource preparation, start commitment, cancellation,
termination, teardown, and parent reaping follow a bounded and retryable order.

This is still a policy/runtime coordination milestone. It does not claim that
a new seL4 TCB is created or that a staged ELF image has executed.

## Lifecycle

`src/posix/process_lifecycle.zig` provides a fixed-size coordinator with these
transitions:

```text
ProcessManager.spawn()
        |
        v
     starting
        |
        | prepare(resource plan + atomic authority reservation)
        v
     prepared
       /   \
      /     \ abort (release reservations; record failed status)
 commit      v
    |       aborted/failed
    v             |
   running         |
    |              |
    | exit(status) |
    v              |
   exited          |
      \            /
       \          /
        v        v
       parent reap
            |
            | release remaining reservations,
            | revoke delegated descendants,
            | verify direct parent/child relation
            v
       process record removed
```

The implementation enforces:

- A process must already exist in `starting` state before it can be prepared.
- The resource plan owner must exactly match the generation-checked process ID.
- A full resource batch is reserved before the coordinator publishes a
  `prepared` launch record.
- `commit` is permitted once and only for a prepared process.
- `abort` is permitted only before commit; it releases all reservations and
  marks the process failed with the internal cancellation status `-125`.
- `exit` is accepted only for a running process and records the exit status.
- `reap` checks direct parent/child ownership before releasing any resource.

## Resource cleanup and retry

Every resource plan is bounded by the Phase 6 object-authority maximum. The
coordinator remembers whether each root reservation was successfully released.
For roots that permit delegation, it first revokes all delegated descendants,
then destroys the root object reservation. Roots without the grant right cannot
have delegated capabilities through this ledger and are destroyed directly.

If teardown fails part way through, the per-resource progress flags preserve
the completed work. A subsequent cleanup attempt skips already-destroyed roots
instead of trying to destroy stale handles again.

When an exited process still has children, its own object reservations are
released, but the process metadata is retained because Phase 4 requires
descendants to be reaped first. A later call to `reap` completes the metadata
removal after the descendants are gone.

`ProcessManager.childOf` provides a direct-child check so a caller cannot
mistakenly release a sibling's or unrelated process's resources by supplying
only a PID.

## API

`src/posix/process_lifecycle.zig` exposes:

- `Manager.prepare(processes, authority, child, plan)`: reserve the complete
  resource set for a starting process and return a launch ticket;
- `Manager.commit(processes, process_id)`: mark the prepared process running
  in the policy state machine;
- `Manager.abort(processes, authority, process_id)`: roll back a prepared
  launch and record a waitable failure;
- `Manager.exit(processes, process_id, exit_code)`: record termination after
  the runtime has stopped the process; and
- `Manager.reap(processes, authority, parent_id, child_pid)`: revoke grants,
  destroy reservations, and delegate final metadata reaping to Phase 4.

The coordinator uses fixed arrays only and performs no dynamic allocation.

## Runtime boundary

Phase 7 does not:

- create, configure, resume, suspend, or delete a real seL4 TCB;
- allocate CSpace slots or create a process CNode;
- retype Untyped memory into Frame or other kernel objects;
- map Frame capabilities into a new VSpace;
- install the ELF entry point and initial stack pointer in a TCB context;
- authenticate the caller over the existing POSIX PP channel; or
- implement working `spawn`, `execve`, or `waitpid` syscalls.

The `commit` transition is deliberately named as a policy commitment, not a
kernel resume. The existing QEMU test still boots the statically composed
bootstrap Protection Domains only.

## Validation

The unified `make test` suite covers the complete prepare/commit/exit/reap
path, cancellation rollback, rejection of non-child reaping before any resource
is released, and revocation of delegated descendants. It also re-runs all
Phase 2-6 tests.

The Phase 7 GitHub Actions workflow runs Zig formatting, all unit tests, the
three Microkit Protection Domain links, Microkit system composition, and the
existing QEMU bootstrap smoke test.
