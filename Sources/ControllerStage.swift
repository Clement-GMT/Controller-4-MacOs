import AppKit
import SceneKit
import SwiftUI

struct ControllerStage: NSViewRepresentable {
    let model: ControllerModel
    let reduceMotion: Bool
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> StageView {
        StageView()
    }

    func updateNSView(_ view: StageView, context: Context) {
        view.onStep = onStep
        view.show(model, animated: !reduceMotion)
    }
}

final class StageView: SCNView {
    var onStep: ((Int) -> Void)?
    private var models: [SCNNode] = []
    private var selected: ControllerModel?
    private var dragStart: CGFloat?
    private var scrollDistance: CGFloat = 0
    private var scrollLocked = false
    private var lastScrollTime: TimeInterval = 0

    init() {
        super.init(frame: .zero, options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
        let stage = SCNScene()
        scene = stage
        backgroundColor = .clear
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 60

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 29
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 65
        camera.position = SCNVector3(0, 0.0, 10.4)
        stage.rootNode.addChildNode(camera)
        pointOfView = camera

        addLight(.ambient, rgb(0xbecfff), 360, SCNVector3Zero)
        addLight(.omni, rgb(0xf9f7ff), 780, SCNVector3(-3, 5, 6))
        addLight(.omni, rgb(0xa9c1ff), 390, SCNVector3(4, -1.5, 4))
        addLight(.omni, rgb(0xa197ff), 320, SCNVector3(0, 3, -2))
        models = ControllerModel.allCases.map { model in
            let node: SCNNode
            switch model {
            case .xbox: node = standardPad(scuf: false)
            case .scuf: node = standardPad(scuf: true)
            case .joycon2: node = joyCons()
            }
            stage.rootNode.addChildNode(node)
            return node
        }
    }

    required init?(coder: NSCoder) { nil }

    private func addLight(_ type: SCNLight.LightType, _ color: NSColor, _ intensity: CGFloat, _ position: SCNVector3) {
        let node = SCNNode()
        let light = SCNLight()
        light.type = type
        light.color = color
        light.intensity = intensity
        node.light = light
        node.position = position
        scene?.rootNode.addChildNode(node)
    }

    func show(_ model: ControllerModel, animated: Bool) {
        guard model != selected else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = selected == nil || !animated ? 0 : 0.52
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        selected = model
        for (index, node) in models.enumerated() {
            let offset = (index - model.index + models.count) % models.count
            switch offset {
            case 0:
                node.position = SCNVector3(0, 0.05, 1.2)
                node.eulerAngles = SCNVector3(0.11, -0.13, -0.025)
                node.scale = SCNVector3(1.02, 1.02, 1.02)
                node.opacity = 1
            default:
                let side: CGFloat = offset == 1 ? 1 : -1
                node.position = SCNVector3(side * 4.45, -0.02, -2.45)
                node.eulerAngles = SCNVector3(0.11, side * -0.46, side * -0.06)
                node.scale = SCNVector3(0.76, 0.76, 0.76)
                node.opacity = 0.48
            }
        }
        SCNTransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil).x
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        dragStart = nil
        let end = convert(event.locationInWindow, from: nil).x
        let delta = end - start
        if abs(delta) > 32 {
            onStep?(delta < 0 ? 1 : -1)
        } else if end < bounds.width * 0.30 {
            onStep?(-1)
        } else if end > bounds.width * 0.70 {
            onStep?(1)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), event.momentumPhase.isEmpty else {
            return
        }
        if event.phase == .began || event.timestamp - lastScrollTime > 0.38 {
            scrollDistance = 0
            scrollLocked = false
        }
        lastScrollTime = event.timestamp
        guard !scrollLocked else { return }
        scrollDistance += event.scrollingDeltaX
        if abs(scrollDistance) > 38 {
            scrollLocked = true
            onStep?(scrollDistance < 0 ? 1 : -1)
        }
    }
}

private func rgb(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: 1)
}

private let darkPlastic: UInt32 = 0x101621
private let gripPlastic: UInt32 = 0x202a39

private func material(_ color: UInt32, roughness: CGFloat = 0.43, metalness: CGFloat = 0.04) -> SCNMaterial {
    let result = SCNMaterial()
    result.lightingModel = .physicallyBased
    result.diffuse.contents = rgb(color)
    result.roughness.contents = roughness
    result.metalness.contents = metalness
    return result
}

@discardableResult
private func add(_ geometry: SCNGeometry, to parent: SCNNode, _ x: CGFloat, _ y: CGFloat, _ z: CGFloat,
                 color: UInt32, roughness: CGFloat = 0.43) -> SCNNode {
    geometry.firstMaterial = material(color, roughness: roughness)
    let node = SCNNode(geometry: geometry)
    node.position = SCNVector3(x, y, z)
    parent.addChildNode(node)
    return node
}

@discardableResult
private func box(_ parent: SCNNode, _ width: CGFloat, _ height: CGFloat, _ depth: CGFloat, _ radius: CGFloat,
                 _ x: CGFloat, _ y: CGFloat, _ z: CGFloat, color: UInt32) -> SCNNode {
    add(SCNBox(width: width, height: height, length: depth, chamferRadius: radius),
        to: parent, x, y, z, color: color)
}

private func disk(_ parent: SCNNode, radius: CGFloat, depth: CGFloat, x: CGFloat, y: CGFloat, z: CGFloat, color: UInt32) {
    let cylinder = SCNCylinder(radius: radius, height: depth)
    cylinder.radialSegmentCount = 36
    let node = add(cylinder, to: parent, x, y, z, color: color, roughness: 0.37)
    node.eulerAngles.x = .pi / 2
}

private func ring(_ parent: SCNNode, radius: CGFloat, tube: CGFloat, x: CGFloat, y: CGFloat, z: CGFloat, color: UInt32) {
    let geometry = SCNTorus(ringRadius: radius, pipeRadius: tube)
    geometry.ringSegmentCount = 38
    geometry.pipeSegmentCount = 10
    let node = add(geometry, to: parent, x, y, z, color: color)
    node.eulerAngles.x = .pi / 2
}

private func stick(_ parent: SCNNode, x: CGFloat, y: CGFloat, z: CGFloat, ringColor: UInt32 = 0x242e3b, scale: CGFloat = 1) {
    disk(parent, radius: 0.37 * scale, depth: 0.08, x: x, y: y, z: z, color: darkPlastic)
    ring(parent, radius: 0.29 * scale, tube: 0.025, x: x, y: y, z: z + 0.055, color: ringColor)
    disk(parent, radius: 0.23 * scale, depth: 0.16, x: x, y: y, z: z + 0.12, color: 0x111924)
    ring(parent, radius: 0.20 * scale, tube: 0.031 * scale, x: x, y: y, z: z + 0.207, color: 0x364253)
    disk(parent, radius: 0.17 * scale, depth: 0.015, x: x, y: y, z: z + 0.20, color: 0x232d3b)
}

private func glyph(_ parent: SCNNode, _ text: String, x: CGFloat, y: CGFloat, z: CGFloat, height: CGFloat, color: UInt32) {
    let label = SCNText(string: text, extrusionDepth: 0.002)
    label.font = .monospacedSystemFont(ofSize: 1, weight: .bold)
    label.flatness = 0.05
    let ink = SCNMaterial()
    ink.lightingModel = .constant
    ink.diffuse.contents = rgb(color)
    label.firstMaterial = ink
    let node = SCNNode(geometry: label)
    let (min, max) = node.boundingBox
    guard max.y > min.y else { return }
    let ratio = height / (max.y - min.y)
    node.pivot = SCNMatrix4MakeTranslation((min.x + max.x) / 2, (min.y + max.y) / 2, 0)
    node.scale = SCNVector3(ratio, ratio, ratio)
    node.position = SCNVector3(x, y, z)
    parent.addChildNode(node)
}

private func faceButtons(_ parent: SCNNode, x: CGFloat, y: CGFloat, z: CGFloat,
                         nintendo: Bool = false, colored: Bool = false) {
    let separation: CGFloat = nintendo ? 0.185 : 0.245
    let positions: [(CGFloat, CGFloat, String, UInt32)] = [
        (0, separation, nintendo ? "X" : "Y", 0xffca61),
        (separation, 0, nintendo ? "A" : "B", 0xff7781),
        (0, -separation, nintendo ? "B" : "A", 0x7ee6ad),
        (-separation, 0, nintendo ? "Y" : "X", 0x7ec4ff)
    ]
    for (dx, dy, label, tint) in positions {
        disk(parent, radius: nintendo ? 0.097 : 0.126, depth: 0.10, x: x + dx, y: y + dy, z: z, color: darkPlastic)
        glyph(parent, label, x: x + dx, y: y + dy, z: z + 0.052, height: nintendo ? 0.083 : 0.102,
              color: colored ? tint : 0xe1e8f3)
    }
}

private func gamepadShell(scuf: Bool) -> SCNShape {
    let path = NSBezierPath()
    path.flatness = 0.012
    path.move(to: .init(x: -1.36, y: 0.96))
    path.curve(to: .init(x: 1.36, y: 0.96), controlPoint1: .init(x: -0.70, y: 1.02), controlPoint2: .init(x: 0.70, y: 1.02))
    path.curve(to: .init(x: 1.90, y: 0.46), controlPoint1: .init(x: 1.68, y: 0.92), controlPoint2: .init(x: 1.80, y: 0.75))
    path.curve(to: .init(x: 2.18, y: -1.10), controlPoint1: .init(x: 2.03, y: 0.06), controlPoint2: .init(x: 2.20, y: -0.72))
    path.curve(to: .init(x: 1.51, y: -1.29), controlPoint1: .init(x: 2.16, y: -1.48), controlPoint2: .init(x: 1.76, y: -1.48))
    path.curve(to: .init(x: 0.79, y: -0.53), controlPoint1: .init(x: 1.18, y: -1.00), controlPoint2: .init(x: 1.01, y: -0.65))
    path.curve(to: .init(x: -0.79, y: -0.53), controlPoint1: .init(x: 0.52, y: -0.43), controlPoint2: .init(x: -0.52, y: -0.43))
    path.curve(to: .init(x: -1.51, y: -1.29), controlPoint1: .init(x: -1.01, y: -0.65), controlPoint2: .init(x: -1.18, y: -1.00))
    path.curve(to: .init(x: -2.18, y: -1.10), controlPoint1: .init(x: -1.76, y: -1.48), controlPoint2: .init(x: -2.16, y: -1.48))
    path.curve(to: .init(x: -1.90, y: 0.46), controlPoint1: .init(x: -2.20, y: -0.72), controlPoint2: .init(x: -2.03, y: 0.06))
    path.curve(to: .init(x: -1.36, y: 0.96), controlPoint1: .init(x: -1.80, y: 0.75), controlPoint2: .init(x: -1.68, y: 0.92))
    path.close()
    let shell = SCNShape(path: path, extrusionDepth: 0.57)
    shell.chamferRadius = scuf ? 0.13 : 0.18
    return shell
}

private func standardPad(scuf: Bool) -> SCNNode {
    let root = SCNNode()
    let shell = gamepadShell(scuf: scuf)
    // SCNShape extrudes symmetrically about the XY plane.
    add(shell, to: root, 0, 0.05, 0, color: scuf ? 0x344569 : 0xdce5eb)
    let lower = gamepadShell(scuf: scuf)
    let back = add(lower, to: root, 0, 0.03, -0.16, color: scuf ? 0x131c31 : 0x606d7a)
    back.scale = SCNVector3(0.99, 0.99, 0.75)
    for side: CGFloat in [-1, 1] {
        let trigger = box(root, 0.92, 0.39, 0.52, 0.14, side * 1.23, 0.91, -0.18, color: darkPlastic)
        trigger.eulerAngles.z = -side * 0.10
        box(root, 0.80, 0.18, 0.30, 0.065, side * 1.20, 1.01, 0.07,
            color: scuf ? 0x62e2e9 : 0x384456)
    }

    let accent: UInt32 = scuf ? 0x76e8f3 : 0x2c3947
    stick(root, x: -1.13, y: 0.39, z: 0.30, ringColor: accent)
    stick(root, x: 0.53, y: -0.26, z: 0.30, ringColor: accent)
    disk(root, radius: 0.31, depth: 0.077, x: -0.56, y: -0.26, z: 0.31, color: 0x394454)
    box(root, 0.49, 0.15, 0.075, 0.027, -0.56, -0.26, 0.37, color: darkPlastic)
    box(root, 0.15, 0.49, 0.075, 0.027, -0.56, -0.26, 0.37, color: darkPlastic)
    faceButtons(root, x: 1.11, y: 0.37, z: 0.33, colored: !scuf)

    disk(root, radius: 0.171, depth: 0.07, x: 0.0, y: 0.61, z: 0.32, color: darkPlastic)
    ring(root, radius: 0.13, tube: 0.012, x: 0, y: 0.61, z: 0.36, color: scuf ? 0x76e8f3 : 0x9bedb3)
    glyph(root, scuf ? "S" : "X", x: 0, y: 0.61, z: 0.361, height: 0.15, color: 0xe0eff5)
    for side: CGFloat in [-1, 1] {
        disk(root, radius: 0.08, depth: 0.05, x: side * 0.26, y: 0.27, z: 0.31, color: darkPlastic)
        if scuf {
            let stripe = box(root, 0.10, 0.62, 0.053, 0.026, side * 1.75, -0.66, 0.26, color: 0x63deeb)
            stripe.eulerAngles.z = -side * 0.22
        }
    }
    return root
}

private func joyCons() -> SCNNode {
    let node = SCNNode()
    for isLeft in [true, false] {
        let remote = SCNNode()
        remote.position.x = isLeft ? -0.80 : 0.80
        remote.eulerAngles.z = isLeft ? -0.11 : 0.11
        node.addChildNode(remote)
        let accent: UInt32 = isLeft ? 0x5cc7f9 : 0xff8974
        box(remote, 1.08, 2.66, 0.52, 0.25, 0, 0, 0, color: 0x3b475b)
        box(remote, 0.16, 2.26, 0.28, 0.067, isLeft ? 0.47 : -0.47, 0, -0.12, color: accent)
        box(remote, 0.69, 0.23, 0.35, 0.10, 0, 1.255, -0.15, color: darkPlastic)
        stick(remote, x: 0, y: isLeft ? 0.64 : -0.21, z: 0.27, ringColor: accent, scale: 0.80)
        if isLeft {
            for (x, y, text): (CGFloat, CGFloat, String) in [(0, -0.015, "▲"), (0, -0.385, "▼"), (-0.185, -0.20, "‹"), (0.185, -0.20, "›")] {
                disk(remote, radius: 0.097, depth: 0.10, x: x, y: y, z: 0.29, color: darkPlastic)
                glyph(remote, text, x: x, y: y, z: 0.352, height: 0.07, color: 0xd8e4f4)
            }
        } else {
            faceButtons(remote, x: 0, y: 0.60, z: 0.29, nintendo: true)
        }
        disk(remote, radius: 0.084, depth: 0.04, x: isLeft ? -0.21 : 0.21, y: -0.83, z: 0.27, color: darkPlastic)
        let markX: CGFloat = isLeft ? 0.30 : -0.30
        box(remote, 0.12, 0.025, 0.016, 0.007, markX, 1.03, 0.269, color: 0xd8e4f4)
        if !isLeft {
            box(remote, 0.025, 0.12, 0.016, 0.007, markX, 1.03, 0.269, color: 0xd8e4f4)
        }
        for index in 0..<4 {
            box(remote, 0.045, 0.045, 0.025, 0.008, isLeft ? 0.44 : -0.44,
                -0.57 + CGFloat(index) * 0.09, 0.247, color: index == 0 ? 0x9df4b3 : 0x222d3e)
        }
    }
    return node
}
