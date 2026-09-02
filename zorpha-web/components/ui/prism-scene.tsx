'use client';

import * as React from 'react';
import * as THREE from 'three';
import { Canvas, useFrame, useThree } from '@react-three/fiber';
import { MeshTransmissionMaterial, Environment, Lightformer } from '@react-three/drei';

/**
 * The WebGL half of PrismHero: a faceted crystal that sits BEHIND the wordmark
 * and throws light through it.
 *
 * Loaded through next/dynamic with ssr:false from prism-hero.tsx. Nothing here
 * renders on the server, so the copy stays in the delivered HTML while the
 * canvas is strictly a client-side enhancement.
 *
 * NOTHING IS FETCHED. The studio rig is built from <Lightformer> children
 * rather than an HDRI, and the geometry is procedural. That is not only a
 * stylistic choice: vercel.json pins `connect-src 'self'`, so an Environment
 * preset or a loaded model would be blocked outright in production.
 */

/* -------------------------------------------------------------------------- */
/*  Refracted echo                                                            */
/* -------------------------------------------------------------------------- */

/**
 * Canvas `ctx.font` does not understand CSS custom properties, so any `var(--x)`
 * in the stack has to be resolved against the document first -- otherwise the
 * assignment is rejected silently and the text falls back to 10px.
 */
function resolveFontStack(stack: string): string {
  if (typeof window === 'undefined') return stack;
  const root = getComputedStyle(document.documentElement);
  return stack.replace(/var\(\s*(--[\w-]+)\s*\)/g, (_m, name: string) => {
    const v = root.getPropertyValue(name).trim();
    return v || 'serif';
  });
}

function drawWord(text: string, color: string, fontFamily: string): THREE.CanvasTexture | null {
  if (typeof document === 'undefined') return null;

  const W = 2048;
  const H = 640;
  const canvas = document.createElement('canvas');
  canvas.width = W;
  canvas.height = H;
  const ctx = canvas.getContext('2d');
  if (!ctx) return null;

  ctx.clearRect(0, 0, W, H);

  // Fit to the canvas width rather than guessing a size.
  const stack = resolveFontStack(fontFamily);
  let size = 460;
  do {
    ctx.font = '500 ' + size + 'px ' + stack;
    size -= 8;
  } while (ctx.measureText(text).width > W * 0.92 && size > 40);

  ctx.fillStyle = color;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(text, W / 2, H / 2);

  const t = new THREE.CanvasTexture(canvas);
  t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = 8;
  t.needsUpdate = true;
  return t;
}

/**
 * Built synchronously so the mesh mounts with its map already attached --
 * attaching a map to an already-mounted material is a well-known three.js trap.
 * Redrawn once webfonts land, otherwise the fallback face is what gets baked in.
 */
function useWordTexture(text: string, color: string, fontFamily: string) {
  const [texture, setTexture] = React.useState(() => drawWord(text, color, fontFamily));

  React.useEffect(() => {
    let cancelled = false;
    const rebake = () => {
      if (!cancelled) setTexture(drawWord(text, color, fontFamily));
    };
    if (document.fonts?.ready) {
      document.fonts.ready.then(rebake).catch(rebake);
    } else {
      rebake();
    }
    return () => {
      cancelled = true;
    };
  }, [text, color, fontFamily]);

  React.useEffect(() => () => texture?.dispose(), [texture]);

  return texture;
}

/**
 * Soft radial glow, built procedurally, sitting furthest back in the stack.
 *
 * WHY THIS IS NOT DECORATION
 *
 * A crystal at transmission 1 and roughness 0.03 is almost purely refractive:
 * it shows what is BEHIND it rather than reflecting the rig in front. Behind it
 * is a near-black page, so across its rotation the stone kept passing through
 * angles where every facet refracted nothing and it disappeared from the hero
 * entirely -- verified by sampling three frames four seconds apart, one of
 * which was effectively blank.
 *
 * Giving it a lit field to refract fixes the cause rather than the symptom, and
 * it does so on brand: the core is the violet accent, so the dispersion splits
 * brand colour through the letterforms instead of splitting grey.
 */
function makeGlow(color: string): THREE.CanvasTexture | null {
  if (typeof document === 'undefined') return null;

  const S = 512;
  const canvas = document.createElement('canvas');
  canvas.width = S;
  canvas.height = S;
  const ctx = canvas.getContext('2d');
  if (!ctx) return null;

  // Via THREE.Color so any CSS colour form the caller passes works, not just
  // the 6-digit hex that string concatenation would silently require.
  const c = new THREE.Color(color);
  const rgb = [c.r, c.g, c.b].map((v) => Math.round(v * 255)).join(',');

  // Falls to nothing well inside the plane's edge, so this reads as a halo
  // around the stone rather than a violet wash over the whole band -- at a
  // wider falloff it lit the description too and cost that text its crispness.
  const g = ctx.createRadialGradient(S / 2, S / 2, 0, S / 2, S / 2, S / 2);
  g.addColorStop(0, `rgba(${rgb},0.85)`);
  g.addColorStop(0.24, `rgba(${rgb},0.4)`);
  g.addColorStop(0.55, `rgba(${rgb},0.1)`);
  g.addColorStop(1, `rgba(${rgb},0)`);
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, S, S);

  const t = new THREE.CanvasTexture(canvas);
  t.colorSpace = THREE.SRGBColorSpace;
  t.needsUpdate = true;
  return t;
}

function Backlight({ color, z, size }: { color: string; z: number; size: number }) {
  const texture = React.useMemo(() => makeGlow(color), [color]);
  React.useEffect(() => () => texture?.dispose(), [texture]);
  if (!texture) return null;

  return (
    <mesh position={[0, 0, z]} renderOrder={-2}>
      <planeGeometry args={[size, size]} />
      <meshBasicMaterial
        map={texture}
        transparent
        blending={THREE.AdditiveBlending}
        depthWrite={false}
        toneMapped={false}
      />
    </mesh>
  );
}

/**
 * A dim copy of the wordmark placed BEHIND the crystal, so the stone has
 * something of the brand to refract.
 *
 * This is the optical half of "shine through". The crisp word is DOM text in
 * front of the canvas; this echo is what the prism actually transmits and
 * splits into colour. Without it the stone refracts only the lightformers and
 * reads as a generic glass blob that happens to sit near some type.
 *
 * Kept deliberately faint. At full strength the refraction competes with the
 * real wordmark a few units in front of it and both turn to mush.
 */
function RefractedEcho({
  texture,
  z,
  opacity,
}: {
  texture: THREE.CanvasTexture | null;
  z: number;
  opacity: number;
}) {
  const { viewport } = useThree();
  const width = Math.min(viewport.width * 0.96, 16);
  const height = width * (640 / 2048);

  if (!texture || opacity <= 0) return null;

  return (
    <mesh position={[0, 0, z]} renderOrder={-1}>
      <planeGeometry args={[width, height]} />
      <meshBasicMaterial
        map={texture}
        transparent
        opacity={opacity}
        depthWrite={false}
        toneMapped={false}
      />
    </mesh>
  );
}

/* -------------------------------------------------------------------------- */
/*  Crystal                                                                   */
/* -------------------------------------------------------------------------- */

function Crystal({
  progress,
  reducedMotion,
  dispersion,
  tint,
  spec,
  z,
}: {
  progress: React.RefObject<number>;
  reducedMotion: boolean;
  dispersion: number;
  tint: string;
  spec: QualitySpec;
  z: number;
}) {
  const ref = React.useRef<THREE.Mesh>(null);
  const pointer = React.useRef({ x: 0, y: 0 });
  const { viewport } = useThree();

  // Size against the *smaller* viewport axis so it never dominates a portrait
  // phone the way a fixed world-radius does.
  //
  // The upper clamp is deliberately tight. Sized to fit/4.6 the stone spilled
  // well past the wordmark and put bright white facets directly behind the
  // description, which is unreadable however good it looks in a still. It has
  // to frame the word, not the column.
  const portrait = viewport.width < viewport.height;
  const fit = Math.min(viewport.width, viewport.height);
  const baseScale = THREE.MathUtils.clamp(fit / 5.6, portrait ? 0.32 : 0.46, 0.95);

  React.useEffect(() => {
    if (reducedMotion) return;
    const onMove = (e: PointerEvent) => {
      pointer.current.x = (e.clientX / window.innerWidth - 0.5) * 2;
      pointer.current.y = (e.clientY / window.innerHeight - 0.5) * 2;
    };
    window.addEventListener('pointermove', onMove, { passive: true });
    return () => window.removeEventListener('pointermove', onMove);
  }, [reducedMotion]);

  useFrame((state, delta) => {
    const mesh = ref.current;
    if (!mesh) return;
    const p = progress.current ?? 0;
    const t = state.clock.elapsedTime;

    // Under reduced motion the stone is PARKED, not merely un-spun.
    //
    // Gating rotation.y alone -- which is all the original did -- left x and z
    // still oscillating on sin(t)/cos(t), so a viewer who had asked the OS for
    // less movement got a stone that wobbled on two axes indefinitely. The
    // parked angle is off-axis on purpose: square to the camera an icosahedron
    // presents one flat face and stops reading as cut glass at all.
    if (reducedMotion) {
      mesh.rotation.set(0.34, 0.62, 0.08);
      mesh.position.set(0, 0, z);
      mesh.scale.setScalar(baseScale);
      return;
    }

    // Slow idle rotation, accelerated by scroll. Never linear -- the drift keeps
    // facets catching light at irregular intervals.
    mesh.rotation.y = t * 0.13 + p * Math.PI * 1.1;
    mesh.rotation.x = Math.sin(t * 0.21) * 0.14 + p * 0.4;
    mesh.rotation.z = Math.cos(t * 0.17) * 0.08;

    // Ease toward the pointer rather than tracking it exactly.
    const tx = pointer.current.x * 0.3;
    const ty = -pointer.current.y * 0.24;
    mesh.position.x += (tx - mesh.position.x) * Math.min(1, delta * 2.2);
    mesh.position.y += (ty - mesh.position.y) * Math.min(1, delta * 2.2);

    mesh.scale.setScalar(baseScale * (1 + p * 0.18));
  });

  return (
    <mesh ref={ref} position={[0, 0, z]}>
      {/* 20 flat facets. Slightly elongated so it reads as cut, not a ball. */}
      <icosahedronGeometry args={[1.32, 0]} />
      <MeshTransmissionMaterial
        transmission={1}
        thickness={1.35}
        roughness={0.03}
        ior={1.92}
        chromaticAberration={dispersion}
        anisotropy={0.25}
        distortion={0.18}
        distortionScale={0.35}
        temporalDistortion={0.06}
        backside={spec.backside}
        backsideThickness={0.5}
        samples={spec.samples}
        resolution={spec.resolution}
        color={tint}
        attenuationColor={tint}
        attenuationDistance={8}
      />
    </mesh>
  );
}

/* -------------------------------------------------------------------------- */
/*  Atmosphere                                                                */
/* -------------------------------------------------------------------------- */

/** Deterministic PRNG -- keeps the mote field identical on every mount. */
function mulberry32(seed: number) {
  return function () {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * Slow drifting motes. Gives the frame depth without a texture.
 *
 * Still rendered under reduced motion -- the depth is worth keeping -- but not
 * advanced. A field of ninety independently drifting specks is precisely the
 * kind of ambient movement the preference exists to suppress.
 */
function Motes({
  count,
  color,
  reducedMotion,
}: {
  count: number;
  color: string;
  reducedMotion: boolean;
}) {
  const ref = React.useRef<THREE.Points>(null);

  const { positions, speeds } = React.useMemo(() => {
    const rand = mulberry32(1337);
    const pos = new Float32Array(count * 3);
    const spd = new Float32Array(count);
    for (let i = 0; i < count; i++) {
      pos[i * 3] = (rand() - 0.5) * 18;
      pos[i * 3 + 1] = (rand() - 0.5) * 11;
      pos[i * 3 + 2] = (rand() - 0.5) * 6 - 1;
      spd[i] = 0.02 + rand() * 0.05;
    }
    return { positions: pos, speeds: spd };
  }, [count]);

  useFrame((_, delta) => {
    const pts = ref.current;
    if (!pts || reducedMotion) return;
    const attr = pts.geometry.getAttribute('position') as THREE.BufferAttribute;
    const arr = attr.array as Float32Array;
    for (let i = 0; i < count; i++) {
      arr[i * 3 + 1] += speeds[i] * delta;
      if (arr[i * 3 + 1] > 5.5) arr[i * 3 + 1] = -5.5;
    }
    attr.needsUpdate = true;
  });

  return (
    <points ref={ref} frustumCulled={false}>
      <bufferGeometry>
        <bufferAttribute attach="attributes-position" args={[positions, 3]} />
      </bufferGeometry>
      <pointsMaterial
        size={0.045}
        color={color}
        transparent
        opacity={0.5}
        sizeAttenuation
        depthWrite={false}
      />
    </points>
  );
}

/* -------------------------------------------------------------------------- */
/*  Adaptive quality                                                          */
/* -------------------------------------------------------------------------- */

type Quality = 'low' | 'medium' | 'high';

export interface QualitySpec {
  samples: number;
  resolution: number;
  motes: number;
  backside: boolean;
  maxDpr: number;
}

const QUALITY: Record<Quality, QualitySpec> = {
  // Transmission re-renders the scene into a buffer every frame, so samples and
  // buffer resolution are the two knobs that actually cost money. samples:2 /
  // res:128 left visible colour speckle on the facets; 3/192 is still far
  // cheaper than the desktop tier but reads clean.
  low: { samples: 3, resolution: 192, motes: 30, backside: false, maxDpr: 1.25 },
  medium: { samples: 4, resolution: 256, motes: 55, backside: true, maxDpr: 1.5 },
  high: { samples: 6, resolution: 512, motes: 90, backside: true, maxDpr: 1.75 },
};

/** Stable subscription so the tier re-evaluates if the window is resized. */
function subscribeToViewport(cb: () => void) {
  window.addEventListener('resize', cb);
  return () => window.removeEventListener('resize', cb);
}

function detectQuality(): Quality {
  if (typeof window === 'undefined') return 'medium';
  const cores = navigator.hardwareConcurrency ?? 4;
  const w = window.innerWidth;
  if (w < 768 || cores <= 4) return 'low';
  if (w < 1440 || cores <= 8) return 'medium';
  return 'high';
}

/* -------------------------------------------------------------------------- */
/*  Public canvas                                                             */
/* -------------------------------------------------------------------------- */

export interface PrismSceneProps {
  word: string;
  background: string;
  /** Colour of the refracted echo behind the stone. */
  echoColor: string;
  /** 0 disables the echo entirely. */
  echoOpacity: number;
  displayFont: string;
  moteColor: string;
  tint: string;
  dispersion: number;
  progress: React.RefObject<number>;
  reducedMotion: boolean;
  /** Lifts the stone so it sits behind the wordmark, not the whole band. */
  lift: number;
  /** Paused when the hero scrolls away: transmission is the page's dearest draw. */
  active: boolean;
  sceneChildren?: React.ReactNode;
}

function Scene({
  word,
  echoColor,
  echoOpacity,
  displayFont,
  moteColor,
  tint,
  dispersion,
  progress,
  reducedMotion,
  lift,
  spec,
}: Omit<PrismSceneProps, 'background' | 'active' | 'sceneChildren'> & { spec: QualitySpec }) {
  const texture = useWordTexture(word, echoColor, displayFont);
  const { viewport } = useThree();
  const portrait = viewport.width < viewport.height;

  return (
    <>
      {/* Studio rig from lightformers, tinted to the brand so the dispersion
          throws violet and cyan through the wordmark rather than the warm gold
          of a default studio. */}
      <Environment resolution={256}>
        <Lightformer intensity={5} position={[0, 5, 4]} scale={[12, 4, 1]} color="#fdfbff" />
        <Lightformer intensity={3.4} position={[-6, 1, 3]} scale={[4, 9, 1]} color="#a48dff" />
        <Lightformer intensity={2.8} position={[6, -2, 2]} scale={[5, 6, 1]} color="#5ee9ff" />
        <Lightformer intensity={2.2} position={[2, 4, -2]} scale={[6, 3, 1]} color="#ff7ad9" />
        <Lightformer intensity={1.6} position={[0, -4, -3]} scale={[9, 3, 1]} color="#ffffff" />
      </Environment>

      <group position={[0, lift, portrait ? -0.8 : 0]}>
        {/* Back to front: the lit field, the word's echo over it, then the stone
            that refracts both. The crisp wordmark is DOM, layered over this
            canvas by prism-hero.tsx. */}
        <Backlight color={moteColor} z={-4.4} size={6.8} />
        <RefractedEcho texture={texture} z={-3.4} opacity={echoOpacity} />
        <Crystal
          progress={progress}
          reducedMotion={reducedMotion}
          dispersion={dispersion}
          tint={tint}
          spec={spec}
          z={-1}
        />
      </group>

      <Motes color={moteColor} count={spec.motes} reducedMotion={reducedMotion} />
    </>
  );
}

export default function PrismScene({ background, active, sceneChildren, ...rest }: PrismSceneProps) {
  // useSyncExternalStore rather than an effect: the server snapshot keeps
  // hydration deterministic, there is no cascading re-render on mount, and the
  // tier re-evaluates for free when the window crosses a breakpoint.
  const quality = React.useSyncExternalStore(
    subscribeToViewport,
    detectQuality,
    () => 'medium' as Quality,
  );
  const spec = QUALITY[quality];

  return (
    <Canvas
      frameloop={active ? 'always' : 'never'}
      dpr={[1, spec.maxDpr]}
      gl={{ antialias: true, alpha: false, powerPreference: 'high-performance' }}
      camera={{ fov: 40, near: 0.1, far: 60, position: [0, 0, 7] }}
      onCreated={({ gl }) => gl.setClearColor(new THREE.Color(background), 1)}
    >
      <Scene {...rest} spec={spec} />
      {sceneChildren}
    </Canvas>
  );
}
