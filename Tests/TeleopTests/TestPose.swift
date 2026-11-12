import simd

/// Camera poses as ARKit reports them, for tests that have no ARKit.
enum TestPose {
    /// A phone held upright in portrait, back camera looking along world −z. ARKit's camera +x runs toward the
    /// phone's bottom edge, +y toward its right edge, +z out of the screen.
    static let portrait = simd_float4x4(
        columns: (
            SIMD4(0, -1, 0, 0),
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, 0, 0, 1)
        ))

    /// That phone after turning it `degrees` about a world axis.
    static func portrait(turned degrees: Float, about axis: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: axis)) * portrait
    }

    static func portrait(at position: SIMD3<Float>) -> simd_float4x4 {
        var pose = portrait
        pose.columns.3 = SIMD4(position.x, position.y, position.z, 1)
        return pose
    }
}
