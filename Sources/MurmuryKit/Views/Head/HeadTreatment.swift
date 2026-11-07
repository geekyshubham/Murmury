import AppKit
import SceneKit
import SwiftUI

/// How the supplied sculpt is finished: a matte, tinted sculpture rather than a glossy mannequin.
/// `.legacy` keeps the round-1 glossy porcelain as a rollback.
enum HeadTreatment {
    enum Style: String, CaseIterable { case ceramic, satin, graphite, legacy }
    enum Eyes: String, CaseIterable {
        /// Sculpted socket: the eye darkened toward violet, matte.
        case sculpted, gem
        case socket
        /// Stylised iris: a dark glossy disc that catches the key light.
        case iris
        /// A calm gaze: a large iris in a deeper tone of the head's own colour, with a satin catchlight.
        case soft
    }
    /// Round 3 ceramic and sculpted eyes; graphite/iris remain launch-option rollbacks.
    nonisolated(unsafe) static var style = Style.ceramic
    /// Round 34: soft irises. Round 18's grey irises (a dark glossy disc on a pale eye) read as a
    /// doll's stare; sculpted blank eyes read as a display mannequin. A large iris in a deeper tone
    /// of the head's own colour gives a calm gaze. `MURMURY_EYES` overrides for evidence.
    nonisolated(unsafe) static var eyes = Eyes(rawValue: ProcessInfo.processInfo.environment["MURMURY_EYES"] ?? "") ?? .soft

    struct Finish: Equatable {
        var albedo: RGB
        var roughness: Double
        var clearCoat = 0.10
        var clearCoatRoughness = 0.40
        var rimStrength: Double
        var rimPower = 2.6
    }
    static func finish(_ style: Style, dark: Bool, hue: Hue = .control) -> Finish {
        // Dark gets a wider, stronger hue rim so the bust glows against the field (lead review, round 2).
        switch style {
        // Round 10: a satin glaze, not a wet coat: broad soft highlights, no hot spots on crown and cheeks.
        // Matte-satin bisque: a light, broad glaze so cheeks shine softly instead of reading wet.
        case .ceramic: Finish(albedo: ceramicAlbedo(hue: hue, dark: dark, height: 1), roughness: dark ? 0.58 : 0.62,
                              clearCoat: 0.12, clearCoatRoughness: 0.42, rimStrength: dark ? 0.38 : 0.2, rimPower: 2.6)
        case .satin, .legacy: Finish(albedo: RGB(dark ? 0xCEC8DE : 0xBEB6D4), roughness: dark ? 0.55 : 0.60, rimStrength: dark ? 0.85 : 0.38, rimPower: dark ? 2.2 : 2.6)
        case .graphite: Finish(albedo: RGB(dark ? 0x8F88A6 : 0xA79FC0), roughness: 0.5, rimStrength: dark ? 0.85 : 0.38, rimPower: dark ? 2.2 : 2.6)
        }
    }
    /// Start at the plan's white mixes, then enforce its authoritative dye/brightness bounds.
    /// Pale cyan/green and light-mode mixes otherwise exceed 0.75 luminance or lose their hue.
    /// Mixes the hue with as much white as `white` allows while keeping at least `saturation`.
    private static func dye(_ hue: RGB, white: Double, saturation: Double = 0.19) -> RGB {
        var low = 0.0, high = white
        for _ in 0..<32 {
            let f = (low + high) / 2
            if hue.mixed(with: RGB(0xFFFFFF), fraction: f).saturation >= saturation + 1e-6 { low = f } else { high = f }
        }
        var result = hue.mixed(with: RGB(0xFFFFFF), fraction: low).limitedLuminance(0.75)
        // Candy-coloured objects sit darker than pastel: a 0.22 floor keeps planes readable and colour alive.
        if result.luminance < 0.22 {
            low = 0; high = 1
            for _ in 0..<32 {
                let f = (low + high) / 2
                if result.mixed(with: RGB(0xFFFFFF), fraction: f).luminance < 0.220001 { low = f } else { high = f }
            }
            result = result.mixed(with: RGB(0xFFFFFF), fraction: high)
        }
        return result
    }
    static func ceramicAlbedo(hue: Hue, dark: Bool, height: Double) -> RGB {
        // Round 4: lighter in dark so the bust glows against the field instead of reading grey.
        // Round 5: a designed object, not a mannequin: visibly hue-coloured ceramic (the old 19%
        // saturation floor always landed on the same pale tint), light hue at the crown deepening to
        // the section's deep hue at the neck, like CleanMyMac's candy-coloured hero objects.
        let top = dye(hue.aRGB, white: dark ? 0.76 : 0.80, saturation: dark ? 0.62 : 0.55)
        let neck = dye(hue.bRGB, white: dark ? 0.58 : 0.64, saturation: dark ? 0.66 : 0.60)
        return neck.mixed(with: top, fraction: height)
    }
    /// Variant A's socket colour and the iris colour.
    static func socket(albedo: RGB, dark: Bool) -> RGB {
        RGB(r: albedo.r * 0.6, g: albedo.g * 0.6, b: albedo.b * 0.6).mixed(with: RGB(dark ? 0x2A1F4D : 0x4A3F6E), fraction: 0.2)
    }
    static let iris = RGB(0x3B3158)
    static let irisFraction = 0.45
    /// The soft eye's iris: its size (sine of its angular radius) and how far it deepens the head's colour.
    nonisolated(unsafe) static var softIrisFraction = Double(ProcessInfo.processInfo.environment["MURMURY_IRIS_SIZE"] ?? "") ?? 0.56
    static let softIrisDepth = RGB(r: 0.5, g: 0.46, b: 0.62)

    /// Skin geometry elements that are separate eyeballs: small elements beside the main face mesh.
    static func eyeElements(in root: SCNNode) -> [Int] {
        guard let geometry = root.childNode(withName: "skin", recursively: true)?.geometry, geometry.elements.count > 1 else { return [] }
        let largest = geometry.elements.map(\.primitiveCount).max() ?? 0
        return geometry.elements.indices.filter { geometry.elements[$0].primitiveCount * 10 < largest }
    }

    /// Measured from the asset: skin bounds and eyeball centres in the skin's own coordinates.
    struct Anatomy: Equatable {
        var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)
        var eyes: [SIMD3<Float>]
        var eyeRadius: Float
        var height: Float { bounds.max.y - bounds.min.y }
        /// The chin, from the nose: a fixed proportion of the head below the nose tip.
        var chinY: Float
        /// Where the lips meet, found on the mesh (see `lipSeam`): its height and how far forward
        /// the face is there. Nil if the profile has no seam.
        var mouthY: Float? = nil
        var mouthZ: Float? = nil
        static func == (a: Anatomy, b: Anatomy) -> Bool {
            a.bounds.min == b.bounds.min && a.bounds.max == b.bounds.max && a.eyes == b.eyes && a.eyeRadius == b.eyeRadius
                && a.chinY == b.chinY && a.mouthY == b.mouthY && a.mouthZ == b.mouthZ
        }
    }
    static func anatomy(of skin: SCNNode, noseTip: SCNNode?) -> Anatomy? {
        guard let geometry = skin.geometry, let source = geometry.sources(for: .vertex).first else { return nil }
        let positions = HeroStills.readVectors(source)
        guard let first = positions.first else { return nil }
        let bounds = positions.reduce((first, first)) { (simd_min($0.0, $1), simd_max($0.1, $1)) }
        var eyes: [SIMD3<Float>] = [], radius: Float = 0
        for index in eyeElements(in: skin.parent ?? skin) where index < geometry.elements.count {
            if let (a, b) = HeroStills.bounds(of: geometry.elements[index], positions: positions) {
                eyes.append((a + b) / 2); radius = max(radius, (b.x - a.x) / 2)
            }
        }
        eyes.sort { $0.x < $1.x }
        let height = bounds.1.y - bounds.0.y
        let noseY = noseTip.map { Float(skin.convertPosition($0.position, from: $0.parent).y) } ?? (bounds.0.y + 0.56 * height)
        let seam = lipSeam(positions, bounds: bounds, noseY: noseY)
        return Anatomy(bounds: bounds, eyes: eyes, eyeRadius: radius, chinY: noseY - 0.15 * height, mouthY: seam?.y, mouthZ: seam?.z)
    }

    // MARK: Shaders (object-space position comes from the geometry stage; nothing is rebuilt from view space)

    /// The jaw: everything below the lip line and in front of the hinge turns down about the
    /// hinge (near the ears) by `jawA.x` radians, fading out toward the cheeks and into the neck so
    /// the skin stretches rather than tears; the lip seam that opens shades as the mouth's dark.
    /// Shading keeps the undeformed position (`objPos`), so tint, eyes and sockets don't swim.
    static let geometryModifier = """
    #pragma arguments
    float4 jawA;
    float4 jawB;
    #pragma varyings
    float3 objPos;
    float mouthGap;
    #pragma body
    out.objPos = _geometry.position.xyz;
    float3 p0 = _geometry.position.xyz;
    out.mouthGap = 0.0;
    float jawAngle = jawA.x;
    if (jawAngle > 0.0005) {
        float mouthY = jawA.y; float hingeY = jawA.z; float hingeZ = jawA.w;
        float chinY = jawB.x; float lipBand = jawB.y; float mouthHalf = jawB.z; float jawHalf = jawB.w;
        float span = mouthY - chinY;
        float lower = 1.0 - smoothstep(mouthY - lipBand, mouthY + lipBand, p0.y);
        float neck = smoothstep(chinY - 0.8 * span, chinY, p0.y);
        float side = 1.0 - smoothstep(0.7 * jawHalf, jawHalf, abs(p0.x));
        float front = smoothstep(hingeZ, hingeZ + 0.6 * span, p0.z);
        float w = lower * neck * side * front;
        float a = jawAngle * w, c = cos(a), s = sin(a);
        float dy = p0.y - hingeY, dz = p0.z - hingeZ;
        _geometry.position.y = hingeY + dy * c - dz * s;
        _geometry.position.z = hingeZ + dy * s + dz * c;
        float3 n = _geometry.normal;
        _geometry.normal = float3(n.x, n.y * c - n.z * s, n.y * s + n.z * c);
        // Where upper and lower lip part: the lips' inner faces (they face each other, not forward)
        // near the seam and across the mouth's width shade as the mouth's dark.
        float seam = 1.0 - smoothstep(2.0 * lipBand, 5.0 * lipBand, abs(p0.y - mouthY));
        float width = 1.0 - smoothstep(0.75 * mouthHalf, mouthHalf, abs(p0.x));
        float inner = 1.0 - smoothstep(0.35, 0.75, n.z);
        out.mouthGap = seam * width * inner * smoothstep(0.0, 0.08, jawAngle);
    }
    """
    /// Neck tint: the bust takes on the section's colour below the chin.
    /// Every argument is a `float4`: SceneKit packs mixed float/float3 arguments differently from
    /// Metal's 16-byte float3 alignment, so values after the first vector were read shifted (the
    /// dye arrived as black under the clear coat, the "grey mannequin"). Uniform float4s line up.
    static let surfaceModifier = """
    #pragma arguments
    float4 headA;
    float4 headB;
    float4 headC;
    float4 tintColor;
    float4 eyeL;
    float4 eyeR;
    float4 irisColor;
    float4 ceramicTop;
    float4 ceramicNeck;
    #pragma body
    float chinY = headA.x;
    float headH = headA.y;
    float tintAmount = headA.z;
    float eyeRadius = headA.w;
    float irisCos = headB.x;
    float isEye = headB.y;
    float debugEyes = headB.z;
    float ceramic = headB.w;
    float ceramicEye = headC.x;
    float bottomY = headC.y;
    float gradientHeight = headC.z;
    float gemEye = headC.w;
    float neck = 1.0 - smoothstep(chinY - 0.30 * headH, chinY, in.objPos.y);
    _surface.diffuse.rgb = mix(_surface.diffuse.rgb, tintColor.rgb, tintAmount * neck * (1.0 - isEye));
    if (ceramic > 0.5) {
        float dyeHeight = clamp((in.objPos.y - bottomY) / max(0.001, gradientHeight), 0.0, 1.0);
        _surface.diffuse.rgb = mix(ceramicNeck.rgb, ceramicTop.rgb, dyeHeight) * (1.0 - 0.34 * ceramicEye);
    }
    // The open mouth's dark, where the lips part (see the geometry modifier's jaw).
    _surface.diffuse.rgb = mix(_surface.diffuse.rgb, _surface.diffuse.rgb * 0.10, in.mouthGap);
    _surface.roughness = mix(_surface.roughness, 1.0, in.mouthGap);
    if (isEye < 0.5 && eyeRadius > 0.0) {
        // A soft fill in each socket, as a reflector under the brow would give: the crease between
        // lid and cheek reads as a gentle hollow in every pose, not a dark cut around the eye.
        float de = min(distance(in.objPos, eyeL.xyz), distance(in.objPos, eyeR.xyz)) / eyeRadius;
        float socket = 1.0 - smoothstep(1.0, 2.2, de);
        _surface.emission.rgb += _surface.diffuse.rgb * (0.28 * socket);
    }
    if (isEye > 0.5) {
        float3 eyeCentre = in.objPos.x > 0.0 ? eyeR.xyz : eyeL.xyz;
        float3 eyeDir = normalize(in.objPos - eyeCentre);
        float iris = smoothstep(irisCos - 0.05, irisCos + 0.03, eyeDir.z);  // a soft iris edge, sculpted not printed
        _surface.diffuse.rgb = mix(_surface.diffuse.rgb, irisColor.rgb, iris);
        float pupil = smoothstep(0.98, 0.995, eyeDir.z) * gemEye;
        _surface.diffuse.rgb = mix(_surface.diffuse.rgb, float3(0.070588, 0.039216, 0.133333), pupil);
        _surface.roughness = mix(_surface.roughness, 0.5, iris);  // a calm satin gaze, not a wet glint
        // The upper lid's shadow and a soft falloff toward the lids: eyes set into the head, not a
        // bright ball under a hard rim (what made the gaze read as a stare).
        float lidShade = mix(0.9, 1.0, smoothstep(0.45, 0.9, eyeDir.z)) * mix(1.0, 0.92, smoothstep(0.05, 0.55, eyeDir.y));
        _surface.diffuse.rgb *= lidShade;
        if (debugEyes > 0.5) { _surface.diffuse.rgb = float3(1.0, 0.0, 1.0); }
    }
    """
    /// Hue rim (lower to upper: hue.b to hue.a), fading out on the neck, then a soft highlight knee.
    static let fragmentModifier = """
    #pragma arguments
    float4 rimA;
    float4 rimLow;
    float4 rimHigh;
    float4 shadowTint;
    #pragma body
    // Surface and fragment bodies share one scope: these names must not repeat the surface's.
    float rimStrength = rimA.x;
    float rimPower = rimA.y;
    float topY = rimA.z;
    float shadowLift = rimA.w;
    float rimNeck = 1.0 - smoothstep(chinY - 0.30 * headH, chinY, in.objPos.y);
    float rimHeight = clamp((in.objPos.y - (chinY - 0.30 * headH)) / max(0.001, topY - (chinY - 0.30 * headH)), 0.0, 1.0);
    float rimFacing = max(dot(normalize(_surface.normal), normalize(_surface.view)), 0.0);
    float rimAmount = pow(1.0 - rimFacing, rimPower);
    // No rim or shadow lift inside the open mouth: its inner faces graze the view and would glow.
    float openDark = 1.0 - in.mouthGap;
    float3 lit = _output.color.rgb + mix(rimLow.rgb, rimHigh.rgb, rimHeight) * rimAmount * rimStrength * (1.0 - rimNeck) * openDark;
    float shadowWeight = 1.0 - smoothstep(0.05, 0.60, dot(lit, float3(0.2126, 0.7152, 0.0722)));
    lit += shadowTint.rgb * shadowLift * shadowWeight * openDark;
    lit *= 1.0 - 0.75 * in.mouthGap;
    // Highlight knee on luminance, scaling the colour as a whole: a per-channel knee flattened a
    // brightly lit hue into neutral grey (the old "grey mannequin").
    float litLuma = dot(lit, float3(0.2126, 0.7152, 0.0722));
    float kneeLuma = litLuma > 0.86 ? 0.86 + (litLuma - 0.86) * 0.35 : litLuma;
    _output.color.rgb = lit * (litLuma > 0.0001 ? kneeLuma / litLuma : 1.0);
    """

    /// A shader `float3` argument as Metal lays it out: three 32-bit floats padded to 16 bytes.
    /// `NSValue(scnVector3:)` carries 64-bit CGFloats on macOS and arrived as zeros, which silently
    /// disabled the dye, rim colours, eye positions and shadow tint.
    static func float3(_ v: SIMD3<Float>) -> NSData {
        var values: [Float] = [v.x, v.y, v.z, 0]
        return NSData(bytes: &values, length: MemoryLayout<Float>.size * 4)
    }

    /// Where the lips meet: on the face's front profile near the midline, the upper lip is the
    /// most forward point below the nose, and the seam is the dip just below it (before the lower
    /// lip comes forward again). Proportions alone missed it by a lip's height.
    static func lipSeam(_ positions: [SIMD3<Float>], bounds: (SIMD3<Float>, SIMD3<Float>), noseY: Float) -> (y: Float, z: Float)? {
        let h = bounds.1.y - bounds.0.y, midline = 0.012 * (bounds.1.x - bounds.0.x)
        let top = noseY - 0.04 * h, bottom = noseY - 0.2 * h, bins = 90
        var front = [Float](repeating: -.infinity, count: bins)
        for p in positions where abs(p.x) < midline && p.y < top && p.y > bottom {
            let b = min(bins - 1, Int((top - p.y) / (top - bottom) * Float(bins)))
            front[b] = max(front[b], p.z)
        }
        func y(_ b: Int) -> Float { top - (Float(b) + 0.5) / Float(bins) * (top - bottom) }
        // The upper lip: the most forward bin in the band just below the nose.
        let upperBand = (0..<bins).filter { y($0) > noseY - 0.12 * h && front[$0].isFinite }
        guard let upper = upperBand.max(by: { front[$0] < front[$1] }) else { return nil }
        // Walk down to the seam: the lowest front point before the lower lip rises by a millimetre's worth.
        var seam = upper, rise = 0.004 * h
        for b in (upper + 1)..<bins where front[b].isFinite {
            if front[b] < front[seam] { seam = b } else if front[b] > front[seam] + rise { break }
        }
        return seam == upper ? nil : (y(seam), front[seam])
    }

    /// The mouth's dark interior: a small, flat, matte shape just behind the lips. Closed lips hide
    /// it; as the jaw opens it is what shows between them (the sculpt's lips are split through to
    /// the inside of the head, which would otherwise show pale). Narrow and shallow, so it never
    /// reaches the cheeks or chin.
    static func mouthInterior(anatomy a: Anatomy) -> SCNNode? {
        guard let y = a.mouthY, let z = a.mouthZ else { return nil }
        let h = a.height
        let spacing = a.eyes.count == 2 ? abs(a.eyes[1].x - a.eyes[0].x) : 0.3 * (a.bounds.max.x - a.bounds.min.x)
        let sphere = SCNSphere(radius: 1); sphere.segmentCount = 48
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor(srgbRed: 0.10, green: 0.04, blue: 0.10, alpha: 1)
        sphere.materials = [m]
        let node = SCNNode(geometry: sphere); node.name = "mouthInterior"
        // Behind the upper lip (which never moves) and deep enough that the chin, which swings a
        // little back as the jaw opens, always stays in front of it.
        node.scale = SCNVector3(0.34 * spacing, 0.03 * h, 0.026 * h)
        node.position = SCNVector3(0, y, z - 0.052 * h)
        return node
    }

    /// The jaw's shader arguments for an opening of `angle` radians: the lip line where the mesh's
    /// lips meet (falling back to 42% of the way from the nose to the chin), the hinge near the
    /// ears at the nose's height, and the jaw spans most of the head's width.
    static func jaw(anatomy a: Anatomy, angle: Float) -> (a: SIMD4<Float>, b: SIMD4<Float>) {
        let h = a.height, noseY = a.chinY + 0.15 * h
        let mouthY = a.mouthY ?? noseY + (a.chinY - noseY) * 0.42
        let hingeY = noseY + 0.02 * h, hingeZ = a.bounds.min.z + 0.42 * (a.bounds.max.z - a.bounds.min.z)
        let halfWidth = (a.bounds.max.x - a.bounds.min.x) / 2
        let spacing = a.eyes.count == 2 ? abs(a.eyes[1].x - a.eyes[0].x) : 0.6 * 2 * halfWidth
        // The jaw moves whole down to its underside (13% of the head below the lips), then fades into the neck.
        return (SIMD4(angle, mouthY, hingeY, hingeZ), SIMD4(mouthY - 0.13 * h, 0.006 * h, 0.42 * spacing, 0.85 * halfWidth))
    }
    /// How far the jaw turns at a full opening (radians): about 8 degrees, a wide spoken vowel.
    static let jawRange: Float = 0.14

    /// The head shader's arguments, bound as `float4` packs (see `surfaceModifier`).
    struct Uniforms: Equatable {
        var chinY: Float, headH: Float, tintAmount: Float, eyeRadius: Float = 0
        var irisCos: Float, isEye: Float, debugEyes: Float, ceramic: Float
        var ceramicEye: Float, bottomY: Float, gradientHeight: Float, gemEye: Float
        var tint: SIMD3<Float>, eyeL: SIMD3<Float>, eyeR: SIMD3<Float>, iris: SIMD3<Float>
        var ceramicTop: SIMD3<Float>, ceramicNeck: SIMD3<Float>
        var rimStrength: Float, rimPower: Float, topY: Float, shadowLift: Float
        var rimLow: SIMD3<Float>, rimHigh: SIMD3<Float>, shadowTint: SIMD3<Float>
        /// The jaw (see `geometryModifier`): angle, lip line, hinge y and z; chin, lip band, mouth and jaw half-widths.
        var jawA: SIMD4<Float> = .zero, jawB: SIMD4<Float> = .zero

        var packs: [String: SIMD4<Float>] {
            func v(_ x: SIMD3<Float>) -> SIMD4<Float> { SIMD4(x, 1) }
            return ["headA": SIMD4(chinY, headH, tintAmount, eyeRadius), "headB": SIMD4(irisCos, isEye, debugEyes, ceramic),
                    "headC": SIMD4(ceramicEye, bottomY, gradientHeight, gemEye), "tintColor": v(tint), "eyeL": v(eyeL),
                    "eyeR": v(eyeR), "irisColor": v(iris), "ceramicTop": v(ceramicTop), "ceramicNeck": v(ceramicNeck),
                    "rimA": SIMD4(rimStrength, rimPower, topY, shadowLift), "rimLow": v(rimLow), "rimHigh": v(rimHigh),
                    "shadowTint": v(shadowTint), "jawA": jawA, "jawB": jawB]
        }
        func bind(to m: SCNMaterial) { for (key, value) in packs { m.setValue(HeadTreatment.float4(value), forKey: key) } }
    }
    /// A shader `float4` argument as four 32-bit floats.
    static func float4(_ v: SIMD4<Float>) -> NSData {
        var values: [Float] = [v.x, v.y, v.z, v.w]
        return NSData(bytes: &values, length: MemoryLayout<Float>.size * 4)
    }
    /// Reads a bound `float4` argument back (for tests and inspection).
    static func pack(_ m: SCNMaterial, _ key: String) -> SIMD4<Float>? {
        guard let data = m.value(forKey: key) as? NSData, data.length == 16 else { return nil }
        var values = [Float](repeating: 0, count: 4)
        data.getBytes(&values, length: 16)
        return SIMD4(values[0], values[1], values[2], values[3])
    }

    /// Skin and eye materials for one appearance and hue.
    static func materials(style: Style, eyes: Eyes, scheme: ColorScheme, hue: Hue, anatomy: Anatomy?, debugEyes: Bool) -> (skin: SCNMaterial, eye: SCNMaterial) {
        if style == .legacy {
            let m = StudioMaterials.porcelain(scheme, hue: hue)
            return (m, m)
        }
        let dark = scheme == .dark
        let f = finish(style, dark: dark, hue: hue)
        let a = anatomy
        // The shader works in linear light; tokens are sRGB.
        func linear(_ c: RGB) -> SIMD3<Float> {
            func decode(_ v: Double) -> Float { Float(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)) }
            return SIMD3(decode(c.r), decode(c.g), decode(c.b))
        }
        let defaults = Uniforms(
            chinY: Float(a?.chinY ?? -1e6), headH: Float(a?.height ?? 1), tintAmount: 0.55, eyeRadius: a?.eyeRadius ?? 0,
            irisCos: Float((1 - irisFraction * irisFraction).squareRoot()), isEye: 0, debugEyes: debugEyes ? 1 : 0,
            ceramic: style == .ceramic ? 1 : 0, ceramicEye: 0, bottomY: Float(a?.bounds.min.y ?? -1),
            gradientHeight: Float(a?.height ?? 2), gemEye: 0,
            tint: linear(f.albedo.mixed(with: hue.bRGB, fraction: 0.5)), eyeL: a?.eyes.first ?? .zero, eyeR: a?.eyes.last ?? .zero,
            iris: linear(iris), ceramicTop: linear(ceramicAlbedo(hue: hue, dark: dark, height: 1)),
            ceramicNeck: linear(ceramicAlbedo(hue: hue, dark: dark, height: 0)),
            rimStrength: Float(f.rimStrength), rimPower: Float(f.rimPower), topY: Float(a?.bounds.max.y ?? 1),
            shadowLift: style == .ceramic ? (dark ? 0.22 : 0.16) : 0,
            rimLow: linear(hue.bRGB), rimHigh: linear(hue.aRGB), shadowTint: linear(hue.bRGB.mixed(with: RGB(0), fraction: 0.20)),
            jawA: a.map { Self.jaw(anatomy: $0, angle: 0).a } ?? .zero, jawB: a.map { Self.jaw(anatomy: $0, angle: 0).b } ?? .zero)
        func base(_ albedo: RGB, roughness: Double, _ edit: (inout Uniforms) -> Void = { _ in }) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = albedo.nsColor
            m.roughness.contents = roughness
            m.metalness.contents = 0
            m.clearCoat.contents = f.clearCoat
            m.clearCoatRoughness.contents = f.clearCoatRoughness
            m.shaderModifiers = [.geometry: geometryModifier, .surface: surfaceModifier, .fragment: fragmentModifier]
            var uniforms = defaults
            edit(&uniforms)
            uniforms.bind(to: m)
            return m
        }
        let skin = base(f.albedo, roughness: f.roughness)
        let eye: SCNMaterial
        switch eyes {
        case .sculpted:
            let color = RGB(r: f.albedo.r * 0.88, g: f.albedo.g * 0.88, b: f.albedo.b * 0.88)
            eye = base(color, roughness: 0.14) { $0.ceramicEye = 1; $0.isEye = debugEyes ? 1 : 0; $0.irisCos = 2 }
            eye.clearCoat.contents = 1.0; eye.clearCoatRoughness.contents = 0.04
        case .gem:
            eye = base(f.albedo, roughness: 0.25) {
                $0.isEye = 1; $0.gemEye = 1; $0.irisCos = Float(sqrt(1 - 0.62 * 0.62))
                $0.iris = linear(RGB(r: hue.aRGB.r * 0.45, g: hue.aRGB.g * 0.45, b: hue.aRGB.b * 0.45))
            }
            eye.clearCoat.contents = 1
        case .socket:
            // The socket is one tone; only the debug overlay uses the eye branch.
            eye = base(socket(albedo: f.albedo, dark: dark), roughness: 0.85) { $0.isEye = debugEyes ? 1 : 0; $0.irisCos = 2 }
        case .iris:
            eye = base(f.albedo.mixed(with: RGB(0xFFFFFF), fraction: 0.15), roughness: 0.45) { $0.isEye = 1 }
        case .soft:
            // The grey iris and the ring of pale eye around it read as a fixed doll's stare. A large
            // iris that meets the lids, in a deeper tone of the head's own colour, reads as a gaze.
            let deep = ceramicAlbedo(hue: hue, dark: dark, height: 0.5)
            let tone = RGB(r: deep.r * softIrisDepth.r, g: deep.g * softIrisDepth.g, b: deep.b * softIrisDepth.b)
            eye = base(f.albedo, roughness: 0.62) {
                $0.isEye = 1; $0.irisCos = Float((1 - softIrisFraction * softIrisFraction).squareRoot()); $0.iris = linear(tone)
            }
            // A soft satin catchlight, not a glassy one: the gloss is what made the lids look hard-edged.
            // Satin like the skin, so the eyes read as part of one sculpture rather than glossy balls.
            eye.clearCoat.contents = 0.06; eye.clearCoatRoughness.contents = 0.5
        }
        return (skin, eye)
    }
}
