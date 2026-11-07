"""Minimal binary-FBX (7.x) mesh reader: Geometry Vertices + PolygonVertexIndex -> OBJ (triangulated)."""
import struct, sys, zlib

def read_props(b, o, n):
    props = []
    for _ in range(n):
        t = chr(b[o]); o += 1
        if t in 'YCIFDL':
            fmt = {'Y': '<h', 'C': '<?', 'I': '<i', 'F': '<f', 'D': '<d', 'L': '<q'}[t]
            sz = struct.calcsize(fmt); props.append(struct.unpack_from(fmt, b, o)[0]); o += sz
        elif t in 'fdlib':
            ln, enc, clen = struct.unpack_from('<III', b, o); o += 12
            raw = b[o:o + clen]; o += clen
            if enc == 1: raw = zlib.decompress(raw)
            fmt = {'f': 'f', 'd': 'd', 'l': 'q', 'i': 'i', 'b': '?'}[t]
            props.append(list(struct.unpack('<%d%s' % (ln, fmt), raw)))
        elif t in 'SR':
            ln = struct.unpack_from('<I', b, o)[0]; o += 4
            props.append(b[o:o + ln]); o += ln
        else:
            raise ValueError('prop type %r' % t)
    return props, o

def read_node(b, o, wide):
    if wide:
        end, nprops, plen = struct.unpack_from('<QQQ', b, o); o += 24
    else:
        end, nprops, plen = struct.unpack_from('<III', b, o); o += 12
    if end == 0: return None, o
    nlen = b[o]; o += 1
    name = b[o:o + nlen].decode('ascii', 'replace'); o += nlen
    props, o = read_props(b, o, nprops)
    kids = []
    null = 25 if wide else 13
    while o < end - null + 1 and o < end:
        if end - o == null and all(x == 0 for x in b[o:end]): o = end; break
        k, o = read_node(b, o, wide)
        if k is None: break
        kids.append(k)
    return (name, props, kids), end

def walk(n, out):
    out.append(n)
    for k in n[2]: walk(k, out)

def main(src, dst):
    b = open(src, 'rb').read()
    assert b[:20] == b'Kaydara FBX Binary  ', 'not a binary FBX'
    ver = struct.unpack_from('<I', b, 23)[0]
    wide = ver >= 7500
    o, nodes = 27, []
    while o < len(b) - 200:
        n, o2 = read_node(b, o, wide)
        if n is None: break
        walk(n, nodes); o = o2
    geoms = [n for n in nodes if n[0] == 'Geometry']
    print('FBX version', ver, 'geometries', len(geoms))
    with open(dst, 'w') as f:
        base = 0
        for g in geoms:
            kid = {k[0]: k for k in g[2]}
            if 'Vertices' not in kid or 'PolygonVertexIndex' not in kid: continue
            v = kid['Vertices'][1][0]; idx = kid['PolygonVertexIndex'][1][0]
            f.write('o part%d\n' % geoms.index(g))
            for i in range(0, len(v), 3): f.write('v %.6f %.6f %.6f\n' % (v[i], v[i + 1], v[i + 2]))
            poly, tris = [], 0
            for x in idx:
                last = x < 0
                poly.append((-x - 1) if last else x)
                if last:
                    for j in range(1, len(poly) - 1):
                        f.write('f %d %d %d\n' % (base + poly[0] + 1, base + poly[j] + 1, base + poly[j + 1] + 1)); tris += 1
                    poly = []
            print('  geometry', g[1][1][:40] if len(g[1]) > 1 else '', 'verts', len(v) // 3, 'tris', tris)
            base += len(v) // 3

main(sys.argv[1], sys.argv[2])
