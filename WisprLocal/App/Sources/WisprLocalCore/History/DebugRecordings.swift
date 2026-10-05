import Foundation

/// Recent-recordings store ("Keep last 20 recordings (on this Mac)", ON by default; see
/// `isEnabled(in:)`):
/// delivered dictations keep trimmed 16 kHz mono audio as a WAV plus a JSON sidecar (raw ASR,
/// final text, timings). Failed dictations may keep audio but never text; secure-input blocks
/// and cancellations keep neither. Files are named by the history entry's `id` —
/// `<id>.wav` + `<id>.json` — and are linked to History by that id only, never by timestamp.
/// Rolling: only the newest `limit` pairs are kept. Local only — nothing here ever leaves the
/// machine. Replay a clip in History, or with `swift run WisprLocalReplay <wav>`.
public final class DebugRecordingStore: @unchecked Sendable {
    public static let defaultsKey = "keepDebugRecordings"
    public static let defaultLimit = 20
    /// Posted (any thread) after clips are added or removed; History refreshes its play buttons.
    public static let didChangeNotification = Notification.Name("WisprLocalDebugRecordingsDidChange")

    /// The setting as stored: ON unless the user explicitly turned it OFF. A key that was never
    /// written (new installs, and existing installs that never touched the toggle) reads as ON;
    /// an explicit `false` is always respected.
    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    public let directory: URL
    public let limit: Int
    /// Read live at every dictation (the Settings toggle takes effect immediately).
    public let isEnabled: @Sendable () -> Bool
    private let queue = DispatchQueue(label: "wisprlocal.recordings")
    private var generation: UInt64 = 0
    private var tombstones = Set<UUID>()
    public var saveGeneration: UInt64 { queue.sync { generation } }

    public init(directory: URL = AppPaths.debugRecordingsDirectory, limit: Int = DebugRecordingStore.defaultLimit,
                isEnabled: @escaping @Sendable () -> Bool = { DebugRecordingStore.isEnabled(in: .standard) }) {
        self.directory = directory; self.limit = max(1, limit); self.isEnabled = isEnabled
    }

    /// Writes `<entry.id>.wav` + `<entry.id>.json` (0600 in a 0700 folder), then prunes to
    /// `limit`. Returns the WAV URL. Saving the same id again replaces that pair. Refuses
    /// (nil) an entry whose outcome may not keep audio.
    @discardableResult
    public func save(samples: [Float], sampleRate: Int = Int(AudioConstants.sampleRate), entry: HistoryEntry, generation submittedGeneration: UInt64? = nil) -> URL? {
        let generation = submittedGeneration ?? saveGeneration
        let result = queue.sync { saveOnQueue(samples: samples, sampleRate: sampleRate, entry: entry, submittedGeneration: generation) }
        if result != nil { notifyChanged() }
        return result
    }

    private func saveOnQueue(samples: [Float], sampleRate: Int, entry: HistoryEntry, submittedGeneration: UInt64) -> URL? {
        // SEC-2 (STRUCTURAL): an outcome-only entry never gets a clip, whoever calls this.
        guard !samples.isEmpty, entry.outcome.mayKeepDebugAudio else { return nil }
        let wav: URL
        do {
            guard isEnabled(), !tombstones.contains(entry.id),
                  submittedGeneration == generation else { return nil }
            try AppPaths.ensureDirectory(directory)
            wav = wavURL(entry.id)
            try AppPaths.writePrivate(WAV.encode(samples, sampleRate: sampleRate), to: wav)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            try AppPaths.writePrivate(enc.encode(entry), to: jsonURL(entry.id))
            prune()
        } catch {
            Log.error("debug recording not saved: \(error.localizedDescription)")
            return nil
        }
        return wav
    }

    func wavURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".wav") }
    func jsonURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    /// The clip for a history entry id, nil when none is kept.
    public func clipURL(for id: UUID) -> URL? {
        let url = wavURL(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Ids that currently have a clip (one directory listing).
    public func clipIDs() -> Set<UUID> {
        Set(files().filter { $0.pathExtension == "wav" }.compactMap(Self.id(of:)))
    }

    /// WAV files, oldest first (by the sidecar's entry timestamp, else file date).
    public func recordings() -> [URL] {
        let wavs: [(url: URL, at: Date)] = files().filter { $0.pathExtension == "wav" }.map { ($0, Self.recordedAt($0)) }
        let sorted = wavs.sorted { (a: (url: URL, at: Date), b: (url: URL, at: Date)) -> Bool in
            if a.at != b.at { return a.at < b.at }
            return a.url.lastPathComponent < b.url.lastPathComponent
        }
        return sorted.map { $0.url }
    }

    /// Removes the clip pair for one history entry (History › Delete).
    public func delete(id: UUID) { delete(ids: [id]) }

    public func delete(ids: some Sequence<UUID>) {
        var removed = false
        queue.sync {
            for id in ids {
                tombstones.insert(id)
                for url in [wavURL(id), jsonURL(id)] where FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url); removed = true
                }
            }
        }
        if removed { notifyChanged() }
    }

    /// Removes every recording + sidecar (Settings "Delete All", History "Clear All"). Only our
    /// own file types.
    public func deleteAll() {
        queue.sync {
            generation &+= 1
            tombstones = []
            for f in files() where ["wav", "json"].contains(f.pathExtension) { try? FileManager.default.removeItem(at: f) }
        }
        notifyChanged()
    }

    /// Startup sweep: removes clips that no longer belong to a history entry (deleted entry,
    /// unpaired file, or a pre-id timestamp name), then applies the rolling `limit`. Files
    /// modified at or after `cutoff` are left alone, so a dictation saved while the sweep runs
    /// is never mistaken for an orphan. Returns the number of files removed.
    @discardableResult
    public func sweep(keeping historyIDs: Set<UUID>, cutoff: Date = Date()) -> Int {
        var removed = 0
        queue.sync {
            let all = files().filter { ["wav", "json"].contains($0.pathExtension) }
            let stems = Dictionary(grouping: all) { $0.deletingPathExtension().lastPathComponent }
            for (stem, group) in stems {
                let id = UUID(uuidString: stem)
                let paired = Set(group.map(\.pathExtension)) == ["wav", "json"]
                let linked = id.map(historyIDs.contains) ?? false
                guard !(paired && linked) else { continue }
                for f in group where Self.modified(f) < cutoff {
                    if (try? FileManager.default.removeItem(at: f)) != nil { removed += 1 }
                }
            }
            removed += prune()
        }
        if removed > 0 { notifyChanged() }
        return removed
    }

    /// Rolling limit: drops the oldest pairs beyond `limit`. Caller runs on `queue`.
    @discardableResult
    private func prune() -> Int {
        let wavs = recordings()
        guard wavs.count > limit else { return 0 }
        var n = 0
        for wav in wavs.prefix(wavs.count - limit) {
            for f in [wav, wav.deletingPathExtension().appendingPathExtension("json")] {
                if (try? FileManager.default.removeItem(at: f)) != nil { n += 1 }
            }
        }
        return n
    }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    static func id(of url: URL) -> UUID? { UUID(uuidString: url.deletingPathExtension().lastPathComponent) }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// The entry timestamp from the sidecar (ISO 8601), else the WAV's modification date.
    static func recordedAt(_ wav: URL) -> Date {
        let json = wav.deletingPathExtension().appendingPathExtension("json")
        if let d = try? Data(contentsOf: json),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let s = obj["timestamp"] as? String, let t = ISO8601DateFormatter().date(from: s) {
            return t
        }
        return modified(wav)
    }
}

/// Minimal 16-bit PCM mono WAV codec (debug recordings / replay).
public enum WAV {
    public static func encode(_ samples: [Float], sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        d.reserveCapacity(d.count + samples.count * 2)
        for s in samples {
            let v = Int16((max(-1, min(1, s)) * 32767).rounded())
            u16(UInt16(bitPattern: v))
        }
        return d
    }

    public struct DecodeError: Error, LocalizedError {
        public var reason: String
        public var errorDescription: String? { "Unsupported WAV: \(reason)" }
    }

    /// Decodes 16-bit PCM or 32-bit float mono WAV → (samples, sampleRate).
    public static func decode(_ data: Data) throws -> (samples: [Float], sampleRate: Int) {
        let b = [UInt8](data)
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o+1]) << 8 | UInt32(b[o+2]) << 16 | UInt32(b[o+3]) << 24 }
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o+1]) << 8 }
        guard b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: b[8..<12], encoding: .ascii) == "WAVE" else { throw DecodeError(reason: "not RIFF/WAVE") }
        var o = 12, format: UInt16 = 0, channels: UInt16 = 0, rate = 0, bits: UInt16 = 0
        while o + 8 <= b.count {
            let id = String(bytes: b[o..<o+4], encoding: .ascii) ?? ""
            let size = Int(u32(o + 4)); let body = o + 8
            guard size <= b.count - body else { throw DecodeError(reason: "truncated chunk") }
            if id == "fmt " {
                guard size >= 16 else { throw DecodeError(reason: "short fmt chunk") }
                format = u16(body); channels = u16(body + 2); rate = Int(u32(body + 4)); bits = u16(body + 14)
            } else if id == "data" {
                guard channels == 1 else { throw DecodeError(reason: "\(channels) channels (mono only)") }
                if format == 1 && bits == 16 {
                    var out = [Float](); out.reserveCapacity(size / 2)
                    var i = body
                    while i + 1 < body + size { out.append(Float(Int16(bitPattern: u16(i))) / 32767); i += 2 }
                    return (out, rate)
                }
                if format == 3 && bits == 32 {
                    var out = [Float](); out.reserveCapacity(size / 4)
                    var i = body
                    while i + 3 < body + size { out.append(Float(bitPattern: u32(i))); i += 4 }
                    return (out, rate)
                }
                throw DecodeError(reason: "format \(format), \(bits) bit")
            }
            o = body + size + (size & 1)
        }
        throw DecodeError(reason: "no data chunk")
    }
}
