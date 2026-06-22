//
//  Settings.swift
//  ReadFlow
//
//  UserDefaults-backed ObservableObject holding every user preference (engine,
//  rate, voices, region, font/spacing, Kokoro base URL) and the ONLY gateway to
//  the Azure subscription key in the Keychain.
//
//  Conforms to the surface in docs/SPEC.md §3.1 and uses ONLY the keys defined
//  in Core/Contracts.swift (`SettingsKey.*`).
//
//  Hard rules honored here:
//    * The Azure key is NEVER written to UserDefaults and NEVER logged.
//    * Playback-affecting changes post `.readFlowSettingsChanged` (main thread).
//    * `@MainActor`; all `@Published` mutations therefore happen on the main
//      thread. No retain cycles (no stored closures capturing self).
//

import Foundation
import Combine
import Security

@MainActor
final class Settings: ObservableObject {

    // MARK: - Singleton

    /// The shared instance the whole app reads/writes through.
    static let shared = Settings()

    // MARK: - Bounds

    /// Sane clamp band for the normalized rate multiplier (1.0 == natural).
    private static let rateRange: ClosedRange<Double> = 0.5...2.0
    /// Reasonable visual bounds so a bad value can't make the HUD unusable.
    private static let fontSizeRange: ClosedRange<Double> = 10.0...96.0
    private static let lineHeightRange: ClosedRange<Double> = 0.8...3.0
    private static let letterSpacingRange: ClosedRange<Double> = -2.0...12.0

    /// Default Kokoro endpoint when none is stored.
    private static let defaultKokoroBaseURL = "http://localhost:8880"

    /// Default Chatterbox endpoint when none is stored (the Framerstation GPU box).
    private static let defaultChatterboxBaseURL = "http://192.168.4.176:8004"

    /// Default Chatterbox predefined voice.
    private static let defaultChatterboxVoice = "Abigail"

    // MARK: - Storage

    private let defaults: UserDefaults

    // MARK: - Published preferences

    /// Which concrete engine drives playback. Persisted as `EngineKind.rawValue`.
    @Published var engineKind: EngineKind {
        didSet {
            guard engineKind != oldValue else { return }
            defaults.set(engineKind.rawValue, forKey: SettingsKey.engineKind)
            postSettingsChanged()
        }
    }

    /// Normalized speed multiplier, clamped to `0.5...2.0`.
    @Published var rate: Double {
        didSet {
            let clamped = Self.rateRange.clamp(rate)
            if clamped != rate {
                // Re-entrant set lands here again but `clamped == rate`, so the
                // persistence/notify branch below runs exactly once.
                rate = clamped
                return
            }
            guard rate != oldValue else { return }
            defaults.set(rate, forKey: SettingsKey.rate)
            postSettingsChanged()
        }
    }

    /// System voice identifier; "" means the platform default voice.
    @Published var systemVoiceID: String {
        didSet {
            guard systemVoiceID != oldValue else { return }
            defaults.set(systemVoiceID, forKey: SettingsKey.systemVoiceID)
            postSettingsChanged()
        }
    }

    /// Kokoro voice name (e.g. "af_sky").
    @Published var kokoroVoice: String {
        didSet {
            guard kokoroVoice != oldValue else { return }
            defaults.set(kokoroVoice, forKey: SettingsKey.kokoroVoice)
            postSettingsChanged()
        }
    }

    /// Azure neural voice name (e.g. "en-US-JennyNeural").
    @Published var azureVoice: String {
        didSet {
            guard azureVoice != oldValue else { return }
            defaults.set(azureVoice, forKey: SettingsKey.azureVoice)
            postSettingsChanged()
        }
    }

    /// Azure region (e.g. "eastus").
    @Published var azureRegion: String {
        didSet {
            guard azureRegion != oldValue else { return }
            defaults.set(azureRegion, forKey: SettingsKey.azureRegion)
            postSettingsChanged()
        }
    }

    /// HUD font name; "" means system font, "OpenDyslexic" the bundled face.
    @Published var fontName: String {
        didSet {
            guard fontName != oldValue else { return }
            defaults.set(fontName, forKey: SettingsKey.fontName)
            // Appearance-only — HUD observes the @Published value directly.
        }
    }

    /// HUD font size in points, clamped to a usable band.
    @Published var fontSize: Double {
        didSet {
            let clamped = Self.fontSizeRange.clamp(fontSize)
            if clamped != fontSize { fontSize = clamped; return }
            guard fontSize != oldValue else { return }
            defaults.set(fontSize, forKey: SettingsKey.fontSize)
        }
    }

    /// HUD line-height multiplier, clamped.
    @Published var lineHeight: Double {
        didSet {
            let clamped = Self.lineHeightRange.clamp(lineHeight)
            if clamped != lineHeight { lineHeight = clamped; return }
            guard lineHeight != oldValue else { return }
            defaults.set(lineHeight, forKey: SettingsKey.lineHeight)
        }
    }

    /// HUD letter-spacing in points, clamped.
    @Published var letterSpacing: Double {
        didSet {
            let clamped = Self.letterSpacingRange.clamp(letterSpacing)
            if clamped != letterSpacing { letterSpacing = clamped; return }
            guard letterSpacing != oldValue else { return }
            defaults.set(letterSpacing, forKey: SettingsKey.letterSpacing)
        }
    }

    /// Kokoro base URL string. Empty/whitespace falls back to the default.
    @Published var kokoroBaseURL: String {
        didSet {
            guard kokoroBaseURL != oldValue else { return }
            defaults.set(kokoroBaseURL, forKey: SettingsKey.kokoroBaseURL)
            postSettingsChanged()
        }
    }

    /// Chatterbox base URL string. Empty/whitespace falls back to the default.
    @Published var chatterboxBaseURL: String {
        didSet {
            guard chatterboxBaseURL != oldValue else { return }
            defaults.set(chatterboxBaseURL, forKey: SettingsKey.chatterboxBaseURL)
            postSettingsChanged()
        }
    }

    /// Chatterbox predefined voice name (e.g. "Abigail"). Stored WITHOUT the
    /// ".wav" extension; the engine appends it when calling the server.
    @Published var chatterboxVoice: String {
        didSet {
            guard chatterboxVoice != oldValue else { return }
            defaults.set(chatterboxVoice, forKey: SettingsKey.chatterboxVoice)
            postSettingsChanged()
        }
    }

    // MARK: - Init

    /// Designated initializer. Defaults to `.standard`; injectable for tests.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Register fallback values so first-launch reads are well-defined and a
        // never-set key returns the intended default rather than zero/"".
        defaults.register(defaults: [
            SettingsKey.engineKind:     EngineKind.system.rawValue,
            SettingsKey.rate:           1.0,
            SettingsKey.systemVoiceID:  "",
            SettingsKey.kokoroVoice:    "af_sky",
            SettingsKey.azureVoice:     "en-US-JennyNeural",
            SettingsKey.azureRegion:    "eastus",
            SettingsKey.fontName:       "",
            SettingsKey.fontSize:       28.0,
            SettingsKey.lineHeight:     1.4,
            SettingsKey.letterSpacing:  0.5,
            SettingsKey.kokoroBaseURL:  Self.defaultKokoroBaseURL,
            SettingsKey.chatterboxBaseURL: Self.defaultChatterboxBaseURL,
            SettingsKey.chatterboxVoice:   Self.defaultChatterboxVoice
        ])

        // Hydrate each stored property from defaults. `didSet` does NOT fire
        // during phase-1 initialization, so these reads don't re-persist/notify.
        let storedEngine = defaults.string(forKey: SettingsKey.engineKind) ?? EngineKind.system.rawValue
        self.engineKind     = EngineKind(rawValue: storedEngine) ?? .system
        self.rate           = Self.rateRange.clamp(defaults.double(forKey: SettingsKey.rate))
        self.systemVoiceID  = defaults.string(forKey: SettingsKey.systemVoiceID) ?? ""
        self.kokoroVoice    = defaults.string(forKey: SettingsKey.kokoroVoice) ?? "af_sky"
        self.azureVoice     = defaults.string(forKey: SettingsKey.azureVoice) ?? "en-US-JennyNeural"
        self.azureRegion    = defaults.string(forKey: SettingsKey.azureRegion) ?? "eastus"
        self.fontName       = defaults.string(forKey: SettingsKey.fontName) ?? ""
        self.fontSize       = Self.fontSizeRange.clamp(defaults.double(forKey: SettingsKey.fontSize))
        self.lineHeight     = Self.lineHeightRange.clamp(defaults.double(forKey: SettingsKey.lineHeight))
        self.letterSpacing  = Self.letterSpacingRange.clamp(defaults.double(forKey: SettingsKey.letterSpacing))

        let storedURL = defaults.string(forKey: SettingsKey.kokoroBaseURL) ?? Self.defaultKokoroBaseURL
        self.kokoroBaseURL  = storedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultKokoroBaseURL
            : storedURL

        let storedCBURL = defaults.string(forKey: SettingsKey.chatterboxBaseURL) ?? Self.defaultChatterboxBaseURL
        self.chatterboxBaseURL = storedCBURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultChatterboxBaseURL
            : storedCBURL
        self.chatterboxVoice = defaults.string(forKey: SettingsKey.chatterboxVoice) ?? Self.defaultChatterboxVoice
    }

    // MARK: - Derived accessors

    /// The Kokoro base URL as a `URL`, falling back to the default if the stored
    /// string is empty or unparsable. Convenience for `KokoroEngine`.
    var kokoroBaseURLValue: URL {
        let trimmed = kokoroBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed.isEmpty ? Self.defaultKokoroBaseURL : trimmed) {
            return url
        }
        // Default is a known-good literal, so this force-unwrap is safe.
        return URL(string: Self.defaultKokoroBaseURL)!
    }

    /// The Chatterbox base URL as a `URL`, falling back to the default if the
    /// stored string is empty or unparsable. Convenience for `ChatterboxEngine`.
    var chatterboxBaseURLValue: URL {
        let trimmed = chatterboxBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed.isEmpty ? Self.defaultChatterboxBaseURL : trimmed) {
            return url
        }
        return URL(string: Self.defaultChatterboxBaseURL)!
    }

    // MARK: - Azure Keychain (the ONLY secret store)

    /// Read the Azure subscription key from the Keychain. Returns `nil` if none
    /// is stored. NEVER logs the key or the lack of one with its value.
    func loadAzureKey() -> String? {
        var query = keychainBaseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    /// Store (or replace) the Azure subscription key in the Keychain.
    /// Returns `true` on success. Empty input deletes any existing key.
    @discardableResult
    func saveAzureKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return deleteAzureKey()
        }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Update in place if present; otherwise add. This avoids a delete+add
        // race and keeps any existing access attributes consistent.
        let matchQuery = keychainBaseQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = keychainBaseQuery()
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
        return false
    }

    /// Delete the Azure subscription key from the Keychain. Returns `true` if it
    /// was removed OR was already absent (idempotent).
    @discardableResult
    func deleteAzureKey() -> Bool {
        let status = SecItemDelete(keychainBaseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Whether an Azure key is currently stored. Lets the manager check for a
    /// credential without materializing the secret.
    var hasAzureKey: Bool {
        var query = keychainBaseQuery()
        query[kSecReturnData as String] = kCFBooleanFalse
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Private helpers

    /// The identity query shared by every Keychain operation. Uses the service +
    /// account constants fixed in `SettingsKey`.
    private func keychainBaseQuery() -> [String: Any] {
        return [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: SettingsKey.azureKeychainService,
            kSecAttrAccount as String: SettingsKey.azureKeychainAccount
        ]
    }

    /// Post the playback-affecting change signal on the main thread. Because the
    /// type is `@MainActor`, `didSet` already runs on the main thread, but we
    /// post explicitly through `NotificationCenter` so non-actor observers
    /// (AppKit) receive it synchronously on the same thread.
    private func postSettingsChanged() {
        NotificationCenter.default.post(name: .readFlowSettingsChanged, object: nil)
    }
}

// MARK: - Clamp utility

private extension ClosedRange where Bound == Double {
    /// Clamp `value` into the range; NaN snaps to `lowerBound`.
    func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return lowerBound }
        return Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
