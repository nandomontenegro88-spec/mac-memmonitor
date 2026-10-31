import SwiftUI
import AppKit
import Combine

let gb = 1024.0 * 1024 * 1024

// MARK: - Dados

struct Mem {
    var app = 0.0, wired = 0.0, compressed = 0.0, cached = 0.0
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
    m.app = Double(UInt64(s.internal_page_count) - UInt64(s.purgeable_count)) * page
    m.wired = Double(s.wire_count) * page
    m.compressed = Double(s.compressor_page_count) * page
    m.cached = Double(s.external_page_count) * page
    var p: Int32 = 1
    var l = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &p, &l, nil, 0)
    m.pressure = Int(p)
    return m
}

var lastTicks: (UInt32, UInt32, UInt32, UInt32)?
func readCPU() -> Double {
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    var info = host_cpu_load_info_data_t()
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    let t = info.cpu_ticks
    defer { lastTicks = t }
    guard let l = lastTicks else { return 0 }
    let busy = Double(t.0 &- l.0) + Double(t.1 &- l.1) + Double(t.3 &- l.3)
    let all = busy + Double(t.2 &- l.2)
    return all > 0 ? busy / all : 0
}

struct Row: Identifiable {
    let app: NSRunningApplication
    let bytes: Double
    var cpu = 0.0
    var id: pid_t { app.processIdentifier }
}

/// RSS por app aberto, somando os processos auxiliares que vivem dentro do .app
func readTopApps() -> [Row] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-axo", "rss=,pcpu=,command="]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    task.waitUntilExit()
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

@discardableResult
func sh(_ exe: String, _ args: [String]) -> Data {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: exe)
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    try? task.run()
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return d
}

func ok(_ exe: String, _ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = Pipe(); p.standardError = Pipe()
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

// MARK: - Atualizações (releases do GitHub)

let repoSlug = "nandomontenegro88-spec/mac-memmonitor"
let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"

struct Update { var version: String; var url: URL }

func versionGreater(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
        if p != q { return p > q }
    }
    return false
}

func shText(_ exe: String, _ args: [String]) -> String { String(decoding: sh(exe, args), as: UTF8.self) }

struct Batt {
    var pct = 0, cycles = 0, adapterW = 0
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
    if let ad = b["AdapterDetails"] as? [String: Any] { t.adapterW = (ad["Watts"] as? NSNumber)?.intValue ?? 0 }
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

enum Tab: String, CaseIterable { case mem = "Memória", bat = "Bateria", health = "Saúde" }

// MARK: - Modelo

final class Model: ObservableObject {
    @Published var tab = Tab.mem
    @Published var sliding = false  // true durante o deslize de abas: a rolagem dos números fica parada
    @Published var heroOn: Set<Tab> = []   // abas cujo anel/número já «subiram»: ao voltar a uma aba, a animação repete
    @Published var shown = false   // painel aberto: dispara a entrada animada
    @Published var swap = true     // false por instantes ao trocar de aba: o conteúdo novo entra em cascata
    @Published var mem = readMem()
    @Published var cpu = 0.0
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
    @Published var diskFree = 0.0
    @Published var diskTotal = 0.0
    @Published var down = 0.0
    @Published var up = 0.0
    @Published var loginItems: [String] = []
    @Published var loginNote: String?
    @Published var update: Update?
    @Published var updateState = ""
    private var lastUpdateCheck = Date.distantPast

    private var lastNet: (d: Double, u: Double, t: Date)?
    private var slowStamps: [Tab: Date] = [:]

    /// Uma leitura barata no arranque: a 1.ª abertura já tem lista de apps e bateria, e a altura da janela não salta.
    func prefetch() {
        DispatchQueue.global().async {
            let r = readTopApps(), b = readBattery()
            DispatchQueue.main.async { self.rows = Array(r.prefix(5)); self.cpuRows = Array(r.sorted { $0.cpu > $1.cpu }.prefix(3)); self.batt = b }
        }
    }

    /// Uma amostra de ~16 s (RAM, CPU, bateria), mesmo com o painel fechado; guarda ~2 h para os gráficos.
    func record() {
        let m = readMem().fraction, c = readCPU()
        DispatchQueue.global().async {
            let b = readBattery().map { Double($0.pct) }
            DispatchQueue.main.async {
                self.history.append(Sample(mem: m, cpu: c, batt: b))
                if self.history.count > 450 { self.history.removeFirst(self.history.count - 450) }
            }
        }
    }

    func refresh(visible: Bool) {
        mem = readMem()
        guard visible else { return } // fechado: só a RAM, que alimenta o número da barra
        cpu = readCPU()
        let tab = self.tab
        DispatchQueue.global().async {
            let r = tab != .bat ? readTopApps() : nil
            let b = readBattery()
            let n = tab == .health ? readNet() : nil
            DispatchQueue.main.async {
                if let r { self.rows = Array(r.prefix(5)); self.cpuRows = Array(r.sorted { $0.cpu > $1.cpu }.prefix(3)) }
                if let b { self.batt = b }
                if let n {
                    let now = Date()
                    if let l = self.lastNet, now.timeIntervalSince(l.t) > 0.5 {
                        let dt = now.timeIntervalSince(l.t)
                        self.down = max(n.down - l.d, 0) / dt
                        self.up = max(n.up - l.u, 0) / dt
                    }
                    self.lastNet = (n.down, n.up, now)
                }
            }
        }
        // lazy: o que é lento só é lido quando a aba é aberta, e no máximo 1× por minuto
        if tab != .mem, Date().timeIntervalSince(slowStamps[tab] ?? .distantPast) > 60 { refreshSlow(for: tab) }
    }

    /// Coisas lentas (system_profiler, diskutil, System Events): cada aba só pede o que mostra
    func refreshSlow(for tab: Tab) {
        slowStamps[tab] = Date()
        DispatchQueue.global().async {
            var pct: Int?, word: String?
            if let j = try? JSONSerialization.jsonObject(with: sh("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"])) as? [String: Any],
               let arr = j["SPPowerDataType"] as? [[String: Any]],
               let h = arr.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first {
                pct = Int((h["sppower_battery_health_maximum_capacity"] as? String ?? "").replacingOccurrences(of: "%", with: ""))
                word = h["sppower_battery_health"] as? String
            }
            var lp: Bool?, smart: String?, v: URLResourceValues?, items: [String]?
            if tab == .bat { lp = shText("/usr/bin/pmset", ["-g"]).contains("lowpowermode         1") }
            if tab == .health {
                smart = shText("/usr/sbin/diskutil", ["info", "/"]).split(separator: "\n")
                    .first { $0.contains("SMART Status") }?.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
                v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
                let li = shText("/usr/bin/osascript", ["-e", "tell application \"System Events\" to get name of every login item"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                items = li.isEmpty ? [] : li.components(separatedBy: ", ")
            }
            DispatchQueue.main.async {
                self.healthPct = pct; self.healthWord = word
                if let lp { self.lowPower = lp }
                if tab == .health {
                    self.smart = smart
                    self.diskFree = Double(v?.volumeAvailableCapacityForImportantUsage ?? 0)
                    self.diskTotal = Double(v?.volumeTotalCapacity ?? 0)
                    self.loginItems = items ?? []
                }
            }
        }
    }

    /// Pergunta ao GitHub qual é a última release (no máx. 1× a cada 12 h). Não envia nada do Mac.
    func checkUpdate() {
        guard Date().timeIntervalSince(lastUpdateCheck) > 12 * 3600 else { return }
        lastUpdateCheck = Date()
        let args = CommandLine.arguments
        let override = args.firstIndex(of: "--update-url").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } // só para testes
        guard let api = URL(string: override ?? "https://api.github.com/repos/\(repoSlug)/releases/latest") else { return }
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = j["tag_name"] as? String else { return }
            let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard versionGreater(v, than: currentVersion),
                  let assets = j["assets"] as? [[String: Any]],
                  let a = assets.first(where: { ($0["name"] as? String) == "MemMonitor.zip" }),
                  let s = a["browser_download_url"] as? String, let u = URL(string: s),
                  override != nil || ["github.com", "objects.githubusercontent.com"].contains(u.host ?? "") else { return }
            DispatchQueue.main.async {
                self.update = Update(version: v, url: u)
                if CommandLine.arguments.contains("--auto-update") { self.installUpdate() } // só para testes
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
            func run(_ exe: String, _ args: [String]) -> Bool {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.standardError = Pipe()
                try? p.run()
                p.waitUntilExit()
                return p.terminationStatus == 0
            }
            let ok = run("/usr/bin/sudo", ["-n", "/usr/sbin/purge"])
                || run("/usr/bin/osascript", ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"])
            DispatchQueue.main.async {
                let freed = max(before - readMem().cached, 0)
                self.status = ok ? String(format: "Pronto: %.1f GB de cache liberados", freed / gb) : "Cancelado"
                self.busy = false
                self.refresh(visible: true)
            }
        }
    }

    /// O modo de pouca energia só muda com administrador, por isso pede a palavra-passe do Mac.
    func setLowPower(_ on: Bool) {
        lowPower = on
        DispatchQueue.global().async {
            sh("/usr/bin/osascript", ["-e", "do shell script \"/usr/bin/pmset -a lowpowermode \(on ? 1 : 0)\" with administrator privileges"])
            let real = shText("/usr/bin/pmset", ["-g"]).contains("lowpowermode         1")
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

func pressureInfo(_ p: Int) -> (String, Color) {
    p >= 4 ? ("Memória sob pressão", badColor) : p == 2 ? ("Memória a ficar cheia", warnColor) : ("Tudo certo com a memória", okColor)
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

/// Mola única do anel e do número grande: começam e acabam juntos. Parada durante o deslize de abas.
func heroAnim(_ m: Model) -> Animation? {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.55, dampingFraction: 1)
}

struct Tile: View {
    var label: String, value: String, dot: Color
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
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
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
    var swaps = false
    func body(content: Content) -> some View {
        let on = model.shown && (!swaps || model.swap)
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        content.opacity(on ? 1 : 0)
            .offset(y: on || still ? 0 : 12)
            .animation(.spring(response: 0.45, dampingFraction: 1).delay(Double(i) * 0.05), value: on)
    }
}

extension View {
    func enter(_ m: Model, _ i: Int, swaps: Bool = false) -> some View { modifier(Enter(model: m, i: i, swaps: swaps)) }
}

final class Hover: ObservableObject { @Published var on = false }

struct AppRow: View {
    let row: Row
    let maxBytes: Double
    @StateObject private var h = Hover()
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: row.app.icon ?? NSImage()).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(row.app.localizedName ?? "?").font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                GeometryReader { g in
                    Capsule().fill(Color.white.opacity(0.09))
                        .overlay(alignment: .leading) {
                            Capsule().fill(LinearGradient(colors: [okColor.opacity(0.6), okColor], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(g.size.width * row.bytes / max(maxBytes, 1), 4))
                        }
                }
                .frame(height: 4)
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

struct BatHero: View, Animatable {
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
                .animation(heroAnim(model), value: model.heroOn.contains(.mem) ? model.mem.used : 0)
            .padding(.vertical, 2)

            HStack(spacing: 8) {
                Tile(label: "Apps", value: String(format: "%.1f GB", model.mem.app / gb), dot: okColor)
                Tile(label: "Sistema", value: String(format: "%.1f GB", model.mem.wired / gb), dot: Color(red: 0.38, green: 0.65, blue: 0.98))
                Tile(label: "Comprim.", value: String(format: "%.1f GB", model.mem.compressed / gb), dot: warnColor)
                Tile(label: "CPU", value: String(format: "%.0f%%", model.cpu * 100), dot: Color(red: 0.75, green: 0.52, blue: 0.99))
            }

            VStack(spacing: 7) {
                Button { model.purge() } label: {
                    Label(model.busy ? "A liberar…" : "Liberar memória", systemImage: "sparkles")
                }
                .buttonStyle(Press(fill: color))
                .disabled(model.busy)
                Text(model.status ?? String(format: "Cache de ficheiros: %.1f GB", model.mem.cached / gb))
                    .font(.system(size: 11)).foregroundStyle(muted)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("APPS QUE MAIS USAM").font(.system(size: 10.5, weight: .semibold)).tracking(0.7)
                    .foregroundStyle(muted).padding(.horizontal, 10)
                let mx = model.rows.first?.bytes ?? 1
                VStack(spacing: 0) { ForEach(Array(model.rows.enumerated()), id: \.offset) { _, r in AppRow(row: r, maxBytes: mx) } }
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
            }

        }
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
                BatHero(pct: model.heroOn.contains(.bat) ? Double(b.pct) : 0, color: color,
                        caption: b.charging ? (b.minutes.map { "cheia em \(fmtMin($0))" } ?? "a calcular…")
                            : b.plugged ? (b.pct >= 100 ? "carregada" : "carga em pausa")
                            : (b.minutes.map { "restam \(fmtMin($0))" } ?? "a calcular…"))
                    .padding(.vertical, 2)
                    .animation(heroAnim(model), value: model.heroOn.contains(.bat) ? b.pct : 0)

                HStack(spacing: 8) {
                    Tile(label: b.watts >= 0 ? "A entrar" : "Consumo", value: String(format: "%.0f W", abs(b.watts)), dot: okColor)
                    Tile(label: "Carregador", value: b.plugged ? "\(b.adapterW) W" : "—", dot: Color(red: 0.38, green: 0.65, blue: 0.98))
                    Tile(label: "Saúde", value: model.healthPct.map { "\($0)%" } ?? "—", dot: warnColor)
                    Tile(label: "Ciclos", value: "\(b.cycles)", dot: Color(red: 0.75, green: 0.52, blue: 0.99))
                }

                if b.plugged && b.adapterW > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Potência do carregador").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                            Spacer()
                            Text(String(format: "%.0f de %d W", max(b.watts, 0), b.adapterW)).font(.system(size: 12)).monospacedDigit().foregroundStyle(muted)
                        }
                        GeometryReader { g in
                            Capsule().fill(Color.white.opacity(0.09)).overlay(alignment: .leading) {
                                Capsule().fill(LinearGradient(colors: [okColor.opacity(0.6), okColor], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(g.size.width * max(b.watts, 0) / Double(b.adapterW), 4))
                            }
                        }.frame(height: 6)
                    }
                    .padding(12).glassCard()
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

                HStack(spacing: 10) {
                    Image(systemName: "leaf.fill").foregroundStyle(okColor).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Modo de pouca energia").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        Text("Poupa bateria; pede a palavra-passe").font(.system(size: 11)).foregroundStyle(muted)
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
                Tile(label: "Disco livre", value: model.diskTotal > 0 ? String(format: "%.0f GB", model.diskFree / gb) : "—", dot: okColor)
                Tile(label: "SMART", value: model.smart == "Verified" ? "OK" : (model.smart ?? "—"), dot: Color(red: 0.38, green: 0.65, blue: 0.98))
                Tile(label: "Ligado há", value: fmtUptime(bootUptime()), dot: warnColor)
                Tile(label: "Térmico", value: thermal == .nominal ? "Normal" : thermal == .fair ? "Morno" : "Quente", dot: Color(red: 0.75, green: 0.52, blue: 0.99))
            }

            HStack(spacing: 0) {
                Label(fmtRate(model.down), systemImage: "arrow.down").frame(maxWidth: .infinity)
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 18)
                Label(fmtRate(model.up), systemImage: "arrow.up").frame(maxWidth: .infinity)
            }
            .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.white)
            .padding(.vertical, 11).glassCard()

            VStack(alignment: .leading, spacing: 4) {
                Text("MAIS USAM A CPU").font(.system(size: 10.5, weight: .semibold)).tracking(0.7)
                    .foregroundStyle(muted).padding(.horizontal, 10)
                VStack(spacing: 0) {
                    ForEach(Array(model.cpuRows.enumerated()), id: \.offset) { _, r in
                        HStack(spacing: 10) {
                            Image(nsImage: r.app.icon ?? NSImage()).resizable().frame(width: 22, height: 22)
                            Text(r.app.localizedName ?? "?").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f%%", r.cpu)).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(muted)
                        }
                        .padding(.vertical, 5).padding(.horizontal, 10)
                    }
                    if model.cpuRows.isEmpty { Text("A ler…").font(.system(size: 12)).foregroundStyle(muted).padding(10).frame(maxWidth: .infinity) }
                }
                .padding(.vertical, 3).glassCard()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Atividade recente").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    Spacer()
                    HStack(spacing: 4) { Circle().fill(warnColor).frame(width: 6, height: 6); Text("RAM").font(.system(size: 10.5)).foregroundStyle(muted) }
                    HStack(spacing: 4) { Circle().fill(Color(red: 0.75, green: 0.52, blue: 0.99)).frame(width: 6, height: 6); Text("CPU").font(.system(size: 10.5)).foregroundStyle(muted) }
                }
                if model.history.count > 1 {
                    ZStack {
                        Spark(values: model.history.map { $0.mem }, color: warnColor)
                        Spark(values: model.history.map { $0.cpu }, color: Color(red: 0.75, green: 0.52, blue: 0.99))
                    }.frame(height: 34)
                } else {
                    Text("A recolher dados…").font(.system(size: 11)).foregroundStyle(muted).frame(height: 34)
                }
            }
            .padding(12).glassCard()

            VStack(alignment: .leading, spacing: 4) {
                Text("ABREM AO LIGAR O MAC").font(.system(size: 10.5, weight: .semibold)).tracking(0.7)
                    .foregroundStyle(muted).padding(.horizontal, 10)
                VStack(spacing: 0) {
                    if model.loginItems.isEmpty {
                        Text("Nenhum item").font(.system(size: 12)).foregroundStyle(muted).padding(12).frame(maxWidth: .infinity)
                    }
                    ForEach(Array(model.loginItems.prefix(2)), id: \.self) { n in LoginRow(name: n) { model.removeLoginItem(n) } }
                    if model.loginItems.count > 2 {
                        Text("+\(model.loginItems.count - 2) mais").font(.system(size: 11)).foregroundStyle(muted).padding(8)
                    }
                }
                .padding(.vertical, 4).glassCard()
            }
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
            let w = (g.size.width - 6 - 4) / 3 // 3 pt de margem de cada lado, 2 pt entre separadores
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
    var visible: Bool { panel?.isVisible ?? false }
    var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Memória")
        item.button?.imagePosition = .imageLeading
        model.prefetch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.model.checkUpdate() }
        _ = makePanel() // criar a janela só ao abrir deixa-a em branco no 1.º quadro; os dados é que são lazy
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }

        if CommandLine.arguments.contains("--show") {
            if let i = CommandLine.arguments.firstIndex(of: "--tab"), let t = Tab(rawValue: CommandLine.arguments[i + 1]) { model.tab = t }
            if CommandLine.arguments.contains("--switch") { DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.model.tab = .health } }
            if CommandLine.arguments.contains("--back") { DispatchQueue.main.asyncAfter(deadline: .now() + 13) { self.model.tab = .mem } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.toggle()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { print("WIN", self.panel?.windowNumber ?? 0, "alpha", self.panel?.alphaValue ?? -1, "frame", self.panel?.frame ?? .zero, "host", self.host?.frame ?? .zero, "tab", self.model.tab.rawValue, "shown", self.model.shown, "vis", self.visible); fflush(stdout) }
            }
        }
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

        // a altura muda quando chegam dados novos
        model.$rows.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.resize() }.store(in: &bag)
        model.$batt.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.resize() }.store(in: &bag)
        model.$loginItems.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.resize() }.store(in: &bag)
        model.$update.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.resize() }.store(in: &bag)
        // trocar de aba: o conteúdo antigo sai, o novo entra em cascata
        model.$tab.dropFirst().sink { [weak self] t in
            guard let self else { return }
            // a aba que chega «sobe» de 0 ao valor enquanto desliza; a que sai só zera depois de sair de vista
            let old = self.prevTab
            self.prevTab = t
            self.model.heroOn.insert(t)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if self.model.tab != old { self.model.heroOn.remove(old) } }
            self.model.sliding = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.model.sliding = false }
            self.model.refresh(visible: true)
            DispatchQueue.main.async { self.resize() }
        }.store(in: &bag)
        return p
    }

    func tick() {
        ticks += 1
        // fechado: só atualiza o número da barra, de 6 em 6 s
        if ticks % 8 == 1 { model.record() }
        if ticks % 1800 == 0 { model.checkUpdate() } // a cada ~1 h tenta; só consulta o GitHub se passaram 12 h
        if !visible && ticks > 1 && ticks % 3 != 0 { return }
        model.refresh(visible: visible)
        item.button?.title = String(format: " %.1f GB", model.mem.used / gb)
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
        if CommandLine.arguments.contains("--show") { print("WIN0", panel.windowNumber); fflush(stdout) }
        DispatchQueue.main.async { self.model.shown = true; self.model.heroOn = [self.model.tab]; self.prevTab = self.model.tab } // dispara a cascata dos blocos e o anel a encher
        if !CommandLine.arguments.contains("--show") { // em teste o painel não fecha com cliques de fora
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let d = Delegate()
app.delegate = d
app.run()
