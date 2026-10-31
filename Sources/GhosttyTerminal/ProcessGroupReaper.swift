import Darwin
import Foundation

/// 표면을 닫은 뒤에도 남는 자식을 정리한다.
///
/// libghostty는 표면을 닫을 때 자식의 프로세스 그룹에 SIGHUP을 한 번 보내고 직속 자식(맥에서는 `login`)만
/// 기다린다. Claude Code는 SIGHUP도 SIGTERM도 무시하므로(Fine 실측), login이 끝난 뒤에도 PTY를 잃은 채
/// 살아남아 화면으로는 닿을 수 없는데 메모리는 쥔 유령이 된다(10/31 이 패키지의 실험: 신호를 무시하는
/// 자식이 표면을 닫은 뒤에도 살아 있었다). 그래서 닫기 전에 그룹의 구성원을 적어 두고, 유예 뒤에도
/// 살아 있으면 SIGKILL로 끝낸다.
///
/// PID는 재사용되므로 구성원은 (pid, 시작 시각)으로 적고, 신호 직전에 같은 프로세스인지 대조한다.
struct ProcessGroupReaper {
    struct Member: Hashable {
        let pid: pid_t
        let startSeconds: Int
        let startMicros: Int32
    }

    let members: [Member]

    /// `groups`(프로세스 그룹 id)에 지금 속한 프로세스들. 이 앱 자신은 빼 둔다.
    static func snapshot(groups: [pid_t]) -> ProcessGroupReaper {
        var seen = Set<Member>()
        for group in Set(groups) where group > 1 && group != getpgrp() {
            for process in processes(inGroup: group) where process.pid != getpid() {
                seen.insert(process)
            }
        }
        return ProcessGroupReaper(members: Array(seen))
    }

    /// SIGTERM을 보내고 `grace`초 안에 끝나지 않은 구성원에게 SIGKILL. `synchronous`면 이 스레드에서
    /// 끝까지 기다린다(앱 종료 경로 — 비동기로 미루면 실행될 기회가 없다).
    func reap(grace: TimeInterval, synchronous: Bool) {
        guard !members.isEmpty else { return }
        let work = {
            signalAlive(SIGTERM)
            let deadline = Date().addingTimeInterval(grace)
            while Date() < deadline, !alive().isEmpty { usleep(20_000) }
            signalAlive(SIGKILL)
            // SIGKILL은 비동기로 닿는다. 앱 종료 경로가 그 사이에 끝나지 않게 사라질 때까지 잠깐 본다.
            let killDeadline = Date().addingTimeInterval(0.5)
            while Date() < killDeadline, !alive().isEmpty { usleep(10_000) }
        }
        if synchronous { work() } else { DispatchQueue.global(qos: .utility).async(execute: work) }
    }

    func alive() -> [Member] {
        members.filter { Self.identity(of: $0.pid) == $0 }
    }

    private func signalAlive(_ signal: Int32) {
        for member in alive() { kill(member.pid, signal) }
    }

    static func identity(of pid: pid_t) -> Member? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        // 좀비는 이미 끝났다(부모가 거두기만 기다린다).
        guard info.kp_proc.p_stat != SZOMB else { return nil }
        let start = info.kp_proc.p_starttime
        return Member(pid: pid, startSeconds: start.tv_sec, startMicros: start.tv_usec)
    }

    static func processes(inGroup group: pid_t) -> [Member] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 8
        var list = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &list, &size, nil, 0) == 0 else { return [] }
        return list.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap { info in
            guard info.kp_proc.p_stat != SZOMB else { return nil }
            let start = info.kp_proc.p_starttime
            return Member(pid: info.kp_proc.p_pid, startSeconds: start.tv_sec, startMicros: start.tv_usec)
        }
    }
}

/// 프로세스 그룹의 구성원. 표면의 직속 자식은 맥에서 `login`이라, 그 안의 에이전트 pid(대화 등록부가
/// pid로 적힌다)는 그룹을 훑어 찾는다.
public enum ProcessGroup {
    /// `group`에 지금 속한 살아 있는 프로세스들(시작 순서가 아니라 커널이 돌려준 순서).
    public static func members(of group: pid_t) -> [pid_t] {
        guard group > 1 else { return [] }
        return ProcessGroupReaper.processes(inGroup: group).map(\.pid)
    }
}
