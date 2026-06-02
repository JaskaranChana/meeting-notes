import Foundation

struct LibrarySnapshotKey: Hashable {
    var revision: Int
    var query: String
    var mode: LibraryMode
    var collection: SmartCollectionKind
    var typeFilter: LibraryTypeFilter
    var dateFilter: LibraryDateFilter
    var sortMode: LibrarySortMode

    var hasSearchQuery: Bool {
        !query.isEmpty
    }
}

struct LibrarySnapshot: Equatable {
    var pinnedResults: [Meeting] = []
    var libraryResults: [Meeting] = []
    var folderResults: [WorkspaceFolder] = []
    var smartCollections: [SmartCollectionCard] = SmartCollectionKind.allCases.map {
        SmartCollectionCard(kind: $0, count: 0)
    }
    var totalMeetingsCount = 0
    var pinnedCount = 0
    var openLoopCount = 0
    var isMeetingStoreEmpty = true
}

actor LibrarySnapshotBuilder {
    func snapshot(for key: LibrarySnapshotKey, meetings: [Meeting]) -> LibrarySnapshot {
        let recentMeetings = meetings.sorted(by: Meeting.sortDescending)
        let pinnedMeetings = recentMeetings.filter(\.isPinned)
        let scopedMeetings = scopedMeetings(
            from: recentMeetings,
            key: key
        )
        let pinnedIDs = Set(pinnedMeetings.map(\.id))

        let pinnedResults: [Meeting]
        if key.mode == .meetings,
           !key.hasSearchQuery,
           key.collection == .all,
           key.typeFilter == .all,
           key.dateFilter == .all,
           key.sortMode == .newest {
            pinnedResults = pinnedMeetings
        } else {
            pinnedResults = []
        }

        let baseResults = key.collection == .all
            ? scopedMeetings.filter { !pinnedIDs.contains($0.id) }
            : scopedMeetings

        return LibrarySnapshot(
            pinnedResults: pinnedResults,
            libraryResults: sorted(baseResults, mode: key.sortMode),
            folderResults: folderResults(from: recentMeetings, query: key.query),
            smartCollections: smartCollections(from: recentMeetings),
            totalMeetingsCount: meetings.count,
            pinnedCount: pinnedMeetings.count,
            openLoopCount: openLoopCount(from: recentMeetings),
            isMeetingStoreEmpty: meetings.isEmpty
        )
    }

    private func scopedMeetings(from meetings: [Meeting], key: LibrarySnapshotKey) -> [Meeting] {
        let collectionScoped = meetingsMatching(key.collection, in: meetings)
            .filter { matchesTypeFilter(key.typeFilter, meeting: $0) }
            .filter { matchesDateFilter(key.dateFilter, meeting: $0) }

        guard key.hasSearchQuery else { return collectionScoped }
        return collectionScoped.filter { LibrarySearchMatcher.matches($0, query: key.query) }
    }

    private func sorted(_ meetings: [Meeting], mode: LibrarySortMode) -> [Meeting] {
        switch mode {
        case .newest:
            meetings.sorted { $0.when > $1.when }
        case .title:
            meetings.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    private func meetingsMatching(_ collection: SmartCollectionKind, in meetings: [Meeting]) -> [Meeting] {
        switch collection {
        case .all:
            meetings
        case .followUp:
            meetings.filter { $0.status != .shared }
        case .calls:
            meetings.filter(\.isCallMeeting)
        case .pinned:
            meetings.filter(\.isPinned)
        case .shared:
            meetings.filter { $0.status == .shared }
        }
    }

    private func matchesTypeFilter(_ filter: LibraryTypeFilter, meeting: Meeting) -> Bool {
        switch filter {
        case .all:
            true
        case .voice:
            !meeting.audioRecordings.isEmpty || meeting.workspace.caseInsensitiveCompare("Voice Notes") == .orderedSame
        case .calls:
            meeting.isCallMeeting
        case .live:
            meeting.stage.localizedCaseInsensitiveContains("live") || meeting.status == .live
        case .notes:
            meeting.audioRecordings.isEmpty
                && meeting.workspace.caseInsensitiveCompare("Phone") != .orderedSame
                && !meeting.stage.localizedCaseInsensitiveContains("live")
        }
    }

    private func matchesDateFilter(_ filter: LibraryDateFilter, meeting: Meeting) -> Bool {
        let calendar = Calendar.current
        switch filter {
        case .all:
            return true
        case .today:
            return calendar.isDateInToday(meeting.when)
        case .sevenDays:
            let cutoff = calendar.date(byAdding: .day, value: -7, to: .now) ?? .now
            return meeting.when >= cutoff
        case .thirtyDays:
            let cutoff = calendar.date(byAdding: .day, value: -30, to: .now) ?? .now
            return meeting.when >= cutoff
        }
    }

    private func folderResults(from meetings: [Meeting], query: String) -> [WorkspaceFolder] {
        let folders = Dictionary(grouping: meetings, by: \.workspace)
            .compactMap { workspace, meetings -> WorkspaceFolder? in
                guard let latest = meetings.max(by: { $0.when < $1.when }) else { return nil }
                return WorkspaceFolder(
                    name: workspace,
                    description: latest.objective,
                    meetingCount: meetings.count,
                    latestMeetingDate: latest.when
                )
            }
            .sorted { lhs, rhs in
                if lhs.latestMeetingDate == rhs.latestMeetingDate {
                    return lhs.name < rhs.name
                }
                return lhs.latestMeetingDate > rhs.latestMeetingDate
            }

        guard !query.isEmpty else { return folders }
        return folders.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    private func smartCollections(from meetings: [Meeting]) -> [SmartCollectionCard] {
        SmartCollectionKind.allCases.map { kind in
            SmartCollectionCard(kind: kind, count: self.meetingsMatching(kind, in: meetings).count)
        }
    }

    private func openLoopCount(from meetings: [Meeting]) -> Int {
        meetings
            .filter { $0.status != .shared }
            .flatMap(\.commitments)
            .filter { $0.status == .open || $0.status == .atRisk }
            .count
    }

}
