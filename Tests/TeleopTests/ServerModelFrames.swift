import TeleopCore
import TeleopServerModel

extension ServerModelConfig {
    /// This model with the frame numbers of the robot profile's frames: where the base sits in the world, which world
    /// axis each base axis lies along, and the link's signs. Tests build the in-app server from the profile they run
    /// the app with, so the two cannot describe different mountings.
    func settingFrames(from frames: Frames) throws -> ServerModelConfig {
        try settingFrames(
            baseInWorld: frames.baseInWorld, x: frames.worldTurn.x.vector, y: frames.worldTurn.y.vector,
            z: frames.worldTurn.z.vector, linkSigns: frames.linkSigns)
    }
}
