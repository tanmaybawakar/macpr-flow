import AppKit
import MetalKit
import QuartzCore

/// The listening orb: a small lit sphere of moving light, drawn on the GPU at the display's refresh rate.
///
/// Signal shaping follows Halo: instant attack and short release on the voice envelope, syllable onsets that
/// kick an underdamped spring, and Apple's damping/response springs for everything that appears or changes mode.
final class OrbView: MTKView {
    private var renderer: OrbRenderer?

    /// Set from the main thread whenever dictation state changes; read by the renderer each frame (also main thread).
    var state = OrbState() {
        didSet { renderer?.state = state; if state.visible { wake() } }
    }

    init(signal: VoiceSignal) {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.isOpaque = false
        isPaused = true
        enableSetNeedsDisplay = false
        if let device, let renderer = try? OrbRenderer(device: device, signal: signal) {
            renderer.onIdle = { [weak self] in self?.isPaused = true }
            self.renderer = renderer
            delegate = renderer
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        preferredFramesPerSecond = window?.screen?.maximumFramesPerSecond ?? 60
    }

    /// Starts drawing. The renderer pauses itself once the orb has fully faded out, so idle costs nothing.
    func wake() {
        guard renderer != nil, isPaused else { return }
        renderer?.resetClock()
        isPaused = false
    }
}

enum OrbStyle: String, CaseIterable, Identifiable, Sendable {
    case ember, orbit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ember: "Ember"
        case .orbit: "Orbit"
        }
    }
}

struct OrbState {
    var visible = false
    var thinking = false
    var reduceMotion = false
    var style = OrbStyle.ember
    /// 0.5 (calm) … 2.5 (very reactive). Scales how far the voice moves the orb.
    var sensitivity: Float = 1.6
    /// Settings preview: drives the orb with a synthetic voice instead of the microphone.
    var preview = false
}

/// Not actor-isolated on purpose: MTKView calls `draw` on the main thread, and skipping Swift's executor check
/// on this hot path avoids the macOS 26 runtime crash seen in the main-actor thunks.
final class OrbRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let orbitPipeline: MTLRenderPipelineState
    private let signal: VoiceSignal
    private static let ringCount = 4, ringSteps = 72
    private var ringPunch = [Float](repeating: 0, count: 4), ringPunchVelocity = [Float](repeating: 0, count: 4)
    private var comet: Float = 0
    var state = OrbState()
    var onIdle: (() -> Void)?

    private var last = CACurrentMediaTime()
    private var time: Float = 0
    private var level: Float = 0, low: Float = 0, mid: Float = 0, high: Float = 0
    private var slow: Float = 0
    private var punch: Float = 0, punchVelocity: Float = 0
    private var presence: Float = 0, presenceVelocity: Float = 0
    private var thinking: Float = 0, thinkingVelocity: Float = 0
    private var flow: Float = 0
    private var cooldown: Float = 0

    init(device: MTLDevice, signal: VoiceSignal) throws {
        guard let queue = device.makeCommandQueue() else { throw FlowError("Metal is unavailable.") }
        let library = try device.makeLibrary(source: orbShader + orbitShader, options: nil)
        func make(_ fragment: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "orbVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.colorAttachments[0].isBlendingEnabled = false
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        pipeline = try make("orbFragment")
        orbitPipeline = try make("orbitFragment")
        self.queue = queue; self.signal = signal
    }

    func resetClock() { last = CACurrentMediaTime() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Offscreen frame for previews and checks: simulates `seconds` of the synthetic voice, then renders.
    static func snapshot(style: OrbStyle, thinking: Bool, seconds: Float, side: Int) -> CGImage? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = try? OrbRenderer(device: device, signal: VoiceSignal()) else { return nil }
        renderer.state = OrbState(visible: true, thinking: thinking, style: style, preview: !thinking)
        var elapsed: Float = 0
        while elapsed < seconds { renderer.step(renderer.state, dt: 1 / 120); elapsed += 1 / 120 }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
        descriptor.usage = [.renderTarget]; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let command = renderer.queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        renderer.encode(encoder, width: side, height: side)
        encoder.endEncoding()
        command.commit(); command.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        texture.getBytes(&bytes, bytesPerRow: side * 4, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.05, max(0.001, now - last)))
        last = now
        let s = state
        step(s, dt: dt)

        if presence < 0.002 && !s.visible {
            presence = 0; presenceVelocity = 0
            clear(view)
            onIdle?()
            return
        }

        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encode(encoder, width: drawable.texture.width, height: drawable.texture.height)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    private func encode(_ encoder: MTLRenderCommandEncoder, width: Int, height: Int) {
        let s = state
        var uniforms: [Float] = [
            Float(width), Float(height), time, max(0, presence),
            level, low, mid, high,
            punch, thinking, flow, s.reduceMotion ? 1 : 0
        ]
        if s.style == .orbit {
            uniforms += [comet, 0, 0, 0]
            var points = orbitRings()
            encoder.setRenderPipelineState(orbitPipeline)
            encoder.setFragmentBytes(&points, length: points.count * MemoryLayout<SIMD4<Float>>.stride, index: 1)
        } else {
            encoder.setRenderPipelineState(pipeline)
        }
        encoder.setFragmentBytes(&uniforms, length: uniforms.count * MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private func clear(_ view: MTKView) {
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    private func step(_ s: OrbState, dt: Float) {
        let input: VoiceSignal.Frame
        if s.preview { input = Self.syntheticVoice(time) }
        else { input = s.visible && !s.thinking ? signal.read() : VoiceSignal.Frame() }
        // Sensitivity lifts quiet speech (a curve, not just a multiplier) so soft voices still move it.
        let gain = max(0.3, s.sensitivity)
        func boost(_ v: Float) -> Float { min(1, pow(max(0, v), 1 / (0.55 + 0.45 * gain)) * (0.55 + 0.45 * gain)) }
        let shaped = VoiceSignal.Frame(level: boost(input.level), low: boost(input.low), mid: boost(input.mid), high: boost(input.high))
        func follow(_ value: inout Float, _ target: Float, attack: Float, release: Float) {
            let tau = target > value ? attack : release
            value += (target - value) * (1 - exp(-dt / tau))
        }
        follow(&level, shaped.level, attack: 0.008, release: 0.14)
        follow(&low, shaped.low, attack: 0.016, release: 0.18)
        follow(&mid, shaped.mid, attack: 0.014, release: 0.15)
        follow(&high, shaped.high, attack: 0.010, release: 0.11)
        follow(&slow, shaped.level, attack: 0.18, release: 0.35)

        // A syllable is a jump above the recent average. It kicks the orb, and the spring rings it back.
        cooldown -= dt
        let threshold = 0.1 / (0.6 + 0.4 * gain)
        if !s.reduceMotion, cooldown <= 0, level - slow > threshold {
            punchVelocity += (4.5 + 1.8 * gain) * min(1, (level - slow) * 3.5 + 0.3)
            cooldown = 0.09
        }
        integrate(&punch, &punchVelocity, target: 0, response: 0.28, damping: 0.5, dt: dt)
        // Appearing carries a touch of overshoot; leaving is critically damped and quick.
        integrate(&presence, &presenceVelocity, target: s.visible ? 1 : 0,
                  response: s.visible ? 0.42 : 0.24, damping: s.visible ? 0.72 : 1, dt: dt)
        integrate(&thinking, &thinkingVelocity, target: s.thinking ? 1 : 0, response: 0.35, damping: 1, dt: dt)
        // Each ring follows the one outside it, so a syllable ripples inward instead of moving everything at once.
        for k in 0..<Self.ringCount {
            let target = k == 0 ? punch : ringPunch[k - 1]
            integrate(&ringPunch[k], &ringPunchVelocity[k], target: target, response: 0.16, damping: 0.75, dt: dt)
        }
        comet += dt * (s.reduceMotion ? 0.04 : 0.16 + 0.7 * level + 0.55 * thinking)

        let motion: Float = s.reduceMotion ? 0.25 : 1
        time += dt * motion
        flow += dt * motion * (0.35 + 2.2 * level + 0.8 * high + 1.6 * thinking)
    }

    /// A believable speaking rhythm for the Settings preview: syllables inside phrases, with pauses between.
    private static func syntheticVoice(_ t: Float) -> VoiceSignal.Frame {
        let phrase = max(0, sin(t * 0.9)) > 0.15 ? Float(1) : 0.15
        let syllable = pow(abs(sin(t * 5.6)), 3) * 0.75 + 0.15 * abs(sin(t * 13.1))
        let level = min(1, phrase * syllable + 0.04)
        return .init(level: level, low: level * 0.9, mid: level * 0.8 * abs(sin(t * 2.3)), high: level * 0.6 * abs(sin(t * 7.7)))
    }

    /// The tube rings, projected to 2D on the CPU so the shader only measures distances.
    ///
    /// The composition is fixed, the way it was drawn: a near-perfect outer circle, two thick soft loops stacked
    /// on the same diagonal, and a thinner band inside them. Motion never breaks that shape. The whole piece
    /// turns slowly as one, the two loops breathe against each other, and a slight tilt gives the glass depth.
    private func orbitRings() -> [SIMD4<Float>] {
        let size = (0.72 + 0.04 * level - 0.03 * thinking) * max(0, presence)
        let turn = flow * 0.16 + 0.785                         // the shared diagonal, turning slowly
        let breathe = sin(time * 0.9) * 0.05 + punch * 0.03
        let tilt = 0.18 * sin(time * 0.45)                     // just enough to read as 3D
        // half-width, half-height, roundness (2 = ellipse), roll offset, centre offset along the diagonal
        let rings: [(Float, Float, Float, Float, Float)] = [
            (1.04, 1.02, 2.0, -turn + 0.4, 0.00),             // outer circle
            (1.04, 0.64, 3.3, breathe - 0.05, -0.08),         // thick loop
            (1.00, 0.62, 3.3, -breathe * 0.8 + 0.07, 0.09),   // its twin, crossing it at the ends
            (0.86, 0.50, 3.0, breathe * 0.5, 0.01)            // thinner inner band
        ]
        var points: [SIMD4<Float>] = []
        points.reserveCapacity(Self.ringCount * (Self.ringSteps + 1))
        for (k, ring) in rings.enumerated() {
            let grow = 1 + ringPunch[k] * (0.045 + 0.02 * Float(k))
            let exponent = 2 / ring.2
            let roll = turn + ring.3
            let (cr, sr) = (cos(roll), sin(roll))
            let (ct, st) = (cos(tilt + Float(k) * 0.05), sin(tilt + Float(k) * 0.05))
            // Offset perpendicular to the long axis, so the twins sit side by side like the drawing.
            let ox = -sin(turn) * ring.4, oy = cos(turn) * ring.4
            for i in 0...Self.ringSteps {
                let a = 2 * Float.pi * Float(i) / Float(Self.ringSteps)
                let c = cos(a), s = sin(a)
                var x = (c < 0 ? -1 : 1) * pow(abs(c), exponent) * ring.0 * size * grow
                var y = (s < 0 ? -1 : 1) * pow(abs(s), exponent) * ring.1 * size * grow
                (x, y) = (x * cr - y * sr, x * sr + y * cr)
                x += ox * size; y += oy * size
                // Tilt around the diagonal axis: the far side recedes and dims.
                let z = y * st
                y *= ct
                let perspective = 1 / (1 + z * 0.3)
                points.append(SIMD4(x * perspective, y * perspective, z, Float(i) / Float(Self.ringSteps)))
            }
        }
        return points
    }

    private func integrate(_ value: inout Float, _ velocity: inout Float, target: Float, response: Float, damping: Float, dt: Float) {
        var remaining = dt
        let stiffness = pow(2 * .pi / response, 2)
        let friction = 4 * .pi * damping / response
        while remaining > 0 {
            let h = min(remaining, 1 / 240)
            velocity += (-stiffness * (value - target) - friction * velocity) * h
            value += velocity * h
            remaining -= h
        }
    }
}

private let orbShader = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 frame;   // width, height, time, presence
    float4 voice;   // level, low, mid, high
    float4 motion;  // punch, thinking, flow, reduce motion
};
struct Out { float4 position [[position]]; float2 uv; };

vertex Out orbVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    Out o; o.position = float4(p * 2.0 - 1.0, 0, 1); o.uv = p; return o;
}

float hash3(float3 p) {
    p = fract(p * 0.3183099 + 0.1); p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}
float noise3(float3 x) {
    float3 i = floor(x), f = fract(x); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(hash3(i), hash3(i + float3(1,0,0)), f.x), mix(hash3(i + float3(0,1,0)), hash3(i + float3(1,1,0)), f.x), f.y),
               mix(mix(hash3(i + float3(0,0,1)), hash3(i + float3(1,0,1)), f.x), mix(hash3(i + float3(0,1,1)), hash3(i + 1.0), f.x), f.y), f.z);
}
float fbm(float3 p) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 3; i++) { s += a * noise3(p); p = p * 2.02 + float3(1.7, 9.2, 3.1); a *= 0.5; }
    return s / 0.875;
    return s;
}
float3 rotY(float3 p, float a) { float c = cos(a), s = sin(a); return float3(c*p.x + s*p.z, p.y, -s*p.x + c*p.z); }
float3 rotX(float3 p, float a) { float c = cos(a), s = sin(a); return float3(p.x, c*p.y - s*p.z, s*p.y + c*p.z); }

fragment float4 orbFragment(Out in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float t = u.frame.z, presence = u.frame.w;
    float level = u.voice.x, low = u.voice.y, mid = u.voice.z, high = u.voice.w;
    float punch = u.motion.x, think = u.motion.y, flow = u.motion.z, calm = u.motion.w;
    float px = 2.0 / u.frame.x;

    float2 p = in.uv * 2.0 - 1.0; p.y = -p.y;
    float r = length(p), angle = atan2(p.y, p.x);

    // The surface is liquid: each band pushes its own ripple around the rim.
    float ripple = sin(angle * 2.0 + flow * 1.1) * low * 0.07
                 + sin(angle * 3.0 - flow * 1.7) * mid * 0.05
                 + sin(angle * 5.0 + flow * 2.6) * high * 0.026;
    ripple *= (1.0 - think) * (1.0 - calm);
    float breathe = 0.014 * sin(t * 1.7) * (1.0 - level);
    float R = (0.34 + 0.2 * level + 0.09 * punch - 0.04 * think + breathe) * (1.0 + ripple);
    R *= clamp(presence, 0.0, 1.2);

    float3 amber = float3(1.00, 0.55, 0.14);
    float3 coral = float3(1.00, 0.33, 0.30);
    float3 ember = float3(0.42, 0.07, 0.03);
    float3 cream = float3(1.00, 0.95, 0.86);
    float3 sea   = float3(0.20, 0.78, 0.76);

    float4 orb = float4(0);
    if (r < R + px) {
        float2 q = p / max(R, 1e-4);
        float z = sqrt(max(0.0, 1.0 - dot(q, q)));
        float3 n = float3(q, z);
        // Light lives inside a turning sphere, so it reads as depth, not a flat gradient.
        float3 s = rotX(rotY(n, flow * 0.5 + t * 0.1), 0.45 + 0.2 * sin(t * 0.3));
        float warp = fbm(s * 1.25 + float3(0.0, t * 0.18, flow * 0.25));
        float f = fbm(s * 1.8 + warp * 1.6 + float3(flow * 0.35, 0.0, t * 0.08));

        // A warm luminous body, never muddy: coral at depth, amber in the middle, cream where it's hottest.
        float3 col = mix(coral * 0.62, amber, smoothstep(0.3, 0.72, f));
        col = mix(col, coral, smoothstep(0.5, 0.85, warp) * 0.35);
        // Silk: thin ribbons of light that fold through the sphere and brighten as you speak.
        float ribbonA = pow(0.5 + 0.5 * sin(f * 9.0 + warp * 3.5 - flow * 1.4), 7.0);
        float ribbonB = pow(0.5 + 0.5 * sin(warp * 7.0 - f * 2.5 + flow * 0.9 + 1.7), 9.0);
        col += cream * ribbonA * (0.28 + 0.75 * level + 0.35 * think);
        col += mix(cream, sea, 0.55) * ribbonB * (0.10 + 0.25 * high);
        float swirl = pow(0.5 + 0.5 * sin(atan2(s.y, s.x) * 2.0 - t * 5.5 + f * 3.0), 4.0);
        col += cream * swirl * think * 0.45;

        float core = exp(-dot(q, q) * 2.6) * (0.18 + 0.8 * level + 0.4 * punch + 0.25 * think);
        col += cream * core * 0.6;

        // Glass: soft key light, a bright fresnel edge and one clean highlight.
        float3 light = normalize(float3(-0.45, 0.62, 0.68));
        col *= (0.72 + 0.28 * max(dot(n, light), 0.0)) * (0.85 + 0.35 * level + 0.2 * think);
        float fresnel = pow(1.0 - z, 3.0);
        col += mix(coral, cream, 0.6) * fresnel * (0.6 + 0.6 * level);
        float spec = pow(max(dot(reflect(-light, n), float3(0, 0, 1)), 0.0), 40.0);
        col += float3(1.0) * spec * 0.7;

        float cover = smoothstep(-px, px, R - r);
        orb = float4(col * cover, cover);
    }

    // A soft halo, brighter as you speak. Premultiplied so it blends cleanly over any window.
    float outside = max(r - R, 0.0);
    float glow = exp(-outside * (9.0 - 3.5 * level)) * (0.12 + 0.5 * level + 0.25 * punch + 0.2 * think);
    glow *= smoothstep(1.0, 0.72, r) * clamp(presence, 0.0, 1.0);
    float3 haloColor = mix(amber, coral, 0.5 + 0.5 * sin(angle + flow * 0.4));
    float3 rgb = orb.rgb + haloColor * glow * (1.0 - orb.a);
    float a = orb.a + glow * (1.0 - orb.a);
    return float4(rgb, a);
}
"""

private let orbitShader = """
struct OrbitUniforms {
    float4 frame;   // width, height, time, presence
    float4 voice;   // level, low, mid, high
    float4 motion;  // punch, thinking, flow, reduce motion
    float4 extra;   // comet phase
};

constant int ringCount = 4;
constant int ringSteps = 72;

float segmentDistance(float2 p, float2 a, float2 b, thread float &along) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-8), 0.0, 1.0);
    along = h;
    return length(pa - ba * h);
}

// One neon glass tube: brighter at its edges like real glass, a hot core line, a soft glow around it.
float3 tube(float d, float w, float3 tint, float depth, float energy, float pulse) {
    float inside = 1.0 - smoothstep(w * 0.8, w, d);
    float x = clamp(d / w, 0.0, 1.0);
    float body = inside * (0.28 + 0.72 * x * x);
    float core = exp(-pow(d / (w * 0.26), 2.0)) * inside;
    float glow = exp(-max(d - w * 0.8, 0.0) * (15.0 - 6.0 * energy)) * (0.30 + 0.55 * energy);
    float lit = mix(1.0, 0.42, smoothstep(-0.7, 0.7, depth));
    float3 col = tint * (body * 0.95 + glow * 0.7) * lit;
    col += float3(0.92, 1.0, 1.0) * core * (0.6 + 0.45 * energy) * lit;
    col += float3(0.9, 1.0, 1.0) * pulse * (inside * 0.9 + glow * 0.5);
    return col;
}

fragment float4 orbitFragment(Out in [[stage_in]], constant OrbitUniforms& u [[buffer(0)]], constant float4* points [[buffer(1)]]) {
    float t = u.frame.z, presence = clamp(u.frame.w, 0.0, 1.2);
    float level = u.voice.x, low = u.voice.y, high = u.voice.w;
    float punch = u.motion.x, think = u.motion.y, flow = u.motion.z;
    float comet = u.extra.x;
    float2 p = in.uv * 2.0 - 1.0; p.y = -p.y;
    float px = 2.0 / u.frame.x;
    float energy = clamp(level * 0.9 + punch * 0.3 + think * 0.35, 0.0, 1.0);
    float3 cyan = float3(0.24, 0.93, 0.95);
    float3 ice = float3(0.62, 0.97, 1.0);
    float3 col = float3(0);

    float widths[4] = { 0.013, 0.062, 0.054, 0.016 };
    float size = 0.72 * presence;
    for (int k = 0; k < ringCount; k++) {
        float best = 1e9, bestZ = 0, bestU = 0;
        for (int i = 0; i < ringSteps; i++) {
            float4 a = points[k * (ringSteps + 1) + i];
            float4 b = points[k * (ringSteps + 1) + i + 1];
            float h;
            float d = segmentDistance(p, a.xy, b.xy, h);
            if (d < best) { best = d; bestZ = mix(a.z, b.z, h); bestU = mix(a.w, b.w, h); }
        }
        float w = widths[k] * size * (k == 0 ? 1.0 : 1.0 + 0.35 * low) + px;
        // Light travels around each tube; the tail fades behind its head.
        float head = fract(comet * (k % 2 == 0 ? 1.0 : -1.0) * (1.0 + 0.23 * float(k)) + float(k) * 0.27);
        float behind = fract((k % 2 == 0 ? head - bestU : bestU - head));
        // Soft head and long tail, so the light glides rather than switching on.
        float pulse = exp(-behind * 7.0) * (1.0 - exp(-behind * 60.0)) * smoothstep(1.0, 0.93, behind)
                    * (0.3 + 0.8 * energy) * (k == 0 ? 0.5 : 1.0);
        float3 tint = mix(cyan, ice, 0.25 + 0.35 * energy);
        col += tube(best, w, tint, bestZ, energy, pulse) * (k == 0 ? 0.9 : (k == 3 ? 0.6 : 1.0));
    }

    // Inner circuit: four arcs with terminal dots, turning slowly against the rings.
    float r = length(p);
    float ringR = 0.47 * size;
    float spin = flow * 0.28 + t * 0.05;
    float angle = atan2(p.y, p.x) - spin;
    float quarter = 6.2831853 / 4.0;
    float local = fract((angle + 6.2831853) / quarter);
    float arcMask = smoothstep(0.06, 0.09, local) * (1.0 - smoothstep(0.91, 0.94, local));
    float arcLine = exp(-pow((r - ringR) / (0.006 * size + px), 2.0)) * arcMask;
    float inner = exp(-pow((r - ringR * 0.86) / (0.004 * size + px), 2.0)) * 0.35;
    float dots = 0.0;
    for (int j = 0; j < 4; j++) {
        for (int e = 0; e < 2; e++) {
            float a = spin + quarter * (float(j) + (e == 0 ? 0.12 : 0.88));
            float2 c = float2(cos(a), sin(a)) * ringR * 0.9;
            dots += exp(-pow(length(p - c) / (0.012 * size + px), 2.0));
        }
    }
    float circuit = (arcLine * (0.55 + 0.6 * high) + inner) * (0.7 + 0.5 * energy);
    col += cyan * circuit + float3(0.92, 1.0, 1.0) * dots * (0.6 + 0.6 * high);

    // Premultiplied light: alpha follows brightness, so it glows over any wallpaper.
    float a = clamp(max(col.r, max(col.g, col.b)), 0.0, 1.0);
    col = min(col, float3(a));
    return float4(col, a);
}
"""
