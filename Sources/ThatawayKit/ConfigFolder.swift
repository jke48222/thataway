import Foundation

/// Where Thataway keeps the files a person can read and edit: the exclusion
/// list and saved lessons.
///
/// The app was called ScreenCoach until September 2026 and kept these under
/// `~/.config/screencoach`. The first time the folder is asked for, if the new
/// one does not exist yet and the old one does, the old folder is moved into
/// place. Without that, an exclusion rule someone added by hand would be
/// replaced by the defaults with no message, and a privacy control that
/// quietly forgets its rules is worse than none.
public enum ConfigFolder {

    public static let name = "thataway"
    public static let legacyName = "screencoach"

    /// `~/.config/thataway`, after the one-time move from the old name.
    public static var url: URL {
        resolve(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The folder under `home`. Moves the legacy folder into place when only
    /// the legacy one exists; never touches either when the new one is there.
    @discardableResult
    public static func resolve(home: URL, fileManager fm: FileManager = .default) -> URL {
        let config = home.appendingPathComponent(".config", isDirectory: true)
        let current = config.appendingPathComponent(name, isDirectory: true)
        let legacy = config.appendingPathComponent(legacyName, isDirectory: true)
        var legacyIsDirectory: ObjCBool = false
        if !fm.fileExists(atPath: current.path),
           fm.fileExists(atPath: legacy.path, isDirectory: &legacyIsDirectory),
           legacyIsDirectory.boolValue {
            // Two stores can ask at launch; if the other one moved it first,
            // this move fails and the folder is already where it belongs.
            try? fm.moveItem(at: legacy, to: current)
        }
        return current
    }
}
