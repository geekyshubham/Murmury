import simd

/// Millimetres, in the plan's closed-case orientation: width x, thickness y, depth z.
/// The presentation floats the buds above the opened case; the head uses its own measured scale.
enum BudsSpec {
    static let scale: Float = 0.04
    static let budSize = SIMD3<Float>(18.1, 33.2, 19.8)
    static let caseSize = SIMD3<Float>(58.9, 24.4, 48.7)
    static let housingRadii = SIMD3<Float>(9, 8.4, 9.9)
    static let housingVertical: Float = 0.82, housingHorizontal: Float = 0.70
    static let contactInset: Float = 0.35
    static let housingY: Float = 8.2, collarTop: Float = 2.3, bladeTop: Float = -0.2
    static let collarLength: Float = 2.5, bladeLength: Float = 16.4
    static let topWidth: Float = 7, topDepth: Float = 5.6, bottomWidth: Float = 5.2, bottomDepth: Float = 4
    static let rearBevel: Float = 0.6, edgeFacet: Float = 0.25
    static let nozzleRadius: Float = 3, nozzleLength: Float = 4.5, nozzleForward: Float = 20
    static let bladeLightWidth: Float = 0.9, bladeLightInset: Float = 0.15, bladeCoreWidth: Float = 0.4
    static let bladeLightFraction: Float = 0.82
    static let baseHeight: Float = 16, lidHeight: Float = 8.4, lidWall: Float = 0.8
    static let seamRadius: Float = 0.35, hingeRadius: Float = 1.2, lidDegrees: Float = -100
    static func onHeadScale(chinToCrown: Float) -> Float { chinToCrown / 230 }
}
