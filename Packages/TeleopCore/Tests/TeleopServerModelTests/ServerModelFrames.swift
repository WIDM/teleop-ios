import TeleopCore
import TeleopServerModel

extension ServerModelConfig {
    /// This model with the frame numbers of `frames`: the base's place in the world, which world axis each base axis
    /// lies along, and the link's signs.
    func settingFrames(from frames: Frames) throws -> ServerModelConfig {
        try settingFrames(
            baseInWorld: frames.baseInWorld, x: frames.worldTurn.x.vector, y: frames.worldTurn.y.vector,
            z: frames.worldTurn.z.vector, linkSigns: frames.linkSigns)
    }

    /// The same simulator, scene and arm, as a server whose base has `frames` instead of `source`'s: the places and
    /// offsets given in the base frame (where the arm starts, the tool offset) are the same physical ones, written in
    /// the other base. The scene (table, cube, goal) is in the world frame and does not change.
    func framed(by frames: Frames, from source: Frames) throws -> ServerModelConfig {
        guard frames != source else { return try settingFrames(from: frames) }
        var config = try settingFrames(from: frames)
        config.armStart = frames.base(fromWorld: source.world(fromBase: armStart))
        config.toolOffset = frames.base(fromWorldDirection: source.worldDirection(fromBase: toolOffset))
        return config
    }
}
