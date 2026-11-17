import Foundation

struct BatteryReading: Equatable {
    let percent: Int
    let estimated: Bool
    var millivolts: Int?

    var label: String {
        if estimated && percent == 0 { return "< 5 %" }
        return (estimated ? "≈ " : "") + "\(percent) %"
    }

    var details: String {
        if let millivolts {
            let volts = (Double(millivolts) / 1_000).formatted(.number.precision(.fractionLength(2)))
            return "Estimation à partir de la tension mesurée (\(volts) V)."
        }
        return estimated ? "Estimation d’après la plage communiquée par le pilote." : "Niveau communiqué par le pilote."
    }

    static func reported(_ battery: [String: Any]) -> BatteryReading? {
        let value = battery["percentage"]
        if let percent = value as? Int, (0...100).contains(percent) {
            return BatteryReading(percent: percent, estimated: false)
        }
        let bounds: [Int]
        if let array = value as? [Int] {
            bounds = array
        } else if let range = value as? [String: Int], let lower = range["lowerBound"], let upper = range["upperBound"] {
            bounds = [lower, upper]
        } else {
            return nil
        }
        guard bounds.count == 2, (0...100).contains(bounds[0]), (bounds[0]...100).contains(bounds[1]) else { return nil }
        return BatteryReading(percent: (bounds[0] + bounds[1]) / 2, estimated: bounds[0] != bounds[1])
    }

    static func fromCapture(_ data: Data) -> BatteryReading? {
        let samples = data.split(separator: 10).compactMap { line -> Int? in
            guard let report = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  report["direction"] as? String == "Rx",
                  let hex = report["hex"] as? String else { return nil }
            let bytes = hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
            // The normalized 0x05 report includes the ID, unlike the raw GATT value.
            guard bytes.count == 64, bytes[0] == 0x05 else { return nil }
            let millivolts = Int(bytes[32]) | Int(bytes[33]) << 8
            return (2_800...4_450).contains(millivolts) ? millivolts : nil
        }.sorted()
        guard !samples.isEmpty else { return nil }
        let measured = samples[samples.count / 2]
        // Approximate open-circuit curve. Voltage shifts under load and during charging.
        let curve = [(3_000, 0), (3_450, 5), (3_600, 13), (3_700, 26), (3_780, 49),
                     (3_860, 67), (3_950, 80), (4_060, 91), (4_200, 100)]
        let upperIndex = curve.firstIndex { $0.0 > measured } ?? curve.count
        let percentage: Int
        if upperIndex == 0 {
            percentage = 0
        } else if upperIndex == curve.count {
            percentage = 100
        } else {
            let (lowVoltage, lowPercent) = curve[upperIndex - 1]
            let (highVoltage, highPercent) = curve[upperIndex]
            percentage = lowPercent + (measured - lowVoltage) * (highPercent - lowPercent) / (highVoltage - lowVoltage)
        }
        // Five-point steps reflect the limited precision of a voltage estimate.
        return BatteryReading(percent: Int((Double(percentage) / 5).rounded()) * 5, estimated: true, millivolts: measured)
    }
}

struct JoyConStatus: Equatable {
    var connected = false
    var battery: BatteryReading?
    var charging = false
}

struct DriverStatus: Equatable {
    enum Availability { case missing, idle, running, unreachable }

    var availability: Availability
    var left = JoyConStatus()
    var right = JoyConStatus()

    private static let path = "/Applications/OpenJoystickDriver.app/Contents/MacOS/OpenJoystickDriver"
    static var initial: DriverStatus {
        DriverStatus(availability: FileManager.default.isExecutableFile(atPath: path) ? .idle : .missing)
    }

    static func read(launcher: URL, batteries: Bool) -> DriverStatus {
        let initial = Self.initial
        guard initial.availability != .missing else { return initial }
        guard let data = run(launcher, ["--driver-status"]),
              let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let service = report["service"] as? [String: Any] else { return DriverStatus(availability: .unreachable) }
        let running = (service["state"] as? String)?.lowercased() == "running"
        guard running else { return DriverStatus(availability: .idle) }

        let controllers = report["controllers"] as? [[String: Any]] ?? []
        func joyCon(_ product: Int, _ usbID: String) -> JoyConStatus {
            let matches = controllers.filter { $0["vendorID"] as? Int == 0x057e && $0["productID"] as? Int == product }
            guard matches.count == 1, let match = matches.first else { return JoyConStatus() }
            let power = match["power"] as? [String: Any] ?? [:]
            let observed = BatteryReading.reported(power["battery"] as? [String: Any] ?? [:])
            let captured = (batteries && observed == nil) ? run(launcher, ["--joycon-battery", usbID]).flatMap(BatteryReading.fromCapture) : nil
            let charging = (power["charging"] as? String)?.lowercased() == "charging"
            return JoyConStatus(connected: true, battery: observed ?? captured, charging: charging)
        }
        return DriverStatus(availability: .running, left: joyCon(0x2067, "057E:2067"), right: joyCon(0x2066, "057E:2066"))
    }

    private static func run(_ launcher: URL, _ arguments: [String]) -> Data? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = [launcher.path] + arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        try? pipe.fileHandleForWriting.close()
        let result = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return task.terminationStatus == 0 ? result : nil
    }
}
