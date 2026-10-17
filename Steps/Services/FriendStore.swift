import CloudKit
import CoreImage
import Foundation
import Observation
import UIKit
import WidgetKit

struct FriendSample: Identifiable, Equatable {
    let id: Int
    let date: Date
    let steps: Int
}

struct FriendCurve: Identifiable, Equatable {
    let id: String
    var name: String
    var colorIndex: Int
    var samples: [FriendSample]

    var steps: Int { samples.last?.steps ?? 0 }
}

private struct CachedCurve: Codable {
    var code: String
    var offsets: [TimeInterval]
    var steps: [Int]
}

private struct FriendDayCache: Codable {
    var day: String
    var curves: [CachedCurve]
}

private struct WidgetFriendSnapshot: Codable {
    var name: String
    var colorIndex: Int
    var offsets: [TimeInterval]
    var steps: [Int]
}

private struct SavedFriend: Codable, Equatable {
    var code: String
    var name: String
    var colorIndex: Int
}

@MainActor
@Observable
final class FriendStore {
    static let shared = FriendStore()
    static let friendLimit = 5

    private(set) var friends: [FriendCurve] = []
    private(set) var message: String?
    var displayName: String {
        didSet {
            defaults.set(displayName, forKey: Self.nameKey)
            UserDefaults(suiteName: WidgetSnapshot.suite)?.set(displayName, forKey: Self.widgetNameKey)
            guard !applyingCloud else { return }
            pushIdentityToICloud()
            namePublish?.cancel()
            namePublish = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                await self?.updatePublicName()
            }
        }
    }

    /// Home-screen widgets draw friend lines when this is on. Missing value means on.
    var showOnWidget: Bool {
        didSet {
            guard showOnWidget != oldValue else { return }
            publishWidgetFriends()
        }
    }

    private(set) var code: String

    private let defaults = UserDefaults.standard
    private let ubiquitous = NSUbiquitousKeyValueStore.default
    private let container = CKContainer(identifier: "iCloud.com.bryandebourbon.steps")
    private var saved: [SavedFriend] = []
    private var applyingCloud = false
    private var identityReady = false
    private var adoptedCloudName = false
    private var resolveTask: Task<Void, Never>?
    private var ubiquityObserver: NSObjectProtocol?
    private var poll: Task<Void, Never>?
    private var upload: Task<Void, Never>?
    private var openFetch: Task<Void, Never>?
    private var namePublish: Task<Void, Never>?
    private var cloudChain: Task<Bool, Never>?
    private var lastUpload = Date.distantPast
    private var lastPayload = ""

    private static let nameKey = "steps.friendName"
    private static let codeKey = "steps.friendCode"
    private static let savedKey = "steps.savedFriends"
    private static let showOnWidgetKey = "steps.widget.showFriends"
    private static let widgetFriendsKey = "steps.widget.friends"
    private static let curveKey = "steps.friendDayCache"
    private static let widgetNameKey = "steps.displayName"
    private static let alphabet = FriendCode.alphabet

    init() {
        if let existing = defaults.string(forKey: Self.codeKey), FriendCode.normalize(existing) != nil {
            code = existing
        } else {
            code = ""
        }
        let name = defaults.string(forKey: Self.nameKey) ?? ""
        displayName = name
        let shared = UserDefaults(suiteName: WidgetSnapshot.suite)
        shared?.set(name, forKey: Self.widgetNameKey)
        if let shared, shared.object(forKey: Self.showOnWidgetKey) != nil {
            showOnWidget = shared.bool(forKey: Self.showOnWidgetKey)
        } else {
            showOnWidget = true
        }
        if let data = defaults.data(forKey: Self.savedKey),
           let decoded = try? JSONDecoder().decode([SavedFriend].self, from: data) {
            saved = Array(decoded.prefix(Self.friendLimit))
            reloadSavedFriends()
        }
        ubiquityObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: ubiquitous,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyExternalIdentity()
            }
        }
        ubiquitous.synchronize()
    }

    func start(day: WalkDay?) {
        Task { await self.ensureIdentity() }
        if let day { scheduleUpload(day, force: true) }
        Task { await ensureSubscription() }
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.refresh()
            }
        }
    }

    func note(_ day: WalkDay) {
        scheduleUpload(day, force: false)
    }

    func publishNow(_ day: WalkDay) {
        scheduleUpload(day, force: true)
    }

    func add(code raw: String) async -> Bool {
        await add(code: raw, announceFailure: true)
    }

    /// Nearby tap can arrive before the other phone’s first upload has finished.
    func addFromNearby(code: String) async -> Bool {
        for attempt in 0..<6 {
            if await add(code: code, announceFailure: false) {
                message = "Added."
                return true
            }
            if message == "Already added." || message == "That’s your code." || message == "Five friends is the limit." {
                return false
            }
            if attempt == 5 {
                message = "Couldn’t add them yet. Hold the phones together again."
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        return false
    }

    private func add(code raw: String, announceFailure: Bool) async -> Bool {
        guard let code = FriendCode.normalize(raw) else {
            if announceFailure { message = "Enter the 6-character code." }
            return false
        }
        guard code != self.code else {
            message = "That’s your code."
            return false
        }
        guard !saved.contains(where: { $0.code == code }) else {
            message = "Already added."
            return false
        }
        if let mine = await parties(of: self.code) {
            if mine.contains(code) {
                message = "Already added."
                return false
            }
            guard mine.count < Self.friendLimit else {
                message = "Five friends is the limit."
                return false
            }
        } else if saved.count >= Self.friendLimit {
            message = "Five friends is the limit."
            return false
        }
        if let theirs = await parties(of: code), !theirs.contains(self.code), theirs.count >= Self.friendLimit {
            if announceFailure { message = "They already have five friends." }
            return false
        }
        let record: CKRecord
        do {
            record = try await container.publicCloudDatabase.record(for: CKRecord.ID(recordName: code))
        } catch let error as CKError where error.code == .unknownItem {
            if announceFailure { message = "No one is sharing that code yet." }
            return false
        } catch {
            if announceFailure { message = "Couldn’t look up that code. Check iCloud and try again." }
            return false
        }
        let name = (record["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? code
        let used = Set(saved.map(\.colorIndex))
        let color = (0..<Self.friendLimit).first { !used.contains($0) } ?? saved.count
        let friend = SavedFriend(code: code, name: name, colorIndex: color)
        guard await saveFriendship(friend) else {
            if announceFailure { message = "Couldn't save that friend to iCloud." }
            return false
        }
        saved.append(friend)
        persistSaved()
        message = "Added."
        await refresh()
        return true
    }

    /// Disconnects this phone. The old code, steps, and friendships stay in iCloud.
    func resetCode() async {
        await ensureIdentity()
        guard identityReady else { return }
        if let cloudChain { _ = await cloudChain.value }
        let previous = code
        var made = previous
        repeat {
            made = String((0..<6).map { _ in Self.alphabet.randomElement()! })
        } while made == previous
        code = made
        defaults.set(made, forKey: Self.codeKey)
        lastPayload = ""
        lastUpload = .distantPast
        saved = []
        friends = []
        message = nil
        persistSaved()
        let start = Calendar.current.startOfDay(for: Date())
        remember([], day: Self.dayKey(start), start: start)
        publishWidgetFriends()
        pushIdentityToICloud()
        _ = await ensurePublicRecord()
    }

    /// This iCloud account’s code, name, and friends. A reinstall reads them back instead of minting a new code.
    func ensureIdentity() async {
        await resolveIdentity()
        guard identityReady else { return }
        _ = await ensurePublicRecord()
        guard !adoptedCloudName else { return }
        adoptedCloudName = true
        await adoptCloudName()
    }

    private func resolveIdentity() async {
        if identityReady { return }
        if let resolveTask {
            await resolveTask.value
            return
        }
        let task = Task { @MainActor in
            await self.resolveIdentityBody()
        }
        resolveTask = task
        await task.value
        resolveTask = nil
    }

    private func resolveIdentityBody() async {
        let status = (try? await container.accountStatus()) ?? .couldNotDetermine
        guard status == .available else { return }
        ubiquitous.synchronize()

        if let remote = FriendCode.normalize(ubiquitous.string(forKey: Self.codeKey) ?? "") {
            applyAccount(code: remote, name: ubiquitous.string(forKey: Self.nameKey), friendsData: ubiquitous.data(forKey: Self.savedKey))
            if let owned = await ownedRecords(),
               !owned.contains(where: { $0.recordID.recordName == remote }),
               let record = Self.established(owned) {
                let kept = record.recordID.recordName
                applyingCloud = true
                code = kept
                defaults.set(kept, forKey: Self.codeKey)
                applyingCloud = false
            }
            identityReady = true
            pushIdentityToICloud()
            _ = await ensurePublicRecord()
            return
        }

        let owned = await ownedRecords()
        guard let owned else { return }
        if let record = Self.established(owned) {
            let kept = record.recordID.recordName
            applyingCloud = true
            code = kept
            defaults.set(kept, forKey: Self.codeKey)
            let recordName = (record["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if displayName.isEmpty, !recordName.isEmpty, recordName.caseInsensitiveCompare(kept) != .orderedSame {
                displayName = recordName
            }
            applyingCloud = false
            identityReady = true
            pushIdentityToICloud()
            _ = await ensurePublicRecord()
            return
        }

        if FriendCode.normalize(code) == nil {
            let made = String((0..<6).map { _ in Self.alphabet.randomElement()! })
            code = made
            defaults.set(made, forKey: Self.codeKey)
        }
        identityReady = true
        pushIdentityToICloud()
        _ = await ensurePublicRecord()
    }

    private func applyAccount(code remote: String, name: String?, friendsData: Data?) {
        applyingCloud = true
        code = remote
        defaults.set(remote, forKey: Self.codeKey)
        if let name {
            displayName = name
        }
        if let friendsData, let decoded = try? JSONDecoder().decode([SavedFriend].self, from: friendsData) {
            saved = Array(decoded.prefix(Self.friendLimit))
            if let data = try? JSONEncoder().encode(saved) {
                defaults.set(data, forKey: Self.savedKey)
            }
            reloadSavedFriends()
        }
        applyingCloud = false
    }

    private func applyExternalIdentity() {
        guard identityReady else { return }
        guard let remote = FriendCode.normalize(ubiquitous.string(forKey: Self.codeKey) ?? "") else { return }
        applyAccount(code: remote, name: ubiquitous.string(forKey: Self.nameKey), friendsData: ubiquitous.data(forKey: Self.savedKey))
        Task { _ = await self.ensurePublicRecord() }
    }

    /// The account’s original code: a real name beats a code-named row, and the oldest of those wins.
    private static func established(_ records: [CKRecord]) -> CKRecord? {
        records.min { a, b in
            let an = hasRealName(a)
            let bn = hasRealName(b)
            if an != bn { return an && !bn }
            let ad = a.creationDate ?? .distantFuture
            let bd = b.creationDate ?? .distantFuture
            if ad != bd { return ad < bd }
            let aSteps = (a["steps"] as? NSNumber)?.intValue ?? 0
            let bSteps = (b["steps"] as? NSNumber)?.intValue ?? 0
            return aSteps > bSteps
        }
    }

    private static func hasRealName(_ record: CKRecord) -> Bool {
        let code = record.recordID.recordName
        let name = (record["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !name.isEmpty && name.caseInsensitiveCompare(code) != .orderedSame
    }

    /// nil means the lookup failed. An empty array means this account has no rows yet.
    private func ownedRecords() async -> [CKRecord]? {
        let userID: CKRecord.ID
        do {
            userID = try await container.userRecordID()
        } catch {
            return nil
        }
        let query = CKQuery(recordType: "Walker", predicate: NSPredicate(value: true))
        let matches: [(CKRecord.ID, Result<CKRecord, Error>)]
        do {
            let page = try await container.publicCloudDatabase.records(matching: query, resultsLimit: 200)
            matches = page.matchResults
        } catch {
            return nil
        }
        return matches.compactMap { _, result in
            guard case .success(let record) = result else { return nil }
            guard record.creatorUserRecordID?.recordName == userID.recordName else { return nil }
            return record
        }
    }

    private func pushIdentityToICloud() {
        guard identityReady, FriendCode.normalize(code) != nil else { return }
        ubiquitous.set(code, forKey: Self.codeKey)
        ubiquitous.set(displayName, forKey: Self.nameKey)
        if let data = try? JSONEncoder().encode(saved) {
            ubiquitous.set(data, forKey: Self.savedKey)
        }
        ubiquitous.synchronize()
    }

    private func reloadSavedFriends() {
        let start = Calendar.current.startOfDay(for: Date())
        let today = Self.dayKey(start)
        friends = saved.map { friend in
            FriendCurve(
                id: friend.code,
                name: friend.name,
                colorIndex: friend.colorIndex,
                samples: rememberedSamples(for: friend.code, day: today, start: start)
            )
        }
    }

    private func updatePublicName() async {
        await ensureIdentity()
        guard identityReady else { return }
        _ = await performCloud { record, _ in
            let visible = self.displayName.isEmpty ? self.code : self.displayName
            record["name"] = visible as NSString
            return true
        }
        await renameFriendships()
    }

    /// Creates this phone’s public row only when that code is not already in iCloud.
    private func ensurePublicRecord() async -> Bool {
        await performCloud { record, created in
            guard created else { return false }
            let visible = self.displayName.isEmpty ? self.code : self.displayName
            record["name"] = visible as NSString
            record["code"] = self.code as NSString
            record["zone"] = TimeZone.current.identifier as NSString
            record["day"] = Self.dayKey(Calendar.current.startOfDay(for: Date())) as NSString
            record["samples"] = "" as NSString
            record["steps"] = NSNumber(value: 0)
            return true
        }
    }

    /// The database name is what everyone sees. A later step upload does not overwrite it.
    private func adoptCloudName() async {
        guard FriendCode.normalize(code) != nil else { return }
        guard let record = try? await container.publicCloudDatabase.record(for: CKRecord.ID(recordName: code)) else { return }
        let cloudName = (record["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cloudName.isEmpty else { return }
        applyingCloud = true
        displayName = cloudName.caseInsensitiveCompare(code) == .orderedSame ? "" : cloudName
        applyingCloud = false
    }

    func remove(code: String) {
        saved.removeAll { $0.code == code }
        friends.removeAll { $0.id == code }
        persistSaved()
        let start = Calendar.current.startOfDay(for: Date())
        remember(friends, day: Self.dayKey(start), start: start)
        publishWidgetFriends()
        Task { await self.deleteFriendship(friend: code) }
    }

    /// First work on every open: pull friend curves, then reload widgets with that data.
    func fetchThenUpdateWidget() async {
        if let openFetch {
            await openFetch.value
            return
        }
        let task = Task { @MainActor in
            await self.refresh()
            WidgetCenter.shared.reloadAllTimelines()
        }
        openFetch = task
        await task.value
        openFetch = nil
    }

    func refresh() async {
        await pullFriendships()
        let dayStart = Calendar.current.startOfDay(for: Date())
        let today = Self.dayKey(dayStart)
        var curves: [FriendCurve] = []
        var reachedNetwork = false
        for friend in saved {
            let visible = friends.first { $0.id == friend.code }?.samples ?? []
            let previous = visible.isEmpty
                ? rememberedSamples(for: friend.code, day: today, start: dayStart)
                : visible
            let samples: [FriendSample]
            let name: String
            do {
                let record = try await container.publicCloudDatabase.record(for: CKRecord.ID(recordName: friend.code))
                reachedNetwork = true
                name = (record["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? friend.name
                if let encoded = record["samples"] as? String, let friendDay = record["day"] as? String {
                    let zone = (record["zone"] as? String).flatMap(TimeZone.init(identifier:))
                    samples = Self.decode(encoded, friendDay: friendDay, zone: zone, viewerStart: dayStart)
                } else {
                    samples = []
                }
                if let index = saved.firstIndex(where: { $0.code == friend.code }), saved[index].name != name {
                    saved[index].name = name
                    persistSaved()
                }
            } catch let error as CKError where error.code == .unknownItem {
                reachedNetwork = true
                continue
            } catch {
                name = friend.name
                samples = previous
            }
            curves.append(FriendCurve(id: friend.code, name: name, colorIndex: friend.colorIndex, samples: samples))
        }
        friends = curves
        if reachedNetwork || curves.contains(where: { !$0.samples.isEmpty }) {
            remember(curves, day: today, start: dayStart)
            publishWidgetFriends()
        }
    }

    private func rememberedSamples(for code: String, day: String, start: Date) -> [FriendSample] {
        guard let data = defaults.data(forKey: Self.curveKey),
              let cache = try? JSONDecoder().decode(FriendDayCache.self, from: data),
              cache.day == day,
              let curve = cache.curves.first(where: { $0.code == code }),
              curve.offsets.count == curve.steps.count else { return [] }
        return zip(curve.offsets, curve.steps).enumerated().map { index, pair in
            FriendSample(id: index, date: start.addingTimeInterval(pair.0), steps: pair.1)
        }
    }

    private func remember(_ curves: [FriendCurve], day: String, start: Date) {
        let cache = FriendDayCache(
            day: day,
            curves: curves.map { curve in
                CachedCurve(
                    code: curve.id,
                    offsets: curve.samples.map { $0.date.timeIntervalSince(start) },
                    steps: curve.samples.map(\.steps)
                )
            }
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: Self.curveKey)
    }

    private func publishWidgetFriends() {
        guard let shared = UserDefaults(suiteName: WidgetSnapshot.suite) else { return }
        let start = Calendar.current.startOfDay(for: Date())
        let payload = friends.map { friend in
            WidgetFriendSnapshot(
                name: friend.name,
                colorIndex: friend.colorIndex,
                offsets: friend.samples.map { $0.date.timeIntervalSince(start) },
                steps: friend.samples.map(\.steps)
            )
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let previous = shared.data(forKey: Self.widgetFriendsKey)
        let previousShown = shared.object(forKey: Self.showOnWidgetKey) == nil
            ? true
            : shared.bool(forKey: Self.showOnWidgetKey)
        shared.set(showOnWidget, forKey: Self.showOnWidgetKey)
        shared.set(data, forKey: Self.widgetFriendsKey)
        shared.synchronize()
        if previous != data || previousShown != showOnWidget {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func scheduleUpload(_ day: WalkDay, force: Bool) {
        guard day.source == .live else { return }
        upload?.cancel()
        upload = Task { [weak self] in
            if !force {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard !Task.isCancelled else { return }
            await self?.upload(day, force: force)
        }
    }

    private func upload(_ day: WalkDay, force: Bool) async {
        guard day.source == .live else { return }
        await ensureIdentity()
        guard identityReady else { return }
        let status = (try? await container.accountStatus()) ?? .couldNotDetermine
        guard status == .available else { return }
        let payload = Self.encode(day)
        let now = Date()
        if !force, payload == lastPayload, now.timeIntervalSince(lastUpload) < 45 { return }
        let savedPayload = payload
        let saved = await performCloud { record, created in
            if created {
                let visible = self.displayName.isEmpty ? self.code : self.displayName
                record["name"] = visible as NSString
            }
            record["code"] = self.code as NSString
            record["zone"] = TimeZone.current.identifier as NSString
            record["day"] = Self.dayKey(day.startOfDay) as NSString
            record["samples"] = savedPayload as NSString
            record["steps"] = NSNumber(value: day.stats.steps)
            return true
        }
        if saved {
            lastPayload = payload
            lastUpload = Date()
        }
    }

    /// One CloudKit write at a time, so a new code record cannot wipe a step upload.
    private func performCloud(_ fill: @escaping @MainActor (CKRecord, Bool) -> Bool) async -> Bool {
        let previous = cloudChain
        let task = Task { @MainActor in
            if let previous { _ = await previous.value }
            return await self.writeWalker(fill)
        }
        cloudChain = task
        return await task.value
    }

    private func writeWalker(_ fill: (CKRecord, Bool) -> Bool) async -> Bool {
        let status = (try? await container.accountStatus()) ?? .couldNotDetermine
        guard status == .available else { return false }
        let database = container.publicCloudDatabase
        let recordID = CKRecord.ID(recordName: code)
        for _ in 0..<2 {
            let record: CKRecord
            let created: Bool
            do {
                record = try await database.record(for: recordID)
                created = false
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: "Walker", recordID: recordID)
                created = true
            } catch {
                return false
            }
            let shouldSave = fill(record, created)
            guard shouldSave else { return true }
            record["code"] = code as NSString
            do {
                _ = try await database.save(record)
                return true
            } catch let error as CKError where error.code == .serverRecordChanged {
                continue
            } catch {
                return false
            }
        }
        return false
    }

    private func deleteCloudRecord(named recordName: String) async {
        let status = (try? await container.accountStatus()) ?? .couldNotDetermine
        guard status == .available else { return }
        _ = try? await container.publicCloudDatabase.deleteRecord(withID: CKRecord.ID(recordName: recordName))
    }

    /// One public `Friendship` row links both people. Either phone reads it.
    private func saveFriendship(_ friend: SavedFriend) async -> Bool {
        guard FriendCode.normalize(code) != nil else { return false }
        let database = container.publicCloudDatabase
        let recordID = CKRecord.ID(recordName: "\(code)#\(friend.code)")
        let reverseID = CKRecord.ID(recordName: "\(friend.code)#\(code)")
        let record: CKRecord
        if let reverse = try? await database.record(for: reverseID) {
            record = reverse
        } else {
            do {
                record = try await database.record(for: recordID)
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: "Friendship", recordID: recordID)
            } catch {
                return false
            }
        }
        let mine = displayName.isEmpty ? code : displayName
        if record.recordID == reverseID {
            record["ownerName"] = friend.name as NSString
            record["friendName"] = mine as NSString
        } else {
            record["owner"] = code as NSString
            record["friend"] = friend.code as NSString
            record["ownerName"] = mine as NSString
            record["friendName"] = friend.name as NSString
            record["name"] = friend.name as NSString
        }
        do {
            _ = try await database.save(record)
            return true
        } catch {
            return false
        }
    }

    private func deleteFriendship(friend: String) async {
        guard FriendCode.normalize(code) != nil else { return }
        let database = container.publicCloudDatabase
        for name in ["\(code)#\(friend)", "\(friend)#\(code)"] {
            _ = try? await database.deleteRecord(withID: CKRecord.ID(recordName: name))
        }
        for pair in [(code, friend), (friend, code)] {
            let predicate = NSPredicate(format: "owner == %@ AND friend == %@", pair.0, pair.1)
            guard let matches = try? await database.records(
                matching: CKQuery(recordType: "Friendship", predicate: predicate),
                resultsLimit: 10
            ).matchResults else { continue }
            for (id, result) in matches {
                guard case .success = result else { continue }
                _ = try? await database.deleteRecord(withID: id)
            }
        }
    }

    private func pullFriendships() async {
        guard FriendCode.normalize(code) != nil else { return }
        let owned = await friendshipRecords(NSPredicate(format: "owner == %@", code))
        let followed = await friendshipRecords(NSPredicate(format: "friend == %@", code))
        guard owned != nil || followed != nil else { return }
        let records = (owned ?? []) + (followed ?? [])
        if owned != nil, followed != nil, records.isEmpty {
            for friend in saved.prefix(Self.friendLimit) {
                _ = await saveFriendship(friend)
            }
            return
        }
        guard !records.isEmpty else { return }
        var next: [SavedFriend] = []
        for record in records {
            guard let other = otherParty(in: record, than: code),
                  !next.contains(where: { $0.code == other.code }) else { continue }
            let used = Set(next.map(\.colorIndex))
            let color = saved.first { $0.code == other.code }?.colorIndex
                ?? (0..<Self.friendLimit).first { !used.contains($0) }
                ?? next.count
            next.append(SavedFriend(code: other.code, name: other.name, colorIndex: color))
        }
        guard !next.isEmpty else { return }
        if owned == nil || followed == nil {
            for friend in next where !saved.contains(where: { $0.code == friend.code }) && saved.count < Self.friendLimit {
                saved.append(friend)
            }
        } else {
            saved = Array(next.prefix(Self.friendLimit))
        }
        persistSaved()
        reloadSavedFriends()
    }

    private func parties(of person: String) async -> [String]? {
        let owned = await friendshipRecords(NSPredicate(format: "owner == %@", person))
        let followed = await friendshipRecords(NSPredicate(format: "friend == %@", person))
        guard owned != nil || followed != nil else { return nil }
        var codes: [String] = []
        for record in (owned ?? []) + (followed ?? []) {
            guard let other = otherParty(in: record, than: person), !codes.contains(other.code) else { continue }
            codes.append(other.code)
        }
        return codes
    }

    private func otherParty(in record: CKRecord, than person: String) -> (code: String, name: String)? {
        let owner = (record["owner"] as? String) ?? ""
        let friend = (record["friend"] as? String) ?? ""
        if owner == person, let code = FriendCode.normalize(friend) {
            let name = (record["friendName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (record["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? code
            return (code, name)
        }
        if friend == person, let code = FriendCode.normalize(owner) {
            let name = (record["ownerName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? code
            return (code, name)
        }
        return nil
    }

    private func friendshipRecords(_ predicate: NSPredicate) async -> [CKRecord]? {
        do {
            let page = try await container.publicCloudDatabase.records(
                matching: CKQuery(recordType: "Friendship", predicate: predicate),
                resultsLimit: 20
            )
            return page.matchResults.compactMap { _, result in
                if case .success(let record) = result { return record }
                return nil
            }
        } catch {
            return nil
        }
    }

    private func renameFriendships() async {
        let visible = displayName.isEmpty ? code : displayName
        await renameFriendships(field: "owner", nameField: "ownerName", to: visible)
        await renameFriendships(field: "friend", nameField: "friendName", to: visible)
    }

    private func renameFriendships(field: String, nameField: String, to visible: String) async {
        guard field == "owner" || field == "friend" else { return }
        guard let records = await friendshipRecords(NSPredicate(format: "%K == %@", field, code)) else { return }
        let database = container.publicCloudDatabase
        for record in records {
            record[nameField] = visible as NSString
            _ = try? await database.save(record)
        }
    }

    private func retargetFriendships(from old: String, to new: String) async {
        await retargetFriendships(field: "owner", from: old, to: new)
        await retargetFriendships(field: "friend", from: old, to: new)
    }

    private func retargetFriendships(field: String, from old: String, to new: String) async {
        guard field == "owner" || field == "friend" else { return }
        let database = container.publicCloudDatabase
        let predicate = NSPredicate(format: "%K == %@", field, old)
        let matches: [(CKRecord.ID, Result<CKRecord, Error>)]
        do {
            matches = try await database.records(
                matching: CKQuery(recordType: "Friendship", predicate: predicate),
                resultsLimit: 50
            ).matchResults
        } catch {
            return
        }
        for (_, result) in matches {
            guard case .success(let record) = result else { continue }
            record[field] = new as NSString
            _ = try? await database.save(record)
        }
    }

    private func ensureSubscription() async {
        let subscription = CKQuerySubscription(
            recordType: "Walker",
            predicate: NSPredicate(value: true),
            subscriptionID: "steps.walkers",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try? await container.publicCloudDatabase.save(subscription)
        let links = CKQuerySubscription(
            recordType: "Friendship",
            predicate: NSPredicate(value: true),
            subscriptionID: "steps.friendships",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )
        links.notificationInfo = info
        _ = try? await container.publicCloudDatabase.save(links)
    }

    private func persistSaved() {
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: Self.savedKey)
        }
        pushIdentityToICloud()
    }

    private static func dayKey(_ start: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: start)
    }

    private static func encode(_ day: WalkDay) -> String {
        var buckets: [Int: Int] = [:]
        for point in day.points {
            let minute = max(0, Int(point.date.timeIntervalSince(day.startOfDay) / 60))
            buckets[(minute / 5) * 5] = point.cumulativeSteps
        }
        return buckets.keys.sorted().map { "\($0):\(buckets[$0] ?? 0)" }.joined(separator: ",")
    }

    private static func decode(
        _ encoded: String,
        friendDay: String,
        zone: TimeZone?,
        viewerStart: Date
    ) -> [FriendSample] {
        let friendZone = zone ?? TimeZone.current
        guard let origin = startOfDay(friendDay, zone: friendZone) else { return [] }
        let viewerEnd = viewerStart.addingTimeInterval(24 * 60 * 60)
        let friendEnd = origin.addingTimeInterval(24 * 60 * 60)
        guard origin < viewerEnd, friendEnd > viewerStart else { return [] }

        var points: [(date: Date, steps: Int)] = [(origin, 0)]
        for part in encoded.split(separator: ",") {
            let bits = part.split(separator: ":")
            guard bits.count == 2, let minute = Int(bits[0]), let steps = Int(bits[1]) else { continue }
            points.append((origin.addingTimeInterval(TimeInterval(minute * 60)), steps))
        }
        points.sort { $0.date < $1.date }

        let now = min(Date(), viewerEnd.addingTimeInterval(-1))
        var carry = 0
        var visible: [(date: Date, steps: Int)] = []
        for point in points {
            if point.date < viewerStart {
                carry = point.steps
                continue
            }
            if point.date > now { break }
            if visible.isEmpty {
                visible.append((viewerStart, carry))
            }
            visible.append(point)
        }
        if visible.isEmpty, carry > 0, now >= viewerStart {
            visible = [(viewerStart, carry), (now, carry)]
        }
        return visible.enumerated().map {
            FriendSample(id: $0.offset, date: $0.element.date, steps: $0.element.steps)
        }
    }

    private static func startOfDay(_ key: String, zone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }
}

enum FriendCode {
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func normalize(_ raw: String) -> String? {
        let cleaned = raw.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard cleaned.count == 6 else { return nil }
        guard cleaned.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return cleaned
    }
}

enum FriendCodeImage {
    static func make(_ code: String) -> UIImage? {
        let data = Data(code.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
