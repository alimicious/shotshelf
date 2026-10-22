import AppKit
import CryptoKit

/// A newer release found on GitHub, with its zip and the zip's signature.
struct AvailableUpdate: Equatable {
    let version: String
    let pageURL: URL
    let zipURL: URL
    let signatureURL: URL
}

enum UpdateError: LocalizedError {
    case badSignature
    case wrongApp
    case cantInstall(String)

    var errorDescription: String? {
        switch self {
        case .badSignature: return "The download's signature didn't match, so it wasn't installed."
        case .wrongApp: return "The download wasn't the expected version of ShotShelf, so it wasn't installed."
        case .cantInstall(let reason): return reason
        }
    }
}

/// Built-in updates from GitHub releases. Each release zip is signed with a private key that
/// never leaves the maintainer's Keychain; the app only installs zips that verify against the
/// public key below, so a compromised download or GitHub account can't push a bad update.
enum Updater {
    static let feedURL = URL(string: "https://api.github.com/repos/alimicious/shotshelf/releases/latest")!

    /// The public half of the release signing key (Curve25519, raw, base64).
    static let publicKey = "lwcsKBdMndRpsg4EgGBDmVGq4ywljj6yi2cvFi7x59A="

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Compares dotted version numbers: 1.10.0 is newer than 1.9.2.
    static func isNewer(_ version: String, than other: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = other.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Asks GitHub for the latest release. Nil when it isn't newer, or has no signed zip to install.
    static func check(feed: URL = feedURL, current: String = currentVersion) async throws -> AvailableUpdate? {
        struct Release: Decodable {
            let tag_name: String
            let html_url: URL
            let assets: [Asset]
        }
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        let release = try JSONDecoder().decode(Release.self, from: data)
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard isNewer(version, than: current),
              let zip = release.assets.first(where: { $0.name == "ShotShelf-\(version).zip" }),
              let signature = release.assets.first(where: { $0.name == "ShotShelf-\(version).zip.sig" }) else { return nil }
        return AvailableUpdate(version: version, pageURL: release.html_url,
                               zipURL: zip.browser_download_url, signatureURL: signature.browser_download_url)
    }

    /// Downloads the update, checks its signature, unzips it and checks the app inside.
    /// Returns the new app, in a temporary folder on the same disk as `destination`.
    static func prepare(_ update: AvailableUpdate, nextTo destination: URL) async throws -> URL {
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: destination, create: true)
        let (zipData, _) = try await URLSession.shared.data(from: update.zipURL)
        let (signature, _) = try await URLSession.shared.data(from: update.signatureURL)
        guard verify(zipData, signature: signature) else { throw UpdateError.badSignature }

        let zip = work.appendingPathComponent("update.zip")
        try zipData.write(to: zip)
        try run("/usr/bin/ditto", "-x", "-k", zip.path, work.path)
        let app = work.appendingPathComponent("ShotShelf.app")

        // Belt and braces: the same app, the version promised, and an intact code signature.
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == update.version else { throw UpdateError.wrongApp }
        try run("/usr/bin/codesign", "--verify", "--deep", "--strict", app.path)
        return app
    }

    /// Swaps the new app in where the old one is, putting the old one back if anything fails.
    static func install(_ newApp: URL, replacing appURL: URL) throws {
        if appURL.path.contains("/AppTranslocation/") {
            throw UpdateError.cantInstall("Move ShotShelf into your Applications folder, open it from there, then try again.")
        }
        let fm = FileManager.default
        let work = newApp.deletingLastPathComponent()
        let previous = work.appendingPathComponent("ShotShelf-previous.app")
        do {
            try fm.moveItem(at: appURL, to: previous)
        } catch {
            throw UpdateError.cantInstall("macOS didn't let ShotShelf replace itself. Download the update from GitHub instead.")
        }
        do {
            try fm.moveItem(at: newApp, to: appURL)
        } catch {
            try? fm.moveItem(at: previous, to: appURL)
            throw UpdateError.cantInstall("Couldn't put the new version in place, so the current one was kept.")
        }
        try? fm.removeItem(at: work)
    }

    /// Quits, and reopens the app once this copy has fully exited.
    @MainActor static func relaunch(_ appURL: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\"", "sh", appURL.path]
        try? relauncher.run()
        NSApp.terminate(nil)
    }

    // MARK: - Signing

    static func verify(_ data: Data, signature: Data) -> Bool {
        let text = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signatureData = Data(base64Encoded: text) else { return false }
        return key.isValidSignature(signatureData, for: data)
    }

    /// For release.sh: signs a zip with the private key (base64, read from stdin).
    static func sign(_ data: Data, privateKey base64: String) throws -> String {
        guard let raw = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw UpdateError.cantInstall("That isn't a valid signing key.")
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw).signature(for: data).base64EncodedString()
    }

    private static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.wrongApp }
    }
}
