import AppKit
import Foundation
import Darwin

/// Live system-utilization metrics for the tab-bar widget. Samples
/// CPU, RAM, and aggregate network throughput once per second using
/// macOS's Mach host_statistics + getifaddrs APIs (no shell-outs).
/// Cheap enough to run continuously — the whole refresh is a few
/// syscalls, on the order of microseconds.
@MainActor
final class SystemStats: ObservableObject {
    @Published var cpuPercent: Double = 0
    @Published var ramPercent: Double = 0
    @Published var netDownKBps: Double = 0
    @Published var netUpKBps: Double = 0

    /// Rolling history of the last `historyDepth` samples, used by
    /// the widget's sparkline + popover graphs. Oldest first,
    /// newest last.
    @Published var cpuHistory: [Double] = []
    @Published var ramHistory: [Double] = []
    private let historyDepth = 30

    private var lastCpuTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32) = (0, 0, 0, 0)
    private var lastNetRx: UInt64 = 0
    private var lastNetTx: UInt64 = 0
    private var lastNetTime: TimeInterval = 0
    private var timer: Timer?
    private var activeObs: NSObjectProtocol?
    private var inactiveObs: NSObjectProtocol?

    init() {
        // Prime the deltas so the first published values aren't a
        // spike from a zero-baseline.
        _ = readCPU()
        _ = readNetwork()

        // Only sample while Conterm is the ACTIVE app. A stats pill is
        // only useful when you're looking at it; a terminal frequently
        // sits in the background where sampling + re-rendering it every
        // couple seconds is pure battery waste. Foreground → 2 s timer
        // (coalesced via tolerance). Background → timer fully stopped.
        let nc = NotificationCenter.default
        activeObs = nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startTimer() }
        }
        inactiveObs = nc.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopTimer() }
        }
        if NSApp?.isActive ?? true { startTimer() }
        refresh()
    }

    private func startTimer() {
        guard timer == nil else { return }
        // `tolerance` lets macOS coalesce the wakeup with other timers
        // (fewer CPU package wakes = less battery).
        // 3 s: each tick re-renders the glass-heavy window (SwiftUI
        // displaylist + CA commit), which is the periodic foreground
        // cost. 3 s is still perfectly glanceable for CPU/RAM/net and
        // cuts that render frequency by a third vs 2 s.
        let t = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 0.8
        timer = t
        refresh()   // immediate refresh so it isn't stale on refocus
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    isolated deinit {
        timer?.invalidate()
        if let activeObs { NotificationCenter.default.removeObserver(activeObs) }
        if let inactiveObs { NotificationCenter.default.removeObserver(inactiveObs) }
    }

    private func refresh() {
        let cpu = readCPU()
        let ram = readRAM()
        let net = readNetwork()

        // Only mutate a @Published property when its *visible*
        // representation actually changes. SwiftUI re-renders (and
        // re-rasterizes glyphs) on every assignment to a @Published —
        // publishing 12.1→12.4 when the pill only shows "12%" caused a
        // needless full-widget redraw every second, which (since the
        // widget displays the app's own CPU%) fed back into itself and
        // pinned ~35% CPU forever. Comparing the rounded/formatted
        // value first makes an idle machine an idle widget.
        if Int(cpu.rounded()) != Int(cpuPercent.rounded()) { cpuPercent = cpu }
        if Int(ram.rounded()) != Int(ramPercent.rounded()) { ramPercent = ram }
        if Self.rateLabel(net.rx) != Self.rateLabel(netDownKBps) { netDownKBps = net.rx }
        if Self.rateLabel(net.tx) != Self.rateLabel(netUpKBps)   { netUpKBps = net.tx }

        // History drives the sparklines — append a sample every tick
        // (rounded so tiny noise doesn't force a path recompute when
        // the line is visually identical).
        let cpuR = (cpu * 2).rounded() / 2
        let ramR = (ram * 2).rounded() / 2
        if cpuHistory.last.map({ abs($0 - cpuR) >= 0.5 }) ?? true || cpuHistory.count < historyDepth {
            cpuHistory.append(cpuR)
            if cpuHistory.count > historyDepth { cpuHistory.removeFirst(cpuHistory.count - historyDepth) }
        }
        if ramHistory.last.map({ abs($0 - ramR) >= 0.5 }) ?? true || ramHistory.count < historyDepth {
            ramHistory.append(ramR)
            if ramHistory.count > historyDepth { ramHistory.removeFirst(ramHistory.count - historyDepth) }
        }
    }

    /// Mirrors the pill's `formatRate` so throttling compares the
    /// exact string the user sees.
    nonisolated static func rateLabel(_ kbps: Double) -> String {
        let k = max(0, kbps)
        if k < 1.0   { return "0K" }
        if k < 1024  { return String(format: "%.0fK", k) }
        return         String(format: "%.1fM", k / 1024)
    }

    // MARK: - CPU

    private func readCPU() -> Double {
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride /
            MemoryLayout<integer_t>.stride
        )
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return cpuPercent }

        let user = info.cpu_ticks.0
        let sys  = info.cpu_ticks.1
        let idle = info.cpu_ticks.2
        let nice = info.cpu_ticks.3

        let dUser = user &- lastCpuTicks.user
        let dSys  = sys  &- lastCpuTicks.sys
        let dIdle = idle &- lastCpuTicks.idle
        let dNice = nice &- lastCpuTicks.nice
        lastCpuTicks = (user, sys, idle, nice)

        let total = UInt64(dUser) + UInt64(dSys) + UInt64(dIdle) + UInt64(dNice)
        guard total > 0 else { return cpuPercent }
        let busy = UInt64(dUser) + UInt64(dSys) + UInt64(dNice)
        return Double(busy) / Double(total) * 100
    }

    // MARK: - RAM

    private func readRAM() -> Double {
        var size = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride /
            MemoryLayout<integer_t>.stride
        )
        var info = vm_statistics64()
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return ramPercent }

        // vm_kernel_page_size is a global mutable; query it via
        // host_page_size for concurrency safety.
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pageSizeU64 = UInt64(pageSize)
        let total = ProcessInfo.processInfo.physicalMemory
        // "Used" in macOS's Activity Monitor sense: active + wired +
        // speculative + compressed. Free + inactive + purgeable are
        // available for reuse.
        let used = (UInt64(info.active_count)
                  + UInt64(info.wire_count)
                  + UInt64(info.speculative_count)
                  + UInt64(info.compressor_page_count)) * pageSizeU64
        guard total > 0 else { return ramPercent }
        return Double(used) / Double(total) * 100
    }

    // MARK: - Network

    private func readNetwork() -> (rx: Double, tx: Double) {
        var rxTotal: UInt64 = 0
        var txTotal: UInt64 = 0
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return (netDownKBps, netUpKBps) }
        defer { if let ifap = ifap { freeifaddrs(ifap) } }

        var ptr = ifap
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            // Only AF_LINK entries carry the if_data with byte counts.
            guard let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            // Skip loopback and pseudo-interfaces — they'd otherwise
            // pollute the rate with self-traffic.
            if name.hasPrefix("lo") || name.hasPrefix("utun")
                || name.hasPrefix("awdl") || name.hasPrefix("llw")
                || name.hasPrefix("anpi") || name.hasPrefix("ap")
                || name.hasPrefix("gif") || name.hasPrefix("stf") {
                continue
            }
            guard let data = cur.pointee.ifa_data?
                .assumingMemoryBound(to: if_data.self) else { continue }
            rxTotal += UInt64(data.pointee.ifi_ibytes)
            txTotal += UInt64(data.pointee.ifi_obytes)
        }

        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastNetTime
        defer {
            lastNetRx = rxTotal
            lastNetTx = txTotal
            lastNetTime = now
        }
        guard lastNetTime > 0, dt > 0 else { return (0, 0) }
        let dRx = rxTotal > lastNetRx ? rxTotal - lastNetRx : 0
        let dTx = txTotal > lastNetTx ? txTotal - lastNetTx : 0
        return (Double(dRx) / 1024 / dt, Double(dTx) / 1024 / dt)
    }
}
