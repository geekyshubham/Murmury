// Converts a head OBJ (from scripts/assets/fbx2obj.py) into Resources/Models/head.scn for HeadRig:
// smooth normals, centred on the skull, scaled to the rig (head ≈ 2.1 tall), and anchor nodes
// "earLeft", "earRight", "noseTip". Usage: swift scripts/assets/make-head.swift <in.obj> <out.scn>
import Foundation
import ModelIO
import SceneKit
import SceneKit.ModelIO

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let asset = MDLAsset(url: input)
var meshes: [MDLMesh] = []
for i in 0..<asset.count {
    asset.object(at: i).enumerateChildObjects(of: MDLMesh.self, root: asset.object(at: i), using: { o, _ in meshes.append(o as! MDLMesh) }, stopPointer: UnsafeMutablePointer<ObjCBool>.allocate(capacity: 1))
    if let m = asset.object(at: i) as? MDLMesh { meshes.append(m) }
}
var points: [SIMD3<Float>] = []
let root = SCNNode()
for (i, m) in meshes.enumerated() {
    m.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.75)
    let node = SCNNode(mdlObject: m)
    node.name = i == 0 ? "skin" : "eye\(i)"
    root.addChildNode(node)
    if let attr = m.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) {
        for k in 0..<m.vertexCount {
            let p = attr.dataStart.advanced(by: k * attr.stride).assumingMemoryBound(to: Float.self)
            points.append(SIMD3(p[0], p[1], p[2]))
        }
    }
}
// The skull: the top 45% of the bust's height.
let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
let headPts = points.filter { $0.y > minY + (maxY - minY) * 0.55 }
let cx = headPts.map(\.x).reduce(0, +) / Float(headPts.count)
let nose = headPts.max { $0.z < $1.z }!
let earBand = headPts.filter { abs($0.y - (nose.y + (maxY - nose.y) * 0.15)) < (maxY - minY) * 0.06 }
let earL = earBand.min { $0.x < $1.x }!, earR = earBand.max { $0.x < $1.x }!
let headTop = maxY, chin = nose.y - (maxY - nose.y) * 0.75
let centre = SIMD3<Float>(cx, (headTop + chin) / 2, (earL.z + earR.z) / 2)
let scale = 2.1 / (headTop - chin)
let pivot = SCNNode()
pivot.addChildNode(root)
root.position = SCNVector3(-centre.x * scale, -centre.y * scale, -centre.z * scale)
root.scale = SCNVector3(scale, scale, scale)
func anchor(_ name: String, _ p: SIMD3<Float>) {
    let n = SCNNode(); n.name = name
    n.position = SCNVector3((p.x - centre.x) * scale, (p.y - centre.y) * scale, (p.z - centre.z) * scale)
    pivot.addChildNode(n)
}
anchor("earLeft", earL); anchor("earRight", earR); anchor("noseTip", nose)
let scene = SCNScene()
pivot.name = "head"
scene.rootNode.addChildNode(pivot)
print(String(format: "meshes %d, vertices %d, scale %.4f, ears ±%.2f, nose z %.2f", meshes.count, points.count, scale,
             (earR.x - earL.x) * scale / 2, (nose.z - centre.z) * scale))
guard scene.write(to: output, options: nil, delegate: nil, progressHandler: nil) else { fatalError("write failed") }
