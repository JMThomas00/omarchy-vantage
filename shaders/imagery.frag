#version 440
// GPU map styles: one equirectangular texture, drawn either as an orthographic globe
// (per-pixel inverse projection, the exact inverse of Geo.projectGlobe) or as the flat map
// (inverse of the flat projection).
//
//   mode 0  satellite  the texture is true-colour imagery
//   mode 1  topo       the texture is packed elevation (v = R*256 + G, metres = v*STEP - OFFSET);
//                      shaded, coloured and contoured here from the theme's accent colour
//   mode 2  contour    the same elevation drawn as a line map: adaptive contour lines with
//                      index contours, in the theme's accent colour on a faint relief tint
//   mode 3  mosaic     BLOCKS: a fixed grid of square blocks (screen aligned, like teletext),
//                      each lit when its spot on Earth is land (the texture is a land mask)
//
// Zoomed in, modes 0-2 also read up to two "detail" textures (DetailStack.qml): web-mercator
// tiles streamed for the visible area, composited into one image each. `detail` is the current
// patch and `detail2` the one before it, so a pan or zoom refines the picture instead of blanking it.
// Satellite tiles are RGB; elevation tiles are Terrarium-encoded (metres = R*256 + G + B/256 - 32768).
// Each tile fades in (alpha), and wherever detail is missing the next layer down shows: the previous
// patch, then the whole-planet texture.
//
// Compile with tools/build-shaders.sh (qsb). The .qsb next to this file is what ships.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    mat4 vm;          // upper-left 3x3 = Geo.viewMatrix (row-major, as in JS)
    vec4 geom;        // cx, cy (px), globe radius R (px), pixels per degree (flat)
    vec4 view;        // width, height (px), lat0 (deg), lon0 (deg)
    vec4 opts;        // mode, flat (0/1), dark (0/1), global texture width (px)
    vec4 accent;
    vec4 bg;
    vec4 fg;
    vec4 tilebox;     // current detail patch extent in normalised web-mercator: u0, v0, du, dv
    vec4 pinfo;       // current patch: on (0/1), width (px), height (px); w = mosaic block size (px)
    vec4 tilebox2;    // previous detail patch, same layout
    vec4 pinfo2;
} u;

layout(binding = 1) uniform sampler2D tex;
layout(binding = 2) uniform sampler2D detail;
layout(binding = 3) uniform sampler2D detail2;

const float STEP_M = 10.0;
const float OFFSET_M = 11000.0;

float elevation(vec2 uv, vec2 dx, vec2 dy) {
    vec4 t = textureGrad(tex, uv, dx, dy);
    return (t.r * 255.0 * 256.0 + t.g * 255.0) * STEP_M - OFFSET_M;
}

vec4 dTex(int which, vec2 p, vec2 gx, vec2 gy) {
    return which == 0 ? textureGrad(detail, p, gx, gy) : textureGrad(detail2, p, gx, gy);
}

// Where this fragment falls in a detail patch (web-mercator), with its gradients there.
bool patchCoords(vec4 box, vec4 info, float uvcx, float myv, float lat, vec2 dx, vec2 dy, vec2 dmy,
                 out vec2 pu, out vec2 pdx, out vec2 pdy) {
    float dd = uvcx - box.x;
    dd -= floor(dd);
    pu = vec2(dd / box.z, (myv - box.y) / box.w);
    pdx = vec2(dx.x / box.z, dmy.x / box.w);
    pdy = vec2(dy.x / box.z, dmy.y / box.w);
    return info.x > 0.5 && abs(lat) < 85.0 && dd < box.z && pu.y > 0.001 && pu.y < 0.999;
}

// Elevation and its four neighbours from one source, with the geometry needed to turn them into slopes.
struct ElevSet {
    float e, eE, eW, eN, eS;
    float cover;          // 0..1: how much of this source is loaded here (tiles fade in)
    vec2 st, gx, gy;      // sample step (uv units of the source) and the source's gradients per screen pixel
    float mx, my;         // ground metres per sample step
};

ElevSet gatherGlobal(vec2 uv, vec2 dx, vec2 dy, vec2 foot0, float texW, float cosLat) {
    ElevSet r;
    // sample spacing: one texel, or the pixel footprint when that is larger (avoids shimmer zoomed out)
    r.st = max(vec2(1.0 / texW, 2.0 / texW), foot0);
    r.e  = elevation(uv, dx, dy);
    r.eE = elevation(vec2(uv.x + r.st.x, uv.y), dx, dy);
    r.eW = elevation(vec2(uv.x - r.st.x, uv.y), dx, dy);
    r.eN = elevation(vec2(uv.x, uv.y - r.st.y), dx, dy);
    r.eS = elevation(vec2(uv.x, uv.y + r.st.y), dx, dy);
    r.cover = 1.0;
    r.gx = dx; r.gy = dy;
    r.mx = 111320.0 * cosLat * 360.0 * r.st.x;
    r.my = 111320.0 * 180.0 * r.st.y;
    return r;
}

// Terrarium-encoded elevation from a detail patch.
float elevD(int which, vec2 p, vec2 gx, vec2 gy, out float a) {
    vec4 t = dTex(which, p, gx, gy);
    a = t.a;
    return t.r * 255.0 * 256.0 + t.g * 255.0 + t.b * (255.0 / 256.0) - 32768.0;
}

ElevSet gatherDetail(int which, vec4 box, vec2 pu, vec2 pdx, vec2 pdy, vec4 info, float cosLat) {
    ElevSet r;
    vec2 pfoot = vec2(abs(pdx.x) + abs(pdy.x), abs(pdx.y) + abs(pdy.y));
    r.st = max(vec2(1.0 / info.y, 1.0 / info.z), pfoot);
    float a0, a1, a2, a3, a4;
    r.e  = elevD(which, pu, pdx, pdy, a0);
    r.eE = elevD(which, pu + vec2(r.st.x, 0.0), pdx, pdy, a1);
    r.eW = elevD(which, pu - vec2(r.st.x, 0.0), pdx, pdy, a2);
    r.eN = elevD(which, pu - vec2(0.0, r.st.y), pdx, pdy, a3);
    r.eS = elevD(which, pu + vec2(0.0, r.st.y), pdx, pdy, a4);
    r.cover = smoothstep(0.45, 1.0, min(min(min(a0, a1), min(a2, a3)), a4));
    r.gx = pdx; r.gy = pdy;
    r.mx = 111320.0 * cosLat * 360.0 * box.z * r.st.x;
    r.my = 40030174.0 * cosLat * box.w * r.st.y;
    return r;
}

// `top` over `under` by `t`: values blend smoothly; the geometry follows whichever dominates.
ElevSet blendSets(ElevSet under, ElevSet top, float t) {
    ElevSet r = t > 0.5 ? top : under;
    r.e  = mix(under.e,  top.e,  t);
    r.eE = mix(under.eE, top.eE, t);
    r.eW = mix(under.eW, top.eW, t);
    r.eN = mix(under.eN, top.eN, t);
    r.eS = mix(under.eS, top.eS, t);
    r.cover = 1.0 - (1.0 - under.cover) * (1.0 - t);
    return r;
}

// screen px -> lat/lon (degrees) and limb factor; false when the point is off the globe.
bool unproject(vec2 s, out float lat, out float lon, out float limb) {
    limb = 1.0;
    if (u.opts.y > 0.5) {
        lon = u.view.w + (s.x - u.geom.x) / u.geom.w;
        lat = u.view.z - (s.y - u.geom.y) / u.geom.w;
        return lat <= 90.0 && lat >= -90.0 && lon >= -180.0 && lon <= 180.0;     // the flat map does not repeat
    }
    vec2 pq = vec2((s.x - u.geom.x) / u.geom.z, (u.geom.y - s.y) / u.geom.z);
    float r2 = dot(pq, pq);
    if (r2 > 1.0) return false;
    float x2 = sqrt(1.0 - r2);
    vec3 v = vec3(x2, pq.x, pq.y) * mat3(u.vm);                  // v = M^T s
    lat = degrees(asin(clamp(v.z, -1.0, 1.0)));
    lon = degrees(atan(v.y, v.x));
    limb = x2;
    return true;
}

void main() {
    vec2 px = qt_TexCoord0 * u.view.xy;
    bool isFlat = u.opts.y > 0.5;
    float mode = u.opts.x;
    float lat, lon, limbF;

    // ------------------------------------------------------------------ mosaic (BLOCKS)
    if (mode > 2.5) {
        if (!unproject(px, lat, lon, limbF)) { fragColor = vec4(0.0); return; }
        float edgeM = 1.0;
        if (!isFlat) edgeM = clamp((1.0 - length(vec2(px.x - u.geom.x, px.y - u.geom.y)) / u.geom.z) * u.geom.z, 0.0, 1.0);
        float q = max(2.0, u.pinfo.w);
        vec2 c = (floor(px / q) + 0.5) * q;
        // land coverage of the block: its centre and four points toward the corners
        vec2 offs[5] = vec2[5](vec2(0.0), vec2(-0.3, -0.3), vec2(0.3, -0.3), vec2(-0.3, 0.3), vec2(0.3, 0.3));
        float cov = 0.0, wsum = 0.0, lc = 1.0;
        for (int k = 0; k < 5; k++) {
            float la, lo, li;
            float wgt = k == 0 ? 2.0 : 1.0;
            wsum += wgt;
            if (!unproject(c + offs[k] * q, la, lo, li)) continue;
            if (k == 0) lc = li;
            vec2 uvm = vec2(fract(lo / 360.0 + 0.5), clamp(0.5 - la / 180.0, 0.0, 1.0));
            cov += textureLod(tex, uvm, 0.0).r * wgt;
        }
        if (cov < 0.5 * wsum) { fragColor = vec4(0.0); return; }
        float a = (u.opts.z > 0.5 ? 0.55 : 0.66) * mix(0.5, 1.0, pow(lc, 0.6));
        fragColor = vec4(u.accent.rgb * a, a) * edgeM * u.qt_Opacity;
        return;
    }

    // ------------------------------------------------------------------ imagery / topo / contour
    float edge = 1.0;     // antialiasing of the disc edge
    if (!unproject(px, lat, lon, limbF)) { fragColor = vec4(0.0); return; }
    if (!isFlat) edge = clamp((1.0 - length(vec2(px.x - u.geom.x, px.y - u.geom.y)) / u.geom.z) * u.geom.z, 0.0, 1.0);

    // continuous texture coordinate (u may run outside 0..1; wrapped below)
    vec2 uvc = vec2(lon / 360.0 + 0.5, 0.5 - lat / 180.0);

    // Texture gradients. On the globe, atan() jumps at the antimeridian, which
    // would make the derivative huge along that seam and pick the blurriest mip
    // there: take the gradient of whichever wrapping is continuous.
    vec2 dx = dFdx(uvc), dy = dFdy(uvc);
    if (!isFlat) {
        vec2 uvb = vec2(fract(uvc.x + 0.5), uvc.y);
        vec2 dxb = dFdx(uvb), dyb = dFdy(uvb);
        if (abs(dx.x) + abs(dy.x) > abs(dxb.x) + abs(dyb.x)) { dx = dxb; dy = dyb; }
    }
    vec2 uv = vec2(fract(uvc.x), clamp(uvc.y, 0.0, 1.0));

    // where this fragment falls in each detail patch (web-mercator), and its gradients there
    float myv = 0.5 - log(tan(0.78539816 + radians(clamp(lat, -85.0, 85.0)) * 0.5)) / 6.28318531;
    vec2 dmy = vec2(dFdx(myv), dFdy(myv));
    vec2 pu1, pdx1, pdy1, pu2, pdx2, pdy2;
    bool in1 = patchCoords(u.tilebox,  u.pinfo,  uvc.x, myv, lat, dx, dy, dmy, pu1, pdx1, pdy1);
    bool in2 = patchCoords(u.tilebox2, u.pinfo2, uvc.x, myv, lat, dx, dy, dmy, pu2, pdx2, pdy2);

    vec3 col;
    if (mode < 0.5) {
        // ---------------------------------------------------------------- satellite
        vec3 base = textureGrad(tex, uv, dx, dy).rgb;
        col = base;
        // previous patch first, then the current one on top; each tile fades in through its alpha
        for (int w = 1; w >= 0; w--) {
            bool ins = w == 0 ? in1 : in2;
            if (!ins) continue;
            vec4 t = dTex(w, w == 0 ? pu1 : pu2, w == 0 ? pdx1 : pdx2, w == 0 ? pdy1 : pdy2);
            if (t.a < 0.01) continue;
            vec3 c = t.rgb / t.a;
            // The Landsat composite marks "no data" (open ocean, polar gaps, swath edges) as pure
            // black: treat near-black as missing so the whole-planet imagery shows through there.
            float have = smoothstep(0.02, 0.07, max(c.r, max(c.g, c.b)));
            col = mix(col, c, t.a * have);
        }
        // Deep open water always uses the whole-planet imagery: the composite has no detail there, and
        // mixing sharp coastal tiles with smooth sea depending on what has loaded looks patchy.
        float blueness = base.b - max(base.r, base.g);
        float deepSea = smoothstep(0.02, 0.05, blueness) * (1.0 - smoothstep(0.22, 0.40, max(base.r, max(base.g, base.b))));
        col = mix(col, base, deepSea);
        col *= mix(0.5, 1.0, pow(limbF, 0.45));       // gentle limb darkening
    } else {
        // ---------------------------------------------------------------- topo + contour
        float texW = u.opts.w;
        float texH = texW * 0.5;
        float cosLat = max(0.05, cos(radians(lat)));
        // ground metres per screen pixel (from the whole-planet texture's footprint)
        vec2 foot0 = vec2(abs(dx.x) + abs(dy.x), abs(dx.y) + abs(dy.y));
        float mpp = 0.5 * (foot0.x * 360.0 * 111320.0 * cosLat + foot0.y * 180.0 * 111320.0);

        // Elevation and its four neighbours: the current detail patch where loaded, blended over the previous
        // patch, blended over the whole-planet texture. Each source is only sampled if a higher one does not
        // already cover the pixel completely.
        ElevSet s1, s2, sg;
        float w1 = 0.0, w2 = 0.0;
        if (in1) { s1 = gatherDetail(0, u.tilebox, pu1, pdx1, pdy1, u.pinfo, cosLat); w1 = s1.cover; }
        if (in2 && w1 < 0.999) { s2 = gatherDetail(1, u.tilebox2, pu2, pdx2, pdy2, u.pinfo2, cosLat); w2 = s2.cover; }
        bool needG = !(in1 && w1 >= 0.999) && !(in2 && w1 + (1.0 - w1) * w2 >= 0.999);
        ElevSet cur;
        if (needG) cur = gatherGlobal(uv, dx, dy, foot0, texW, cosLat);
        else if (in2 && w1 < 0.999) cur = s2;
        else cur = s1;
        if (needG && in2) cur = blendSets(cur, s2, w2);
        if (in1 && needG) cur = blendSets(cur, s1, w1);
        else if (in1 && in2 && w1 < 0.999) cur = blendSets(s2, s1, w1);
        bool det = !needG || cur.cover > 0.5;
        // "detail" for the purposes of line thresholds: any real (non-global) data dominates here
        det = in1 && w1 > 0.5 || in2 && w2 > 0.5 && w1 <= 0.5;
        float e = cur.e, eE = cur.eE, eW = cur.eW, eN = cur.eN, eS = cur.eS;
        vec2 st = cur.st, gx = cur.gx, gy = cur.gy;
        float mxm = cur.mx, mym = cur.my;

        // hillshade (light from the north-west, 45 deg up). The vertical is exaggerated so coarse
        // data still shows relief, and less so as the data gets finer.
        float exag = clamp(mpp / 500.0, 1.5, 14.0);
        // note: +y in this normal is north (texture v grows southwards, hence eS - eN)
        vec3 n = normalize(vec3(-(eE - eW) * exag / (2.0 * mxm), (eS - eN) * exag / (2.0 * mym), 1.0));
        vec3 L = normalize(vec3(-0.6, 0.6, 0.7));
        float lit = dot(n, L) - 0.7;

        // Global elevation is stored in 10 m steps, so flat areas sit on exact plateaus (often exactly 0):
        // a line there would fill the whole plateau, so lines fade out where the slope is ~0.
        float dedx = ((eE - eW) / (2.0 * st.x)) * gx.x + ((eS - eN) / (2.0 * st.y)) * gx.y;
        float dedy = ((eE - eW) / (2.0 * st.x)) * gy.x + ((eS - eN) / (2.0 * st.y)) * gy.y;
        float slope = max(0.0001, length(vec2(dedx, dedy)));       // metres of elevation per screen pixel
        float hasSlope = det ? smoothstep(0.01, 0.08, slope) : smoothstep(0.4, 1.6, slope);
        vec2 crowd = det ? vec2(1.2, 3.0) : vec2(2.5, 6.0);         // lines closer than this many px fade out

        vec3 c;
        if (mode < 1.5) {
            // ------------------------------------------------------------ topo (hypsometric + shaded)
            float shade = clamp(0.86 + 1.0 * lit, 0.3, 1.45);
            if (e < 0.0) {
                float d = clamp(-e / 6500.0, 0.0, 1.0);
                c = mix(u.accent.rgb, u.bg.rgb, 0.78 + 0.20 * sqrt(d));
            } else {
                float t = clamp(e / 5200.0, 0.0, 1.0);
                c = mix(u.bg.rgb, u.accent.rgb, 0.42 + 0.56 * sqrt(t));
                c = mix(c, u.fg.rgb, smoothstep(0.55, 1.0, t) * 0.75);
            }
            c *= shade;
            // contours: every 500 m on land (every 2 km stronger), every 1 km at sea, and the coast.
            // Zoomed in on real detail, the interval follows the scale the same way CONTOUR's does.
            float step_m = e < 0.0 ? 1000.0 : 500.0;
            float major = 2000.0;
            if (det) {
                float tgt = clamp(14.3 * pow(mpp, 0.455), 20.0, 1000.0);
                step_m = tgt <= 30.0 ? 20.0 : (tgt <= 75.0 ? 50.0 : (tgt <= 150.0 ? 100.0 : (tgt <= 350.0 ? 200.0 : (tgt <= 750.0 ? 500.0 : 1000.0))));
                major = step_m * 5.0;
            }
            float dist = abs(fract(e / step_m - 0.5) - 0.5) * step_m / slope;
            float lines = (1.0 - smoothstep(0.35, 1.1, dist)) * smoothstep(crowd.x, crowd.y, step_m / slope) * hasSlope;
            float distM = abs(fract(e / major - 0.5) - 0.5) * major / slope;
            float linesM = (1.0 - smoothstep(0.45, 1.3, distM)) * smoothstep(crowd.x, crowd.y, major / slope) * (e > 0.0 ? 1.0 : 0.0) * hasSlope;
            float coast = (1.0 - smoothstep(0.5, 1.4, abs(e) / slope)) * hasSlope;
            c = mix(c, u.accent.rgb, lines * (e < 0.0 ? 0.28 : 0.42));
            c = mix(c, u.fg.rgb, linesM * 0.55);
            c = mix(c, u.fg.rgb, coast * 0.85);
        } else {
            // ------------------------------------------------------------ contour (line map, USGS-quad style)
            // The contour interval follows the zoom, like a real map adding detail as you zoom in:
            // it grows with the ground scale, snapped to a 1-2-5 ladder and cross-faded between
            // rungs so it never pops.
            float target = clamp(14.3 * pow(mpp, 0.455), 10.0, 2000.0);
            float rung[8] = float[8](10.0, 20.0, 50.0, 100.0, 200.0, 500.0, 1000.0, 2000.0);
            int i0 = 0;
            for (int i = 0; i < 7; i++) if (target >= rung[i + 1]) i0 = i + 1;
            float A = rung[i0], B = rung[min(i0 + 1, 7)];
            float w = i0 == 7 ? 0.0 : clamp(log2(target / A) / log2(B / A), 0.0, 1.0);

            // a very faint relief tint so the map has some body, land a touch lighter than sea
            float relief = clamp(1.0 + 0.9 * lit, 0.55, 1.35);
            vec3 paper = e < 0.0 ? u.bg.rgb : mix(u.bg.rgb, u.accent.rgb, 0.10 * relief);
            c = paper;

            // Contour a lightly smoothed surface: the global data is 10 km per texel in 10 m steps, and
            // contouring it raw shows every quantisation kink as a wiggle.
            float es = (4.0 * e + eE + eW + eN + eS) * 0.125;
            // thin contours; every 5th is an index contour: heavier and brighter
            float dA  = abs(fract(es / A - 0.5) - 0.5) * A / slope;
            float dB  = abs(fract(es / B - 0.5) - 0.5) * B / slope;
            float dAi = abs(fract(es / (5.0 * A) - 0.5) - 0.5) * (5.0 * A) / slope;
            float dBi = abs(fract(es / (5.0 * B) - 0.5) - 0.5) * (5.0 * B) / slope;
            float thinA = (1.0 - smoothstep(0.30, 0.95, dA)) * smoothstep(crowd.x, crowd.y - 1.0, A / slope);
            float thinB = (1.0 - smoothstep(0.30, 0.95, dB)) * smoothstep(crowd.x, crowd.y - 1.0, B / slope);
            float idxA  = (1.0 - smoothstep(0.55, 1.50, dAi)) * smoothstep(crowd.x, crowd.y - 1.0, 5.0 * A / slope);
            float idxB  = (1.0 - smoothstep(0.55, 1.50, dBi)) * smoothstep(crowd.x, crowd.y - 1.0, 5.0 * B / slope);
            float thin = mix(thinA, thinB, w) * hasSlope;
            float idx  = mix(idxA, idxB, w) * hasSlope;
            float sea  = e < 0.0 ? 1.0 : 0.0;

            vec3 ink = u.accent.rgb;
            vec3 inkIdx = mix(u.accent.rgb, u.fg.rgb, 0.35);
            c = mix(c, ink, thin * mix(0.78, 0.30, sea));
            c = mix(c, inkIdx, idx * mix(1.0, 0.0, sea));
            // coastline: the zero contour, always drawn firmly
            float coast = (1.0 - smoothstep(0.6, 1.6, abs(e) / slope)) * hasSlope;
            c = mix(c, inkIdx, coast);
        }
        col = c * mix(0.6, 1.0, pow(limbF, 0.5));
    }

    fragColor = vec4(col, 1.0) * edge * u.qt_Opacity;
}
