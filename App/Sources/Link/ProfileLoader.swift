import Foundation
import TeleopCore

/// Chooses and reads the robot profile a run drives. Profiles are JSON files bundled with the app
/// (`App/Resources/Profiles`, format in docs/PROFILE.md), named by their id, the file name without `.json`. The build
/// names one in its Info.plist under `TeleopRobotProfile` (set in project.yml); the launch argument
/// `-robotProfile <id>` overrides it. This is the only place that turns an id into a profile.
enum ProfileLoader {
    static let infoKey = "TeleopRobotProfile"
    /// The launch argument's name without its dash, as it arrives in the argument domain.
    static let argumentKey = "robotProfile"

    enum Failure: Error, Equatable, CustomStringConvertible {
        case noneChosen
        case notBundled(id: String)
        case unreadable(id: String, reason: String)

        var description: String {
            switch self {
            case .noneChosen:
                return "No robot profile is chosen: set \(ProfileLoader.infoKey) in project.yml or launch with "
                    + "-\(ProfileLoader.argumentKey) <id>."
            case .notBundled(let id):
                return "The robot profile \(id).json is not in the app. Add it to App/Resources/Profiles."
            case .unreadable(let id, let reason):
                return "The robot profile \(id).json cannot be used: \(reason)"
            }
        }
    }

    /// The profile this run drives, read once. A run without a usable profile cannot move an arm safely, so a missing
    /// or invalid file stops the app with the reason.
    static let current: RobotProfile = {
        do {
            return try chosen()
        } catch {
            fatalError("\(error)")
        }
    }()

    /// The id the launch argument names, else the one the build names.
    static func chosenID(
        arguments: [String: Any] = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain),
        info: [String: Any]? = Bundle.main.infoDictionary
    ) throws -> String {
        if let id = arguments[argumentKey] as? String, !id.isEmpty { return id }
        if let id = info?[infoKey] as? String, !id.isEmpty { return id }
        throw Failure.noneChosen
    }

    static func chosen(
        arguments: [String: Any] = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain),
        bundle: Bundle = .main
    ) throws -> RobotProfile {
        try load(id: chosenID(arguments: arguments, info: bundle.infoDictionary), bundle: bundle)
    }

    /// Reads and checks the bundled profile with this id.
    static func load(id: String, bundle: Bundle = .main) throws -> RobotProfile {
        guard let url = bundle.url(forResource: id, withExtension: "json") else { throw Failure.notBundled(id: id) }
        do {
            return try RobotProfile.load(json: Data(contentsOf: url))
        } catch let error as ProfileFormatError {
            throw Failure.unreadable(id: id, reason: error.description)
        } catch {
            throw Failure.unreadable(id: id, reason: error.localizedDescription)
        }
    }
}
