# Translucent green glass orb for the README.
# Usage: python3 assets/make-orb.py assets/faceorb-orb.svg
import math, sys
out = sys.argv[1]
S, C, R = 320, 160, 90
RAY = "#22a35a"          # reads on GitHub's light and dark themes
SPARK = "#3ccf7a"

def ray_lines():
    rays = []
    for i in range(16):
        a = i / 16 * 2 * math.pi - math.pi / 2
        long_ = i % 2 == 0
        r0a, r1a = R + 12, R + (24 if long_ else 18)
        r0b, r1b = R + (36 if long_ else 30), R + (64 if long_ else 48)
        p = lambda r: (C + r * math.cos(a), C + r * math.sin(a))
        (x0a, y0a), (x1a, y1a), (x0b, y0b), (x1b, y1b) = p(r0a), p(r1a), p(r0b), p(r1b)
        common = 'dur="2.4s" repeatCount="indefinite" keyTimes="0;0.12;0.45;1" calcMode="spline" keySplines="0.2 0.8 0.3 1;0.2 0.8 0.3 1;0 0 1 1"'
        a4 = lambda attr, va, vb: '<animate attributeName="%s" values="%.1f;%.1f;%.1f;%.1f" %s/>' % (attr, va, va, vb, vb, common)
        rays.append('<line stroke="%s" stroke-width="%d" stroke-linecap="round" opacity="0">' % (RAY, 5 if long_ else 3)
                    + a4("x1", x0a, x0b) + a4("y1", y0a, y0b) + a4("x2", x1a, x1b) + a4("y2", y1a, y1b)
                    + '<animate attributeName="opacity" values="0;1;0;0" %s/></line>' % common)
    return "".join(rays)

def star(deg, size, begin, r=124):
    a = math.radians(deg - 90)
    x, y = round(C + r * math.cos(a)), round(C + r * math.sin(a))
    q = size * 0.12
    d = "M0 -{s}C{q} -{q} {q} -{q} {s} 0C{q} {q} {q} {q} 0 {s}C-{q} {q} -{q} {q} -{s} 0C-{q} -{q} -{q} -{q} 0 -{s}Z".format(s=size, q=q)
    return ('<g transform="translate(%d %d)"><path d="%s" fill="%s" transform="scale(0)">'
            '<animateTransform attributeName="transform" type="scale" values="0;1;0;0" keyTimes="0;0.15;0.3;1" dur="3s" begin="%s" repeatCount="indefinite"/>'
            '</path></g>') % (x, y, d, SPARK, begin)

# Soft bands of lighter green inside the glass, turning slowly so the orb reads as spinning.
def bands():
    out = []
    for i, (w, o) in enumerate([(0.55, 0.22), (0.35, 0.16), (0.45, 0.12)]):
        a0 = i * 2 * math.pi / 3
        rx = R * w
        out.append('<ellipse cx="%d" cy="%d" rx="%.1f" ry="%.1f" fill="url(#band)" opacity="%.2f" transform="rotate(%d %d %d)"/>'
                   % (C, C - R * 0.35, rx, R * 0.9, o, math.degrees(a0), C, C))
    return "".join(out)

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}" role="img" aria-label="FaceOrb logo">
  <title>FaceOrb</title>
  <defs>
    <clipPath id="ball"><circle cx="{C}" cy="{C}" r="{R}"/></clipPath>
    <filter id="blur6" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="6"/></filter>
    <filter id="blur3" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="3"/></filter>
    <!-- Glass body: clear in the middle, denser green toward the rim (like real glass seen edge-on). -->
    <radialGradient id="body" cx="50%" cy="50%" r="50%" fx="40%" fy="36%">
      <stop offset="0" stop-color="#b6ffd4" stop-opacity="0.28"/>
      <stop offset="0.55" stop-color="#3fd17f" stop-opacity="0.45"/>
      <stop offset="0.85" stop-color="#139a52" stop-opacity="0.72"/>
      <stop offset="1" stop-color="#0a6b38" stop-opacity="0.92"/>
    </radialGradient>
    <!-- Light passing through and gathering at the far side. -->
    <radialGradient id="caustic" cx="64%" cy="72%" r="38%">
      <stop offset="0" stop-color="#d9ffe9" stop-opacity="0.85"/>
      <stop offset="0.5" stop-color="#7dffb5" stop-opacity="0.35"/>
      <stop offset="1" stop-color="#7dffb5" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="core" cx="50%" cy="50%" r="50%">
      <stop offset="0" stop-color="#eafff3" stop-opacity="0.55"/>
      <stop offset="1" stop-color="#eafff3" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="band" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#c8ffe0" stop-opacity="0"/>
      <stop offset="0.5" stop-color="#c8ffe0" stop-opacity="1"/>
      <stop offset="1" stop-color="#c8ffe0" stop-opacity="0"/>
    </linearGradient>
    <radialGradient id="gloss" cx="38%" cy="26%" r="34%">
      <stop offset="0" stop-color="#fff" stop-opacity="0.9"/>
      <stop offset="0.6" stop-color="#fff" stop-opacity="0.25"/>
      <stop offset="1" stop-color="#fff" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#e8fff1" stop-opacity="0.9"/>
      <stop offset="0.5" stop-color="#2fbf6e" stop-opacity="0.5"/>
      <stop offset="1" stop-color="#bfffd9" stop-opacity="0.95"/>
    </linearGradient>
    <linearGradient id="sweep" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#fff" stop-opacity="0"/>
      <stop offset="0.5" stop-color="#fff" stop-opacity="0.55"/>
      <stop offset="1" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
  </defs>

  <g>{ray_lines()}</g>
  <g>{star(56.25, 16, "0.3s")}{star(213.75, 12, "1.3s")}{star(303.75, 9, "2.1s")}{star(123.75, 10, "0.9s")}</g>

  <!-- Green-tinted shadow and light cast on the ground under the glass. -->
  <ellipse cx="{C}" cy="{C + R + 10}" rx="{R * 0.78:.0f}" ry="9" fill="#0b5d33" opacity="0.28" filter="url(#blur6)"/>
  <ellipse cx="{C + 8}" cy="{C + R + 8}" rx="{R * 0.32:.0f}" ry="4" fill="#5cf29b" opacity="0.45" filter="url(#blur3)"/>

  <circle cx="{C}" cy="{C}" r="{R}" fill="url(#body)"/>
  <g clip-path="url(#ball)">
    <g>{bands()}<animateTransform attributeName="transform" type="rotate" from="0 {C} {C}" to="360 {C} {C}" dur="6s" repeatCount="indefinite"/></g>
    <circle cx="{C}" cy="{C}" r="{R * 0.55:.0f}" fill="url(#core)">
      <animate attributeName="opacity" values="0.6;1;0.6" dur="2.4s" repeatCount="indefinite"/>
    </circle>
    <circle cx="{C}" cy="{C}" r="{R}" fill="url(#caustic)"/>
    <ellipse cx="{C - R * 0.22:.0f}" cy="{C - R * 0.42:.0f}" rx="{R * 0.62:.0f}" ry="{R * 0.42:.0f}" fill="url(#gloss)" transform="rotate(-20 {C} {C})"/>
    <g transform="rotate(-25 {C} {C})"><rect x="{C - 26}" y="{C - 2 * R}" width="52" height="{4 * R}" fill="url(#sweep)">
      <animateTransform attributeName="transform" type="translate" values="{-2 * R} 0;{2 * R} 0;{2 * R} 0" keyTimes="0;0.35;1" dur="3.6s" repeatCount="indefinite"/>
    </rect></g>
  </g>
  <!-- Sharp specular highlight and a thin bright rim. -->
  <ellipse cx="{C - R * 0.38:.0f}" cy="{C - R * 0.5:.0f}" rx="{R * 0.16:.0f}" ry="{R * 0.09:.0f}" fill="#fff" opacity="0.95" transform="rotate(-35 {C - R * 0.38:.0f} {C - R * 0.5:.0f})"/>
  <circle cx="{C - R * 0.12:.0f}" cy="{C - R * 0.62:.0f}" r="3" fill="#fff" opacity="0.8"/>
  <circle cx="{C}" cy="{C}" r="{R - 1}" fill="none" stroke="url(#rim)" stroke-width="2"/>
</svg>
'''
open(out, "w").write(svg)
print(out, len(svg), "bytes")
