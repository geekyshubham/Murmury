"""Bounded child probes: unavailable rendering is evidence, never a pass."""
import os
import pathlib
import subprocess
import sys

round_name, binary = sys.argv[1:]
out = pathlib.Path('llm-council/evidence') / (round_name + '-offline')
out.mkdir(parents=True, exist_ok=True)
manifest = ['CPU evidence only; SceneKit surfaces: unavailable offline',
            'Live screenshots: skipped by user instruction (sandbox cannot capture windows)',
            'Icon hero renderer: unavailable offline; CPU fallback explicitly forced, current ICNS unchanged']
env = dict(os.environ, MURMURY_OFFLINE='1')
probes = [('pages', '--render-pages'), ('components', '--render-components'),
          ('aura-sidebar', '--aura-pixel-probe'), ('primary', '--orb-contrast-probe'),
          ('scene-inspection', '--inspect-scenes'), ('icon-cpu-fallback', '--offline-icon-probe'), ('pointer-performance', '--pointer-perf-probe')]
for name, flag in probes:
    destination = out / name
    destination.mkdir(exist_ok=True)
    with (out / (name + '.log')).open('w') as log:
        try:
            result = subprocess.run([binary, flag, str(destination.resolve())], env=env,
                                    stdout=log, stderr=log, timeout=55)
            status = 'produced' if result.returncode == 0 else f'unavailable (exit {result.returncode})'
        except subprocess.TimeoutExpired:
            status = 'unavailable (55 s timeout)'
        manifest.append(f'{name}: {status}; see {name}.log')
icons = out / 'icon-preview.iconset'
result = subprocess.run(['iconutil', '-c', 'iconset', 'Resources/AppIcon.icns', '-o', str(icons)],
                        capture_output=True, text=True)
manifest.append('Existing icon previews: ' + ('decoded' if result.returncode == 0 else 'unavailable: ' + result.stderr))
(out / 'manifest.txt').write_text('\n'.join(manifest) + '\n')
print('\n'.join(manifest))
