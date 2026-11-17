import Foundation

/// Pure helpers for member filter chip eligibility and active filter resolution.
public enum MemberFilter {
    /// Returns members eligible for filtering: `me` first (if present),
    /// followed by other members who appear in `memberIds` of at least one
    /// non-archived project, preserving their existing relative order.
    public static func filterableMembers(members: [Member], projects: [Project]) -> [Member] {
        let activeMemberIds = Set(
            projects
                .lazy
                .filter { !$0.archived }
                .flatMap(\.memberIds)
        )
        let eligible = members.filter { $0.isMe || activeMemberIds.contains($0.id) }
        return eligible.filter(\.isMe) + eligible.filter { !$0.isMe }
    }

    /// Resolves a selected member id against `filterMembers`, returning `nil`
    /// (全部) unless multiple filterable members exist and `selection` belongs
    /// to one of them.
    public static func effectiveFilter(_ selection: String?, among filterMembers: [Member]) -> String? {
        guard filterMembers.count > 1,
              let id = selection,
              filterMembers.contains(where: { $0.id == id }) else {
            return nil
        }
        return id
    }
}
