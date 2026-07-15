import Foundation

struct LibrarySnapshotKey: Hashable {
    var revision: Int
    var query: String
    var mode: LibraryMode
    var collection: SmartCollectionKind
    var typeFilter: LibraryTypeFilter
    var dateFilter: LibraryDateFilter
    var sortMode: LibrarySortMode
    var segment: LibrarySegment

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
    var segmentCounts: [LibrarySegment: Int] = [:]
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
        var segmentCounts: [LibrarySegment: Int] = [:]
        for meeting in scopedMeetings {
            for segment in LibrarySegment.allCases where segment.matches(meeting) {
                segmentCounts[segment, default: 0] += 1
            }
        }

        let pinnedResults: [Meeting]
        if key.mode == .meetings,
           !key.hasSearchQuery,
           key.collection == .all,
           key.typeFilter == .all,
           key.dateFilter == .all,
           key.sortMode == .newest,
           key.segment == .all {
            pinnedResults = pinnedMeetings
        } else {
            pinnedResults = []
        }

        let baseResults: [Meeting]
        if key.segment == .all, !pinnedResults.isEmpty {
            baseResults = scopedMeetings.filter { !pinnedIDs.contains($0.id) }
        } else {
            baseResults = scopedMeetings.filter(key.segment.matches)
        }

        return LibrarySnapshot(
            pinnedResults: pinnedResults,
            libraryResults: sorted(baseResults, mode: key.sortMode),
            // The current Library surface renders meetings only. Folder and
            // collection aggregation used to run on every search keystroke even
            // though no view consumed it.
            folderResults: [],
            smartCollections: [],
            totalMeetingsCount: meetings.count,
            pinnedCount: pinnedMeetings.count,
            openLoopCount: openLoopCount(from: recentMeetings),
            isMeetingStoreEmpty: meetings.isEmpty,
            segmentCounts: segmentCounts
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
            // `meetings` is already filtered from `recentMeetings`, preserving
            // its descending order. Avoid a second O(n log n) sort.
            meetings
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
            meetings.filter { $0.status != .shared && openLoopCount(for: $0) > 0 }
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
        meetings.reduce(into: 0) { count, meeting in
            guard meeting.status != .shared, meeting.allowsAccountabilityExtraction else { return }
            count += meeting.commitments.reduce(into: 0) { commitmentCount, commitment in
                if commitment.status == .open || commitment.status == .atRisk {
                    commitmentCount += 1
                }
            }
        }
    }

    private func openLoopCount(for meeting: Meeting) -> Int {
        guard meeting.allowsAccountabilityExtraction else { return 0 }
        return meeting.commitments
            .filter { $0.status == .open || $0.status == .atRisk }
            .count
    }

}
