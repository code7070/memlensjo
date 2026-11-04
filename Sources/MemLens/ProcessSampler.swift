import Darwin
import Foundation

private struct BundleInfo: Sendable {
    let path: String
    let name: String
    let id: String?
    let version: String?
}

/// Reads every process the current user may inspect and groups them by app.
/// An actor so its caches are never touched by two samples at once.
actor ProcessSampler {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    private let host: mach_port_t = mach_host_self()
    private let pageSize: UInt64
    private let responsibleSymbol: UnsafeMutableRawPointer?
    private var argBuffer: [UInt8]
    private var kindCache: [String: String?] = [:]
    private var bundleCache: [String: BundleInfo?] = [:]

    init() {
        pageSize = ProcessSampler.sysctlUInt64("hw.pagesize") ?? 16_384
        // Private SPI that Activity Monitor-style grouping relies on; absent → path-based grouping only.
        responsibleSymbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid")
        let argMax = Int(ProcessSampler.sysctlUInt64("kern.argmax") ?? 262_144)
        argBuffer = [UInt8](repeating: 0, count: argMax)
    }

    func sample() -> Snapshot {
        var samples: [ProcSample] = []
        var responsibleOf: [pid_t: pid_t] = [:]
        var pathOf: [pid_t: String] = [:]
        var seen = Set<String>()
        var unreadable = 0

        for pid in listPids() where pid > 0 {
            let path = pidPath(pid)
            if let path { pathOf[pid] = path }
            guard let bsd = bsdInfo(pid), let footprint = footprint(pid) else {
                // A path means it's still alive (owned by root/another user); no path → it just exited.
                if path != nil { unreadable += 1 }
                continue
            }
            let start = UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec)
            let key = "\(pid)-\(start)"
            seen.insert(key)
            let kind: String?
            if let cached = kindCache[key] {
                kind = cached
            } else {
                kind = processKind(pid)
                kindCache[key] = kind
            }
            let name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? procName(pid)
            samples.append(ProcSample(pid: pid, startTime: start, name: name, path: path ?? "",
                                      footprint: footprint, kind: kind))
            responsibleOf[pid] = responsiblePid(pid)
        }
        kindCache = kindCache.filter { seen.contains($0.key) }

        var groups: [String: AppGroup] = [:]
        for proc in samples {
            let responsiblePath = responsibleOf[proc.pid].flatMap { pathOf[$0] ?? pidPath($0) }
            // Own bundle first (keeps Chromium helpers and the Claude Code CLI apart),
            // then the responsible app (WebKit XPC services → Safari/Mail).
            let bundle = bundleInfo(forExecutable: proc.path)
                ?? responsiblePath.flatMap { bundleInfo(forExecutable: $0) }
            let key = bundle?.path ?? "proc:\(proc.name)"
            if groups[key] == nil {
                groups[key] = AppGroup(id: key, name: bundle?.name ?? proc.name, bundlePath: bundle?.path,
                                       bundleID: bundle?.id, version: bundle?.version,
                                       footprint: 0, processes: [])
            }
            groups[key]!.footprint += proc.footprint
            groups[key]!.processes.append(proc)
        }

        let sorted = groups.values.map { group -> AppGroup in
            var g = group
            g.processes.sort { $0.footprint > $1.footprint }
            return g
        }.sorted { $0.footprint > $1.footprint }

        return Snapshot(system: systemStats(), groups: sorted, unreadableCount: unreadable)
    }

    // MARK: - libproc

    private func listPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        // proc_listallpids returns a pid count, not bytes.
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(0, min(count, Int32(pids.count))))))
    }

    private func pidPath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        return len > 0 ? String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
    }

    private func procName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let len = proc_name(pid, &buf, UInt32(buf.count))
        return len > 0 ? String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : "pid \(pid)"
    }

    private func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// Same number Activity Monitor shows in its Memory column.
    private func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    private func responsiblePid(_ pid: pid_t) -> pid_t? {
        guard let responsibleSymbol else { return nil }
        let fn = unsafeBitCast(responsibleSymbol, to: ResponsibleFn.self)
        let r = fn(pid)
        return r > 0 && r != pid ? r : nil
    }

    // MARK: - argv (KERN_PROCARGS2)

    private func processKind(_ pid: pid_t) -> String? {
        let args = processArgs(pid)
        if args.contains("--extension-process") { return "extension" }
        guard let type = args.first(where: { $0.hasPrefix("--type=") })?.dropFirst(7) else { return nil }
        if type == "utility",
           let sub = args.first(where: { $0.hasPrefix("--utility-sub-type=") })?.split(separator: "=").last {
            return "utility:\(sub)"
        }
        return String(type)
    }

    private func processArgs(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argBuffer.count
        let ok = argBuffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) } == 0
        guard ok, size > MemoryLayout<Int32>.size else { return [] }

        return argBuffer.withUnsafeBytes { raw -> [String] in
            let bytes = raw.bindMemory(to: UInt8.self)
            let argc = Int(raw.loadUnaligned(as: Int32.self))
            guard argc > 0, argc < 10_000 else { return [] }
            var i = MemoryLayout<Int32>.size
            while i < size && bytes[i] != 0 { i += 1 }   // exec path
            while i < size && bytes[i] == 0 { i += 1 }   // padding NULs
            var args: [String] = []
            while args.count < argc && i < size {
                let start = i
                while i < size && bytes[i] != 0 { i += 1 }
                args.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self))
                i += 1
            }
            return args
        }
    }

    // MARK: - Bundles

    /// Outermost real `.app` bundle (one with Contents/Info.plist) that contains the executable.
    private func bundleInfo(forExecutable path: String) -> BundleInfo? {
        guard !path.isEmpty else { return nil }
        if let cached = bundleCache[path] { return cached }
        var result: BundleInfo?
        var prefix = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            prefix += "/" + component
            guard component.hasSuffix(".app"),
                  FileManager.default.fileExists(atPath: prefix + "/Contents/Info.plist") else { continue }
            let plist = NSDictionary(contentsOfFile: prefix + "/Contents/Info.plist") as? [String: Any] ?? [:]
            let fallback = String(component.dropLast(4))
            let rawName = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? fallback
            // Some apps (WhatsApp) prefix their name with invisible direction marks.
            let name = String(String.UnicodeScalarView(rawName.unicodeScalars.filter { $0.properties.generalCategory != .format }))
                .trimmingCharacters(in: .whitespaces)
            result = BundleInfo(path: prefix, name: name.isEmpty ? fallback : name,
                                id: plist["CFBundleIdentifier"] as? String,
                                version: plist["CFBundleShortVersionString"] as? String)
            break
        }
        bundleCache[path] = result
        return result
    }

    // MARK: - System

    func systemStats() -> SystemStats {
        var stats = SystemStats()
        stats.total = ProcessSampler.sysctlUInt64("hw.memsize") ?? 0

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let anonymous = UInt64(vm.internal_page_count)
            let purgeable = UInt64(vm.purgeable_count)
            stats.appMemory = (anonymous - min(purgeable, anonymous)) * pageSize
            stats.wired = UInt64(vm.wire_count) * pageSize
            stats.compressed = UInt64(vm.compressor_page_count) * pageSize
            stats.used = stats.appMemory + stats.wired + stats.compressed
            stats.cached = (UInt64(vm.external_page_count) + purgeable) * pageSize
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            stats.swapUsed = swap.xsu_used
            stats.swapTotal = swap.xsu_total
        }
        return stats
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // Some keys are 32-bit; size tells which.
        return size == MemoryLayout<UInt32>.size ? UInt64(UInt32(truncatingIfNeeded: value)) : value
    }
}
