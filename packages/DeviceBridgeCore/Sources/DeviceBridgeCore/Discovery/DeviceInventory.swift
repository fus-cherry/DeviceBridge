import Foundation

public enum DeviceInventory {
    public static func aggregate(_ candidates: [TransportCandidate]) -> [DeviceRecord] {
        Dictionary(grouping: candidates, by: \.identity)
            .map { identity, groupedCandidates in
                let sortedCandidates = groupedCandidates.sorted(by: transportPrecedes)
                let preferred = sortedCandidates.first(where: isUsable)
                let displayMetadata = preferred?.metadata ?? sortedCandidates.first?.metadata ?? [:]
                return DeviceRecord(
                    identity: identity,
                    name: displayMetadata["name"]
                        ?? displayMetadata["model"]
                        ?? (identity.platform == .android ? "Android device" : "iOS device"),
                    model: displayMetadata["model"],
                    osVersion: displayMetadata["osVersion"],
                    authorization: authorization(for: groupedCandidates),
                    candidates: sortedCandidates,
                    preferredTransportID: preferred?.id
                )
            }
            .sorted {
                if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return $0.identity.displaySuffix < $1.identity.displaySuffix
            }
    }

    private static func authorization(
        for candidates: [TransportCandidate]
    ) -> AuthorizationState {
        if candidates.contains(where: isUsable) {
            return .authorized
        }
        if candidates.allSatisfy({ $0.status == .unauthorized }) {
            return .denied
        }
        if candidates.contains(where: { $0.status == .unauthorized }) {
            return .actionRequired
        }
        return .unknown
    }

    private static func isUsable(_ candidate: TransportCandidate) -> Bool {
        candidate.status == .available
            || candidate.status == .candidate
            || candidate.status == .probing
    }

    private static func transportPrecedes(
        _ lhs: TransportCandidate,
        _ rhs: TransportCandidate
    ) -> Bool {
        let lhsRank = statusRank(lhs.status)
        let rhsRank = statusRank(rhs.status)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.kind != rhs.kind { return lhs.kind == .usb }
        return lhs.id < rhs.id
    }

    private static func statusRank(_ status: TransportStatus) -> Int {
        switch status {
        case .available: 0
        case .candidate: 1
        case .probing: 2
        case .degraded: 3
        case .offline: 4
        case .unauthorized: 5
        case .removed: 6
        }
    }
}
