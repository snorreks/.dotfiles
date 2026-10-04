//! Kill safety: the rules that decide *whether a process may be signalled*.
//!
//! `ports::kill_port` answers "what is listening on this port"; this module
//! answers "is it safe to kill that". Splitting them keeps the /proc walking
//! (mechanical, platform-dependent) apart from the policy (security
//! decisions, worth testing hard) and keeps the policy testable without any
//! real process being terminated.
//!
//! Three distinct failure modes are closed here, and each is a separate
//! defence rather than three names for one check:
//!
//!   1. **Wrong owner.** The daemon is a user process; nothing it should be
//!      killing is a different user's process. A UID mismatch is refused, so a
//!      root-owned system service on a port is reported, never signalled.
//!   2. **PID reuse.** Between discovering that PID 4242 holds the listening
//!      socket and signalling it, the process can exit and the number be
//!      reused by something unrelated. Signalling by number alone would kill
//!      that unrelated process. A pidfd opened at *discovery* time pins the
//!      exact process; where the kernel has no pidfd, a start-time comparison
//!      is the equivalent.
//!   3. **Protected targets.** Management processes and their ports — sshd,
//!      tailscaled, this dashboard — are never targets, whatever their UID or
//!      port. The vocabulary is borrowed from `kill-switch.sh` so the two
//!      mechanisms cannot drift into disagreeing about what "management
//!      process" means.

use std::collections::HashSet;
use std::sync::Arc;

/// A process we refuse to signal, and why. Surfaced to the operator so a
/// refusal is diagnosable rather than a bare "nothing happened".
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// The dashboard may not kill itself; that is the process serving this
    /// very request.
    SelfPort { port: u16 },
    /// The port belongs to the management plane, not to a workload.
    ManagementPort { port: u16, service: &'static str },
    /// The listening process runs as a different user.
    ForeignUid { pid: u32, expected: u32, found: u32 },
    /// The process we found is gone, or is a different process now.
    NotTheSameProcess { pid: u32 },
    /// No process holds the port any more.
    Gone,
}

/// Ports whose listener is part of the management plane and is therefore never
/// a kill target.
///
/// This is the port-level counterpart of the name-based protection in
/// `kill-switch.sh`. Ports are listed because a name check cannot help when the
/// attacker picks the port: `/api/kill` takes a port number, so protection
/// has to be keyed on the port as well as on the resolved process.
///
/// The dashboard's own port is deliberately NOT in this table. It is protected
/// by `self_port`, which tracks the *running* configuration. Hard-coding 3333
/// here would both duplicate that rule and be wrong in the other direction:
/// on a host where the daemon has been moved to, say, 4545, something else
/// holding 3333 is a legitimate target.
pub const MANAGEMENT_PORTS: &[(u16, &str)] = &[
    (22, "sshd"),
    (5335, "moshi-hook"),
    (7456, "collie"),
];

/// Executable names that are never kill targets, whatever port they hold.
///
/// Mirrors the "management processes are never targeted" rule in
/// `kill-switch.sh`; kept here so the dashboard cannot kill the way back out
/// even if a management service is listening on an unexpected port.
pub const PROTECTED_NAMES: &[&str] = &[
    "herdr",
    "collie",
    "moshi-hook",
    "sys-daemon",
    "sshd",
    "tailscaled",
    "aged",
    "ns-maint",
    "kill-switch",
];

/// Is `port` reserved for the management plane?
///
/// `self_port` is the dashboard's own port, which is protected even when it is
/// not one of the well-known values — including when the operator has moved it
/// to something unremarkable.
pub fn is_management_port(port: u16, self_port: u16) -> Option<&'static str> {
    if port == self_port {
        return Some("dev-ports dashboard");
    }
    MANAGEMENT_PORTS
        .iter()
        .find(|(p, _)| *p == port)
        .map(|(_, name)| *name)
}

/// Is a process whose executable basename is `name` protected?
pub fn is_protected_name(name: &str) -> bool {
    let base = std::path::Path::new(name)
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| name.to_string());
    PROTECTED_NAMES.contains(&base.as_str())
}

/// Refuse the whole operation if any discovered process is protected.
///
/// Killing the three workload PIDs and skipping the one `sshd` that happens to
/// hold the same port would still be a surprising half-result, and the caller
/// asked to stop "the thing on this port". Refusing outright keeps the
/// contract simple: either the port is a kill target, or it is not.
pub fn check_targets(targets: &[Target]) -> Result<(), Refusal> {
    for t in targets {
        if let Some(service) = is_management_port(t.port, t.self_port) {
            return Err(Refusal::ManagementPort {
                port: t.port,
                service,
            });
        }
        if let Some(name) = t.name.as_deref() {
            if is_protected_name(name) {
                return Err(Refusal::ManagementPort {
                    port: t.port,
                    service: "management process",
                });
            }
        }
        if t.uid != t.expected_uid {
            return Err(Refusal::ForeignUid {
                pid: t.pid,
                expected: t.expected_uid,
                found: t.uid,
            });
        }
    }
    Ok(())
}

/// A process discovered on a port, with the identity needed to prove it is
/// still the same process at signal time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub pid: u32,
    pub port: u16,
    pub self_port: u16,
    pub uid: u32,
    pub expected_uid: u32,
    pub name: Option<String>,
    /// Field 22 of `/proc/<pid>/stat`, in clock ticks since boot. Together
    /// with the pid this is the process's identity for reuse purposes.
    pub start_time: u64,
    /// A pidfd opened at *discovery* time, if the kernel supports one.
    ///
    /// This is the whole point of the field. Opening the pidfd here rather
    /// than inside `signal_target` is what makes PID reuse impossible rather
    /// than merely unlikely: a pidfd opened now refers to this process even
    /// after it exits and the number is reused, but a pidfd opened *later*
    /// refers to whatever holds the number by then, which reopens exactly the
    /// window a pidfd is supposed to close.
    pub pidfd: Option<PidFd>,
}

// ── /proc readers ───────────────────────────────────────────────────────────

/// Real UID owning `pid`, from `/proc/<pid>/status`.
pub fn process_uid(pid: u32) -> Option<u32> {
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("Uid:") {
            let first = rest.split_whitespace().next()?;
            return first.parse().ok();
        }
    }
    None
}

/// Field 22 of `/proc/<pid>/stat`: process start time in clock ticks since
/// boot. Uniquely identifies a process for as long as the pid is not reused
/// for a *different* start time.
///
/// The comm field (field 2) may itself contain spaces and parentheses, so the
/// split is done from the last `)` rather than by whitespace.
pub fn process_start_time(pid: u32) -> Option<u64> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let close = stat.rfind(')')?;
    let rest = stat.get(close + 1..)?;
    // After `pid (comm)` comes state as field 3, so starttime is the 20th
    // field of `rest`.
    rest.split_whitespace().nth(19)?.parse().ok()
}

/// Executable basename for `pid`, preferring cmdline over comm.
pub fn process_name(pid: u32) -> Option<String> {
    let from_cmdline = std::fs::read_to_string(format!("/proc/{pid}/cmdline"))
        .ok()
        .and_then(|s| {
            let first = s.split('\0').next().unwrap_or("").to_string();
            if first.is_empty() {
                return None;
            }
            let base = std::path::Path::new(&first)
                .file_name()?
                .to_string_lossy()
                .to_string();
            let base = base.trim_start_matches('.').to_string();
            if base.is_empty() {
                None
            } else {
                Some(base)
            }
        });
    if from_cmdline.is_some() {
        return from_cmdline;
    }
    let comm = std::fs::read_to_string(format!("/proc/{pid}/comm")).ok()?;
    let comm = comm.trim().trim_start_matches('.').to_string();
    if comm.is_empty() {
        None
    } else {
        Some(comm)
    }
}

/// This process's real UID, the only owner we are willing to kill as.
pub fn self_uid() -> u32 {
    // Safe: `geteuid` always succeeds and cannot fail.
    unsafe { libc::geteuid() }
}

// ── signalling ──────────────────────────────────────────────────────────────

/// How the signal was delivered, or refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SignalOutcome {
    /// Delivered through a pidfd — immune to pid reuse by construction.
    PidFd,
    /// Delivered after re-confirming start time — the pre-pidfd equivalent.
    StartTimeVerified,
    /// Refused: the pid was reused or the process exited.
    Reused(Refusal),
    /// The kernel refused the syscall for a reason we cannot classify.
    Failed(String),
}

extern "C" {
    fn syscall(num: libc::c_long, ...) -> libc::c_long;
}

/// An open pidfd, held for as long as the target is live.
///
/// Wrapped in an `Arc` because `Target` is cloned around: a bare `RawFd` would
/// be closed once per clone and leave the others signalling a recycled fd.
/// The close happens exactly once, when the last clone drops.
///
/// `PartialEq` is pointer identity, not fd number: two pidfds for the same
/// process are different pins, and comparing raw numbers would make two
/// distinct targets look equal.
#[derive(Clone)]
pub struct PidFd(Arc<PidFdInner>);

impl std::fmt::Debug for PidFd {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "PidFd({})", self.as_raw())
    }
}

impl PartialEq for PidFd {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}

impl Eq for PidFd {}

struct PidFdInner {
    fd: std::sync::atomic::AtomicI32,
}

impl Drop for PidFdInner {
    fn drop(&mut self) {
        let fd = self
            .fd
            .swap(-1, std::sync::atomic::Ordering::SeqCst);
        if fd >= 0 {
            unsafe { libc::close(fd) };
        }
    }
}

impl PidFd {
    fn new(fd: i32) -> Self {
        PidFd(Arc::new(PidFdInner {
            fd: std::sync::atomic::AtomicI32::new(fd),
        }))
    }

    fn as_raw(&self) -> i32 {
        self.0.fd.load(std::sync::atomic::Ordering::SeqCst)
    }
}

/// Open a pidfd for `pid`, pinning that exact process for the kernel.
///
/// Linux 5.3+. A pidfd cannot be recycled: once open, it refers to the
/// process it was opened for even after that process has exited and its pid
/// has been reused. Returns `None` on kernels without `pidfd_open`.
///
/// Call this at *discovery* time and keep the result — see [`Target::pidfd`].
pub fn pidfd_open(pid: u32) -> Option<PidFd> {
    let rc = unsafe {
        syscall(
            libc::SYS_pidfd_open,
            pid as libc::c_int,
            0 as libc::c_uint,
        )
    };
    if rc < 0 {
        None
    } else {
        Some(PidFd::new(rc as i32))
    }
}

/// Send `signal` through an already-open pidfd.
pub fn pidfd_send_signal(pidfd: &PidFd, signal: i32) -> bool {
    let fd = pidfd.as_raw();
    if fd < 0 {
        return false;
    }
    let rc = unsafe {
        syscall(
            libc::SYS_pidfd_send_signal,
            fd as libc::c_int,
            signal as libc::c_int,
            std::ptr::null::<libc::siginfo_t>(),
            0 as libc::c_uint,
        )
    };
    rc == 0
}

pub const SIGTERM: i32 = libc::SIGTERM;
pub const SIGKILL: i32 = libc::SIGKILL;

/// Signal `target`, but only if it is still the process we identified.
///
/// Prefers the pidfd captured at discovery time. That fd names one specific
/// process and keeps naming it after the pid is reused, so this path has no
/// reuse window at all — not a narrow one, none.
///
/// Where the kernel has no pidfd, re-reads the start time immediately before
/// signalling. That narrows the race to the microseconds between the read and
/// the signal rather than removing it, which is why the pidfd path is preferred
/// and why the fallback is reported honestly in [`SignalOutcome`] rather than
/// being presented as equivalent.
pub fn signal_target(target: &Target, signal: i32) -> SignalOutcome {
    if let Some(pidfd) = target.pidfd.as_ref() {
        // ESRCH here means the process we pinned is gone — which is the
        // correct answer, not a failure: the pin held even if the pid did not.
        return if pidfd_send_signal(pidfd, signal) {
            SignalOutcome::PidFd
        } else {
            SignalOutcome::Reused(Refusal::NotTheSameProcess { pid: target.pid })
        };
    }

    // Fallback: confirm identity as late as possible.
    if process_start_time(target.pid) == Some(target.start_time) {
        let rc = unsafe { libc::kill(target.pid as i32, signal) };
        if rc == 0 {
            SignalOutcome::StartTimeVerified
        } else {
            SignalOutcome::Reused(Refusal::NotTheSameProcess { pid: target.pid })
        }
    } else {
        SignalOutcome::Reused(Refusal::NotTheSameProcess { pid: target.pid })
    }
}

/// Build the kill target list for `pid` on `port`, refusing if the identity
/// checks fail. Shared by the real path and the tests so both agree.
///
/// This is the discovery step, and it is where the pidfd is taken: see
/// [`Target::pidfd`] for why it must not be deferred to signal time.
pub fn describe(pid: u32, port: u16, self_port: u16) -> Result<Target, Refusal> {
    let uid = process_uid(pid).ok_or(Refusal::Gone)?;
    let start_time = process_start_time(pid).ok_or(Refusal::Gone)?;
    Ok(Target {
        pid,
        port,
        self_port,
        uid,
        expected_uid: self_uid(),
        name: process_name(pid),
        start_time,
        pidfd: pidfd_open(pid),
    })
}

/// Is `pid` still running?
///
/// A terminated-but-unreaped child is a zombie: `/proc/<pid>/status` still
/// exists and `kill(pid, 0)` still succeeds, so both of the obvious checks
/// report it as alive. It is not — it has done everything, it is just waiting
/// to be reaped. Treating it as alive makes a caller wait forever for a
/// process that already exited, so the state field is checked explicitly.
pub fn process_is_running(pid: u32) -> bool {
    let Some(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok() else {
        return false;
    };
    let Some(close) = stat.rfind(')') else {
        return false;
    };
    // Field 3 (state) is the first whitespace-separated token after
    // `pid (comm)`. 'Z' is zombie, 'X'/'x' is dead.
    match stat.get(close + 1..).and_then(|r| r.split_whitespace().next()) {
        Some("Z") | Some("X") | Some("x") => false,
        Some(_) => true,
        None => false,
    }
}

/// Ports currently held by any PID this daemon is willing to consider.
/// Exposed for tests that assert the discovery path stays narrow.
pub fn ports_seen(ports: &HashSet<u16>) -> Vec<u16> {
    let mut v: Vec<u16> = ports.iter().copied().collect();
    v.sort_unstable();
    v
}