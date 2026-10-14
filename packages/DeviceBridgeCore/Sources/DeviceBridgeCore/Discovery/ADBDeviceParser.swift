import Foundation

public enum DeviceParseError: Error, Equatable, Sendable {
    case malformedInventory
    case missingTransportID
    case invalidIdentity
}

public struct ADBDeviceParser: Sendable {
    public init() {}

    public func parse(_ output: String, observedAt: Date) throws -> [TransportCandidate] {
        var seenTransportIDs = Set<String>()
        var candidates: [TransportCandidate] = []

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("List of devices attached") else { continue }

            // adb pads the serial, but does not escape spaces inside mDNS instance names.
            // Match the state before the metadata suffix, not the second whitespace token.
            let row = try NSRegularExpression(pattern: #"^(.+?)\s+(\S+)\s+((?:[A-Za-z_]+:\S+\s*)+)$"#)
            guard let match = row.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let serialRange = Range(match.range(at: 1), in: line),
                  let stateRange = Range(match.range(at: 2), in: line),
                  let metadataRange = Range(match.range(at: 3), in: line) else {
                throw DeviceParseError.missingTransportID
            }
            let fields = line[metadataRange].split(whereSeparator: \.isWhitespace).map(String.init)
            let serial = String(line[serialRange])
            let state = String(line[stateRange])
            let metadataFields = fields[...]
            var metadata: [String: String] = [:]
            for field in metadataFields {
                guard let separator = field.firstIndex(of: ":") else { continue }
                let key = String(field[..<separator])
                let value = String(field[field.index(after: separator)...])
                metadata[key] = value
            }

            guard let transportID = metadata["transport_id"], !transportID.isEmpty else {
                throw DeviceParseError.missingTransportID
            }
            guard seenTransportIDs.insert(transportID).inserted else { continue }

            let kind: TransportKind = metadata["usb"] == nil ? .wifi : .usb
            let status: TransportStatus
            switch state {
            case "device": status = .candidate
            case "offline": status = .offline
            case "unauthorized": status = .unauthorized
            default: status = .degraded
            }

            if let model = metadata["model"] {
                metadata["model"] = model.replacingOccurrences(of: "_", with: " ")
            }
            let identity: DeviceIdentity
            metadata["adbSerial"] = serial
            do {
                identity = try DeviceIdentity(
                    rawValue: "android:\(serial)",
                    stability: .provisional,
                    platform: .android
                )
            } catch {
                throw DeviceParseError.invalidIdentity
            }
            let endpoint = kind == .wifi && serial.contains(":") ? serial : nil
            candidates.append(try TransportCandidate(
                id: transportID,
                identity: identity,
                kind: kind,
                source: .adb,
                status: status,
                observedAt: observedAt,
                metadata: metadata,
                endpoint: endpoint
            ))
        }
        return candidates
    }
}
