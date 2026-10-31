import SwiftUI
import AppKit
import Combine

let gb = 1024.0 * 1024 * 1024

// MARK: - Dados

struct Mem: Equatable {
    var app = 0.0, wired = 0.0, compressed = 0.0, cached = 0.0
    var free = 0.0, uncompressed = 0.0, swapUsed = 0.0, swapTotal = 0.0
    var total = Double(ProcessInfo.processInfo.physicalMemory)
    var pressure = 1
    var used: Double { app + wired + compressed }
    var fraction: Double { min(used / total, 1) }
}

func readMem() -> Mem {
    var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    var s = vm_statistics64_data_t()
    _ = withUnsafeMutablePointer(to: &s) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
        }
    }
    let page = Double(vm_kernel_page_size)
    var m = Mem()
    // mesma conta do Monitor de Atividade
    m.app = Double(max(Int64(s.internal_page_count) - Int64(s.purgeable_count), 0)) * page
    m.wired = Double(s.wire_count) * page
    m.compressed = Double(s.compressor_page_count) * page
    m.cached = Double(s.external_page_count) * page
    m.free = Double(s.free_count) * page
    m.uncompressed = Double(s.total_uncompressed_pages_in_compressor) * page
    var sw = xsw_usage(), swl = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &sw, &swl, nil, 0) == 0 { m.swapUsed = Double(sw.xsu_used); m.swapTotal = Double(sw.xsu_total) }
    var p: Int32 = 1
    var l = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &p, &l, nil, 0)
    m.pressure = Int(p)
    return m
}

/// Cada quem lê a CPU com o seu próprio «contador anterior». Se dois partilhassem um só,
/// uma leitura encurtava a janela da outra e aparecia 0 % ou 100 % do nada.
final class CPUMeter {
    private var last: (UInt32, UInt32, UInt32, UInt32)?
    func read() -> Double {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        let t = info.cpu_ticks
        defer { last = t }
        guard let l = last else { return 0 }
        let busy = Double(t.0 &- l.0) + Double(t.1 &- l.1) + Double(t.3 &- l.3)
        let all = busy + Double(t.2 &- l.2)
        return all > 0 ? busy / all : 0
    }
}
let panelCPU = CPUMeter(), historyCPU = CPUMeter()

func sysctlInt(_ name: String) -> Int {
    var v: Int32 = 0, l = MemoryLayout<Int32>.size
    sysctlbyname(name, &v, &l, nil, 0)
    return Int(v)
}
/// Núcleos de desempenho (P) e de eficiência (E). Nos chips Apple, os de eficiência vêm primeiro na lista de núcleos.
let perfCores = sysctlInt("hw.perflevel0.logicalcpu"), effCores = sysctlInt("hw.perflevel1.logicalcpu")

/// Uso de cada núcleo (0…1) e o total dividido em usuário/sistema, desde a leitura anterior.
final class CoreMeter {
    private var last: [(busy: Double, idle: Double, user: Double, sys: Double)] = []
    func read() -> (cores: [Double], user: Double, sys: Double) {
        var n: natural_t = 0, cnt: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) == KERN_SUCCESS, let info else { return ([], 0, 0) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(cnt) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var now: [(busy: Double, idle: Double, user: Double, sys: Double)] = []
        for i in 0..<Int(n) {
            let b = i * Int(CPU_STATE_MAX)
            let u = Double(info[b + Int(CPU_STATE_USER)]), sy = Double(info[b + Int(CPU_STATE_SYSTEM)])
            let ni = Double(info[b + Int(CPU_STATE_NICE)]), id = Double(info[b + Int(CPU_STATE_IDLE)])
            now.append((u + sy + ni, id, u + ni, sy))
        }
        let prev = last
        last = now
        guard prev.count == now.count else { return (Array(repeating: 0, count: now.count), 0, 0) }
        var cores: [Double] = [], all = 0.0, user = 0.0, sys = 0.0
        for (a, p) in zip(now, prev) {
            let busy = max(a.busy - p.busy, 0), idle = max(a.idle - p.idle, 0), total = busy + idle
            cores.append(total > 0 ? busy / total : 0)
            all += total; user += max(a.user - p.user, 0); sys += max(a.sys - p.sys, 0)
        }
        return (cores, all > 0 ? user / all : 0, all > 0 ? sys / all : 0)
    }
}
let coreMeter = CoreMeter()

struct Temps: Equatable {
    var cpuAvg = 0.0, cpuMax = 0.0
    var chips: Double?, ssd: Double?, battery: Double?
}

/// Sensores de temperatura do Mac (chips Apple). Não há API oficial: a leitura usa funções internas do IOKit,
/// carregadas em tempo de execução. Se não existirem (outro macOS/Mac), `read()` devolve nil e o app segue normal.
final class Thermals {
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloat = @convention(c) (CFTypeRef, Int32) -> Double
    private var services: [(name: String, ref: CFTypeRef)] = []
    private var copyEvent: CopyEvent?, getFloat: GetFloat?
    private var client: CFTypeRef?   // tem de viver tanto quanto os serviços: se for liberado, as leituras usam memória morta e o app cai

    init() {
        _ = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(UnsafeMutableRawPointer(bitPattern: -2), n).map { unsafeBitCast($0, to: t) } }
        guard let create = sym("IOHIDEventSystemClientCreate", Create.self), let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServices.self), let copyProp = sym("IOHIDServiceClientCopyProperty", CopyProperty.self),
              let ev = sym("IOHIDServiceClientCopyEvent", CopyEvent.self), let gf = sym("IOHIDEventGetFloatValue", GetFloat.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        self.client = client
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary) // sensores de temperatura
        guard let list = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return }
        services = list.map { ((copyProp($0, "Product" as CFString)?.takeRetainedValue() as? String) ?? "", $0) }
        copyEvent = ev; getFloat = gf
    }

    func read() -> Temps? {
        guard let copyEvent, let getFloat else { return nil }
        var cpu: [Double] = [], chips: [Double] = [], ssd: [Double] = [], bat: [Double] = []
        for s in services {
            guard let e = copyEvent(s.ref, 15, 0, 0)?.takeRetainedValue() else { continue } // 15 = temperatura
            let v = getFloat(e, 15 << 16)
            guard v > 10, v < 120 else { continue } // há sensores sem uso que devolvem valores absurdos
            if s.name.hasPrefix("PMU tdie") { cpu.append(v) } else if s.name.hasPrefix("PMU2 tdie") { chips.append(v) }
            else if s.name.hasPrefix("NAND") { ssd.append(v) } else if s.name.hasPrefix("gas gauge") { bat.append(v) }
        }
        guard !cpu.isEmpty else { return nil }
        func avg(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
        return Temps(cpuAvg: avg(cpu)!, cpuMax: cpu.max()!, chips: avg(chips), ssd: avg(ssd), battery: avg(bat))
    }
}
let thermals = Thermals()

struct Row: Identifiable, Equatable {
    static func == (a: Row, b: Row) -> Bool { a.id == b.id && a.bytes == b.bytes && a.cpu == b.cpu }
    let app: NSRunningApplication
    let bytes: Double
    var cpu = 0.0
    var id: pid_t { app.processIdentifier }
}

/// RSS por app aberto, somando os processos auxiliares que vivem dentro do .app
func readTopApps() -> [Row] {
    let out = shText("/bin/ps", ["-axo", "rss=,pcpu=,command="])
    let me = ProcessInfo.processInfo.processIdentifier
    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && $0.bundleURL != nil && $0.processIdentifier != me
    }
    var total: [pid_t: (bytes: Double, cpu: Double)] = [:]
    for line in out.split(separator: "\n") {
        let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard f.count == 3, let kb = Double(f[0]), let cpu = Double(f[1]) else { continue }
        for a in apps where f[2].hasPrefix(a.bundleURL!.path + "/") {
            let o = total[a.processIdentifier] ?? (0, 0)
            total[a.processIdentifier] = (o.bytes + kb * 1024, o.cpu + cpu)
            break
        }
    }
    return apps.compactMap { a in total[a.processIdentifier].map { Row(app: a, bytes: $0.bytes, cpu: $0.cpu) } }
        .sorted { $0.bytes > $1.bytes }
}

// MARK: - Mais dados do Mac

/// Roda um comando: devolve a saída e se terminou bem. O erro vai para o lixo (um pipe que ninguém lê pode travar o comando).
func run(_ exe: String, _ args: [String]) -> (out: Data, ok: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return (Data(), false) }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (d, p.terminationStatus == 0)
}

@discardableResult func sh(_ exe: String, _ args: [String]) -> Data { run(exe, args).out }
func ok(_ exe: String, _ args: [String]) -> Bool { run(exe, args).ok }

// MARK: - Atualizações (releases do GitHub)

let repoSlug = "nandomontenegro88-spec/mac-memmonitor"
let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"

struct Update { var version: String; var url: URL }

/// 1.10 > 1.9; «1.2» é mais novo que «1.2-beta».
func versionGreater(_ a: String, than b: String) -> Bool {
    func parse(_ v: String) -> (nums: [Int], pre: Bool) {
        let parts = v.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let nums = (parts.first ?? "").split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        return (nums, parts.count > 1)
    }
    let x = parse(a), y = parse(b)
    for i in 0..<max(x.nums.count, y.nums.count) {
        let p = i < x.nums.count ? x.nums[i] : 0, q = i < y.nums.count ? y.nums[i] : 0
        if p != q { return p > q }
    }
    return y.pre && !x.pre
}

/// Lê a linha `lowpowermode` do `pmset -g` pelo último número, sem depender do espaçamento.
func lowPowerOn(_ pmset: String) -> Bool {
    pmset.split(separator: "\n").first { $0.contains("lowpowermode") }
        .flatMap { $0.split(whereSeparator: \.isWhitespace).last }.map(String.init) == "1"
}

func shText(_ exe: String, _ args: [String]) -> String { String(decoding: sh(exe, args), as: UTF8.self) }

struct Batt: Equatable {
    var pct = 0, cycles = 0, adapterW = 0, designmAh = 0, nominalmAh = 0
    var volts = 0.0, amps = 0.0, adapterV = 0.0, adapterA = 0.0
    var charging = false, plugged = false
    var minutes: Int?
    var watts = 0.0   // + a entrar na bateria, − a sair
}

func readBattery() -> Batt? {
    let d = sh("/usr/sbin/ioreg", ["-arn", "AppleSmartBattery"])
    guard let arr = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [[String: Any]], let b = arr.first else { return nil }
    func i(_ k: String) -> Int { (b[k] as? NSNumber)?.intValue ?? 0 }
    var t = Batt()
    t.pct = i("CurrentCapacity")
    t.cycles = i("CycleCount")
    t.charging = (b["IsCharging"] as? Bool) ?? false
    t.plugged = (b["ExternalConnected"] as? Bool) ?? false
    let amp = Int64(bitPattern: (b["InstantAmperage"] as? NSNumber)?.uint64Value ?? 0)
    t.watts = Double(amp) * Double(i("Voltage")) / 1e6
    t.volts = Double(i("Voltage")) / 1000
    t.amps = Double(amp) / 1000
    if let bd = b["BatteryData"] as? [String: Any] {
        t.designmAh = (bd["DesignCapacity"] as? NSNumber)?.intValue ?? 0
        t.nominalmAh = (bd["NominalChargeCapacity"] as? NSNumber)?.intValue ?? 0
    }
    if let ad = b["AdapterDetails"] as? [String: Any] {
        t.adapterW = (ad["Watts"] as? NSNumber)?.intValue ?? 0
        t.adapterV = Double((ad["AdapterVoltage"] as? NSNumber)?.intValue ?? 0) / 1000
        t.adapterA = Double((ad["Current"] as? NSNumber)?.intValue ?? 0) / 1000
    }
    let m = t.charging ? i("AvgTimeToFull") : i("TimeRemaining")
    t.minutes = (m > 0 && m < 65535) ? m : nil // 65535 = ainda a calcular
    return t
}

func readNet() -> (down: Double, up: Double) {
    var d = 0.0, u = 0.0
    for line in shText("/usr/sbin/netstat", ["-ibn"]).split(separator: "\n") {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count >= 10, f[0].hasPrefix("en"), f[2].hasPrefix("<Link"), let i = Double(f[6]), let o = Double(f[9]) else { continue }
        d += i; u += o
    }
    return (d, u)
}

/// tempo desde o arranque, a contar também o repouso (ProcessInfo.systemUptime não conta)
func bootUptime() -> TimeInterval {
    var tv = timeval()
    var l = MemoryLayout<timeval>.size
    sysctlbyname("kern.boottime", &tv, &l, nil, 0)
    return Date().timeIntervalSince1970 - TimeInterval(tv.tv_sec)
}

func fmtMin(_ m: Int) -> String { m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min" }

func fmtRate(_ b: Double) -> String {
    b >= 1_000_000 ? String(format: "%.1f MB/s", b / 1_000_000) : String(format: "%.0f KB/s", b / 1000)
}

func fmtUptime(_ s: TimeInterval) -> String {
    let h = Int(s / 3600)
    return h >= 48 ? "\(h / 24) dias" : h >= 1 ? "\(h) h" : "\(Int(s / 60)) min"
}

struct Sample { var mem: Double; var cpu: Double; var batt: Double? }

/// Os 4 cards abaixo do anel da Memória: o selecionado mostra os detalhes por baixo.
enum MemCard: String, CaseIterable { case apps, system, compressed, available }
enum CPUCard: String, CaseIterable { case live, cores, temp, load }

enum BatCard: String, CaseIterable { case power, charger, health, cycles }
enum HealthCard: String, CaseIterable { case disk, smart, uptime, thermal }

func thermalInfo(_ t: ProcessInfo.ThermalState) -> (title: String, sub: String) {
    switch t {
    case .nominal: return ("Normal", "Sem aquecimento")
    case .fair: return ("Morno", "O Mac está a aquecer um pouco")
    case .serious: return ("Quente", "O macOS já reduz a velocidade")
    default: return ("Muito quente", "Fecha apps pesados e deixa arrefecer")
    }
}

enum Tab: String, CaseIterable { case mem = "Memória", cpu = "CPU", bat = "Bateria", health = "Saúde" }

/// Espaço do disco: `free` é o livre de verdade (o que o Finder mostra); `purgeable` é o que o macOS apaga sozinho se faltar espaço (cache, etc.).
struct DiskInfo: Equatable { var free = 0.0, total = 0.0, purgeable = 0.0 }

struct Live: Equatable { var cpu: Double; var temp: Double? }

/// Tudo o que a aba CPU mostra, num só valor: uma atualização = uma passagem de desenho (e não seis).
struct CPUData: Equatable {
    var total = 0.0
    var cores: [Double] = []
    var userPct = 0.0, sysPct = 0.0
    var temps: Temps?
    var live: [Live] = []     // últimos 60 s, 1 por segundo
    var load = [0.0, 0.0, 0.0]
}

// MARK: - Modelo

final class Model: ObservableObject {
    @Published var tab = Tab.mem
    @Published var memCard = MemCard.apps
    @Published var batCard = BatCard.power
    @Published var healthCard = HealthCard.disk
    @Published var cpuCard = CPUCard.live
    @Published var cpuData = CPUData()
    var cpu: Double { cpuData.total }
    var cores: [Double] { cpuData.cores }
    var userPct: Double { cpuData.userPct }
    var sysPct: Double { cpuData.sysPct }
    var temps: Temps? { cpuData.temps }
    var live: [Live] { cpuData.live }
    var load: [Double] { cpuData.load }
    @Published var diskModel: String?
    @Published var diskSolid: Bool?
    @Published var heroOn: Set<Tab> = []   // abas cujo anel/número já «subiram»: ao voltar a uma aba, a animação repete
    @Published var shown = false   // painel aberto: dispara a entrada animada
    @Published var mem = readMem()
    @Published var rows: [Row] = []
    @Published var cpuRows: [Row] = []
    @Published var history: [Sample] = []
    @Published var busy = false
    @Published var status: String?

    @Published var batt: Batt?
    @Published var healthPct: Int?
    @Published var healthWord: String?
    @Published var lowPower = false
    @Published var smart: String?
    @Published var disk = DiskInfo()
    var diskFree: Double { disk.free }
    var diskTotal: Double { disk.total }
    var diskPurgeable: Double { disk.purgeable }
    @Published var down = 0.0
    @Published var up = 0.0
    @Published var loginItems: [String] = []
    @Published var update: Update?
    @Published var updateState = ""
    private var lastUpdateCheck = Date.distantPast
    private var checkingUpdate = false
    private var refreshing = false          // evita empilhar leituras quando o Mac está lento
    private var lastApps = Date.distantPast
    private var lastMem = Date.distantPast
    private var recording = false
    private var slowRunning: Set<Tab> = []

    private var lastNet: (d: Double, u: Double, t: Date)?
    private var slowStamps: [Tab: Date] = [:]

    /// Só publica se mudou: cada publicação redesenha o painel inteiro.
    func setApps(_ r: [Row]) {
        let top = Array(r.prefix(5)), c = Array(r.sorted { $0.cpu > $1.cpu }.prefix(3))
        if top != rows { rows = top }
        if c != cpuRows { cpuRows = c }
    }

    /// Uma leitura barata no arranque: a 1.ª abertura já tem lista de apps e bateria.
    func prefetch() {
        DispatchQueue.global().async {
            let r = readTopApps(), b = readBattery()
            DispatchQueue.main.async { self.setApps(r); self.batt = b }
        }
    }

    /// Uma amostra de ~16 s (RAM, CPU, bateria), mesmo com o painel fechado; guarda ~2 h para os gráficos.
    func record() {
        guard !recording else { return }
        recording = true
        let m = readMem().fraction, c = historyCPU.read()
        DispatchQueue.global().async {
            let b = readBattery()
            DispatchQueue.main.async {
                self.recording = false
                if let b, b != self.batt { self.batt = b } // a bateria fica fresca (≤16 s) sem ler a cada 2 s
                self.history.append(Sample(mem: m, cpu: c, batt: b.map { Double($0.pct) }))
                if self.history.count > 450 { self.history.removeFirst(self.history.count - 450) }
            }
        }
    }

    func refresh(visible: Bool) {
        let tab = self.tab
        // na aba CPU (1×/s) a RAM só se atualiza a cada 2 s: cada publicação redesenha o painel
        if !visible || tab != .cpu || Date().timeIntervalSince(lastMem) >= 1.9 {
            lastMem = Date()
            let m = readMem()
            if m != mem { mem = m }
        }
        guard visible else { return } // fechado: só a RAM, que alimenta o número da barra
        let c = (panelCPU.read() * 100).rounded() / 100
        if tab == .health {
            let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            let free = Double(v?.volumeAvailableCapacity ?? 0)
            let d = DiskInfo(free: free, total: Double(v?.volumeTotalCapacity ?? 0), purgeable: max(Double(v?.volumeAvailableCapacityForImportantUsage ?? 0) - free, 0))
            if d != disk { disk = d }
        }
        let k = coreMeter.read() // barato; lê sempre para a janela de tempo ser curta quando abres a aba CPU
        if tab == .cpu || tab == .health {
            var d = cpuData
            d.temps = thermals.read()
            if tab == .cpu {
                d.total = c; d.cores = k.cores; d.userPct = k.user; d.sysPct = k.sys
                var l = [0.0, 0.0, 0.0]; getloadavg(&l, 3); d.load = l
                d.live.append(Live(cpu: c, temp: d.temps?.cpuAvg))
                if d.live.count > 60 { d.live.removeFirst(d.live.count - 60) }
            }
            if d != cpuData { cpuData = d } // uma só publicação
        }
        if !refreshing && Date().timeIntervalSince(lastApps) >= 1.9 { // ps/ioreg/netstat: no máx. 1× a cada 2 s, mesmo com a aba CPU a 1 s
            lastApps = Date()
            refreshing = true
            DispatchQueue.global().async {
                let r = tab != .bat ? readTopApps() : nil
                let b = tab == .bat ? readBattery() : nil
                let n = tab == .health ? readNet() : nil
                DispatchQueue.main.async {
                    self.refreshing = false
                    if let r { self.setApps(r) }
                    if let b, b != self.batt { self.batt = b }
                    if let n {
                        let now = Date()
                        // se passou muito tempo desde a última leitura (saíste da aba), não inventa uma velocidade média
                        if let l = self.lastNet, case let dt = now.timeIntervalSince(l.t), dt > 0.5, dt < 5 {
                            self.down = max(n.down - l.d, 0) / dt
                            self.up = max(n.up - l.u, 0) / dt
                        }
                        self.lastNet = (n.down, n.up, now)
                    }
                }
            }
        }
        // lazy: o que é lento só é lido quando a aba é aberta, e no máximo 1× por minuto
        if tab == .bat || tab == .health, Date().timeIntervalSince(slowStamps[tab] ?? .distantPast) > 60 { refreshSlow(for: tab) }
    }

    /// Coisas lentas (system_profiler, diskutil, System Events): cada aba só pede o que mostra
    func refreshSlow(for tab: Tab) {
        guard !slowRunning.contains(tab) else { return }
        slowRunning.insert(tab)
        slowStamps[tab] = Date()
        DispatchQueue.global().async {
            var pct: Int?, word: String?
            if let j = try? JSONSerialization.jsonObject(with: sh("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"])) as? [String: Any],
               let arr = j["SPPowerDataType"] as? [[String: Any]],
               let h = arr.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first {
                pct = Int((h["sppower_battery_health_maximum_capacity"] as? String ?? "").replacingOccurrences(of: "%", with: ""))
                word = h["sppower_battery_health"] as? String
            }
            var lp: Bool?, smart: String?, dModel: String?, dSolid: Bool?, items: [String]?
            if tab == .bat { lp = lowPowerOn(shText("/usr/bin/pmset", ["-g"])) }
            if tab == .health {
                func field(_ text: String, _ k: String) -> String? {
                    text.split(separator: "\n").first { $0.contains(k) }?.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
                }
                let root = shText("/usr/sbin/diskutil", ["info", "/"]), disk = shText("/usr/sbin/diskutil", ["info", "disk0"]) // o modelo só aparece no disco físico
                smart = field(root, "SMART Status"); dSolid = field(root, "Solid State").map { $0 == "Yes" }; dModel = field(disk, "Device / Media Name")
                // um nome por linha: nomes com vírgula não se partem em dois
                items = shText("/usr/bin/osascript", ["-e", "tell application \"System Events\" to set n to name of every login item",
                                                      "-e", "set AppleScript's text item delimiters to linefeed", "-e", "return n as text"])
                    .split(separator: "\n").map(String.init)
            }
            DispatchQueue.main.async {
                self.slowRunning.remove(tab)
                self.healthPct = pct; self.healthWord = word
                if let lp { self.lowPower = lp }
                if tab == .health {
                    self.smart = smart; self.diskModel = dModel; self.diskSolid = dSolid
                    self.loginItems = items ?? []
                }
            }
        }
    }

    /// Pergunta ao GitHub qual é a última release (no máx. 1× a cada 12 h). Não envia nada do Mac.
    /// Só conta como «consultado» se o GitHub respondeu: sem rede no login, tenta de novo na hora seguinte.
    func checkUpdate() {
        guard !checkingUpdate, Date().timeIntervalSince(lastUpdateCheck) > 12 * 3600 else { return }
        var source = "https://api.github.com/repos/\(repoSlug)/releases/latest"
        var trusted = true
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--update-url"), i + 1 < args.count { source = args[i + 1]; trusted = false } // só para testes
        #endif
        guard let api = URL(string: source) else { return }
        checkingUpdate = true
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var found: Update?, answered = false
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = j["tag_name"] as? String {
                answered = true
                let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if versionGreater(v, than: currentVersion),
                   let assets = j["assets"] as? [[String: Any]],
                   let a = assets.first(where: { ($0["name"] as? String) == "MemMonitor.zip" }),
                   let s = a["browser_download_url"] as? String, let u = URL(string: s),
                   !trusted || ["github.com", "objects.githubusercontent.com"].contains(u.host ?? "") {
                    found = Update(version: v, url: u)
                }
            }
            DispatchQueue.main.async {
                self.checkingUpdate = false
                if answered { self.lastUpdateCheck = Date() }
                if let found {
                    self.update = found
                    #if DEBUG
                    if CommandLine.arguments.contains("--auto-update") { self.installUpdate() } // só para testes
                    #endif
                }
            }
        }.resume()
    }

    /// Baixa, confere (identificador, versão, assinatura), troca o app e reabre. Falhou algo: o app atual fica intacto.
    func installUpdate() {
        guard let up = update, updateState != "A atualizar…" else { return }
        updateState = "A atualizar…"
        DispatchQueue.global().async {
            func fail(_ m: String) { DispatchQueue.main.async { self.updateState = "Não deu: \(m)" } }
            guard let data = try? Data(contentsOf: up.url) else { return fail("sem ligação") }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("memmonitor-update-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let zip = tmp.appendingPathComponent("MemMonitor.zip")
            guard (try? data.write(to: zip)) != nil, ok("/usr/bin/ditto", ["-x", "-k", zip.path, tmp.appendingPathComponent("out").path]) else { return fail("pacote inválido") }
            let app = tmp.appendingPathComponent("out/MemMonitor.app")
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == "local.memmonitor",
                  let nv = info?["CFBundleShortVersionString"] as? String, versionGreater(nv, than: currentVersion) else { return fail("versão inesperada") }
            guard ok("/usr/bin/codesign", ["--verify", app.path]) else { return fail("assinatura não confere") }
            let dest = Bundle.main.bundleURL.path
            guard FileManager.default.isWritableFile(atPath: (dest as NSString).deletingLastPathComponent) else { return fail("sem permissão na pasta") }
            // espera este processo sair; copia ao lado e só então troca (nunca fica sem app)
            let script = "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/ditto \"$2\" \"$1.new\" && rm -rf \"$1\" && mv \"$1.new\" \"$1\"; /usr/bin/xattr -cr \"$1\"; open \"$1\"; rm -rf \"$3\""
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script, "sh", dest, app.path, tmp.path]
            guard (try? p.run()) != nil else { return fail("não consegui trocar") }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// `purge` esvazia o cache de ficheiros. Sem palavra-passe se existir a regra sudo; senão pede ao macOS.
    func purge() {
        busy = true
        status = nil
        let before = readMem().cached
        DispatchQueue.global().async {
            let done = ok("/usr/bin/sudo", ["-n", "/usr/sbin/purge"])
                || ok("/usr/bin/osascript", ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"])
            DispatchQueue.main.async {
                let freed = max(before - readMem().cached, 0)
                self.status = done ? String(format: "Pronto: %.1f GB de cache liberados", freed / gb) : "Cancelado"
                self.busy = false
                self.refresh(visible: true)
            }
        }
    }

    /// O modo de pouca energia só muda com administrador: sem senha se existir a regra do `tirar-senha.sh`, senão pede ao macOS.
    func setLowPower(_ on: Bool) {
        lowPower = on
        DispatchQueue.global().async {
            let v = on ? "1" : "0"
            _ = ok("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "lowpowermode", v])
                || ok("/usr/bin/osascript", ["-e", "do shell script \"/usr/bin/pmset -a lowpowermode \(v)\" with administrator privileges"])
            let real = lowPowerOn(shText("/usr/bin/pmset", ["-g"]))
            DispatchQueue.main.async { self.lowPower = real }
        }
    }

    func removeLoginItem(_ name: String) {
        loginItems.removeAll { $0 == name }
        let safe = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.global().async {
            sh("/usr/bin/osascript", ["-e", "tell application \"System Events\" to delete login item \"\(safe)\""])
            DispatchQueue.main.async { self.slowStamps[.health] = nil; self.refresh(visible: true) }
        }
    }

    /// (texto, grave?) — alimenta o selo geral da aba Saúde
    func issues() -> [(String, Bool)] {
        var r: [(String, Bool)] = []
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: r.append(("O Mac está muito quente", true))
        case .fair: r.append(("O Mac está a aquecer", false))
        default: break
        }
        if let s = smart, s != "Verified" { r.append(("O disco reporta problemas (SMART)", true)) }
        if mem.pressure >= 4 { r.append(("Memória sob pressão crítica", true)) } else if mem.pressure == 2 { r.append(("Memória quase cheia", false)) }
        if let h = healthPct, h < 80 { r.append(("Bateria gasta (\(h)% da capacidade)", false)) }
        if diskTotal > 0, diskFree / diskTotal < 0.1 { r.append(("Pouco espaço livre no disco", false)) }
        let up = bootUptime()
        if up > 7 * 86400 { r.append(("Ligado há \(fmtUptime(up)): vale reiniciar", false)) }
        return r
    }
}

// MARK: - Visual (glassmorphism escuro, verde de estado)

let okColor = Color(red: 0.133, green: 0.773, blue: 0.369)   // #22C55E
let warnColor = Color(red: 0.961, green: 0.620, blue: 0.043) // #F59E0B
let badColor = Color(red: 0.937, green: 0.267, blue: 0.267)  // #EF4444
let muted = Color(red: 0.58, green: 0.64, blue: 0.72)        // #94A3B8
let blueColor = Color(red: 0.38, green: 0.65, blue: 0.98)
let purpleColor = Color(red: 0.75, green: 0.52, blue: 0.99)

func pressureInfo(_ p: Int) -> (String, Color) {
    p >= 4 ? ("Memória sob pressão", badColor) : p == 2 ? ("Memória a ficar cheia", warnColor) : ("Tudo certo com a memória", okColor)
}

/// Ícone da barra de menu: arco de 270° (aberto em baixo) que mostra a memória EM USO (o número ao lado é o livre).
/// A cor segue a pressão da memória; a pista usa a cor do texto, por isso funciona em tema claro e escuro.
func gaugeImage(fraction: Double, pressure: Int) -> NSImage {
    let color: NSColor = pressure >= 4 ? .systemRed : pressure == 2 ? .systemOrange : .systemGreen
    let f = CGFloat(min(max(fraction, 0), 1))
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        func arc(_ from: CGFloat, _ to: CGFloat, _ col: NSColor) {
            let p = NSBezierPath()
            p.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 6.4, startAngle: from, endAngle: to, clockwise: true)
            p.lineWidth = 2.4; p.lineCapStyle = .round
            col.setStroke(); p.stroke()
        }
        arc(225, -45, NSColor.labelColor.withAlphaComponent(0.28)) // pista: de baixo-esquerda, por cima, até baixo-direita
        if f > 0.015 { arc(225, 225 - 270 * f, color) }
        return true
    }
    img.isTemplate = false
    return img
}

struct Ring: View {
    var fraction: Double
    var color: Color
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 12)
            Circle().trim(from: 0, to: max(fraction, 0.015))
                .stroke(AngularGradient(colors: [color.opacity(0.45), color], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(fraction, 0.015))),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.55), radius: 9)
        }
    }
}

/// Mola única do anel e do número grande: começam e acabam juntos.
var heroAnim: Animation? {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.55, dampingFraction: 1)
}

struct Tile: View {
    var label: String, value: String, dot: Color
    var selected = false
    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                .contentTransition(.identity)
            HStack(spacing: 4) {
                Circle().fill(dot).frame(width: 5, height: 5)
                Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(muted)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(selected ? 0.13 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selected ? dot.opacity(0.9) : Color.white.opacity(0.09), lineWidth: selected ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) // o card inteiro é clicável
    }
}

/// Card clicável (as três abas usam o mesmo): o selecionado ganha contorno na cor dele.
struct TileButton: View {
    var label: String, value: String, dot: Color, selected: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) { Tile(label: label, value: value, dot: dot, selected: selected) }.buttonStyle(TilePress())
    }
}

/// Título pequeno e caixa de vidro dos detalhes que aparecem por baixo dos cards.
func detailHeading(_ t: String) -> some View {
    Text(t).font(.system(size: 10.5, weight: .semibold)).tracking(0.7).foregroundStyle(muted).padding(.horizontal, 10)
}
func detailCard<C: View>(@ViewBuilder _ c: () -> C) -> some View {
    VStack(spacing: 0) { c() }.padding(.vertical, 4).glassCard()
}

/// feedback instantâneo ao premir um card
struct TilePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1).animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// feedback instantâneo ao premir
struct Press: ButtonStyle {
    var fill: Color
    var solid = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(solid ? Color(red: 0.06, green: 0.09, blue: 0.16) : fill)
            .frame(maxWidth: .infinity).padding(.vertical, solid ? 11 : 6)
            .background(Capsule().fill(solid ? fill : fill.opacity(0.18)))
            .overlay(Capsule().stroke(Color.white.opacity(solid ? 0.25 : 0), lineWidth: 1))
            .shadow(color: solid ? fill.opacity(0.4) : .clear, radius: 8, y: 2)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Entrada em cascata: mola amortecida (sem ressalto), com atraso por posição. Com «Reduzir movimento» só faz fade.
struct Enter: ViewModifier {
    @ObservedObject var model: Model
    var i: Int
    func body(content: Content) -> some View {
        let on = model.shown
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        content.opacity(on ? 1 : 0)
            .offset(y: on || still ? 0 : 12)
            .animation(.spring(response: 0.45, dampingFraction: 1).delay(Double(i) * 0.05), value: on)
    }
}

extension View {
    func enter(_ m: Model, _ i: Int) -> some View { modifier(Enter(model: m, i: i)) }
}

final class Hover: ObservableObject { @Published var on = false }

/// Barra de progresso fina (lista de apps e potência do carregador).
struct Bar: View {
    var fraction: Double
    var height: CGFloat
    var body: some View {
        GeometryReader { g in
            Capsule().fill(Color.white.opacity(0.09))
                .overlay(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [okColor.opacity(0.6), okColor], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(g.size.width * min(max(fraction, 0), 1), 4))
                }
        }
        .frame(height: height)
    }
}

struct AppRow: View {
    let row: Row
    let maxBytes: Double
    @StateObject private var h = Hover()
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: row.app.icon ?? NSImage()).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(row.app.localizedName ?? "?").font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                Bar(fraction: row.bytes / max(maxBytes, 1), height: 4)
            }
            ZStack(alignment: .trailing) {
                Text(String(format: "%.0f MB", row.bytes / 1024 / 1024))
                    .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(muted)
                    .opacity(h.on ? 0 : 1)
                Button("Fechar") { row.app.terminate() } // pede com calma; o app ainda pergunta se há algo por guardar
                    .buttonStyle(Press(fill: badColor, solid: false))
                    .frame(width: 64)
                    .opacity(h.on ? 1 : 0)
            }
            .frame(width: 66, alignment: .trailing)
            .animation(.easeOut(duration: 0.12), value: h.on)
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(h.on ? 0.07 : 0)))
        .onHover { h.on = $0 }
    }
}

struct FootLink: View {
    var icon: String, title: String, action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) { Image(systemName: icon); Text(title) }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
                .padding(.vertical, 6).padding(.horizontal, 4)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// Anel + número grande da Memória. Um único valor animado (`used`) alimenta os dois: andam sempre em uníssono
/// e, por serem vistas normais (sem a rolagem de dígitos do sistema), acompanham o deslize da página.
struct MemHero: View, Animatable {
    var used: Double   // GB
    var total: Double
    var color: Color
    var animatableData: Double {
        get { used }
        set { used = newValue }
    }
    var body: some View {
        ZStack {
            Ring(fraction: used / total, color: color)
            VStack(spacing: 0) {
                Text(String(format: "%.1f", used))
                    .font(.system(size: 40, weight: .semibold)).tracking(-1).monospacedDigit().foregroundStyle(.white)
                Text(String(format: "de %.0f GB em uso", total)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(muted)
            }
        }
        .frame(width: 140, height: 140)
    }
}

struct PctHero: View, Animatable {
    var pct: Double
    var color: Color
    var caption: String
    var animatableData: Double {
        get { pct }
        set { pct = newValue }
    }
    var body: some View {
        ZStack {
            Ring(fraction: pct / 100, color: color)
            VStack(spacing: 0) {
                Text("\(Int(pct.rounded()))%").font(.system(size: 40, weight: .semibold)).tracking(-1).monospacedDigit().foregroundStyle(.white)
                Text(caption).font(.system(size: 11.5, weight: .medium)).foregroundStyle(muted)
            }
        }
        .frame(width: 140, height: 140)
    }
}

func gbText(_ bytes: Double) -> String { String(format: "%.1f GB", bytes / gb) }
/// Disco em GB decimais (1 GB = 10⁹ bytes), a mesma unidade do Finder; a RAM usa GB binários, como o Monitor de Atividade.
func diskText(_ bytes: Double) -> String { String(format: "%.1f GB", bytes / 1e9) }

/// Uma linha de detalhe: título, explicação curta, valor e (opcional) barra.
struct DetailRow: View {
    var title: String, sub: String, value: String
    var fraction: Double?
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                if !sub.isEmpty { Text(sub).font(.system(size: 11)).foregroundStyle(muted).lineLimit(2) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(value).font(.system(size: 12.5, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                if let f = fraction { Bar(fraction: f, height: 4).frame(width: 84) }
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
    }
}

struct MemDetail: View {
    @ObservedObject var model: Model
    var body: some View {
        let m = model.mem
        VStack(alignment: .leading, spacing: 4) {
            switch model.memCard {
            case .apps:
                detailHeading("APPS QUE MAIS USAM")
                let mx = model.rows.first?.bytes ?? 1
                detailCard { ForEach(Array(model.rows.enumerated()), id: \.offset) { _, r in AppRow(row: r, maxBytes: mx) } }
            case .system:
                detailHeading("O QUE O SISTEMA USA")
                detailCard {
                    DetailRow(title: "Sistema (fixa)", sub: "Kernel e drivers: não dá para liberar", value: gbText(m.wired), fraction: m.wired / m.total)
                    DetailRow(title: "Pressão da memória", sub: "Quão apertada está a RAM", value: m.pressure >= 4 ? "Crítica" : m.pressure == 2 ? "Média" : "Normal")
                    DetailRow(title: "Memória instalada", sub: "", value: gbText(m.total))
                }
            case .compressed:
                detailHeading("MEMÓRIA COMPRIMIDA")
                detailCard {
                    DetailRow(title: "Comprimida agora", sub: "Espaço que ocupa na RAM", value: gbText(m.compressed), fraction: m.compressed / m.total)
                    DetailRow(title: "Equivale a", sub: "O que ocuparia sem compressão", value: gbText(m.uncompressed), fraction: m.uncompressed / m.total)
                    DetailRow(title: "Economia", sub: "RAM poupada pela compressão", value: gbText(max(m.uncompressed - m.compressed, 0)), fraction: max(m.uncompressed - m.compressed, 0) / m.total)
                    DetailRow(title: "Swap em disco", sub: "Só entra quando comprimir não basta", value: gbText(m.swapUsed), fraction: m.swapTotal > 0 ? m.swapUsed / m.swapTotal : 0)
                }
            case .available:
                detailHeading("MEMÓRIA DISPONÍVEL")
                detailCard {
                    DetailRow(title: "Livre", sub: "Sem nenhum uso agora", value: gbText(m.free), fraction: m.free / m.total)
                    DetailRow(title: "Cache de arquivos", sub: "O macOS libera sozinho quando precisa", value: gbText(m.cached), fraction: m.cached / m.total)
                    DetailRow(title: "Total disponível", sub: "Livre + cache", value: gbText(m.free + m.cached), fraction: (m.free + m.cached) / m.total)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 244, alignment: .topLeading)
    }
}

struct MemView: View {
    @ObservedObject var model: Model
    var body: some View {
        let (title, color) = pressureInfo(model.mem.pressure)
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Memória").font(.system(size: 20, weight: .bold)).tracking(-0.4).foregroundStyle(.white)
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 7, height: 7).shadow(color: color, radius: 4)
                        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
                    }
                }
                Spacer()
            }

            MemHero(used: model.heroOn.contains(.mem) ? model.mem.used / gb : 0, total: model.mem.total / gb, color: color)
                .animation(heroAnim, value: model.heroOn.contains(.mem))
            .padding(.vertical, 2)

            HStack(spacing: 8) {
                TileButton(label: "Apps", value: String(format: "%.1f GB", model.mem.app / gb), dot: okColor, selected: model.memCard == .apps) { model.memCard = .apps }
                TileButton(label: "Sistema", value: String(format: "%.1f GB", model.mem.wired / gb), dot: blueColor, selected: model.memCard == .system) { model.memCard = .system }
                TileButton(label: "Comprim.", value: String(format: "%.1f GB", model.mem.compressed / gb), dot: warnColor, selected: model.memCard == .compressed) { model.memCard = .compressed }
                TileButton(label: "Disponível", value: gbText(model.mem.free + model.mem.cached), dot: purpleColor, selected: model.memCard == .available) { model.memCard = .available }
            }
            .animation(.easeOut(duration: 0.15), value: model.memCard)

            VStack(spacing: 7) {
                Button { model.purge() } label: {
                    Label(model.busy ? "A liberar…" : "Liberar memória", systemImage: "sparkles")
                }
                .buttonStyle(Press(fill: color))
                .disabled(model.busy)
                Text(model.status ?? String(format: "Cache de ficheiros: %.1f GB", model.mem.cached / gb))
                    .font(.system(size: 11)).foregroundStyle(muted)
            }

            MemDetail(model: model)
        }
    }
}

/// Uma linha da lista de apps por CPU (ícone, nome e %).
struct CPUAppRow: View {
    let row: Row
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: row.app.icon ?? NSImage()).resizable().frame(width: 22, height: 22)
            Text(row.app.localizedName ?? "?").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            Spacer()
            Text(String(format: "%.0f%%", row.cpu)).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(muted)
        }
        .padding(.vertical, 5).padding(.horizontal, 10)
    }
}

struct CPUDetail: View {
    @ObservedObject var model: Model
    func stat(_ title: String, _ v: Double) -> some View {
        VStack(spacing: 2) {
            Text(String(format: "%.0f%%", v * 100)).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
            Text(title).font(.system(size: 10.5)).foregroundStyle(muted)
        }.frame(maxWidth: .infinity)
    }
    func coreRow(_ label: String, _ v: Double) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(muted).frame(width: 22, alignment: .leading)
            Bar(fraction: v, height: 6)
            Text(String(format: "%.0f%%", v * 100)).font(.system(size: 11.5, weight: .medium)).monospacedDigit().foregroundStyle(.white).frame(width: 38, alignment: .trailing)
        }
        .padding(.vertical, 3.5).padding(.horizontal, 10)
    }
    var body: some View {
        let n = Double(ProcessInfo.processInfo.activeProcessorCount)
        VStack(alignment: .leading, spacing: 4) {
            switch model.cpuCard {
            case .live:
                detailHeading("USO NOS ÚLTIMOS 60 S")
                VStack(alignment: .leading, spacing: 10) {
                    if model.live.count > 1 {
                        Spark(values: model.live.map { $0.cpu }, color: purpleColor).frame(height: 120)
                    } else {
                        Text("A recolher dados…").font(.system(size: 11)).foregroundStyle(muted).frame(height: 120)
                    }
                    HStack {
                        stat("Usuário", model.userPct)
                        stat("Sistema", model.sysPct)
                        stat("Livre", max(1 - model.userPct - model.sysPct, 0))
                    }
                }
                .padding(12).glassCard()
            case .cores:
                detailHeading("USO POR NÚCLEO")
                detailCard {
                    // os de eficiência vêm primeiro na lista do sistema; mostra os de desempenho no topo
                    ForEach(0..<perfCores, id: \.self) { i in coreRow("P\(i + 1)", effCores + i < model.cores.count ? model.cores[effCores + i] : 0) }
                    ForEach(0..<effCores, id: \.self) { i in coreRow("E\(i + 1)", i < model.cores.count ? model.cores[i] : 0) }
                }
            case .temp:
                detailHeading("TEMPERATURAS")
                if let t = model.temps {
                    detailCard {
                        DetailRow(title: "Chip (CPU)", sub: String(format: "Máxima entre os sensores: %.0f °C", t.cpuMax), value: String(format: "%.0f °C", t.cpuAvg), fraction: min(t.cpuAvg / 110, 1))
                        if let c = t.chips { DetailRow(title: "Outros blocos do chip", sub: "", value: String(format: "%.0f °C", c)) }
                        if let c = t.ssd { DetailRow(title: "SSD", sub: "", value: String(format: "%.0f °C", c)) }
                        if let c = t.battery { DetailRow(title: "Bateria", sub: "", value: String(format: "%.0f °C", c)) }
                    }
                    let tv = model.live.compactMap { $0.temp }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Chip nos últimos 60 s").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        if tv.count > 1 {
                            let lo = tv.min()! - 2, hi = max(tv.max()! + 4, lo + 10)
                            Spark(values: tv.map { ($0 - lo) / (hi - lo) }, color: warnColor).frame(height: 52)
                        } else {
                            Text("A recolher dados…").font(.system(size: 11)).foregroundStyle(muted).frame(height: 52)
                        }
                    }
                    .padding(12).glassCard()
                } else {
                    detailCard { Text("Este Mac não permite ler os sensores de temperatura.").font(.system(size: 12)).foregroundStyle(muted).padding(12) }
                }
            case .load:
                detailHeading("CARGA MÉDIA")
                detailCard {
                    DetailRow(title: "1 · 5 · 15 min", sub: "O Mac tem \(Int(n)) núcleos: acima disso, há fila", value: String(format: "%.1f · %.1f · %.1f", model.load[0], model.load[1], model.load[2]), fraction: model.load[0] / n)
                }
                detailHeading("MAIS USAM A CPU")
                detailCard {
                    ForEach(Array(model.cpuRows.enumerated()), id: \.offset) { _, r in CPUAppRow(row: r) }
                    if model.cpuRows.isEmpty { Text("A ler…").font(.system(size: 12)).foregroundStyle(muted).padding(10).frame(maxWidth: .infinity) }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 262, alignment: .topLeading)
    }
}

struct CPUView: View {
    @ObservedObject var model: Model
    var body: some View {
        let pct = model.cpu * 100
        let color: Color = pct >= 75 ? badColor : pct >= 40 ? warnColor : okColor
        let state = pct >= 75 ? "Uso alto" : pct >= 40 ? "Uso moderado" : "Uso leve"
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CPU").font(.system(size: 20, weight: .bold)).tracking(-0.4).foregroundStyle(.white)
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 7, height: 7).shadow(color: color, radius: 4)
                        Text("\(state) · \(ProcessInfo.processInfo.activeProcessorCount) núcleos").font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
                    }
                }
                Spacer()
            }
            PctHero(pct: model.heroOn.contains(.cpu) ? pct : 0, color: color, caption: "\(perfCores)P + \(effCores)E")
                .padding(.vertical, 2)
                .animation(heroAnim, value: model.heroOn.contains(.cpu))  // só na chegada à aba: animar a cada segundo mantém o painel desenhando sem parar
            HStack(spacing: 8) {
                TileButton(label: "Uso", value: String(format: "%.0f%%", pct), dot: purpleColor, selected: model.cpuCard == .live) { model.cpuCard = .live }
                TileButton(label: "Núcleos", value: "\(perfCores)P·\(effCores)E", dot: okColor, selected: model.cpuCard == .cores) { model.cpuCard = .cores }
                TileButton(label: "Temp.", value: model.temps.map { "\(Int($0.cpuAvg.rounded()))°" } ?? "—", dot: warnColor, selected: model.cpuCard == .temp) { model.cpuCard = .temp }
                TileButton(label: "Carga", value: String(format: "%.1f", model.load[0]), dot: blueColor, selected: model.cpuCard == .load) { model.cpuCard = .load }
            }
            .animation(.easeOut(duration: 0.15), value: model.cpuCard)
            CPUDetail(model: model)
        }
    }
}

struct BatDetail: View {
    @ObservedObject var model: Model
    var b: Batt
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.batCard {
            case .power:
                let hasAdapter = b.plugged && b.adapterW > 0
                detailHeading(b.watts >= 0 ? "ENERGIA A ENTRAR" : "CONSUMO AGORA")
                detailCard {
                    DetailRow(title: b.watts >= 0 ? "Potência a entrar" : "Potência de consumo",
                              sub: hasAdapter ? "De \(b.adapterW) W do carregador" : "O que a bateria gasta agora",
                              value: String(format: "%.0f W", abs(b.watts)), fraction: hasAdapter ? max(b.watts, 0) / Double(b.adapterW) : nil)
                    DetailRow(title: "Tensão da bateria", sub: String(format: "Corrente de %.2f A", abs(b.amps)), value: String(format: "%.1f V", b.volts))
                }
                let bv = model.history.compactMap { $0.batt }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Bateria desde que o app abriu").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        Spacer()
                        if let f = bv.first, let l = bv.last, bv.count > 1 {
                            Text(String(format: "%+.0f%%", l - f)).font(.system(size: 12)).monospacedDigit().foregroundStyle(muted)
                        }
                    }
                    if bv.count > 1 {
                        let lo = bv.min()!, hi = max(bv.max()!, lo + 10) // escala ajustada para variações pequenas aparecerem
                        Spark(values: bv.map { ($0 - lo) / (hi - lo) }, color: okColor).frame(height: 34)
                    } else {
                        Text("A recolher dados…").font(.system(size: 11)).foregroundStyle(muted).frame(height: 34)
                    }
                }
                .padding(12).glassCard()
            case .charger:
                detailHeading("CARREGADOR")
                detailCard {
                    DetailRow(title: "Potência máxima", sub: b.plugged ? "O que o carregador pode entregar" : "Não está na tomada", value: b.plugged ? "\(b.adapterW) W" : "—")
                    DetailRow(title: "Tensão e corrente", sub: "O que o carregador combinou com o Mac", value: b.plugged ? String(format: "%.0f V · %.1f A", b.adapterV, b.adapterA) : "—")
                    DetailRow(title: "Estado", sub: b.pct >= 80 && b.plugged && !b.charging ? "Carga em pausa para poupar a bateria" : "", value: b.charging ? "A carregar" : b.plugged ? "Em pausa" : "Fora da tomada")
                }
            case .health:
                detailHeading("SAÚDE DA BATERIA")
                detailCard {
                    DetailRow(title: "Capacidade máxima", sub: "Em relação a quando era nova", value: model.healthPct.map { "\($0)%" } ?? "—", fraction: model.healthPct.map { Double($0) / 100 })
                    DetailRow(title: "Condição", sub: "Avaliação do macOS", value: model.healthWord.map { $0 == "Good" ? "Normal" : $0 } ?? "—")
                    DetailRow(title: "De fábrica", sub: "Capacidade quando era nova", value: b.designmAh > 0 ? "\(b.designmAh) mAh" : "—")
                    DetailRow(title: "Máxima agora", sub: "O quanto ainda consegue guardar", value: b.nominalmAh > 0 ? "\(b.nominalmAh) mAh" : "—")
                }
            case .cycles:
                detailHeading("CICLOS DE CARGA")
                detailCard {
                    DetailRow(title: "Ciclos feitos", sub: "Cada 100% gastos contam 1 ciclo", value: "\(b.cycles)", fraction: min(Double(b.cycles) / 1000, 1))
                    Text("A Apple projeta cerca de 1000 ciclos antes de a bateria perder uns 20% da capacidade.")
                        .font(.system(size: 11)).foregroundStyle(muted).padding(.horizontal, 10).padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 206, maxHeight: 206, alignment: .topLeading)
    }
}

struct BatView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(spacing: 14) {
            if let b = model.batt {
                let color: Color = (b.pct <= 20 && !b.plugged) ? badColor : b.pct <= 40 && !b.plugged ? warnColor : okColor
                let state = b.charging ? "A carregar" : b.plugged ? "Na tomada" : "Na bateria"
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Bateria").font(.system(size: 20, weight: .bold)).tracking(-0.4).foregroundStyle(.white)
                        HStack(spacing: 6) {
                            Image(systemName: b.charging ? "bolt.fill" : b.plugged ? "powerplug.fill" : "battery.75percent")
                                .font(.system(size: 11)).foregroundStyle(color)
                            Text(model.healthWord.map { "\(state) · condição \($0 == "Good" ? "normal" : $0.lowercased())" } ?? state)
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
                        }
                    }
                    Spacer()
                }
                PctHero(pct: model.heroOn.contains(.bat) ? Double(b.pct) : 0, color: color,
                        caption: b.charging ? (b.minutes.map { "cheia em \(fmtMin($0))" } ?? "a calcular…")
                            : b.plugged ? (b.pct >= 100 ? "carregada" : "carga em pausa")
                            : (b.minutes.map { "restam \(fmtMin($0))" } ?? "a calcular…"))
                    .padding(.vertical, 2)
                    .animation(heroAnim, value: model.heroOn.contains(.bat))

                HStack(spacing: 8) {
                    TileButton(label: b.watts >= 0 ? "A entrar" : "Consumo", value: String(format: "%.0f W", abs(b.watts)), dot: okColor, selected: model.batCard == .power) { model.batCard = .power }
                    TileButton(label: "Carregador", value: b.plugged ? "\(b.adapterW) W" : "—", dot: blueColor, selected: model.batCard == .charger) { model.batCard = .charger }
                    TileButton(label: "Saúde", value: model.healthPct.map { "\($0)%" } ?? "—", dot: warnColor, selected: model.batCard == .health) { model.batCard = .health }
                    TileButton(label: "Ciclos", value: "\(b.cycles)", dot: purpleColor, selected: model.batCard == .cycles) { model.batCard = .cycles }
                }
                .animation(.easeOut(duration: 0.15), value: model.batCard)

                BatDetail(model: model, b: b)

                HStack(spacing: 10) {
                    Image(systemName: "leaf.fill").foregroundStyle(okColor).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Modo de pouca energia").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        Text("Poupa bateria e esquenta menos").font(.system(size: 11)).foregroundStyle(muted)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { model.lowPower }, set: { model.setLowPower($0) }))
                        .toggleStyle(.switch).labelsHidden().tint(okColor)
                }
                .padding(12).glassCard()

            } else {
                Text(model.tab == .bat ? "A ler a bateria…" : "").font(.system(size: 13)).foregroundStyle(muted).padding(.vertical, 40)
            }
        }
    }
}

struct HealthDetail: View {
    @ObservedObject var model: Model
    var body: some View {
        let up = bootUptime(), total = model.diskTotal, free = model.diskFree
        VStack(alignment: .leading, spacing: 4) {
            switch model.healthCard {
            case .disk:
                detailHeading("ARMAZENAMENTO")
                detailCard {
                    DetailRow(title: "Livre", sub: "O mesmo valor do Finder", value: total > 0 ? diskText(free) : "—", fraction: total > 0 ? free / total : nil)
                    DetailRow(title: "Liberável pelo macOS", sub: "Cache e arquivos que ele apaga se faltar espaço", value: total > 0 ? diskText(model.diskPurgeable) : "—", fraction: total > 0 ? model.diskPurgeable / total : nil)
                    DetailRow(title: "Usado", sub: "Apps, arquivos e sistema", value: total > 0 ? diskText(total - free) : "—", fraction: total > 0 ? (total - free) / total : nil)
                    DetailRow(title: "Total", sub: model.diskModel ?? "", value: total > 0 ? diskText(total) : "—")
                }
            case .smart:
                detailHeading("SAÚDE DO DISCO")
                detailCard {
                    DetailRow(title: "Estado SMART", sub: "O próprio disco avalia a sua saúde", value: model.smart == "Verified" ? "OK" : (model.smart ?? "—"))
                    DetailRow(title: "Modelo", sub: "", value: model.diskModel ?? "—")
                    DetailRow(title: "Tipo", sub: "", value: model.diskSolid.map { $0 ? "SSD" : "Disco rígido" } ?? "—")
                }
            case .uptime:
                detailHeading("TEMPO LIGADO")
                detailCard {
                    DetailRow(title: "Ligado há", sub: "Contando o tempo em repouso", value: fmtUptime(up), fraction: min(up / (7 * 86400), 1))
                    DetailRow(title: "Último arranque", sub: up > 7 * 86400 ? "Já faz mais de 7 dias: vale reiniciar" : "",
                              value: Date().addingTimeInterval(-up).formatted(date: .abbreviated, time: .shortened))
                }
                detailHeading("ABREM AO LIGAR O MAC")
                detailCard {
                    if model.loginItems.isEmpty {
                        Text("Nenhum item").font(.system(size: 12)).foregroundStyle(muted).padding(12).frame(maxWidth: .infinity)
                    }
                    ForEach(Array(model.loginItems.prefix(2)), id: \.self) { n in LoginRow(name: n) { model.removeLoginItem(n) } }
                    if model.loginItems.count > 2 {
                        Text("+\(model.loginItems.count - 2) mais").font(.system(size: 11)).foregroundStyle(muted).padding(8)
                    }
                }
            case .thermal:
                let t = thermalInfo(ProcessInfo.processInfo.thermalState)
                detailHeading("TEMPERATURA")
                detailCard {
                    DetailRow(title: "Estado térmico", sub: t.sub, value: t.title)
                    if let tp = model.temps { DetailRow(title: "Temperatura do chip", sub: String(format: "Máxima entre os sensores: %.0f °C", tp.cpuMax), value: String(format: "%.0f °C", tp.cpuAvg)) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Text("Atividade recente").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        Spacer()
                        HStack(spacing: 4) { Circle().fill(warnColor).frame(width: 6, height: 6); Text("RAM").font(.system(size: 10.5)).foregroundStyle(muted) }
                        HStack(spacing: 4) { Circle().fill(purpleColor).frame(width: 6, height: 6); Text("CPU").font(.system(size: 10.5)).foregroundStyle(muted) }
                    }
                    if model.history.count > 1 {
                        ZStack {
                            Spark(values: model.history.map { $0.mem }, color: warnColor)
                            Spark(values: model.history.map { $0.cpu }, color: purpleColor)
                        }.frame(height: 34)
                    } else {
                        Text("A recolher dados…").font(.system(size: 11)).foregroundStyle(muted).frame(height: 34)
                    }
                }
                .padding(12).glassCard()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 236, alignment: .topLeading)
    }
}

struct HealthView: View {
    @ObservedObject var model: Model
    var body: some View {
        let issues = model.issues()
        let severe = issues.contains { $0.1 }
        let color = severe ? badColor : issues.isEmpty ? okColor : warnColor
        let title = severe ? "Atenção" : issues.isEmpty ? "Tudo bem" : "Pode melhorar"
        let thermal = ProcessInfo.processInfo.thermalState
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: severe ? "exclamationmark.shield.fill" : issues.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 34)).foregroundStyle(color).shadow(color: color.opacity(0.6), radius: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Saúde do Mac").font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
                    Text(title).font(.system(size: 24, weight: .bold)).tracking(-0.5).foregroundStyle(.white)
                }
                Spacer()
            }
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, it in
                        HStack(spacing: 8) {
                            Circle().fill(it.1 ? badColor : warnColor).frame(width: 6, height: 6)
                            Text(it.0).font(.system(size: 12.5)).foregroundStyle(.white)
                            Spacer()
                        }
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).glassCard()
            }

            HStack(spacing: 8) {
                TileButton(label: "Disco livre", value: model.diskTotal > 0 ? String(format: "%.0f GB", model.diskFree / 1e9) : "—", dot: okColor, selected: model.healthCard == .disk) { model.healthCard = .disk }
                TileButton(label: "SMART", value: model.smart == "Verified" ? "OK" : (model.smart ?? "—"), dot: blueColor, selected: model.healthCard == .smart) { model.healthCard = .smart }
                TileButton(label: "Ligado há", value: fmtUptime(bootUptime()), dot: warnColor, selected: model.healthCard == .uptime) { model.healthCard = .uptime }
                TileButton(label: "Térmico", value: model.temps.map { "\(Int($0.cpuAvg.rounded()))°" } ?? thermalInfo(thermal).title, dot: purpleColor, selected: model.healthCard == .thermal) { model.healthCard = .thermal }
            }
            .animation(.easeOut(duration: 0.15), value: model.healthCard)

            HStack(spacing: 0) {
                Label(fmtRate(model.down), systemImage: "arrow.down").frame(maxWidth: .infinity)
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 18)
                Label(fmtRate(model.up), systemImage: "arrow.up").frame(maxWidth: .infinity)
            }
            .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.white)
            .padding(.vertical, 11).glassCard()

            HealthDetail(model: model)
        }
    }
}

struct LoginRow: View {
    let name: String
    let remove: () -> Void
    @StateObject private var h = Hover()
    var body: some View {
        HStack {
            Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            Spacer()
            Button("Remover", action: remove).buttonStyle(Press(fill: badColor, solid: false))
                .frame(width: 76).opacity(h.on ? 1 : 0).animation(.easeOut(duration: 0.12), value: h.on)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(h.on ? 0.07 : 0)))
        .onHover { h.on = $0 }
    }
}

extension View {
    func glassCard() -> some View {
        self.background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// A mesma mola para a cápsula e para o deslize dos painéis, para se moverem em uníssono.
var slideSpring: Animation? {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.42, dampingFraction: 1)
}

/// Altura fixa dos painéis: a janela nunca muda de tamanho, por isso o deslize é puramente horizontal.
let pagerHeight: CGFloat = 600

struct TabBar: View {
    @ObservedObject var model: Model
    var body: some View {
        let idx = CGFloat(Tab.allCases.firstIndex(of: model.tab)!)
        GeometryReader { g in
            let n = CGFloat(Tab.allCases.count)
            let w = (g.size.width - 6 - 2 * (n - 1)) / n // 3 pt de margem de cada lado, 2 pt entre separadores
            ZStack(alignment: .leading) {
                // uma só cápsula que anda de um separador ao outro (não aparece/desaparece)
                Capsule().fill(Color.white.opacity(0.14))
                    .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                    .frame(width: w, height: 28)
                    .offset(x: idx * (w + 2))
                HStack(spacing: 2) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Button { model.tab = t } label: {
                            Text(t.rawValue).font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(model.tab == t ? Color.white : muted)
                                .frame(width: w, height: 28)
                                .contentShape(Capsule()) // área de clique = o separador todo, não só as letras
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(3)
        }
        .frame(height: 34)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .animation(slideSpring, value: model.tab)
    }
}

struct Spark: View {
    var values: [Double]   // 0...1
    var color: Color
    func path(_ size: CGSize, closed: Bool) -> Path {
        Path { p in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            for (i, v) in values.enumerated() {
                let pt = CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat(min(max(v, 0), 1))))
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            if closed { p.addLine(to: CGPoint(x: size.width, y: size.height)); p.addLine(to: CGPoint(x: 0, y: size.height)); p.closeSubpath() }
        }
    }
    var body: some View {
        GeometryReader { g in
            ZStack {
                path(g.size, closed: true).fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                path(g.size, closed: false).stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

struct PanelView: View {
    @ObservedObject var model: Model
    @ViewBuilder func page(_ t: Tab) -> some View {
        switch t {
        case .mem: MemView(model: model)
        case .cpu: CPUView(model: model)
        case .bat: BatView(model: model)
        case .health: HealthView(model: model)
        }
    }
    var body: some View {
        let color = pressureInfo(model.mem.pressure).1
        VStack(spacing: 14) {
            TabBar(model: model).enter(model, 0)
            // três painéis lado a lado: ao escolher um separador, o painel do lado desliza para o lugar
            ZStack(alignment: .top) {
                ForEach(Tab.allCases, id: \.self) { t in
                    page(t)
                        .padding(.horizontal, 18)
                        .frame(width: 360, alignment: .top)
                        .offset(x: CGFloat(Tab.allCases.firstIndex(of: t)! - Tab.allCases.firstIndex(of: model.tab)!) * 360)
                        .allowsHitTesting(t == model.tab)
                        .accessibilityHidden(t != model.tab)
                }
            }
            .frame(width: 360, height: pagerHeight, alignment: .top)
            .clipped()
            .padding(.horizontal, -18)
            .enter(model, 1)
            if let u = model.update {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 20)).foregroundStyle(okColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Nova versão \(u.version)").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                        Text(model.updateState.isEmpty ? "Você tem a \(currentVersion)" : model.updateState)
                            .font(.system(size: 11)).foregroundStyle(muted).lineLimit(1)
                    }
                    Spacer()
                    Button("Atualizar") { model.installUpdate() }
                        .buttonStyle(Press(fill: okColor, solid: false)).frame(width: 90)
                        .disabled(model.updateState == "A atualizar…")
                }
                .padding(10).glassCard()
            }

            HStack {
                FootLink(icon: "chart.bar.xaxis", title: "Monitor de Atividade") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                Spacer()
                Text("v\(currentVersion)").font(.system(size: 11)).foregroundStyle(muted.opacity(0.7))
                Spacer()
                FootLink(icon: "power", title: "Sair") { NSApp.terminate(nil) }
            }
            .enter(model, 3)
        }
        .animation(slideSpring, value: model.tab)
        .padding(18)
        .frame(width: 360)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .background(
            // sobre o vidro: tom escuro + brilho da cor de estado
            ZStack {
                LinearGradient(colors: [Color(red: 0.12, green: 0.16, blue: 0.23).opacity(0.62), Color(red: 0.06, green: 0.09, blue: 0.16).opacity(0.80)], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [color.opacity(0.22), .clear], center: .init(x: 0.5, y: 0.22), startRadius: 4, endRadius: 190)
            }
        )
    }
}

// MARK: - Janela de vidro

final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

class Delegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let model = Model()
    var panel: GlassPanel?
    var host: NSHostingView<PanelView>?
    var timer: Timer?
    var monitor: Any?
    var bag = Set<AnyCancellable>()
    var ticks = 0
    var prevTab = Tab.mem
    var lastIcon = ""
    var visible: Bool { panel?.isVisible ?? false }
    #if DEBUG
    var testing: Bool { CommandLine.arguments.contains("--show") }
    #else
    var testing: Bool { false }
    #endif
    var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func applicationDidFinishLaunching(_ n: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--selftest") { selfTest() }
        if let i = CommandLine.arguments.firstIndex(of: "--iconsheet"), i + 1 < CommandLine.arguments.count { iconSheet(CommandLine.arguments[i + 1]) }
        #endif
        _ = panelCPU.read(); _ = historyCPU.read() // primeira leitura só marca o ponto de partida
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeading
        updateStatusItem()
        model.prefetch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.model.checkUpdate() }
        _ = makePanel() // criar a janela só ao abrir deixa-a em branco no 1.º quadro; os dados é que são lazy
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }

        #if DEBUG
        if CommandLine.arguments.contains("--show") {
            if let i = CommandLine.arguments.firstIndex(of: "--tab"), let t = Tab(rawValue: CommandLine.arguments[i + 1]) { model.tab = t }
            if let i = CommandLine.arguments.firstIndex(of: "--bcard"), let c = BatCard(rawValue: CommandLine.arguments[i + 1]) { model.batCard = c }
            if let i = CommandLine.arguments.firstIndex(of: "--hcard"), let c = HealthCard(rawValue: CommandLine.arguments[i + 1]) { model.healthCard = c }
            if let i = CommandLine.arguments.firstIndex(of: "--ccard"), let c = CPUCard(rawValue: CommandLine.arguments[i + 1]) { model.cpuCard = c }
            if let i = CommandLine.arguments.firstIndex(of: "--card"), let c = MemCard(rawValue: CommandLine.arguments[i + 1]) { model.memCard = c }
            if CommandLine.arguments.contains("--switch") { DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.model.tab = .health } }
            if CommandLine.arguments.contains("--back") { DispatchQueue.main.asyncAfter(deadline: .now() + 13) { self.model.tab = .mem } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.toggle(); if let f = self.item.button?.window?.frame { print("BAR", Int(f.minX), Int(NSScreen.screens[0].frame.height - f.maxY), Int(f.width), Int(f.height)); fflush(stdout) } }
        }
        #endif
    }

    func makePanel() -> GlassPanel {
        if let p = panel { return p }
        let host = NSHostingView(rootView: PanelView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        self.host = host

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .darkAqua)
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 24
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 1
        fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor // luz a bater na borda do vidro
        fx.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: fx.leadingAnchor), host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            host.topAnchor.constraint(equalTo: fx.topAnchor), host.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])

        let p = GlassPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 360, height: 640)),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = fx
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.appearance = NSAppearance(named: .darkAqua)
        panel = p

        // a altura da janela só muda quando aparece a faixa de atualização
        model.$update.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.resize() }.store(in: &bag)
        // trocar de aba: o anel/número da aba que chega sobem de 0
        model.$tab.dropFirst().sink { [weak self] t in
            guard let self else { return }
            // a aba que chega «sobe» de 0 ao valor enquanto desliza; a que sai só zera depois de sair de vista
            let old = self.prevTab
            self.prevTab = t
            self.model.heroOn.insert(t)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if self.model.tab != old { self.model.heroOn.remove(old) } }
            self.model.refresh(visible: true)
        }.store(in: &bag)
        return p
    }

    /// Barra de menu: o arco mostra a memória em uso e o número mostra os GB livres (total − usada): as duas leituras no mesmo canto.
    /// Só redesenha o arco quando muda de verdade.
    func updateStatusItem() {
        let m = model.mem
        let free = max(m.total - m.used, 0)
        item.button?.title = String(format: " %.1f GB", free / gb)
        let key = "\(Int(m.fraction * 40))-\(m.pressure)"
        if key != lastIcon {
            lastIcon = key
            item.button?.image = gaugeImage(fraction: m.fraction, pressure: m.pressure)
            item.button?.imagePosition = .imageLeading
        }
        item.button?.toolTip = String(format: "Em uso: %.1f GB de %.0f GB · Livre: %.1f GB", m.used / gb, m.total / gb, free / gb)
        item.button?.setAccessibilityLabel("Memória em uso (arco) e livre (número)")
    }

    func tick() {
        ticks += 1
        if ticks % 16 == 0 { model.record() } // amostra do gráfico: ~16 s
        if ticks % 3600 == 0 { model.checkUpdate() } // a cada ~1 h tenta; só consulta o GitHub se passaram 12 h
        // painel aberto na aba CPU: 1×/s (gráficos em tempo real); outras abas: 2 s; fechado: só o número da barra, de 6 em 6 s
        let step = visible ? (model.tab == .cpu ? 1 : 2) : 6
        if ticks > 1 && ticks % step != 0 { return }
        model.refresh(visible: visible)
        updateStatusItem()
    }

    func resize() {
        guard let panel, let host, panel.isVisible else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let f = NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
        if abs(f.height - panel.frame.height) < 1 { return }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = still ? 0 : 0.45
            c.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) // aproxima a mola amortecida do conteúdo
            panel.animator().setFrame(f, display: true)
        }
        panel.invalidateShadow()
    }

    func place(_ panel: GlassPanel) {
        guard let bw = item.button?.window, let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let vis = (bw.screen ?? NSScreen.main!).visibleFrame
        let x = min(max(bw.frame.midX - size.width / 2, vis.minX + 8), vis.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: bw.frame.minY - 6 - size.height, width: size.width, height: size.height), display: true)
    }

    @objc func toggle() {
        let panel = makePanel()
        if panel.isVisible { close(); return }
        model.refresh(visible: true)
        place(panel)
        let end = panel.frame
        panel.alphaValue = 0
        if !still { panel.setFrame(end.offsetBy(dx: 0, dy: 8), display: false) }
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.2
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if !still { panel.animator().setFrame(end, display: true) }
        }
        #if DEBUG
        if testing { print("WIN0", panel.windowNumber); fflush(stdout) }
        #endif
        DispatchQueue.main.async { self.model.shown = true; self.model.heroOn = [self.model.tab]; self.prevTab = self.model.tab } // dispara a cascata dos blocos e o anel a encher
        if !testing { // em teste o painel não fecha com cliques de fora
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let bw = self.item.button?.window, !bw.frame.contains(NSEvent.mouseLocation) else { return }
            self.close()
            }
        }
    }

    func close() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil); self.model.shown = false; self.model.heroOn = [] })
    }
}

#if DEBUG
/// Desenha o arco em vários estados, em fundo claro e escuro, ampliado: só para ver o resultado sem fotografar a barra de verdade.
func iconSheet(_ path: String) {
    let states: [(Double, Int)] = [(0.85, 1), (0.55, 1), (0.28, 1), (0.14, 2), (0.05, 4)]
    let scale: CGFloat = 8, cell = 18 * scale + 40
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(cell) * states.count, pixelsHigh: Int(cell) * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for (row, dark) in [false, true].enumerated() {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        for (col, st) in states.enumerated() {
            let r = NSRect(x: CGFloat(col) * cell, y: CGFloat(1 - row) * cell, width: cell, height: cell)
            (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill(); r.fill()
            appearance.performAsCurrentDrawingAppearance {
                gaugeImage(fraction: st.0, pressure: st.1).draw(in: NSRect(x: r.minX + 20, y: r.minY + 20, width: 18 * scale, height: 18 * scale))
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print("sheet ok"); exit(0)
}

/// `swiftc -DDEBUG …` e `./MemMonitor --selftest` (veja tests/run.sh)
func selfTest() {
    var fails = 0
    func check(_ c: Bool, _ m: String) { if !c { print("FALHOU: \(m)"); fails += 1 } }
    check(versionGreater("1.10", than: "1.9"), "1.10 > 1.9")
    check(!versionGreater("1.1", than: "1.1.0"), "1.1 == 1.1.0")
    check(!versionGreater("1.0", than: "1.1"), "1.0 < 1.1")
    check(versionGreater("2.0", than: "1.99.9"), "2.0 > 1.99.9")
    check(versionGreater("1.2", than: "1.2-beta"), "1.2 > 1.2-beta")
    check(!versionGreater("1.2-beta", than: "1.2"), "1.2-beta < 1.2")
    check(versionGreater("1.3-beta", than: "1.2"), "1.3-beta > 1.2")
    check(lowPowerOn("Battery Power:\n lowpowermode         1\n sleep 1"), "lowpowermode 1")
    check(!lowPowerOn(" lowpowermode         0"), "lowpowermode 0")
    check(lowPowerOn(" lowpowermode\t1"), "lowpowermode com tab")
    check(!lowPowerOn("sleep 1"), "sem a linha")
    check(fmtMin(59) == "59 min" && fmtMin(61) == "1 h 1 min", "fmtMin")
    check(fmtUptime(30 * 3600) == "30 h" && fmtUptime(72 * 3600) == "3 dias" && fmtUptime(600) == "10 min", "fmtUptime")
    check(readMem().total > 0 && readMem().fraction <= 1, "readMem")
    check(readMem().free >= 0 && readMem().swapTotal >= readMem().swapUsed, "free e swap coerentes")
    check(perfCores + effCores == ProcessInfo.processInfo.activeProcessorCount, "núcleos P + E = total")
    let cm = CoreMeter(); _ = cm.read(); Thread.sleep(forTimeInterval: 0.2)
    let r = cm.read()
    check(r.cores.count == ProcessInfo.processInfo.activeProcessorCount && r.cores.allSatisfy { $0 >= 0 && $0 <= 1 }, "uso por núcleo entre 0 e 1")
    for _ in 0..<200 { _ = thermals.read() } // leituras seguidas não podem derrubar o app (cliente dos sensores)
    if let t = thermals.read() { check(t.cpuAvg > 15 && t.cpuAvg < 110 && t.cpuMax >= t.cpuAvg, "temperatura plausível") } // nil = sem sensores: tudo bem
    // duas leituras de CPU não se atrapalham: o `b.read()` do meio não pode encurtar a janela de `a`
    let a = CPUMeter(), b = CPUMeter()
    _ = a.read(); _ = b.read()
    let end = Date().addingTimeInterval(0.4); var x = 0.0
    while Date() < end { x += sqrt(x + 1) }
    _ = b.read()
    check(a.read() > 0.03, "a janela de CPU de `a` sobrevive à leitura de `b`")
    print(fails == 0 ? "tudo ok" : "\(fails) falhas")
    exit(fails == 0 ? 0 : 1)
}
#endif

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let d = Delegate()
app.delegate = d
app.run()
