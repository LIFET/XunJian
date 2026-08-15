import Darwin
import Foundation
import XCTest

final class OAuthProcessTests: XCTestCase {
    func testCodexAppServerHomeIsPrivateStableAndDoesNotReuseSharedAuth() throws {
        let userHome = try makePrivateTemporaryDirectory(label: "codex-home-stable")
        defer { try? FileManager.default.removeItem(at: userHome) }
        let sharedDirectory = userHome.appending(path: ".codex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: sharedDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sharedAuth = sharedDirectory.appending(path: "auth.json")
        let sentinel = Data("shared-auth-must-not-move".utf8)
        try sentinel.write(to: sharedAuth, options: .withoutOverwriting)

        let first = try CodexAppServerHome.prepare(userHomeDirectoryURL: userHome)
        XCTAssertEqual(try permissions(of: first.rootURL), 0o700)
        XCTAssertNotEqual(first.rootURL.standardizedFileURL, sharedDirectory.standardizedFileURL)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: first.rootURL.appending(path: "auth.json").path
            )
        )
        let second = try CodexAppServerHome.prepare(userHomeDirectoryURL: userHome)
        XCTAssertEqual(second.rootURL.standardizedFileURL, first.rootURL.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: sharedAuth), sentinel)
    }

    func testCodexAppServerHomeAcceptsOnlyOfficialSkillsScaffoldingAndOpaqueAuth() throws {
        let userHome = try makePrivateTemporaryDirectory(
            label: "codex-home-official-skills"
        )
        defer { try? FileManager.default.removeItem(at: userHome) }
        let initial = try CodexAppServerHome.prepare(userHomeDirectoryURL: userHome)
        let skills = initial.rootURL.appending(
            path: "skills",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: skills,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )

        let emptySkills = try CodexAppServerHome.prepare(userHomeDirectoryURL: userHome)
        XCTAssertEqual(emptySkills.rootURL, initial.rootURL)
        XCTAssertEqual(try permissions(of: skills), 0o700)

        let systemSkills = skills.appending(
            path: ".system",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: systemSkills,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o751]
        )
        let credential = initial.rootURL.appending(path: "auth.json")
        let credentialBytes = Data([0x00, 0xFF, 0x7B, 0x0A])
        XCTAssertTrue(FileManager.default.createFile(
            atPath: credential.path,
            contents: credentialBytes,
            attributes: [.posixPermissions: 0o600]
        ))
        let credentialIdentity = try fileIdentity(of: credential)

        let official = try CodexAppServerHome.prepare(userHomeDirectoryURL: userHome)
        let repeated = try CodexAppServerHome.prepare(userHomeDirectoryURL: userHome)

        XCTAssertEqual(official.rootURL, initial.rootURL)
        XCTAssertEqual(repeated.rootURL, initial.rootURL)
        XCTAssertEqual(try permissions(of: skills), 0o700)
        XCTAssertEqual(try permissions(of: systemSkills), 0o700)
        XCTAssertEqual(try permissions(of: credential), 0o600)
        XCTAssertEqual(try Data(contentsOf: credential), credentialBytes)
        XCTAssertEqual(try fileIdentity(of: credential), credentialIdentity)
    }

    func testCodexAppServerHomeRejectsUnsafeSkillsScaffoldingWithoutTouchingSource() throws {
        for kind in [
            "skills-file",
            "skills-symlink",
            "system-symlink",
            "extra-visible-child"
        ] {
            let userHome = try makePrivateTemporaryDirectory(
                label: "codex-home-skills-\(kind)"
            )
            defer { try? FileManager.default.removeItem(at: userHome) }
            let home = try CodexAppServerHome.prepare(userHomeDirectoryURL: userHome)
            let skills = home.rootURL.appending(
                path: "skills",
                directoryHint: .isDirectory
            )
            let source = userHome.appending(
                path: "external-skills-source",
                directoryHint: .isDirectory
            )
            let markerBytes = Data("preserve-\(kind)".utf8)
            var preservedURL: URL

            switch kind {
            case "skills-file":
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: skills.path,
                    contents: markerBytes,
                    attributes: [.posixPermissions: 0o600]
                ))
                preservedURL = skills

            case "skills-symlink":
                try FileManager.default.createDirectory(
                    at: source,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o755]
                )
                preservedURL = source.appending(path: "marker")
                try markerBytes.write(to: preservedURL, options: .withoutOverwriting)
                try FileManager.default.createSymbolicLink(
                    at: skills,
                    withDestinationURL: source
                )

            case "system-symlink":
                try FileManager.default.createDirectory(
                    at: skills,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                try FileManager.default.createDirectory(
                    at: source,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o755]
                )
                preservedURL = source.appending(path: "marker")
                try markerBytes.write(to: preservedURL, options: .withoutOverwriting)
                try FileManager.default.createSymbolicLink(
                    at: skills.appending(path: ".system"),
                    withDestinationURL: source
                )

            case "extra-visible-child":
                try FileManager.default.createDirectory(
                    at: skills.appending(path: ".system"),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                preservedURL = skills.appending(path: "custom-skill")
                try markerBytes.write(to: preservedURL, options: .withoutOverwriting)

            default:
                XCTFail("Unexpected fixture")
                continue
            }

            let sourcePermissions = kind.contains("symlink")
                ? try permissions(of: source)
                : nil
            XCTAssertThrowsError(
                try CodexAppServerHome.prepare(userHomeDirectoryURL: userHome),
                "Expected unsafe Codex skills rejection: \(kind)"
            )
            XCTAssertEqual(try Data(contentsOf: preservedURL), markerBytes, kind)
            if let sourcePermissions {
                XCTAssertEqual(try permissions(of: source), sourcePermissions, kind)
            }
        }
    }

    func testCodexAppServerHomeAcceptsOnlyOfficialPluginScaffolding() throws {
        let layouts: [(
            name: String,
            hasStaging: Bool,
            hasCache: Bool,
            hasCuratedCache: Bool
        )] = [
            ("empty", false, false, false),
            ("staging-only", true, false, false),
            ("empty-cache-only", false, true, false),
            ("curated-cache-only", false, true, true),
            ("staging-and-curated-cache", true, true, true)
        ]

        for layout in layouts {
            let userHome = try makePrivateTemporaryDirectory(
                label: "codex-home-plugins-\(layout.name)"
            )
            defer { try? FileManager.default.removeItem(at: userHome) }
            let home = try CodexAppServerHome.prepare(userHomeDirectoryURL: userHome)
            let plugins = home.rootURL.appending(
                path: "plugins",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: plugins,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o755]
            )
            var expectedDirectories = [plugins]
            if layout.hasStaging {
                let staging = plugins.appending(
                    path: ".remote-plugin-install-staging",
                    directoryHint: .isDirectory
                )
                try FileManager.default.createDirectory(
                    at: staging,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o751]
                )
                expectedDirectories.append(staging)
            }
            if layout.hasCache {
                let cache = plugins.appending(
                    path: "cache",
                    directoryHint: .isDirectory
                )
                try FileManager.default.createDirectory(
                    at: cache,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o751]
                )
                expectedDirectories.append(cache)
                if layout.hasCuratedCache {
                    let curated = cache.appending(
                        path: "openai-curated-remote",
                        directoryHint: .isDirectory
                    )
                    try FileManager.default.createDirectory(
                        at: curated,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o751]
                    )
                    expectedDirectories.append(curated)
                }
            }

            let prepared = try CodexAppServerHome.prepare(
                userHomeDirectoryURL: userHome
            )
            let repeated = try CodexAppServerHome.prepare(
                userHomeDirectoryURL: userHome
            )

            XCTAssertEqual(prepared.rootURL, home.rootURL, layout.name)
            XCTAssertEqual(repeated.rootURL, home.rootURL, layout.name)
            for directory in expectedDirectories {
                XCTAssertEqual(try permissions(of: directory), 0o700, layout.name)
            }
        }
    }

    func testCodexAppServerHomeRejectsUnsafePluginScaffoldingWithoutMutation() throws {
        let cases = [
            "plugins-file", "plugins-symlink", "plugins-writable",
            "staging-file", "staging-symlink", "staging-writable",
            "staging-nonempty",
            "cache-file", "cache-symlink", "cache-writable",
            "cache-extra-child",
            "curated-file", "curated-symlink", "curated-writable"
        ]

        for kind in cases {
            let userHome = try makePrivateTemporaryDirectory(
                label: "codex-home-plugins-unsafe-\(kind)"
            )
            defer { try? FileManager.default.removeItem(at: userHome) }
            let home = try CodexAppServerHome.prepare(userHomeDirectoryURL: userHome)
            let plugins = home.rootURL.appending(
                path: "plugins",
                directoryHint: .isDirectory
            )
            let staging = plugins.appending(
                path: ".remote-plugin-install-staging",
                directoryHint: .isDirectory
            )
            let cache = plugins.appending(
                path: "cache",
                directoryHint: .isDirectory
            )
            let curated = cache.appending(
                path: "openai-curated-remote",
                directoryHint: .isDirectory
            )
            let source = userHome.appending(
                path: "external-plugin-source",
                directoryHint: .isDirectory
            )
            let markerBytes = Data("preserve-\(kind)".utf8)
            var preservedDataURL: URL?
            var preservedPermissionsURL: URL?
            var preservedPermissions: Int?

            func createDirectory(_ url: URL, permissions: Int = 0o700) throws {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: permissions]
                )
            }

            func createParentDirectories(for path: String) throws {
                try createDirectory(plugins)
                if path == "curated" {
                    try createDirectory(cache)
                }
            }

            func installSymlink(at obstacle: URL) throws {
                try createDirectory(source, permissions: 0o755)
                let marker = source.appending(path: "marker")
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: marker.path,
                    contents: markerBytes,
                    attributes: [.posixPermissions: 0o600]
                ))
                try FileManager.default.createSymbolicLink(
                    at: obstacle,
                    withDestinationURL: source
                )
                preservedDataURL = marker
                preservedPermissionsURL = source
                preservedPermissions = try permissions(of: source)
            }

            switch kind {
            case "plugins-file":
                try markerBytes.write(to: plugins, options: .withoutOverwriting)
                preservedDataURL = plugins
            case "plugins-symlink":
                try installSymlink(at: plugins)
            case "plugins-writable":
                try createDirectory(plugins)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o777],
                    ofItemAtPath: plugins.path
                )
                preservedPermissionsURL = plugins
                preservedPermissions = 0o777

            case "staging-file":
                try createParentDirectories(for: "staging")
                try markerBytes.write(to: staging, options: .withoutOverwriting)
                preservedDataURL = staging
            case "staging-symlink":
                try createParentDirectories(for: "staging")
                try installSymlink(at: staging)
            case "staging-writable":
                try createParentDirectories(for: "staging")
                try createDirectory(staging)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o777],
                    ofItemAtPath: staging.path
                )
                preservedPermissionsURL = staging
                preservedPermissions = 0o777
            case "staging-nonempty":
                try createParentDirectories(for: "staging")
                try createDirectory(staging)
                let marker = staging.appending(path: "partial-install")
                try markerBytes.write(to: marker, options: .withoutOverwriting)
                preservedDataURL = marker

            case "cache-file":
                try createParentDirectories(for: "cache")
                try markerBytes.write(to: cache, options: .withoutOverwriting)
                preservedDataURL = cache
            case "cache-symlink":
                try createParentDirectories(for: "cache")
                try installSymlink(at: cache)
            case "cache-writable":
                try createParentDirectories(for: "cache")
                try createDirectory(cache)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o777],
                    ofItemAtPath: cache.path
                )
                preservedPermissionsURL = cache
                preservedPermissions = 0o777
            case "cache-extra-child":
                try createParentDirectories(for: "cache")
                try createDirectory(cache)
                try createDirectory(curated)
                let marker = cache.appending(path: "unexpected-provider")
                try markerBytes.write(to: marker, options: .withoutOverwriting)
                preservedDataURL = marker

            case "curated-file":
                try createParentDirectories(for: "curated")
                try markerBytes.write(to: curated, options: .withoutOverwriting)
                preservedDataURL = curated
            case "curated-symlink":
                try createParentDirectories(for: "curated")
                try installSymlink(at: curated)
            case "curated-writable":
                try createParentDirectories(for: "curated")
                try createDirectory(curated)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o777],
                    ofItemAtPath: curated.path
                )
                preservedPermissionsURL = curated
                preservedPermissions = 0o777

            default:
                XCTFail("Unexpected fixture")
                continue
            }

            XCTAssertThrowsError(
                try CodexAppServerHome.prepare(userHomeDirectoryURL: userHome),
                "Expected unsafe Codex plugin rejection: \(kind)"
            )
            if let preservedDataURL {
                XCTAssertEqual(
                    try Data(contentsOf: preservedDataURL),
                    markerBytes,
                    kind
                )
            }
            if let preservedPermissionsURL, let preservedPermissions {
                XCTAssertEqual(
                    try permissions(of: preservedPermissionsURL),
                    preservedPermissions,
                    kind
                )
            }
        }
    }

    func testCodexAppServerHomeRejectsConfigurationAndLinkedAuthAndLeasesExclusively() throws {
        for obstacle in ["config", "auth-symlink"] {
            let userHome = try makePrivateTemporaryDirectory(
                label: "codex-home-unsafe-\(obstacle)"
            )
            defer { try? FileManager.default.removeItem(at: userHome) }
            let home = try CodexAppServerHome.prepare(userHomeDirectoryURL: userHome)
            if obstacle == "config" {
                try Data("model = \"unsafe\"\n".utf8).write(
                    to: home.rootURL.appending(path: "config.toml")
                )
            } else {
                let source = userHome.appending(path: "outside-auth")
                try Data("secret".utf8).write(to: source)
                try FileManager.default.createSymbolicLink(
                    at: home.rootURL.appending(path: "auth.json"),
                    withDestinationURL: source
                )
            }
            XCTAssertThrowsError(
                try CodexAppServerHome.prepare(userHomeDirectoryURL: userHome)
            )
        }

        let leaseHome = try makePrivateTemporaryDirectory(label: "codex-home-lease")
        defer { try? FileManager.default.removeItem(at: leaseHome) }
        let home = try CodexAppServerHome.prepare(userHomeDirectoryURL: leaseHome)
        let firstLease = try home.acquireLease()
        XCTAssertThrowsError(try home.acquireLease()) { error in
            XCTAssertEqual(error as? CodexAppServerHomeError, .busy)
        }
        firstLease.release()
        XCTAssertNoThrow(try home.acquireLease().release())
    }

    func testGrokCLIHomeIsStablePrivateAndIdempotent() throws {
        let userHome = try makePrivateTemporaryDirectory(label: "grok-home-stable")
        defer { try? FileManager.default.removeItem(at: userHome) }

        let first = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
        let expectedApplicationSupport = userHome
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .standardizedFileURL
        XCTAssertTrue(
            first.rootURL.standardizedFileURL.path.hasPrefix(
                expectedApplicationSupport.path + "/"
            )
        )
        XCTAssertNotEqual(
            first.rootURL.standardizedFileURL,
            userHome.appending(path: ".grok", directoryHint: .isDirectory)
                .standardizedFileURL
        )
        XCTAssertEqual(try permissions(of: first.rootURL), 0o700)

        let marker = first.rootURL.appending(path: "cli-owned-marker")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: marker.path,
            contents: Data("preserve".utf8)
        ))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: first.rootURL.path
        )

        let second = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
        XCTAssertEqual(second.rootURL.standardizedFileURL, first.rootURL.standardizedFileURL)
        XCTAssertEqual(try permissions(of: second.rootURL), 0o700)
        XCTAssertEqual(try Data(contentsOf: marker), Data("preserve".utf8))
    }

    func testGrokCLIHomeRejectsFileAndSymlinkAtStableRoot() throws {
        for obstacle in ["file", "symlink"] {
            let userHome = try makePrivateTemporaryDirectory(
                label: "grok-home-obstacle-\(obstacle)"
            )
            defer { try? FileManager.default.removeItem(at: userHome) }
            let prepared = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
            let rootURL = prepared.rootURL
            try FileManager.default.removeItem(at: rootURL)

            if obstacle == "file" {
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: rootURL.path,
                    contents: Data("not-a-directory".utf8)
                ))
            } else {
                let target = userHome.appending(path: "symlink-target", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                try FileManager.default.createSymbolicLink(
                    at: rootURL,
                    withDestinationURL: target
                )
            }

            XCTAssertThrowsError(
                try GrokCLIHome.prepare(userHomeDirectoryURL: userHome),
                "Expected stable root obstacle rejection: \(obstacle)"
            )
        }
    }

    func testGrokCLIHomeRejectsLinkedAuthenticationFileWithoutTouchingSource() throws {
        for linkKind in ["symbolic", "hard"] {
            let userHome = try makePrivateTemporaryDirectory(
                label: "grok-home-auth-link-\(linkKind)"
            )
            defer { try? FileManager.default.removeItem(at: userHome) }
            let prepared = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
            let globalGrok = userHome.appending(path: ".grok", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: globalGrok,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let sourceAuth = globalGrok.appending(path: "auth.json")
            let sentinel = Data("global-auth-must-not-be-reused".utf8)
            XCTAssertTrue(FileManager.default.createFile(
                atPath: sourceAuth.path,
                contents: sentinel,
                attributes: [.posixPermissions: 0o600]
            ))
            let dedicatedAuth = prepared.rootURL.appending(path: "auth.json")
            if linkKind == "symbolic" {
                try FileManager.default.createSymbolicLink(
                    at: dedicatedAuth,
                    withDestinationURL: sourceAuth
                )
            } else {
                try FileManager.default.linkItem(at: sourceAuth, to: dedicatedAuth)
            }

            XCTAssertThrowsError(
                try GrokCLIHome.prepare(userHomeDirectoryURL: userHome),
                "Expected linked auth rejection: \(linkKind)"
            )
            XCTAssertEqual(try Data(contentsOf: sourceAuth), sentinel)
        }
    }

    func testGrokCLIHomeLeaseIsMutuallyExclusiveAndReusableAfterRelease() throws {
        let userHome = try makePrivateTemporaryDirectory(label: "grok-home-lease")
        defer { try? FileManager.default.removeItem(at: userHome) }
        let firstHome = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
        let secondHome = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
        let firstLease = try firstHome.acquireLease()

        var rejectedConcurrentLease = false
        do {
            let unexpectedLease = try secondHome.acquireLease()
            unexpectedLease.release()
        } catch {
            rejectedConcurrentLease = true
        }
        XCTAssertTrue(rejectedConcurrentLease)

        firstLease.release()
        let nextLease = try secondHome.acquireLease()
        nextLease.release()
    }

    func testGrokCLIHomeLeaseStaysHeldAcrossLoginFinalizationAndRuntimeTransfer() throws {
        let userHome = try makePrivateTemporaryDirectory(label: "grok-home-transfer")
        defer { try? FileManager.default.removeItem(at: userHome) }
        let firstHome = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
        let competingHome = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
        let ownership = GrokCLIHomeLeaseOwnership(
            lease: try firstHome.acquireLease(),
            initialOwner: .login
        )

        XCTAssertTrue(ownership.beginFinalization())
        ownership.releaseLogin()
        XCTAssertThrowsError(try competingHome.acquireLease())

        XCTAssertTrue(ownership.transferToRuntime())
        ownership.releaseBuilderOrFinalizer()
        XCTAssertThrowsError(try competingHome.acquireLease())

        ownership.releaseRuntime()
        let nextLease = try competingHome.acquireLease()
        nextLease.release()
    }

    func testGrokCLIHomeRejectsKnownExecutableConfigurationSources() throws {
        let names = [
            "lsp.json", ".lsp.json",
            "settings.json", "managed-settings.json"
        ]
        for (index, name) in names.enumerated() {
            let userHome = try makePrivateTemporaryDirectory(
                label: "grok-home-forbidden-\(index)"
            )
            defer { try? FileManager.default.removeItem(at: userHome) }
            let prepared = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
            let source = userHome.appending(path: "source-\(index)")
            let forbidden = prepared.rootURL.appending(path: name)

            switch index % 3 {
            case 0:
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: forbidden.path,
                    contents: Data("forbidden".utf8)
                ))
            case 1:
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: source.path,
                    contents: Data("symlink-source".utf8)
                ))
                try FileManager.default.createSymbolicLink(
                    at: forbidden,
                    withDestinationURL: source
                )
            default:
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: source.path,
                    contents: Data("hardlink-source".utf8)
                ))
                try FileManager.default.linkItem(at: source, to: forbidden)
            }

            XCTAssertThrowsError(
                try GrokCLIHome.prepare(userHomeDirectoryURL: userHome),
                "Expected unsafe configuration source rejection: \(name)"
            )
            if FileManager.default.fileExists(atPath: source.path) {
                XCTAssertFalse((try Data(contentsOf: source)).isEmpty)
            }
        }
    }

    func testGrokCLIHomeAcceptsPrivateCredentialMetadataButRejectsLooseMode() throws {
        let userHome = try makePrivateTemporaryDirectory(label: "grok-home-auth-mode")
        defer { try? FileManager.default.removeItem(at: userHome) }
        let prepared = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
        let credential = prepared.rootURL.appending(path: "auth.json")
        let sentinel = Data("opaque-cli-owned-credential".utf8)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: credential.path,
            contents: sentinel,
            attributes: [.posixPermissions: 0o600]
        ))

        _ = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
        XCTAssertEqual(try Data(contentsOf: credential), sentinel)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: credential.path
        )
        XCTAssertThrowsError(
            try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
        )
        XCTAssertEqual(try permissions(of: credential), 0o644)
        XCTAssertEqual(try Data(contentsOf: credential), sentinel)
    }

    func testGrokCLIHomeAllowsOnlyEmptyHookScaffolding() throws {
        let userHome = try makePrivateTemporaryDirectory(label: "grok-home-hook-scaffold")
        defer { try? FileManager.default.removeItem(at: userHome) }
        let prepared = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
        let hooks = prepared.rootURL.appending(path: "hooks", directoryHint: .isDirectory)
        let registry = prepared.rootURL.appending(path: "hooks-paths")
        try FileManager.default.createDirectory(
            at: hooks,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: registry.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o644]
        ))

        _ = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
        XCTAssertEqual(try permissions(of: hooks), 0o700)
        XCTAssertEqual(try permissions(of: registry), 0o600)

        let hook = hooks.appending(path: "unsafe.json")
        let hookBytes = Data("{\"hooks\":[]}".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: hook.path, contents: hookBytes))
        XCTAssertThrowsError(try GrokCLIHome.prepare(userHomeDirectoryURL: userHome))
        XCTAssertEqual(try Data(contentsOf: hook), hookBytes)
    }

    func testGrokCLIHomeAllowsOnlyExactOfficialMarketplaceBootstrapConfiguration() throws {
        let expected = Data(
            "[marketplace]\ndefault_skills_installs_purged = true\n".utf8
        )
        let safeUserHome = try makePrivateTemporaryDirectory(
            label: "grok-home-bootstrap-config-safe"
        )
        defer { try? FileManager.default.removeItem(at: safeUserHome) }
        let safeHome = try GrokCLIHome.prepare(userHomeDirectoryURL: safeUserHome)
        let safeConfiguration = safeHome.rootURL.appending(path: "config.toml")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: safeConfiguration.path,
            contents: expected,
            attributes: [.posixPermissions: 0o644]
        ))

        _ = try GrokCLIHome.prepare(userHomeDirectoryURL: safeUserHome)
        XCTAssertEqual(try Data(contentsOf: safeConfiguration), expected)
        XCTAssertEqual(try permissions(of: safeConfiguration), 0o600)

        for kind in ["content", "symlink", "hardlink", "mode"] {
            let userHome = try makePrivateTemporaryDirectory(
                label: "grok-home-bootstrap-config-\(kind)"
            )
            defer { try? FileManager.default.removeItem(at: userHome) }
            let prepared = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
            let configuration = prepared.rootURL.appending(path: "config.toml")
            let source = userHome.appending(path: "source")

            switch kind {
            case "content":
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: configuration.path,
                    contents: expected + Data("unsafe = true\n".utf8),
                    attributes: [.posixPermissions: 0o644]
                ))
            case "symlink":
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: source.path,
                    contents: expected,
                    attributes: [.posixPermissions: 0o600]
                ))
                try FileManager.default.createSymbolicLink(
                    at: configuration,
                    withDestinationURL: source
                )
            case "hardlink":
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: source.path,
                    contents: expected,
                    attributes: [.posixPermissions: 0o600]
                ))
                try FileManager.default.linkItem(at: source, to: configuration)
            case "mode":
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: configuration.path,
                    contents: expected,
                    attributes: [.posixPermissions: 0o644]
                ))
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o666],
                    ofItemAtPath: configuration.path
                )
            default:
                XCTFail("Unexpected fixture")
            }

            XCTAssertThrowsError(
                try GrokCLIHome.prepare(userHomeDirectoryURL: userHome),
                "Expected unsafe bootstrap configuration rejection: \(kind)"
            )
            if FileManager.default.fileExists(atPath: source.path) {
                XCTAssertEqual(try Data(contentsOf: source), expected)
            }
        }
    }

    func testGrokCLIHomeHardeningCanonicalizesAcceptedBootstrapStatesAtomically() throws {
        let officialConfiguration = pinnedGrok100OfficialConfiguration()
        XCTAssertEqual(officialConfiguration.count, 200)
        let legacyConfiguration = Data(
            "[marketplace]\ndefault_skills_installs_purged = true\n".utf8
        )
        let seeds: [(name: String, configuration: Data?)] = [
            ("no-config", nil),
            ("legacy-52", legacyConfiguration),
            ("official-200", officialConfiguration)
        ]

        for (index, seed) in seeds.enumerated() {
            let userHome = try makePrivateTemporaryDirectory(
                label: "grok-home-canonical-\(seed.name)"
            )
            defer { try? FileManager.default.removeItem(at: userHome) }
            let home = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
            let configuration = home.rootURL.appending(path: "config.toml")
            var originalConfigurationIdentity: UInt64?
            if let bytes = seed.configuration {
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: configuration.path,
                    contents: bytes,
                    attributes: [.posixPermissions: 0o644]
                ))
                originalConfigurationIdentity = try fileIdentity(of: configuration)
            }

            let credential = home.rootURL.appending(path: "auth.json")
            let credentialBytes = Data("opaque-fake-auth-\(seed.name)".utf8)
            XCTAssertTrue(FileManager.default.createFile(
                atPath: credential.path,
                contents: credentialBytes,
                attributes: [.posixPermissions: 0o600]
            ))
            let fixedCredentialDate = Date(timeIntervalSince1970: 1_700_000_000)
            try FileManager.default.setAttributes(
                [.modificationDate: fixedCredentialDate],
                ofItemAtPath: credential.path
            )
            let credentialIdentity = try fileIdentity(of: credential)
            let credentialModificationDate = try modificationDate(of: credential)

            let bundled = home.rootURL.appending(
                path: "bundled",
                directoryHint: .isDirectory
            )
            let bundledSkills = bundled.appending(
                path: "skills",
                directoryHint: .isDirectory
            )
            if index > 0 {
                try FileManager.default.createDirectory(
                    at: bundled,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o755]
                )
            }
            if index > 1 {
                try FileManager.default.createDirectory(
                    at: bundledSkills,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o755]
                )
            }

            try home.hardenForIsolatedRuntime()

            let expected = canonicalGrokConfiguration(for: home)
            XCTAssertEqual(try Data(contentsOf: configuration), expected, seed.name)
            XCTAssertEqual(try permissions(of: configuration), 0o600, seed.name)
            if let originalConfigurationIdentity {
                XCTAssertNotEqual(
                    try fileIdentity(of: configuration),
                    originalConfigurationIdentity,
                    "Normalization must atomically replace the seed: \(seed.name)"
                )
            }
            if index == 0 {
                XCTAssertFalse(FileManager.default.fileExists(atPath: bundled.path))
            } else {
                XCTAssertEqual(try permissions(of: bundled), 0o700, seed.name)
            }
            if index == 1 {
                XCTAssertFalse(FileManager.default.fileExists(atPath: bundledSkills.path))
            } else if index > 1 {
                XCTAssertEqual(try permissions(of: bundledSkills), 0o700, seed.name)
            }
            XCTAssertEqual(try Data(contentsOf: credential), credentialBytes, seed.name)
            XCTAssertEqual(try fileIdentity(of: credential), credentialIdentity, seed.name)
            XCTAssertEqual(
                try modificationDate(of: credential),
                credentialModificationDate,
                seed.name
            )

            let canonicalIdentity = try fileIdentity(of: configuration)
            let canonicalModificationDate = try modificationDate(of: configuration)
            try home.hardenForIsolatedRuntime()
            XCTAssertEqual(try Data(contentsOf: configuration), expected, seed.name)
            XCTAssertEqual(try permissions(of: configuration), 0o600, seed.name)
            XCTAssertEqual(try fileIdentity(of: configuration), canonicalIdentity, seed.name)
            XCTAssertEqual(
                try modificationDate(of: configuration),
                canonicalModificationDate,
                seed.name
            )
            XCTAssertEqual(try Data(contentsOf: credential), credentialBytes, seed.name)
            XCTAssertEqual(try fileIdentity(of: credential), credentialIdentity, seed.name)
            XCTAssertEqual(
                try modificationDate(of: credential),
                credentialModificationDate,
                seed.name
            )
        }
    }

    func testGrokCLIHomeHardeningRejectsUnsafeBundledScaffoldingWithoutMutation() throws {
        for kind in ["bundled-file", "bundled-symlink", "skills-file", "skills-symlink"] {
            let userHome = try makePrivateTemporaryDirectory(
                label: "grok-home-canonical-\(kind)"
            )
            defer { try? FileManager.default.removeItem(at: userHome) }
            let home = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
            let configuration = home.rootURL.appending(path: "config.toml")
            let canonical = canonicalGrokConfiguration(for: home)
            XCTAssertTrue(FileManager.default.createFile(
                atPath: configuration.path,
                contents: canonical,
                attributes: [.posixPermissions: 0o600]
            ))
            let configurationIdentity = try fileIdentity(of: configuration)
            let configurationModificationDate = try modificationDate(of: configuration)

            let bundled = home.rootURL.appending(
                path: "bundled",
                directoryHint: .isDirectory
            )
            let bundledSkills = bundled.appending(
                path: "skills",
                directoryHint: .isDirectory
            )
            let source = userHome.appending(
                path: "external-bundled-source",
                directoryHint: .isDirectory
            )
            let sourceMarker = source.appending(path: "preserve")
            if kind.hasPrefix("skills-") {
                try FileManager.default.createDirectory(
                    at: bundled,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let obstacle = kind.hasPrefix("bundled-") ? bundled : bundledSkills
            if kind.hasSuffix("-file") {
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: obstacle.path,
                    contents: Data("not-a-directory".utf8),
                    attributes: [.posixPermissions: 0o600]
                ))
            } else {
                try FileManager.default.createDirectory(
                    at: source,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: sourceMarker.path,
                    contents: Data("preserve-source".utf8),
                    attributes: [.posixPermissions: 0o600]
                ))
                try FileManager.default.createSymbolicLink(
                    at: obstacle,
                    withDestinationURL: source
                )
            }

            XCTAssertThrowsError(
                try home.hardenForIsolatedRuntime(),
                "Expected unsafe bundled scaffold rejection: \(kind)"
            )
            XCTAssertEqual(try Data(contentsOf: configuration), canonical, kind)
            XCTAssertEqual(try fileIdentity(of: configuration), configurationIdentity, kind)
            XCTAssertEqual(
                try modificationDate(of: configuration),
                configurationModificationDate,
                kind
            )
            if kind.hasSuffix("-symlink") {
                XCTAssertEqual(
                    try Data(contentsOf: sourceMarker),
                    Data("preserve-source".utf8),
                    kind
                )
            }
        }
    }

    func testGrokCLIHomeHardeningRejectsNoncanonicalConfigurationWithoutMutation() throws {
        let official = pinnedGrok100OfficialConfiguration()
        let officialText = String(decoding: official, as: UTF8.self)
        let unsafeConfigurations: [(name: String, bytes: Data)] = [
            (
                "wrong-purge-marker",
                Data(officialText.replacingOccurrences(
                    of: "default_skills_installs_purged = true",
                    with: "default_skills_installs_purged = false"
                ).utf8)
            ),
            (
                "wrong-auto-install-marker",
                Data(officialText.replacingOccurrences(
                    of: "official_marketplace_auto_installed = true",
                    with: "official_marketplace_auto_installed = false"
                ).utf8)
            ),
            (
                "wrong-official-name",
                Data(officialText.replacingOccurrences(
                    of: "name = \"xAI Official\"",
                    with: "name = \"Untrusted\""
                ).utf8)
            ),
            (
                "wrong-official-url",
                Data(officialText.replacingOccurrences(
                    of: "https://github.com/xai-org/plugin-marketplace.git",
                    with: "https://example.invalid/plugin-marketplace.git"
                ).utf8)
            ),
            (
                "extra-toml",
                official + Data("\n[unsafe]\nenabled = true\n".utf8)
            ),
            (
                "preexisting-noncanonical-skills",
                official + Data("\n[skills]\ndisabled = [\"build-with-ai\"]\n".utf8)
            )
        ]

        for unsafe in unsafeConfigurations {
            let userHome = try makePrivateTemporaryDirectory(
                label: "grok-home-config-\(unsafe.name)"
            )
            defer { try? FileManager.default.removeItem(at: userHome) }
            let home = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
            let configuration = home.rootURL.appending(path: "config.toml")
            XCTAssertTrue(FileManager.default.createFile(
                atPath: configuration.path,
                contents: unsafe.bytes,
                attributes: [.posixPermissions: 0o600]
            ))
            let fixedModificationDate = Date(timeIntervalSince1970: 1_700_000_100)
            try FileManager.default.setAttributes(
                [.modificationDate: fixedModificationDate],
                ofItemAtPath: configuration.path
            )
            let identity = try fileIdentity(of: configuration)
            let originalModificationDate = try modificationDate(of: configuration)

            XCTAssertThrowsError(
                try home.hardenForIsolatedRuntime(),
                "Expected noncanonical configuration rejection: \(unsafe.name)"
            )
            XCTAssertEqual(try Data(contentsOf: configuration), unsafe.bytes, unsafe.name)
            XCTAssertEqual(try fileIdentity(of: configuration), identity, unsafe.name)
            XCTAssertEqual(
                try modificationDate(of: configuration),
                originalModificationDate,
                unsafe.name
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    at: home.rootURL,
                    includingPropertiesForKeys: nil
                ).map(\.lastPathComponent).sorted(),
                ["config.toml"],
                unsafe.name
            )
        }
    }

    func testGrokCLIHomeRejectsUnsafeHookScaffoldLinksAndContent() throws {
        for kind in [
            "registry-content", "registry-symlink", "registry-hardlink",
            "registry-directory", "hooks-symlink", "hooks-file"
        ] {
            let userHome = try makePrivateTemporaryDirectory(label: "grok-hook-\(kind)")
            defer { try? FileManager.default.removeItem(at: userHome) }
            let prepared = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
            let hooks = prepared.rootURL.appending(path: "hooks", directoryHint: .isDirectory)
            let registry = prepared.rootURL.appending(path: "hooks-paths")
            let source = userHome.appending(path: "source")

            switch kind {
            case "registry-content":
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: registry.path,
                    contents: Data("not-empty".utf8),
                    attributes: [.posixPermissions: 0o600]
                ))
            case "registry-symlink":
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: source.path,
                    contents: Data()
                ))
                try FileManager.default.createSymbolicLink(
                    at: registry,
                    withDestinationURL: source
                )
            case "registry-hardlink":
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: source.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o600]
                ))
                try FileManager.default.linkItem(at: source, to: registry)
            case "registry-directory":
                try FileManager.default.createDirectory(
                    at: registry,
                    withIntermediateDirectories: false
                )
            case "hooks-symlink":
                try FileManager.default.createDirectory(
                    at: source,
                    withIntermediateDirectories: false
                )
                try FileManager.default.createSymbolicLink(
                    at: hooks,
                    withDestinationURL: source
                )
            case "hooks-file":
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: hooks.path,
                    contents: Data()
                ))
            default:
                XCTFail("Unexpected fixture")
            }

            XCTAssertThrowsError(
                try GrokCLIHome.prepare(userHomeDirectoryURL: userHome),
                "Expected unsafe hook scaffold rejection: \(kind)"
            )
        }
    }

    func testGrokRuntimeCreatesExactPrivateAgentProfileOnlyForACP() async throws {
        let root = try makePrivateTemporaryDirectory(label: "grok-agent-profile")
        defer { try? FileManager.default.removeItem(at: root) }
        let userHome = root.appending(path: "user-home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: userHome,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let grokHome = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        let runtime = try OAuthCLIProcessSecurity.makeConfiguration(
            provider: .grok,
            executableURL: executable,
            homeDirectoryURL: userHome,
            grokHomeDirectoryURL: grokHome.rootURL,
            temporaryRootURL: root.appending(path: "runtime", directoryHint: .isDirectory)
        )

        let expectedProfile = exactGrokAgentProfile()
        let modelIndex = try XCTUnwrap(runtime.arguments.firstIndex(of: "--model"))
        let reasoningIndex = try XCTUnwrap(
            runtime.arguments.firstIndex(of: "--reasoning-effort")
        )
        let profileIndex = try XCTUnwrap(runtime.arguments.firstIndex(of: "--agent-profile"))
        XCTAssertEqual(runtime.arguments[modelIndex + 1], "grok-4.5")
        XCTAssertEqual(runtime.arguments[reasoningIndex + 1], "high")
        XCTAssertEqual(modelIndex + 2, reasoningIndex)
        XCTAssertEqual(reasoningIndex + 2, profileIndex)
        XCTAssertEqual(profileIndex + 1, runtime.arguments.count - 2)
        let profileURL = URL(fileURLWithPath: runtime.arguments[profileIndex + 1])
        XCTAssertEqual(profileURL.deletingLastPathComponent(), runtime.currentDirectoryURL)
        XCTAssertEqual(profileURL.lastPathComponent, "xunjian-connection-verifier.md")
        XCTAssertEqual(try Data(contentsOf: profileURL), expectedProfile)
        XCTAssertEqual(
            Array(runtime.arguments.suffix(9)),
            [
                "agent", "--no-leader", "--model", "grok-4.5",
                "--reasoning-effort", "high",
                "--agent-profile", profileURL.path, "stdio"
            ]
        )
        XCTAssertEqual(
            runtime.arguments,
            [
                "--no-auto-update", "--permission-mode", "dontAsk", "--deny", "*",
                "--disallowed-tools",
                [
                    "run_terminal_command", "read_file", "search_replace", "list_dir", "grep",
                    "kill_command_or_subagent", "todo_write",
                    "get_command_or_subagent_output", "spawn_subagent",
                    "scheduler_create", "scheduler_delete", "scheduler_list", "monitor",
                    "search_tool", "use_tool", "workflow", "enter_plan_mode",
                    "exit_plan_mode", "ask_user_question", "image_gen", "image_edit",
                    "image_to_video", "reference_to_video", "write", "Agent"
                ].joined(separator: ","),
                "--disable-web-search", "--no-memory", "--no-subagents",
                "--sandbox", "strict", "--cwd", runtime.currentDirectoryURL.path,
                "agent", "--no-leader", "--model", "grok-4.5",
                "--reasoning-effort", "high",
                "--agent-profile", profileURL.path, "stdio"
            ]
        )

        var profileInformation = stat()
        XCTAssertEqual(Darwin.lstat(profileURL.path, &profileInformation), 0)
        XCTAssertEqual(profileInformation.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(profileInformation.st_mode & 0o777, 0o600)
        XCTAssertEqual(profileInformation.st_uid, Darwin.getuid())
        XCTAssertEqual(profileInformation.st_nlink, 1)
        XCTAssertEqual(profileInformation.st_size, off_t(expectedProfile.count))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: runtime.currentDirectoryURL,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent),
            ["xunjian-connection-verifier.md"]
        )

        let inspectionHome = root.appending(path: "inspection-home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: inspectionHome,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let nonACPConfigurations = [
            try OAuthCLIProcessSecurity.makeGrokLoginConfiguration(
                executableURL: executable,
                grokHomeDirectoryURL: grokHome.rootURL,
                temporaryRootURL: root.appending(path: "login", directoryHint: .isDirectory)
            ),
            try OAuthCLIProcessSecurity.makeGrokInspectionConfiguration(
                executableURL: executable,
                grokHomeDirectoryURL: grokHome.rootURL,
                processHomeDirectoryURL: inspectionHome,
                temporaryRootURL: root.appending(path: "inspect", directoryHint: .isDirectory)
            ),
            try OAuthCLIProcessSecurity.makeGrokSessionDeletionConfiguration(
                executableURL: executable,
                grokHomeDirectoryURL: grokHome.rootURL,
                sessionID: "550e8400-e29b-41d4-a716-446655440000",
                temporaryRootURL: root.appending(path: "delete", directoryHint: .isDirectory)
            ),
            try OAuthCLIProcessSecurity.makeGrokLogoutConfiguration(
                executableURL: executable,
                grokHomeDirectoryURL: grokHome.rootURL,
                temporaryRootURL: root.appending(path: "logout", directoryHint: .isDirectory)
            )
        ]
        for configuration in nonACPConfigurations {
            XCTAssertFalse(configuration.arguments.contains("--agent-profile"))
            XCTAssertFalse(configuration.arguments.contains("--no-leader"))
            XCTAssertFalse(configuration.arguments.contains("--model"))
            XCTAssertFalse(configuration.arguments.contains("--reasoning-effort"))
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(
                    at: configuration.currentDirectoryURL,
                    includingPropertiesForKeys: nil
                ).isEmpty
            )
        }

        let ownedRuntimeDirectories = [
            runtime.currentDirectoryURL,
            URL(fileURLWithPath: try XCTUnwrap(runtime.environment["HOME"])),
            URL(fileURLWithPath: try XCTUnwrap(runtime.environment["TMPDIR"]))
        ]
        let process = try SupervisedLineProcess(configuration: runtime)
        await process.close()
        for directory in ownedRuntimeDirectories {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testGrokAgentProfileTamperingFailsBeforeSpawnAndCleansOwnedDirectories() async throws {
        for kind in ["content", "mode", "symlink", "hardlink"] {
            let root = try makePrivateTemporaryDirectory(label: "grok-profile-tamper-\(kind)")
            defer { try? FileManager.default.removeItem(at: root) }
            let userHome = root.appending(path: "user-home", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: userHome,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let grokHome = try GrokCLIHome.prepare(userHomeDirectoryURL: userHome)
            let spawnMarker = root.appending(path: "spawned")
            let executable = root.appending(path: "fake-grok")
            XCTAssertTrue(FileManager.default.createFile(
                atPath: executable.path,
                contents: Data("#!/bin/sh\n/usr/bin/touch \"\(spawnMarker.path)\"\n".utf8),
                attributes: [.posixPermissions: 0o700]
            ))
            let configuration = try OAuthCLIProcessSecurity.makeConfiguration(
                provider: .grok,
                executableURL: executable,
                homeDirectoryURL: userHome,
                grokHomeDirectoryURL: grokHome.rootURL,
                temporaryRootURL: root.appending(path: "runtime", directoryHint: .isDirectory)
            )
            let profileIndex = try XCTUnwrap(
                configuration.arguments.firstIndex(of: "--agent-profile")
            )
            let profileURL = URL(fileURLWithPath: configuration.arguments[profileIndex + 1])
            let source = root.appending(path: "profile-source")

            switch kind {
            case "content":
                try Data("tampered-profile".utf8).write(to: profileURL)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: profileURL.path
                )
            case "mode":
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: profileURL.path
                )
            case "symlink":
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: source.path,
                    contents: exactGrokAgentProfile(),
                    attributes: [.posixPermissions: 0o600]
                ))
                try FileManager.default.removeItem(at: profileURL)
                try FileManager.default.createSymbolicLink(
                    at: profileURL,
                    withDestinationURL: source
                )
            case "hardlink":
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: source.path,
                    contents: exactGrokAgentProfile(),
                    attributes: [.posixPermissions: 0o600]
                ))
                try FileManager.default.removeItem(at: profileURL)
                try FileManager.default.linkItem(at: source, to: profileURL)
            default:
                XCTFail("Unexpected tamper fixture")
            }

            let ownedDirectories = [
                configuration.currentDirectoryURL,
                URL(fileURLWithPath: try XCTUnwrap(configuration.environment["HOME"])),
                URL(fileURLWithPath: try XCTUnwrap(configuration.environment["TMPDIR"]))
            ]
            let process = try SupervisedLineProcess(configuration: configuration)
            do {
                try await process.start()
                XCTFail("Expected profile tamper rejection: \(kind)")
            } catch let error as SupervisedLineProcessError {
                XCTAssertEqual(error, .invalidConfiguration, kind)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: spawnMarker.path), kind)
            await process.close()
            for directory in ownedDirectories {
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), kind)
            }
        }
    }

    func testProcessDrainsStderrAndReassemblesStdout() async throws {
        for mode in ["stderr-flood", "fragmented"] {
            try await withProcess(mode: mode) { process in
                let request = try JSONEncoder().encode(
                    JSONValue.object(["id": .integer(1), "method": .string("echo")])
                )
                try await process.writeLine(request)
                let rawResponse = try await process.readLine()
                let response = try XCTUnwrap(rawResponse)
                let value = try JSONDecoder().decode(JSONValue.self, from: response)
                XCTAssertEqual(value.objectValue?["result"]?.objectValue?["ok"], .bool(true))
            }
        }
    }

    func testProcessReportsNonzeroExitWithoutStderr() async throws {
        try await withProcess(mode: "crash") { process in
            do {
                _ = try await process.readLine()
                XCTFail("Expected process failure")
            } catch let error as SupervisedLineProcessError {
                XCTAssertEqual(error, .processExited(17))
                XCTAssertFalse(String(describing: error).contains("stderr"))
            }
        }
    }

    func testProcessEscalatesFromTermToKill() async throws {
        try await withProcess(
            mode: "ignore-term",
            terminationGraceNanoseconds: 50_000_000
        ) { process in
            let identifier = await process.processIdentifier
            XCTAssertNotNil(identifier)
            await process.close()
            if let identifier {
                XCTAssertEqual(kill(identifier, 0), -1)
                XCTAssertEqual(errno, ESRCH)
            }
        }
    }

    func testProcessCloseInterruptsBlockedInputWrite() async throws {
        try await withProcess(
            mode: "ignore-term",
            terminationGraceNanoseconds: 50_000_000
        ) { process in
            let identifier = await process.processIdentifier
            let write = Task {
                try await process.writeLine(Data(repeating: 65, count: 1_048_576))
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            await process.close()
            do {
                try await write.value
                XCTFail("Expected blocked write to be interrupted")
            } catch let error as SupervisedLineProcessError {
                XCTAssertEqual(error, .writeFailed)
            }
            if let identifier {
                XCTAssertEqual(kill(identifier, 0), -1)
                XCTAssertEqual(errno, ESRCH)
            }
        }
    }

    func testProcessKillsEscapedChildrenAndDoubleFork() async throws {
        for mode in [
            "leader-exits-child-holds-pipes",
            "leader-exits-double-fork"
        ] {
            try await withProcess(
                mode: mode,
                terminationGraceNanoseconds: 50_000_000
            ) { process in
                let childPID = try await escapedChildPID(from: process)
                await process.close()
                try await assertProcessExited(childPID, context: mode)
            }
        }
    }

    func testConcurrentCloseWaitsForEscapedChildCleanup() async throws {
        try await withProcess(
            mode: "leader-exits-double-fork",
            terminationGraceNanoseconds: 100_000_000
        ) { process in
            let childPID = try await escapedChildPID(from: process)
            let firstClose = Task { await process.close() }
            try await Task.sleep(nanoseconds: 5_000_000)
            await process.close()

            XCTAssertEqual(kill(childPID, 0), -1)
            XCTAssertEqual(errno, ESRCH)
            await firstClose.value
        }
    }

    func testBundledCodexRuntimeResolverSelectsAndValidatesBothArchitectures() throws {
        let temporaryRoot = try makePrivateTemporaryDirectory(
            label: "bundled-codex-runtime"
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let runtimeRoot = temporaryRoot.appending(
            path: "CodexAppServer",
            directoryHint: .isDirectory
        )
        let arm64Data = Data("signed-arm64-runtime".utf8)
        let x86Data = Data("signed-x86-runtime".utf8)
        let arm64URL = try writeBundledCodexFixture(
            arm64Data,
            architecture: .arm64,
            runtimeRootURL: runtimeRoot
        )
        let x86URL = try writeBundledCodexFixture(
            x86Data,
            architecture: .x86_64,
            runtimeRootURL: runtimeRoot
        )
        let resolver = BundledCodexRuntimeResolver(
            runtimeRootURL: runtimeRoot,
            signatureValidator: TestManagedRuntimeSignatureValidator(isValid: true),
            expectedArm64SHA256: ManagedRuntimeDigest.sha256Hex(data: arm64Data),
            expectedX86_64SHA256: ManagedRuntimeDigest.sha256Hex(data: x86Data)
        )

        XCTAssertEqual(try resolver.executableURL(for: .arm64), arm64URL)
        XCTAssertEqual(try resolver.executableURL(for: .x86_64), x86URL)
    }

    func testManagedRuntimeDigestInvalidatesWhenContentsChangeButMTimeIsRestored() throws {
        let temporaryRoot = try makePrivateTemporaryDirectory(label: "runtime-digest-cache")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let executableURL = temporaryRoot.appending(path: "runtime")
        let original = Data("AAAA".utf8)
        let replacement = Data("BBBB".utf8)
        try original.write(to: executableURL)
        let originalDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: executableURL.path)[.modificationDate]
                as? Date
        )
        let originalDigest = try ManagedRuntimeDigest.sha256Hex(fileURL: executableURL)

        usleep(20_000)
        let descriptor = open(executableURL.path, O_WRONLY | O_TRUNC | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(replacement.withUnsafeBytes {
            Darwin.write(descriptor, $0.baseAddress, $0.count)
        }, replacement.count)
        XCTAssertEqual(Darwin.close(descriptor), 0)
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate],
            ofItemAtPath: executableURL.path
        )

        let replacementDigest = try ManagedRuntimeDigest.sha256Hex(fileURL: executableURL)
        XCTAssertNotEqual(replacementDigest, originalDigest)
        XCTAssertEqual(replacementDigest, ManagedRuntimeDigest.sha256Hex(data: replacement))
    }

    func testBundledCodexRuntimeResolverRejectsTamperingAndLinks() throws {
        for kind in ["digest", "symlink", "writable"] {
            let temporaryRoot = try makePrivateTemporaryDirectory(
                label: "bundled-codex-runtime-\(kind)"
            )
            defer { try? FileManager.default.removeItem(at: temporaryRoot) }
            let runtimeRoot = temporaryRoot.appending(
                path: "CodexAppServer",
                directoryHint: .isDirectory
            )
            let expectedData = Data("expected-runtime".utf8)
            let executableURL = try writeBundledCodexFixture(
                expectedData,
                architecture: .arm64,
                runtimeRootURL: runtimeRoot
            )
            switch kind {
            case "digest":
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: executableURL.path
                )
                try Data("tampered-runtime".utf8).write(to: executableURL)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o555],
                    ofItemAtPath: executableURL.path
                )
            case "symlink":
                let externalURL = temporaryRoot.appending(path: "external-runtime")
                try expectedData.write(to: externalURL)
                try FileManager.default.removeItem(at: executableURL)
                try FileManager.default.createSymbolicLink(
                    at: executableURL,
                    withDestinationURL: externalURL
                )
            case "writable":
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o577],
                    ofItemAtPath: executableURL.path
                )
            default:
                XCTFail("Unexpected fixture kind")
            }
            let resolver = BundledCodexRuntimeResolver(
                runtimeRootURL: runtimeRoot,
                signatureValidator: TestManagedRuntimeSignatureValidator(isValid: true),
                expectedArm64SHA256: ManagedRuntimeDigest.sha256Hex(data: expectedData),
                expectedX86_64SHA256: String(repeating: "0", count: 64)
            )

            XCTAssertThrowsError(try resolver.executableURL(for: .arm64)) { error in
                XCTAssertEqual(error as? BundledCodexRuntimeError, .unsafeResource)
            }
        }
    }

    func testBundledCodexRuntimeResolverRejectsInvalidVendorSignature() throws {
        let temporaryRoot = try makePrivateTemporaryDirectory(
            label: "bundled-codex-signature"
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let runtimeRoot = temporaryRoot.appending(
            path: "CodexAppServer",
            directoryHint: .isDirectory
        )
        let executableData = Data("unsigned-runtime".utf8)
        _ = try writeBundledCodexFixture(
            executableData,
            architecture: .arm64,
            runtimeRootURL: runtimeRoot
        )
        let resolver = BundledCodexRuntimeResolver(
            runtimeRootURL: runtimeRoot,
            signatureValidator: TestManagedRuntimeSignatureValidator(isValid: false),
            expectedArm64SHA256: ManagedRuntimeDigest.sha256Hex(data: executableData),
            expectedX86_64SHA256: String(repeating: "0", count: 64)
        )

        XCTAssertThrowsError(try resolver.executableURL(for: .arm64)) { error in
            XCTAssertEqual(error as? BundledCodexRuntimeError, .unsafeResource)
        }
    }

    func testBuiltOAuthBridgeContainsBothOfficialCodexRuntimes() throws {
        let productsURL = Bundle(for: OAuthProcessTests.self).bundleURL
            .deletingLastPathComponent()
        let helperURL = productsURL.appending(
            path: "寻简.app/Contents/XPCServices/XunJianOAuthBridge.xpc",
            directoryHint: .isDirectory
        )
        let helperBundle = try XCTUnwrap(Bundle(url: helperURL))
        let resolver = BundledCodexRuntimeResolver(bundle: helperBundle)

        for architecture in [
            ManagedRuntimeArchitecture.arm64,
            ManagedRuntimeArchitecture.x86_64
        ] {
            let executableURL = try resolver.executableURL(for: architecture)
            XCTAssertEqual(
                Array(executableURL.pathComponents.suffix(3)),
                ["CodexAppServer", architecture.rawValue, "codex-app-server"]
            )
        }
    }

    func testBundledGrokRuntimeResolverSelectsAndValidatesBothArchitectures() throws {
        let temporaryRoot = try makePrivateTemporaryDirectory(
            label: "bundled-grok-runtime"
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let runtimeRoot = temporaryRoot.appending(
            path: "GrokRuntime",
            directoryHint: .isDirectory
        )
        let arm64Data = Data("signed-grok-arm64-runtime".utf8)
        let x86Data = Data("signed-grok-x86-runtime".utf8)
        let arm64URL = try writeBundledGrokFixture(
            arm64Data,
            architecture: .arm64,
            runtimeRootURL: runtimeRoot
        )
        let x86URL = try writeBundledGrokFixture(
            x86Data,
            architecture: .x86_64,
            runtimeRootURL: runtimeRoot
        )
        let resolver = BundledGrokRuntimeResolver(
            runtimeRootURL: runtimeRoot,
            signatureValidator: TestManagedRuntimeSignatureValidator(isValid: true),
            expectedArm64SHA256: ManagedRuntimeDigest.sha256Hex(data: arm64Data),
            expectedX86_64SHA256: ManagedRuntimeDigest.sha256Hex(data: x86Data)
        )

        XCTAssertEqual(try resolver.executableURL(for: .arm64), arm64URL)
        XCTAssertEqual(try resolver.executableURL(for: .x86_64), x86URL)
    }

    func testBundledGrokRuntimeResolverRejectsUnsafeResources() throws {
        for kind in ["digest", "symlink", "writable", "signature"] {
            let temporaryRoot = try makePrivateTemporaryDirectory(
                label: "bundled-grok-runtime-\(kind)"
            )
            defer { try? FileManager.default.removeItem(at: temporaryRoot) }
            let runtimeRoot = temporaryRoot.appending(
                path: "GrokRuntime",
                directoryHint: .isDirectory
            )
            let expectedData = Data("expected-grok-runtime".utf8)
            let executableURL = try writeBundledGrokFixture(
                expectedData,
                architecture: .arm64,
                runtimeRootURL: runtimeRoot
            )
            switch kind {
            case "digest":
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: executableURL.path
                )
                try Data("tampered-grok-runtime".utf8).write(to: executableURL)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o555],
                    ofItemAtPath: executableURL.path
                )
            case "symlink":
                let externalURL = temporaryRoot.appending(path: "external-grok")
                try expectedData.write(to: externalURL)
                try FileManager.default.removeItem(at: executableURL)
                try FileManager.default.createSymbolicLink(
                    at: executableURL,
                    withDestinationURL: externalURL
                )
            case "writable":
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o577],
                    ofItemAtPath: executableURL.path
                )
            case "signature":
                break
            default:
                XCTFail("Unexpected fixture kind")
            }
            let resolver = BundledGrokRuntimeResolver(
                runtimeRootURL: runtimeRoot,
                signatureValidator: TestManagedRuntimeSignatureValidator(
                    isValid: kind != "signature"
                ),
                expectedArm64SHA256: ManagedRuntimeDigest.sha256Hex(data: expectedData),
                expectedX86_64SHA256: String(repeating: "0", count: 64)
            )

            XCTAssertThrowsError(try resolver.executableURL(for: .arm64)) { error in
                XCTAssertEqual(error as? BundledGrokRuntimeError, .unsafeResource)
            }
        }
    }

    func testBuiltOAuthBridgeContainsBothOfficialGrokRuntimes() throws {
        let productsURL = Bundle(for: OAuthProcessTests.self).bundleURL
            .deletingLastPathComponent()
        let helperURL = productsURL.appending(
            path: "寻简.app/Contents/XPCServices/XunJianOAuthBridge.xpc",
            directoryHint: .isDirectory
        )
        let helperBundle = try XCTUnwrap(Bundle(url: helperURL))
        let resolver = BundledGrokRuntimeResolver(bundle: helperBundle)

        for architecture in [
            ManagedRuntimeArchitecture.arm64,
            ManagedRuntimeArchitecture.x86_64
        ] {
            let executableURL = try resolver.executableURL(for: architecture)
            XCTAssertEqual(
                Array(executableURL.pathComponents.suffix(3)),
                ["GrokRuntime", architecture.rawValue, "grok"]
            )
        }
    }

    private func writeBundledCodexFixture(
        _ data: Data,
        architecture: ManagedRuntimeArchitecture,
        runtimeRootURL: URL
    ) throws -> URL {
        let architectureURL = runtimeRootURL.appending(
            path: architecture.rawValue,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: architectureURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let executableURL = architectureURL.appending(path: "codex-app-server")
        try data.write(to: executableURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: executableURL.path
        )
        return executableURL.standardizedFileURL
    }

    private func writeBundledGrokFixture(
        _ data: Data,
        architecture: ManagedRuntimeArchitecture,
        runtimeRootURL: URL
    ) throws -> URL {
        let architectureURL = runtimeRootURL.appending(
            path: architecture.rawValue,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: architectureURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let executableURL = architectureURL.appending(path: "grok")
        try data.write(to: executableURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: executableURL.path
        )
        return executableURL.standardizedFileURL
    }

    private func withProcess(
        mode: String,
        terminationGraceNanoseconds: UInt64 = 200_000_000,
        operation: (SupervisedLineProcess) async throws -> Void
    ) async throws {
        let process = try SupervisedLineProcess(
            configuration: try fakeProcessConfiguration(
                mode: mode,
                terminationGraceNanoseconds: terminationGraceNanoseconds
            )
        )
        do {
            try await process.start()
            try await operation(process)
            await process.close()
        } catch {
            await process.close()
            throw error
        }
    }

    private func escapedChildPID(from process: SupervisedLineProcess) async throws -> pid_t {
        let receivedLine = try await process.readLine()
        let line = try XCTUnwrap(receivedLine)
        let value = try JSONDecoder().decode(JSONValue.self, from: line)
        let identifier = try XCTUnwrap(value.objectValue?["childPID"]?.integerValue)
        try await Task.sleep(nanoseconds: 30_000_000)
        return pid_t(identifier)
    }

    private func assertProcessExited(_ identifier: pid_t, context: String) async throws {
        for _ in 0..<50 {
            if kill(identifier, 0) == -1, errno == ESRCH { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Escaped child remained for mode: \(context)")
    }

    private func fakeProcessConfiguration(
        mode: String,
        terminationGraceNanoseconds: UInt64
    ) throws -> SupervisedLineProcessConfiguration {
        let productsDirectory = Bundle(for: OAuthProcessTests.self).bundleURL
            .deletingLastPathComponent()
        let executableURL = productsDirectory
            .appending(path: "XunJianFakeJSONLServer.app/Contents/MacOS/XunJianFakeJSONLServer")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executableURL.path))
        return SupervisedLineProcessConfiguration(
            executableURL: executableURL,
            arguments: ["--mode", mode],
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            environment: [
                "PATH": "/usr/bin:/bin",
                "LANG": "C.UTF-8",
                "TMPDIR": FileManager.default.temporaryDirectory
                    .appending(path: "xunjian-oauth-tmp-\(UUID().uuidString)")
                    .path
            ],
            maximumLineBytes: 1_048_576,
            terminationGraceNanoseconds: terminationGraceNanoseconds
        )
    }

    private func makePrivateTemporaryDirectory(label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "xunjian-\(label)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    private func pinnedGrok100OfficialConfiguration() -> Data {
        Data((
            "[marketplace]\n"
                + "default_skills_installs_purged = true\n"
                + "official_marketplace_auto_installed = true\n"
                + "\n"
                + "[[marketplace.sources]]\n"
                + "name = \"xAI Official\"\n"
                + "git = \"https://github.com/xai-org/plugin-marketplace.git\"\n"
        ).utf8)
    }

    private func exactGrokAgentProfile() -> Data {
        Data(
            (
                "---\n"
                    + "name: xunjian-connection-verifier\n"
                    + "description: Connection verification with no executable tools.\n"
                    + "permissionMode: dontAsk\n"
                    + "tools:\n"
                    + "  - read_file\n"
                    + "disallowedTools:\n"
                    + "  - read_file\n"
                    + "  - search_tool\n"
                    + "  - use_tool\n"
                    + "discoverSkills: false\n"
                    + "inheritSkills: false\n"
                    + "injectDefaultTools: false\n"
                    + "---\n"
                    + "Connection verification only.\n"
            ).utf8
        )
    }

    private func canonicalGrokConfiguration(for home: GrokCLIHome) -> Data {
        let bundledSkillsPath = home.rootURL
            .appending(path: "bundled/skills", directoryHint: .isDirectory)
            .standardizedFileURL
            .path
        return pinnedGrok100OfficialConfiguration() + Data((
            "\n[skills]\n"
                + "ignore = [\n"
                + "  \"\(bundledSkillsPath)\",\n"
                + "]\n"
        ).utf8)
    }

    private func fileIdentity(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(
            (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private func modificationDate(of url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }
}

private struct TestManagedRuntimeSignatureValidator: ManagedRuntimeSignatureValidating {
    let isValid: Bool

    func isValid(
        executableURL: URL,
        signingIdentifier: String,
        teamIdentifier: String
    ) -> Bool {
        isValid
    }
}
