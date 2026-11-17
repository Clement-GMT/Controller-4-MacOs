import GameController
import SwiftUI

@MainActor
private final class InputSample: ObservableObject {
    @Published var controller = ""
    @Published var pressed: Set<String> = []
    @Published var left = CGPoint.zero
    @Published var right = CGPoint.zero
    @Published var leftTrigger: Float = 0
    @Published var rightTrigger: Float = 0

    func update() {
        guard let device = GCController.current ?? GCController.controllers().first else {
            if !controller.isEmpty {
                controller = ""
                pressed = []
                left = .zero
                right = .zero
                leftTrigger = 0
                rightTrigger = 0
            }
            return
        }
        guard let gamepad = device.extendedGamepad else { return }
        controller = device.vendorName ?? "Manette"
        let buttons: [(String, GCControllerButtonInput?)] = [
            ("A", gamepad.buttonA), ("B", gamepad.buttonB), ("X", gamepad.buttonX), ("Y", gamepad.buttonY),
            ("LB", gamepad.leftShoulder), ("RB", gamepad.rightShoulder),
            ("↑", gamepad.dpad.up), ("↓", gamepad.dpad.down), ("←", gamepad.dpad.left), ("→", gamepad.dpad.right),
            ("L3", gamepad.leftThumbstickButton), ("R3", gamepad.rightThumbstickButton),
            ("Menu", gamepad.buttonMenu), ("Options", gamepad.buttonOptions)
        ]
        pressed = Set(buttons.compactMap { title, input in input?.isPressed == true ? title : nil })
        left = CGPoint(x: Double(gamepad.leftThumbstick.xAxis.value), y: Double(gamepad.leftThumbstick.yAxis.value))
        right = CGPoint(x: Double(gamepad.rightThumbstick.xAxis.value), y: Double(gamepad.rightThumbstick.yAxis.value))
        leftTrigger = gamepad.leftTrigger.value
        rightTrigger = gamepad.rightTrigger.value
    }
}

struct ControllerTestView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var sample = InputSample()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Test des entrées").font(.title2.bold())
                    Text(sample.controller.isEmpty ? "En attente d’une manette macOS" : sample.controller)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 22) {
                stick("Stick gauche", value: sample.left)
                stick("Stick droit", value: sample.right)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach([["A", "B", "X", "Y"], ["↑", "↓", "←", "→"], ["LB", "RB", "L3", "R3"], ["Menu", "Options"]], id: \.self) { row in
                        HStack(spacing: 5) {
                            ForEach(row, id: \.self) { name in
                                Text(name)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .frame(minWidth: 30, minHeight: 24)
                                    .padding(.horizontal, 2)
                                    .foregroundStyle(sample.pressed.contains(name) ? .black : .primary)
                                    .background(sample.pressed.contains(name) ? Color.accentColor : Color.white.opacity(0.08),
                                                in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
            }
            HStack(spacing: 20) {
                ProgressView(value: Double(sample.leftTrigger)) { Text("Gâchette gauche") }
                ProgressView(value: Double(sample.rightTrigger)) { Text("Gâchette droite") }
            }
            if sample.controller.isEmpty {
                Text("Active la manette et appuie sur un bouton. Avec un profil Steam/SDL fixe, utilise le test intégré à Steam.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(25)
        .frame(width: 516)
        .task {
            while !Task.isCancelled {
                sample.update()
                try? await Task.sleep(for: .milliseconds(45))
            }
        }
    }

    private func stick(_ title: String, value: CGPoint) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(.white.opacity(0.045))
                Circle().strokeBorder(.white.opacity(0.14))
                Circle().strokeBorder(.white.opacity(0.12)).padding(19)
                Circle().fill(Color.accentColor)
                    .frame(width: 13, height: 13)
                    .offset(x: value.x * 40, y: -value.y * 40)
            }
            .frame(width: 98, height: 98)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("X \(Double(value.x).formatted(.number.precision(.fractionLength(2)))) Y \(Double(value.y).formatted(.number.precision(.fractionLength(2))))")
    }
}
