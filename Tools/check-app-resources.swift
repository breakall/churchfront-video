import Foundation
import Darwin

/// Check the dependency's first font lookup location in the assembled app.
/// This must succeed without consulting developer source paths outside the app.
func embeddedFont(in bundle: URL) throws -> URL {
    guard let resource = Bundle(url: bundle)?.url(forResource: "Figtree-VariableFont_wght", withExtension: "ttf"),
          resource.resolvingSymlinksInPath().path.hasPrefix(bundle.resolvingSymlinksInPath().path + "/") else {
        throw NSError(domain: "CameraBridgeBundleCheck", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "The assembled app is missing its self-contained CueDesign font resource bundle."])
    }
    return resource
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw NSError(domain: "CameraBridgeBundleCheck", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Usage: swift Tools/check-app-resources.swift APP_PATH BUILT_RESOURCE_BUNDLE"])
    }
    let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let packaged = app.appendingPathComponent("Contents/Resources/CueKit_CueDesign.bundle")
    let source = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    let font = try embeddedFont(in: packaged)
    guard try Data(contentsOf: font) == Data(contentsOf: embeddedFont(in: source)) else {
        throw NSError(domain: "CameraBridgeBundleCheck", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Packaged font differs from the built dependency resource."])
    }
    print("PASS: Font resolves from the app's embedded dependency bundle and matches the built resource.")
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
