import Foundation

/// Extension system foundation — the manifest model + permission gating, ported from
/// Recordly's `lib/extensions/types.ts` + `extensionHost.ts` register-gating.
///
/// Scope note: Recordly's web build loads extensions as remote JS modules through a
/// marketplace. A native App Store app **cannot download and execute remote code at
/// runtime** (App Store Review §2.5.2) — the same class of constraint that ruled out the
/// AGPL App Store path — so the dynamic-JS-loading and marketplace layers are deliberately
/// out of scope. What is portable and useful is the manifest schema + permission model a
/// *built-in / curated* contribution system would share; that is what this implements and
/// tests.
enum ExtensionPermission: String, Codable, CaseIterable {
    case render    // hook the frame render pipeline
    case cursor    // cursor telemetry & effects
    case audio     // provide/manipulate audio
    case timeline  // observe timeline lifecycle
    case ui        // settings panels & frames
    case assets    // resolve bundled asset paths
    case export    // hook the export lifecycle
}

struct ExtensionManifest: Codable, Equatable {
    var id: String
    var name: String
    var version: String
    var description: String
    var author: String?
    var homepage: String?
    var license: String?
    var engine: String?
    var icon: String?
    var main: String
    var permissions: [ExtensionPermission]

    enum ValidationError: LocalizedError, Equatable {
        case missingField(String)
        case invalidVersion(String)
        var errorDescription: String? {
            switch self {
            case .missingField(let f): return "Extension manifest is missing required field: \(f)"
            case .invalidVersion(let v): return "Extension version is not valid semver: \(v)"
            }
        }
    }

    /// Requires id/name/main to be non-empty and the version to look like semver.
    func validate() throws {
        if id.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError.missingField("id") }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError.missingField("name") }
        if main.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError.missingField("main") }
        if version.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) == nil {
            throw ValidationError.invalidVersion(version)
        }
    }

    func hasPermission(_ p: ExtensionPermission) -> Bool { permissions.contains(p) }
}

enum ExtensionRegistryError: LocalizedError, Equatable {
    case permissionDenied(ExtensionPermission, action: String)
    var errorDescription: String? {
        switch self {
        case .permissionDenied(let p, let a):
            return "Extension lacks the '\(p.rawValue)' permission required by \(a)"
        }
    }
}

/// Installs validated manifests and gates capability access by declared permission —
/// mirroring the `requirePermission(...)` guard on every `register*` call in Recordly's host.
struct ExtensionRegistry {
    private(set) var installed: [ExtensionManifest] = []

    /// Validates then installs (replacing any existing manifest with the same id).
    mutating func install(_ manifest: ExtensionManifest) throws {
        try manifest.validate()
        installed.removeAll { $0.id == manifest.id }
        installed.append(manifest)
    }

    func manifest(id: String) -> ExtensionManifest? { installed.first { $0.id == id } }

    /// Throws unless the manifest declared the permission the action needs.
    func requirePermission(_ p: ExtensionPermission, of manifest: ExtensionManifest,
                           for action: String) throws {
        guard manifest.hasPermission(p) else {
            throw ExtensionRegistryError.permissionDenied(p, action: action)
        }
    }
}
