import AppKit
import SwiftUI

enum ControllerModel: String, CaseIterable, Identifiable {
    case xbox, scuf, joycon2

    var id: String { rawValue }
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var title: String {
        switch self {
        case .xbox: "Xbox One"
        case .scuf: "SCUF Valor Pro"
        case .joycon2: "Joy-Con 2"
        }
    }

    var transport: String { self == .joycon2 ? "Bluetooth" : "USB filaire" }
    var symbol: String { self == .joycon2 ? "antenna.radiowaves.left.and.right" : "cable.connector" }

    var accent: Color {
        switch self {
        case .xbox: Color(red: 0.61, green: 0.96, blue: 0.77)
        case .scuf: Color(red: 0.45, green: 0.89, blue: 0.98)
        case .joycon2: Color(red: 0.74, green: 0.70, blue: 1.00)
        }
    }

    var connectHint: String {
        switch self {
        case .xbox: "Branche la manette en USB. Quitte Steam avec ⌘Q avant d’activer le pont."
        case .scuf: "Branche la SCUF en USB, active le pont, puis appuie sur A."
        case .joycon2: "Maintiens SYNC sur chaque Joy-Con déconnecté. Le pont réunit automatiquement la paire."
        }
    }

    var supportedModes: [ConnectionMode] {
        self == .xbox ? ConnectionMode.allCases : [.automatic, .mac, .sdl]
    }
}

enum ConnectionMode: String, CaseIterable, Identifiable {
    case automatic
    case mac = "game-controller-compatible"
    case sdl = "sdl-compatible"
    case steam = "steam-direct"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatique"
        case .mac: "macOS et Safari"
        case .sdl: "Steam et SDL"
        case .steam: "Steam en USB direct"
        }
    }

    var hint: String {
        switch self {
        case .automatic: "Le profil suit le jeu au premier plan."
        case .mac: "Pour les jeux macOS et Xbox Cloud Gaming dans Safari."
        case .sdl: "Profil fixe pour Steam et les jeux SDL."
        case .steam: "Ouvre Steam avec la manette en USB direct."
        }
    }
}

@MainActor
final class ControllerSession: ObservableObject {
    @Published private(set) var model: ControllerModel = .xbox
    @Published var mode = ConnectionMode.automatic
    @Published private(set) var output = ""
    @Published private(set) var running = false
    @Published private(set) var stopping = false
    @Published private(set) var connected = false
    @Published private(set) var headline = "En attente"
    @Published private(set) var driver = DriverStatus.initial
    @Published var showsJournal = false
    @Published var showsTester = false

    private var process: Process?
    private var generation = UUID()
    private var pending = Data()
    private var polling = false
    private var currentCommand = ""
    var onStop: (() -> Void)?

    static let driverPage = URL(string: "https://github.com/xsyetopz/OpenJoystickDriver/releases/tag/0.6.0-alpha.2")!
    private var launcher: URL? { Bundle.main.url(forResource: "launcher", withExtension: "zsh") }

    func select(_ option: ControllerModel) {
        guard !running, option != model else { return }
        model = option
        if !option.supportedModes.contains(mode) { mode = .automatic }
        headline = "En attente"
        output = ""
        Task { await refreshDriver() }
    }

    func step(_ direction: Int) {
        let choices = ControllerModel.allCases
        select(choices[(model.index + direction + choices.count) % choices.count])
    }

    func connectOrStop() {
        if running { stop() } else { run(mode.rawValue) }
    }

    func diagnostic() {
        showsJournal = true
        run("diagnostic")
    }

    func refreshDriver() async {
        guard !polling, let launcher else { return }
        polling = true
        let batteries = model == .joycon2
        let snapshot = await Task.detached(priority: .utility) {
            DriverStatus.read(launcher: launcher, batteries: batteries)
        }.value
        polling = false
        if !Task.isCancelled { driver = snapshot }
    }

    private func run(_ command: String) {
        guard process == nil, let launcher else { return }
        let runID = UUID()
        generation = runID
        pending.removeAll()
        output = ""
        connected = false
        currentCommand = command
        headline = command == "diagnostic" ? "Diagnostic en cours" : "Connexion en cours"

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = [launcher.path, model.rawValue, command]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = pipe
        task.standardError = pipe
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { self?.receive(bytes, from: runID) }
        }
        task.terminationHandler = { [weak self] finished in
            let result = finished.terminationStatus
            DispatchQueue.main.async {
                guard let self, self.generation == runID else { return }
                self.process = nil
                self.running = false
                self.connected = false
                self.headline = self.stopping ? "Pont arrêté" : result == 0 ? "Terminé" : "Consulte le journal"
                if !self.stopping && result != 0 { self.showsJournal = true }
                self.stopping = false
                self.onStop?()
                Task { await self.refreshDriver() }
            }
        }
        do {
            try task.run()
            try? pipe.fileHandleForWriting.close()
            process = task
            running = true
            Task { await refreshDriver() }
        } catch {
            reader.readabilityHandler = nil
            output = "Impossible de lancer le pont. \(error.localizedDescription)"
            headline = "Consulte le journal"
            showsJournal = true
        }
    }

    private func receive(_ bytes: Data, from runID: UUID) {
        guard generation == runID else { return }
        pending.append(bytes)
        var ready = ""
        if let newline = pending.lastIndex(of: 10) {
            ready = String(decoding: pending[...newline], as: UTF8.self)
            pending.removeSubrange(...newline)
        }
        if bytes.isEmpty && !pending.isEmpty {
            ready += String(decoding: pending, as: UTF8.self)
            pending.removeAll()
        }
        output += ready
        if output.count > 16_000 { output = String(output.suffix(12_000)) }
        guard running, !stopping, currentCommand != "diagnostic" else { return }
        for line in ready.split(separator: "\n") {
            if line.contains("Manette virtuelle prête") || line.contains("Publication d’une manette virtuelle") {
                connected = true
                headline = line.contains("paire Joy-Con 2") ? "Paire prête" : "Manette prête"
            } else if line.contains("Connexion USB interrompue") || line.contains("Reconnexion de la manette virtuelle") ||
                        line.contains("Joy-Con 2 gauche déconnecté") || line.contains("Joy-Con 2 droit déconnecté") {
                connected = false
                headline = "Reconnexion en cours"
            }
        }
    }

    func stop() {
        guard let process, process.isRunning, !stopping else { return }
        stopping = true
        headline = "Arrêt en cours"
        process.terminate()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = ControllerSession()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard session.running else { return .terminateNow }
        session.onStop = { [weak session] in
            session?.onStop = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        session.stop()
        return .terminateLater
    }
}

private let muted = Color(red: 0.73, green: 0.78, blue: 0.87)
private let quiet = Color(red: 0.59, green: 0.65, blue: 0.77)
private let panel = Color(red: 0.076, green: 0.100, blue: 0.168)
private let hairline = Color.white.opacity(0.105)

struct Dashboard: View {
    @ObservedObject var session: ControllerSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                carousel
                settings
                if session.model == .joycon2 { batteries }
                if session.showsJournal { journal }
            }
            .padding(.horizontal, 34)
            .padding(.top, 24)
            .padding(.bottom, 30)
            .frame(maxWidth: 1_250)
            .frame(maxWidth: .infinity)
        }
        .background {
            LinearGradient(colors: [Color(red: 0.045, green: 0.060, blue: 0.11), Color(red: 0.028, green: 0.036, blue: 0.068)],
                           startPoint: .top, endPoint: .bottom)
        }
        .preferredColorScheme(.dark)
        .tint(session.model.accent)
        .sheet(isPresented: $session.showsTester) { ControllerTestView() }
        .task {
            while !Task.isCancelled {
                if NSApp.isActive { await session.refreshDriver() }
                try? await Task.sleep(for: .seconds(7))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await session.refreshDriver() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:)) {
                Image(nsImage: icon).resizable().interpolation(.high)
                    .frame(width: 48, height: 48).accessibilityHidden(true)
            }
            Text("Controller 4 MacOs")
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.7)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            switch session.driver.availability {
            case .running:
                statusPill("Pilote actif", tint: Color(red: 0.63, green: 0.94, blue: 0.76))
            case .idle:
                statusPill("Pilote installé", tint: quiet)
            case .unreachable:
                statusPill("Pilote à vérifier", tint: Color(red: 1, green: 0.74, blue: 0.52))
            case .missing:
                Link(destination: ControllerSession.driverPage) {
                    Label("Installer le pilote", systemImage: "arrow.down.to.line")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(hairline, in: Capsule())
                }
                .help("Télécharger OpenJoystickDriver")
            }
        }
    }

    private var carousel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choisir une manette")
                .font(.system(size: 16, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            ZStack {
                RoundedRectangle(cornerRadius: 26)
                    .fill(Color(red: 0.073, green: 0.098, blue: 0.17))
                RadialGradient(colors: [session.model.accent.opacity(0.30), Color(red: 0.082, green: 0.109, blue: 0.21).opacity(0.40), .clear],
                               center: .init(x: 0.5, y: 0.48), startRadius: 15, endRadius: 386)
                    .clipShape(RoundedRectangle(cornerRadius: 26))
                RoundedRectangle(cornerRadius: 26).strokeBorder(hairline)

                VStack(spacing: 0) {
                    ZStack {
                        OrbitLines()
                        ControllerStage(model: session.model, reduceMotion: reduceMotion, onStep: session.step)
                            .accessibilityHidden(true)
                        HStack {
                            arrow(-1)
                            Spacer()
                            arrow(1)
                        }
                        .padding(.horizontal, 16)
                    }
                    .frame(height: 250)

                    VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            ForEach(ControllerModel.allCases) { option in
                                Button { session.select(option) } label: {
                                    Capsule().fill(option == session.model ? session.model.accent : .white.opacity(0.22))
                                        .frame(width: option == session.model ? 23 : 7, height: 6)
                                        .frame(minWidth: 19, minHeight: 24)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(session.running)
                                .accessibilityLabel(option.title)
                                .accessibilityAddTraits(option == session.model ? .isSelected : [])
                            }
                        }
                        HStack(spacing: 9) {
                            Text(session.model.title)
                                .font(.system(size: 34, weight: .bold))
                                .tracking(-1.15)
                                .accessibilityAddTraits(.isHeader)
                            Label(session.model.transport, systemImage: session.model.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(muted)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(hairline, in: Capsule())
                        }
                    }
                    .padding(.bottom, 21)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Carrousel de manettes")
            .onMoveCommand { direction in
                if direction == .left { session.step(-1) }
                if direction == .right { session.step(1) }
            }
        }
    }

    private func arrow(_ direction: Int) -> some View {
        Button { session.step(direction) } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 43, height: 43)
                .background(Color.black.opacity(0.30), in: Circle())
                .overlay { Circle().strokeBorder(Color.white.opacity(0.18)) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(session.running)
        .keyboardShortcut(direction < 0 ? .leftArrow : .rightArrow, modifiers: [])
        .help(direction < 0 ? "Manette précédente" : "Manette suivante")
        .accessibilityLabel(direction < 0 ? "Manette précédente" : "Manette suivante")
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Profil de jeu").font(.system(size: 14, weight: .semibold))
                    Text(session.mode.hint).font(.system(size: 12)).foregroundStyle(muted)
                }
                Spacer(minLength: 8)
                Picker("Profil de jeu", selection: $session.mode) {
                    ForEach(session.model.supportedModes) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 181)
                .disabled(session.running)
            }
            Divider().overlay(hairline)
            HStack(spacing: 9) {
                Button(action: session.connectOrStop) {
                    Label(session.running ? "Arrêter" : "Activer le pont",
                          systemImage: session.running ? "stop.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 38)
                        .foregroundStyle(Color(red: 0.027, green: 0.077, blue: 0.13))
                        .background(session.model.accent, in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(session.stopping || (session.driver.availability == .missing && session.mode != .steam))
                Button { session.showsTester = true } label: {
                    Label("Tester", systemImage: "gamecontroller")
                }
                .buttonStyle(UtilityButtonStyle())
                Button(action: session.diagnostic) {
                    Label("Diagnostic", systemImage: "stethoscope")
                }
                .buttonStyle(UtilityButtonStyle())
                .disabled(session.running)
                Button { session.showsJournal.toggle() } label: {
                    Image(systemName: "text.alignleft")
                }
                .buttonStyle(UtilityButtonStyle())
                .help(session.showsJournal ? "Masquer le journal" : "Afficher le journal")
                .accessibilityLabel(session.showsJournal ? "Masquer le journal" : "Afficher le journal")
                Spacer(minLength: 9)
                statusPill(session.headline, tint: session.connected ? session.model.accent : muted)
            }
            Text(session.model.connectHint)
                .font(.system(size: 12))
                .foregroundStyle(quiet)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(17)
        .background(panel, in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(hairline) }
    }

    private func statusPill(_ text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.105), in: Capsule())
    }

    private var batteries: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Batterie des Joy-Con").font(.system(size: 14, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 12) {
                batteryTile("Gauche", status: session.driver.left, tint: Color(red: 0.50, green: 0.80, blue: 1))
                batteryTile("Droit", status: session.driver.right, tint: Color(red: 1, green: 0.62, blue: 0.54))
            }
        }
    }

    private func batteryTile(_ title: String, status: JoyConStatus, tint: Color) -> some View {
        let value = status.battery?.label ?? (status.connected ? "En attente" : "Déconnecté")
        return HStack(spacing: 10) {
            Image(systemName: status.charging ? "battery.100percent.bolt" : batteryIcon(status.battery?.percent))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(value).font(.system(size: 13, weight: status.battery == nil ? .regular : .bold))
                .monospacedDigit()
                .foregroundStyle(status.battery == nil ? quiet : tint)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(hairline) }
        .accessibilityElement(children: .combine)
        .help(status.battery?.details ?? "Le niveau s’affiche quand le pilote reçoit des données.")
    }

    private func batteryIcon(_ level: Int?) -> String {
        guard let level else { return "battery.0percent" }
        switch level {
        case 0...12: return "battery.0percent"
        case 13...38: return "battery.25percent"
        case 39...62: return "battery.50percent"
        case 63...87: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var journal: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Journal de connexion").font(.system(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Copier") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.output, forType: .string)
                }
                .buttonStyle(.plain)
                .foregroundStyle(session.model.accent)
                .disabled(session.output.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.output.isEmpty ? "Le journal s’affiche après l’activation ou le diagnostic." : session.output)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: session.output) { proxy.scrollTo("end", anchor: .bottom) }
                .frame(height: 122)
                .background(Color.black.opacity(0.21), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

private struct OrbitLines: View {
    var body: some View {
        Canvas { context, size in
            for index in 0..<4 {
                let inset = CGFloat(index) * 23
                let rect = CGRect(x: size.width * 0.18 + inset,
                                  y: size.height * 0.83 - CGFloat(index) * 10,
                                  width: size.width * 0.64 - inset * 2,
                                  height: 39 + CGFloat(index) * 12)
                context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.055)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct UtilityButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(enabled ? muted : quiet.opacity(0.6))
            .padding(.horizontal, 11)
            .frame(minHeight: 37)
            .background(Color.white.opacity(configuration.isPressed ? 0.15 : 0.055),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(hairline) }
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

@main
struct PontManettesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Controller 4 MacOs", id: "main") {
            Dashboard(session: delegate.session)
                .frame(minWidth: 720, minHeight: 580)
        }
        .defaultSize(width: 940, height: 715)
        .windowStyle(.hiddenTitleBar)
    }
}
