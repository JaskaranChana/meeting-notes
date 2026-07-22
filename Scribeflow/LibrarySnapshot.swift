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
    var dateGroups: [LibraryDateGroup] = []
    var searchMatches: [Meeting.ID: LibrarySearchMatch] = [:]
}

struct LibraryDateGroup: Equatable {
    let title: String
    let meetings: [Meeting]
}

actor LibrarySnapshotBuilder {
    private var cachedRevision = -1
    private var cachedRecentMeetings: [Meeting] = []
    private var cachedPinnedMeetings: [Meeting] = []
    private var cachedAccountabilityMeetingIDs: Set<Meeting.ID> = []
    private var cachedOpenLoopCount = 0

    func snapshot(for key: LibrarySnapshotKey, meetings: [Meeting]) -> LibrarySnapshot {
        refreshBaseIfNeeded(meetings: meetings, revision: key.revision)
        let scoped = scopedMeetings(
            from: cachedRecentMeetings,
            key: key,
            accountabilityMeetingIDs: cachedAccountabilityMeetingIDs
        )
        let scopedMeetings = scoped.meetings
        let pinnedIDs = Set(cachedPinnedMeetings.map(\.id))
        var segmentCounts: [LibrarySegment: Int] = [:]
        for meeting in scopedMeetings {
            let allowsAccountability = cachedAccountabilityMeetingIDs.contains(meeting.id)
            for segment in LibrarySegment.allCases
            where segment.matches(meeting, allowsAccountability: allowsAccountability) {
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
            pinnedResults = cachedPinnedMeetings
        } else {
            pinnedResults = []
        }

        let baseResults: [Meeting]
        if key.segment == .all, !pinnedResults.isEmpty {
            baseResults = scopedMeetings.filter { !pinnedIDs.contains($0.id) }
        } else {
            baseResults = scopedMeetings.filter {
                key.segment.matches(
                    $0,
                    allowsAccountability: cachedAccountabilityMeetingIDs.contains($0.id)
                )
            }
        }

        let libraryResults = sorted(baseResults, mode: key.sortMode)
        return LibrarySnapshot(
            pinnedResults: pinnedResults,
            libraryResults: libraryResults,
            // The current Library surface renders meetings only. Folder and
            // collection aggregation used to run on every search keystroke even
            // though no view consumed it.
            folderResults: [],
            smartCollections: [],
            totalMeetingsCount: cachedRecentMeetings.count,
            pinnedCount: cachedPinnedMeetings.count,
            openLoopCount: cachedOpenLoopCount,
            isMeetingStoreEmpty: cachedRecentMeetings.isEmpty,
            segmentCounts: segmentCounts,
            dateGroups: dateGroups(from: libraryResults),
            searchMatches: scoped.searchMatches
        )
    }

    private func refreshBaseIfNeeded(meetings: [Meeting], revision: Int) {
        guard revision != cachedRevision else { return }
        cachedRevision = revision
        cachedRecentMeetings = meetings.sorted(by: Meeting.sortDescending)
        cachedPinnedMeetings = cachedRecentMeetings.filter(\.isPinned)
        cachedAccountabilityMeetingIDs = Set(meetings.compactMap { meeting in
            meeting.allowsAccountabilityExtraction ? meeting.id : nil
        })
        cachedOpenLoopCount = openLoopCount(
            from: cachedRecentMeetings,
            accountabilityMeetingIDs: cachedAccountabilityMeetingIDs
        )
    }

    private func dateGroups(from meetings: [Meeting]) -> [LibraryDateGroup] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: .now)
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        let monthAgo = calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday
        var today: [Meeting] = []
        var week: [Meeting] = []
        var month: [Meeting] = []
        var earlier: [Meeting] = []

        for meeting in meetings {
            if meeting.when >= startOfToday {
                today.append(meeting)
            } else if meeting.when >= weekAgo {
                week.append(meeting)
            } else if meeting.when >= monthAgo {
                month.append(meeting)
            } else {
                earlier.append(meeting)
            }
        }

        var groups: [LibraryDateGroup] = []
        if !today.isEmpty { groups.append(LibraryDateGroup(title: "Today", meetings: today)) }
        if !week.isEmpty { groups.append(LibraryDateGroup(title: "This week", meetings: week)) }
        if !month.isEmpty { groups.append(LibraryDateGroup(title: "This month", meetings: month)) }
        if !earlier.isEmpty { groups.append(LibraryDateGroup(title: "Earlier", meetings: earlier)) }
        return groups
    }

    private func scopedMeetings(
        from meetings: [Meeting],
        key: LibrarySnapshotKey,
        accountabilityMeetingIDs: Set<Meeting.ID>
    ) -> (meetings: [Meeting], searchMatches: [Meeting.ID: LibrarySearchMatch]) {
        let collectionScoped = meetingsMatching(
            key.collection,
            in: meetings,
            accountabilityMeetingIDs: accountabilityMeetingIDs
        )
            .filter { matchesTypeFilter(key.typeFilter, meeting: $0) }
            .filter { matchesDateFilter(key.dateFilter, meeting: $0) }

        guard key.hasSearchQuery else { return (collectionScoped, [:]) }
        var results: [Meeting] = []
        var searchMatches: [Meeting.ID: LibrarySearchMatch] = [:]
        results.reserveCapacity(min(collectionScoped.count, 32))

        for meeting in collectionScoped {
            guard !Task.isCancelled else { break }
            guard let match = LibrarySearchMatcher.match(in: meeting, query: key.query) else { continue }
            results.append(meeting)
            searchMatches[meeting.id] = match
        }
        return (results, searchMatches)
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

    private func meetingsMatching(
        _ collection: SmartCollectionKind,
        in meetings: [Meeting],
        accountabilityMeetingIDs: Set<Meeting.ID>
    ) -> [Meeting] {
        switch collection {
        case .all:
            meetings
        case .followUp:
            meetings.filter {
                $0.status != .shared
                    && openLoopCount(
                        for: $0,
                        accountabilityMeetingIDs: accountabilityMeetingIDs
                    ) > 0
            }
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

    private func openLoopCount(
        from meetings: [Meeting],
        accountabilityMeetingIDs: Set<Meeting.ID>
    ) -> Int {
        meetings.reduce(into: 0) { count, meeting in
            guard meeting.status != .shared,
                  accountabilityMeetingIDs.contains(meeting.id)
            else { return }
            count += meeting.commitments.reduce(into: 0) { commitmentCount, commitment in
                if commitment.status == .open || commitment.status == .atRisk {
                    commitmentCount += 1
                }
            }
        }
    }

    private func openLoopCount(
        for meeting: Meeting,
        accountabilityMeetingIDs: Set<Meeting.ID>
    ) -> Int {
        guard accountabilityMeetingIDs.contains(meeting.id) else { return 0 }
        return meeting.commitments.reduce(into: 0) { count, commitment in
            if commitment.status == .open || commitment.status == .atRisk {
                count += 1
            }
        }
    }

}
