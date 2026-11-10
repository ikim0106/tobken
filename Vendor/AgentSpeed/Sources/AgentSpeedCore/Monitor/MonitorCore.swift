import Foundation
import os

/// Runs a `TranscriptSession` on a private serial queue. File notifications wake idle sessions;
/// a one-second update runs only while active, with slower rediscovery as a fallback.
///
/// `@unchecked Sendable`: every mutable property is only touched on `queue`; the cancellation flag and the requested
/// source sets are locked.
final class MonitorCore: RemoteFeedSink, @unchecked Sendable {
    static let publishInterval: DispatchTimeInterval = .seconds(1)
    static let rediscoveryInterval: DispatchTimeInterval = .seconds(10)
    static let changeDebounce: DispatchTimeInterval = .milliseconds(80)
    static let watcherLatency: TimeInterval = 0.1

    private let configuration: MonitorConfiguration
    private let pricing: PriceBook?
    private let mailbox: SnapshotMailbox
    /// `rediscoveryInterval`, except in tests.
    private let rediscoveryEvery: DispatchTimeInterval
    private let queue = DispatchQueue(label: "app.agentspeed.monitor", qos: .utility)
    /// Whole-file reads (METRICS 5.3), one at a time, off the live loop.
    private let wholeFileQueue = DispatchQueue(label: "app.agentspeed.monitor.whole-file", qos: .utility)
    /// Runs before each whole-file read on its queue; tests use it to make a read slow.
    private let wholeFileReadHook: (@Sendable (String) -> Void)?
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    /// Subsets whose measured peak each snapshot reports (METRICS 6.8).
    private let subsets: OSAllocatedUnfairLock<Set<SubsetKey>>
    /// The remote hosts' received state (REMOTE 7), kept by the owner across restarts.
    private let remoteFeed: RemoteFeed?

    private var session: TranscriptSession?
    /// The stored performance history (METRICS 6.11), applied to every session this core creates.
    private var perfHistory: [PerfDayRecord] = []
    /// Live reporting's watch epoch (METRICS 11.10), applied to every session this core creates.
    private var reportWatch: Int?
    private var watcher: DirectoryWatcher?
    private var fileWatcher: ActiveFileWatcher?
    private var updateTimer: DispatchSourceTimer?
    private var lastPublishedNs: UInt64 = 0
    private var context: SnapshotContext?
    private var dayStartMs: Int64?
    private var watchedPaths: [String] = []
    private var timers: [DispatchSourceTimer] = []
    private var isLive = false
    private var dirtyPaths: Set<String> = []
    private var needsRescan = false
    private var flushScheduled = false
    /// When the earliest read that changed the engine since the last snapshot began (METRICS 11.9, Observations).
    private var observedAtMs: Int64?
    private var remotePublishScheduled = false

    init(
        configuration: MonitorConfiguration,
        mailbox: SnapshotMailbox,
        subsets: Set<SubsetKey> = [],
        pricing: PriceBook? = nil,
        remoteFeed: RemoteFeed? = nil,
        rediscoveryInterval: DispatchTimeInterval = MonitorCore.rediscoveryInterval,
        wholeFileReadHook: (@Sendable (String) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.pricing = pricing
        self.mailbox = mailbox
        rediscoveryEvery = rediscoveryInterval
        self.subsets = OSAllocatedUnfairLock(initialState: subsets)
        self.remoteFeed = remoteFeed
        self.wholeFileReadHook = wholeFileReadHook
    }

    /// An abandoned core (its owner released it without `stop()`) still releases its timers and stream.
    deinit {
        updateTimer?.cancel()
        for timer in timers { timer.cancel() }
        watcher?.stop()
    }

    func start() {
        queue.async { [self] in bootstrap() }
    }

    /// Stops asynchronously; seeding in progress is abandoned at the next file boundary.
    func stop() {
        cancelled.withLock { $0 = true }
        queue.async { [self] in teardown() }
    }

    private var isCancelled: Bool { cancelled.withLock { $0 } }

    /// The stored performance history (METRICS 6.11): the score card's baselines follow it.
    func setPerfHistory(_ records: [PerfDayRecord]) {
        queue.async { [weak self] in
            guard let self else { return }
            perfHistory = records
            guard let session else { return }
            session.setPerfHistory(records)
            if isLive { publish() }
        }
    }

    /// Live reporting's watch (METRICS 11.10 *Watch*): the epoch completions count in, nil while it is off.
    func setReportWatch(_ epoch: Int?) {
        queue.async { [weak self] in
            guard let self else { return }
            reportWatch = epoch
            session?.setReportWatch(epoch)
        }
    }

    func setSubsets(_ sets: Set<SubsetKey>) {
        let changed = subsets.withLock { current in
            guard current != sets else { return false }
            current = sets
            return true
        }
        guard changed else { return }
        queue.async { [weak self] in self?.publish() }
    }

    // MARK: - Lifecycle

    private func bootstrap() {
        guard !isCancelled else { return }
        let session = TranscriptSession(configuration: configuration, pricing: pricing)
        session.wholeFileReads = { [weak self] job in self?.scheduleWholeFileRead(job) }
        session.setPerfHistory(perfHistory)
        session.setReportWatch(reportWatch)
        self.session = session
        guard session.hasAvailableRoot || remoteFeed?.hasHosts == true else {
            publishPlaceholder(.noSources, session: session)
            timers = [makeTimer(every: rediscoveryEvery) { [weak self] in self?.retryBootstrap() }]
            return
        }
        seedAndGoLive(session)
    }

    private func retryBootstrap() {
        guard let session, !isLive else { return }
        if session.piRootsChanged || session.openclawRootsChanged { return restart() }
        session.refreshAvailability()
        guard session.hasAvailableRoot || remoteFeed?.hasHosts == true else { return }
        cancelTimers()
        seedAndGoLive(session)
    }

    private func seedAndGoLive(_ session: TranscriptSession) {
        let now = Date()
        let todayStartMs = Self.todayStartMs(for: now)
        let context = SnapshotContext(session: session, todayStartMs: todayStartMs)
        let mailbox = self.mailbox
        let gate = ProgressGate()
        mailbox.post(SnapshotBuilder.placeholder(state: .starting(progress: 0), context: context, now: now))

        let cancelled = self.cancelled
        _ = session.seed(
            todayStartMs: todayStartMs,
            progress: { value in
                guard gate.admit(value) else { return }
                mailbox.post(SnapshotBuilder.placeholder(state: .starting(progress: value), context: context, now: Date()))
            },
            isCancelled: { cancelled.withLock { $0 } }
        )
        guard !isCancelled else { return }
        // Seeding decodes hundreds of megabytes in parallel; hand the freed pages back instead of keeping them dirty.
        malloc_zone_pressure_relief(nil, 0)
        // The hosts' received state joins as seeded, before the peak is established (REMOTE 7 *Monitor restart*).
        if let remoteFeed { session.applyRemote(remoteFeed.attach(self)) }

        // Establish today's peak from the backlog so the first live tick cannot announce a stale record.
        let seededNow = Date()
        _ = session.advance(
            nowMs: Clock.milliseconds(seededNow), todayStartMs: Self.todayStartMs(for: seededNow), emitsEvents: false,
            subsets: subsets.withLock { $0 }
        )
        isLive = true
        updateWatcher()
        timers = [
            makeTimer(every: rediscoveryEvery, leeway: .seconds(1)) { [weak self] in self?.rediscover() },
        ]
        publish()
    }

    private func restart() {
        teardown()
        dirtyPaths.removeAll()
        needsRescan = false
        bootstrap()
    }

    private func teardown() {
        remoteFeed?.detach(self)
        cancelTimers()
        watcher?.stop()
        watcher = nil
        fileWatcher = nil
        updateTimer?.cancel()
        updateTimer = nil
        context = nil
        dayStartMs = nil
        lastPublishedNs = 0
        watchedPaths = []
        session = nil
        isLive = false
    }

    // MARK: - Change handling

    private func handle(_ events: [DirectoryWatcher.Event]) {
        guard isLive else { return }
        for event in events {
            if event.needsRescan {
                needsRescan = true
            } else {
                dirtyPaths.insert(event.path)
            }
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + Self.changeDebounce) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        guard let session, isLive else { return }
        let began = Clock.monotonicMs()
        var changed = false
        if needsRescan {
            needsRescan = false
            changed = session.rediscover(todayStartMs: Self.todayStartMs(for: Date()))
            updateWatcher()
        }
        let paths = dirtyPaths
        dirtyPaths.removeAll()
        changed = session.handleChanges(atCanonicalPaths: paths) || changed
        if changed {
            observe(began)
            publish()
        } else if session.hasDirtyDatabases {
            scheduleUpdate(after: Self.publishInterval)
        }
    }

    private func scheduleWholeFileRead(_ job: WholeFileRead) {
        let hook = wholeFileReadHook
        wholeFileQueue.async { [weak self] in
            guard let self, !isCancelled else { return }
            hook?(job.path)
            let began = Clock.monotonicMs()
            let result = job.perform()
            queue.async { [weak self] in self?.finishWholeFileRead(result, began: began) }
        }
    }

    private func finishWholeFileRead(_ result: WholeFileResult, began: Int64) {
        guard let session, isLive else { return }
        if session.completeWholeFileRead(result) {
            observe(began)
            publish()
        }
    }

    private func rediscover() {
        guard let session, isLive else { return }
        // A new or removed Pi folder, OpenClaw state folder or agent-scoped Codex home is read like at startup: older
        // files from their end, with one dedupe set.
        if session.piRootsChanged || session.openclawRootsChanged { return restart() }
        let began = Clock.monotonicMs()
        let changed = session.rediscover(todayStartMs: Self.todayStartMs(for: Date()))
        updateWatcher()
        if changed || dayStartMs != Self.todayStartMs(for: Date()) {
            observe(began)
            publish()
        }
    }

    // MARK: - Remote hosts

    func remoteFeed(_ changes: [RemoteFeedChange]) {
        queue.async { [weak self] in self?.applyRemote(changes) }
    }

    /// A host's lines are applied between reads of local files; snapshots follow after a short debounce, so a burst
    /// of lines costs one engine tick.
    private func applyRemote(_ changes: [RemoteFeedChange]) {
        guard let session, isLive else { return }
        let began = Clock.monotonicMs()
        guard session.applyRemote(changes) else { return }
        observe(began)
        guard !remotePublishScheduled else { return }
        remotePublishScheduled = true
        queue.asyncAfter(deadline: .now() + Self.changeDebounce) { [weak self] in
            guard let self else { return }
            remotePublishScheduled = false
            publish()
        }
    }

    private func observe(_ began: Int64) {
        context = nil
        observedAtMs = min(observedAtMs ?? began, began)
    }

    private func publish() {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- lastPublishedNs
        guard lastPublishedNs == 0 || elapsed >= 1_000_000_000 else {
            scheduleUpdate(after: .nanoseconds(Int(1_000_000_000 - elapsed)))
            return
        }
        publishNow()
    }

    private func publishNow() {
        guard let session, isLive else { return }
        updateTimer?.cancel()
        updateTimer = nil
        let began = Clock.monotonicMs()
        if session.readDirtyDatabases() { observe(began) }
        if context == nil { updateFileWatcher() }
        let now = Date()
        let todayStartMs = Self.todayStartMs(for: now)
        let requested = subsets.withLock { $0 }
        let (output, events) = session.advance(
            nowMs: Clock.milliseconds(now), todayStartMs: todayStartMs, emitsEvents: true, subsets: requested
        )
        if context == nil || self.dayStartMs != todayStartMs {
            context = SnapshotContext(session: session, todayStartMs: todayStartMs)
        }
        self.dayStartMs = todayStartMs
        guard let context else { return }
        var snapshot = SnapshotBuilder.running(output, context: context)
        snapshot.observedAtMs = observedAtMs
        observedAtMs = nil
        mailbox.post(snapshot, events: events)
        lastPublishedNs = DispatchTime.now().uptimeNanoseconds
        if output.live.output > 0 || session.hasDirtyDatabases {
            scheduleUpdate(after: Self.publishInterval)
        }
    }

    private func scheduleUpdate(after interval: DispatchTimeInterval) {
        guard updateTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, let session, isLive else { return }
            let began = Clock.monotonicMs()
            if session.pollRecentFiles(nowMs: Clock.milliseconds(Date())) {
                observe(began)
            }
            publishNow()
        }
        updateTimer = timer
        timer.resume()
    }

    private func publishPlaceholder(_ state: MonitorState, session: TranscriptSession) {
        let now = Date()
        let context = SnapshotContext(session: session, todayStartMs: Self.todayStartMs(for: now))
        mailbox.post(SnapshotBuilder.placeholder(state: state, context: context, now: now))
    }

    // MARK: - Helpers

    private func updateWatcher() {
        guard let session else { return }
        let paths = session.watchedPaths
        guard paths != watchedPaths || watcher == nil else { return }
        watcher?.stop()
        watcher = DirectoryWatcher(paths: paths, queue: queue, latency: Self.watcherLatency) { [weak self] events in
            self?.handle(events)
        }
        watchedPaths = watcher == nil ? [] : paths
        updateFileWatcher()
    }

    private func updateFileWatcher() {
        guard let session else { return }
        if fileWatcher == nil {
            fileWatcher = ActiveFileWatcher(queue: queue) { [weak self] path in
                self?.handle([DirectoryWatcher.Event(path: path, needsRescan: false)])
            }
        }
        fileWatcher?.update(paths: session.activeFilePaths)
    }

    private func makeTimer(
        every interval: DispatchTimeInterval,
        leeway: DispatchTimeInterval = .milliseconds(250),
        handler: @escaping @Sendable () -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    private func cancelTimers() {
        for timer in timers { timer.cancel() }
        timers = []
    }

    /// Local midnight from the user's current calendar and time zone.
    static func todayStartMs(for date: Date) -> Int64 {
        Clock.milliseconds(Calendar.current.startOfDay(for: date))
    }
}

/// Lets seeding progress through in steps of at least 2 %.
private final class ProgressGate: Sendable {
    private let last = OSAllocatedUnfairLock(initialState: 0.0)

    func admit(_ value: Double) -> Bool {
        last.withLock { last in
            guard value >= 1 || value - last >= 0.02 else { return false }
            last = value
            return true
        }
    }
}
