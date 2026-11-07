import AppKit
import SceneKit
@testable import MurmuryKit

/// Geometry/material inspection only: never instantiates a renderer or a SceneKit view.
@MainActor func inspectScenes(to directory: URL) throws {
    var entries: [[String: Any]] = []
    let asset = URL(fileURLWithPath: "Resources/Models/head.scn")
    let head = try SCNScene(url: asset)
    let rig = HeadRig(assetURL: asset)
    var input = HeadRig.Inputs(); input.reduceMotion = true; input.idle = false
    rig.apply(input, time: 0)
    let projectedBottom = HeroFraming.projectedBottom(rig: rig, aspect: 1 / PageLayout.visualAspect)
    for (name, root) in [("head", head.rootNode), ("buds", BudsGeometry.make(side: 1)),
                          ("case", BudsGeometry.chargingCase(hue: .buds)), ("model", ModelRig().root)] {
        var geometries = 0, materials = 0, normals = 0, invalidNormals = 0
        func inspect(_ node: SCNNode) {
            guard let geometry = node.geometry else { return }
            geometries += 1; materials += geometry.materials.count
            for source in geometry.sources(for: .normal) {
                normals += source.vectorCount
                invalidNormals += HeroStills.readVectors(source).filter { !$0.x.isFinite || !$0.y.isFinite || !$0.z.isFinite }.count
            }
        }
        inspect(root); root.enumerateChildNodes { node, _ in inspect(node) }
        let (lo, hi) = root.boundingBox
        let bounds = [lo.x, lo.y, lo.z, hi.x, hi.y, hi.z].map(Double.init)
        guard bounds.allSatisfy(\.isFinite), invalidNormals == 0 else { throw CocoaError(.coderInvalidValue) }
        entries.append(["name": name, "bounds": bounds, "geometryCount": geometries, "materialCount": materials,
                        "normalCount": normals, "nonFiniteNormals": invalidNormals,
                        "projectedHeadBottom": projectedBottom, "projectedFraming": "CPU camera projection; no SCNRenderer",
                        "rendering": "unavailable offline"])
    }
    try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("scenes.json"))
}
