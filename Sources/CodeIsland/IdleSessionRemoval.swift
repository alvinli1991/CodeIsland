import Foundation
import CodeIslandCore

struct IdleSessionRemovalSelection: Equatable {
    let groups: [Set<String>]

    static let empty = IdleSessionRemovalSelection(groups: [])

    var sessionIDs: Set<String> {
        groups.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    var cardCount: Int { sessionIDs.count }
    var isEmpty: Bool { groups.isEmpty }
}

enum IdleSessionRemovalPolicy {
    static func selection(
        sessions: [String: SessionSnapshot],
        blockedSessionIDs: Set<String>
    ) -> IdleSessionRemovalSelection {
        // Treat parent links as an undirected graph so every connected family is evaluated as one
        // unit, including malformed cycles or children observed before their parent relationship settles.
        var adjacency = Dictionary(uniqueKeysWithValues: sessions.keys.map { ($0, Set<String>()) })
        for (id, session) in sessions {
            guard let parent = session.parentSessionId, sessions[parent] != nil else { continue }
            adjacency[id, default: []].insert(parent)
            adjacency[parent, default: []].insert(id)
        }

        var visited = Set<String>()
        var groups: [Set<String>] = []
        for root in sessions.keys.sorted() where !visited.contains(root) {
            var group = Set<String>()
            var pending = [root]
            visited.insert(root)
            while let id = pending.popLast() {
                group.insert(id)
                for neighbor in adjacency[id, default: []] where visited.insert(neighbor).inserted {
                    pending.append(neighbor)
                }
            }

            let removable = group.allSatisfy { id in
                guard let session = sessions[id] else { return false }
                return session.status == .idle
                    && !blockedSessionIDs.contains(id)
                    && !session.subagents.values.contains(where: { $0.status != .idle })
            }
            if removable { groups.append(group) }
        }

        groups.sort { ($0.min() ?? "") < ($1.min() ?? "") }
        return IdleSessionRemovalSelection(groups: groups)
    }
}

/// Passive snapshots may be stale and cannot undo an explicit removal. Runtime work and requests
/// are user-visible evidence that the conversation is active again and may restore its whole group.
enum RemovedSessionRevivalEvidence {
    case activeWork
    case blockingRequest
    case passive
}
