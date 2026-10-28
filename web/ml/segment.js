/* kidart ML subject segmentation (web prototype only).
 * Model: U^2-Netp (Apache-2.0, github.com/xuebinqin/U-2-Net). ml/u2netp.onnx = rembg's u2netp.onnx
 *   (md5 8e83ca70e441ab06c318d82300c84806, same file in npm @rmbg/model-u2netp and @planby-tech/rmbg-webgpu) with two
 *   graph-only edits (weights untouched): input H/W made dynamic, the 6 unused side outputs removed.
 * Runtime: onnxruntime-web 1.31.1 (MIT), wasm EP, numThreads=1, SIMD, no SharedArrayBuffer / cross-origin isolation needed.
 *
 *   const r = await mlSubjectMask(canvas);   // -> { mask: Float32Array(w*h) 0..1, w, h, ms } | null (never throws)
 *
 * The mask covers the WHOLE canvas, squashed to w x h (224 x 224): mask pixel (u,v) <-> canvas point
 * ((u+0.5)*canvas.width/w, (v+0.5)*canvas.height/h). 1 = subject. null = ML unavailable (use the colour method).
 *
 * Paths tried, in order (first that boots wins; mlSubjectMask.stats.path tells which):
 *   worker+cdn   blob: Web Worker, importScripts(jsdelivr ort.wasm.min.js), ORT imports jsdelivr .mjs glue
 *   worker+local same, ORT JS + glue from ml/
 *   main+cdn / main+local   same on the main thread (<script> tag) if workers are blocked
 * The .wasm binary and the .onnx model are always fetched same-origin from ml/ (cfg.base) and handed to ORT as bytes.
 * Fast failure: a 8-byte wasm module is compiled first ("wasm blocked" -> give up at once, nothing else can work);
 * script loading must finish within bootTimeoutMs; downloads abort after stallTimeoutMs without progress; session
 * creation within createTimeoutMs; a run within runTimeoutMs. Lazy: nothing loads before the first
 * mlSubjectMask()/mlPreload(). The runtime is freed after idleDisposeMs without use, or by mlDispose().
 */
(function (root) {
  "use strict";
  const ORT_VER = "1.31.1", CDN = "https://cdn.jsdelivr.net/npm/onnxruntime-web@" + ORT_VER + "/dist/";
  const docBase = () => { try { return root.document && root.document.baseURI || root.location.href; } catch (e) { return ""; } };
  const cfg = {
    base: null,               // folder holding the model + wasm; default "ml/" next to the page
    model: "u2netp.onnx",     // string or array of chunk names (concatenated in order; each file <= 15 MB)
    size: 224,                // network input size. u2netp was trained at 320, but 224 is ~2x faster and clearly
                              // better on close-up / edge-touching / textured-table photos (more global context)
    norm: "u2net",            // "u2net": x/max(x) then ImageNet mean/std (rembg's U2-Net preprocessing)
    tta: false,               // also run the mirrored image and average (2x time; did not help at 224)
    ortSources: null,         // [[ortJsUrl, glueMjsUrl, label], ...]; default jsdelivr, then the local copies
    workers: true, mainThread: true,
    bootTimeoutMs: 6000, stallTimeoutMs: 15000, createTimeoutMs: 20000, runTimeoutMs: 30000, idleDisposeMs: 120000,
    onStatus: null,           // (phase) => {}: "load" while downloading/initialising, "run" while inferring, "idle"
  };
  let be = null, ready = null, failed = null, seq = 0, idleT = 0;
  const api = { stats: {} };

  // ---------- the ORT side: stringified into the worker, or called directly on the main thread ----------
  function core(post, loadScript, inWorker) {
    const G = typeof self !== "undefined" ? self : window;
    let session = null, inName = null, outName = null, wasmMem = null;
    if (inWorker) try { const OM = WebAssembly.Memory; WebAssembly.Memory = function (d) { const m = new OM(d); wasmMem = m; return m; }; WebAssembly.Memory.prototype = OM.prototype; } catch (e) {}
    const memMB = () => { try { return wasmMem ? +(wasmMem.buffer.byteLength / 1048576).toFixed(1) : null; } catch (e) { return null; } };
    async function get(url, id) {
      const r = await fetch(url); if (!r.ok) throw new Error("HTTP " + r.status + " " + url);
      if (!r.body || !r.body.getReader) return new Uint8Array(await r.arrayBuffer());
      const rd = r.body.getReader(), parts = []; let n = 0, last = 0;
      for (;;) { const { done, value } = await rd.read(); if (done) break; parts.push(value); n += value.length; if (n - last > 262144) { last = n; post({ id, progress: n }); } }
      const o = new Uint8Array(n); let k = 0; for (const p of parts) { o.set(p, k); k += p.length; } return o;
    }
    return async (m) => {
      try {
        if (m.type === "boot") {
          try { new WebAssembly.Module(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0])); } catch (e) { throw new Error("wasm blocked: " + (e && e.message || e)); }
          if (!G.ort) await loadScript(m.ortJs);
          if (!G.ort || !G.ort.InferenceSession) throw new Error("ort missing after " + m.ortJs);
          post({ id: m.id, ok: true });
        } else if (m.type === "fetch") {
          const bufs = []; for (const u of m.urls) bufs.push(await get(u, m.id));
          G.__mlBufs = bufs; post({ id: m.id, ok: true, bytes: bufs.reduce((a, b) => a + b.length, 0) });
        } else if (m.type === "create") {
          const ort = G.ort, [wasm, ...parts] = G.__mlBufs; G.__mlBufs = null;
          ort.env.wasm.numThreads = 1; ort.env.wasm.proxy = false; ort.env.wasm.wasmPaths = { mjs: m.glue }; ort.env.wasm.wasmBinary = wasm.buffer;
          let model = parts[0];
          if (parts.length > 1) { let n = 0; for (const p of parts) n += p.length; model = new Uint8Array(n); let o = 0; for (const p of parts) { model.set(p, o); o += p.length; } }
          session = await ort.InferenceSession.create(model, { executionProviders: ["wasm"], graphOptimizationLevel: "all" });
          inName = session.inputNames[0]; outName = session.outputNames[0];
          post({ id: m.id, ok: true, memMB: memMB() });
        } else if (m.type === "run") {
          const t0 = performance.now(), S = m.size, n = S * S, out = new Float32Array(n);
          for (let pass = 0; pass < m.inputs.length; pass++) {
            const flip = pass === 1, res = await session.run({ [inName]: new G.ort.Tensor("float32", new Float32Array(m.inputs[pass]), [1, 3, S, S]) });
            const d = res[outName].data; let lo = Infinity, hi = -Infinity;
            for (let i = 0; i < n; i++) { const v = d[i]; if (v < lo) lo = v; if (v > hi) hi = v; }
            const k = hi - lo > 1e-6 ? 1 / (hi - lo) : 0;
            for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) out[y * S + x] += (d[y * S + (flip ? S - 1 - x : x)] - lo) * k;
            for (const key in res) try { res[key].dispose && res[key].dispose(); } catch (err) {}
          }
          const kk = 1 / m.inputs.length; for (let i = 0; i < n; i++) out[i] *= kk;
          post({ id: m.id, ok: true, mask: out, ms: performance.now() - t0, memMB: memMB() }, [out.buffer]);
        } else if (m.type === "release") {
          try { session && session.release && await session.release(); } catch (e) {} session = null; post({ id: m.id, ok: true });
        }
      } catch (err) { post({ id: m.id, ok: false, error: String(err && err.message || err) }); }
    };
  }

  // ---------- backends ----------
  function makeBackend(kind) {
    const pending = new Map(), b = { kind, pending, dead: false };
    const onMsg = (d) => { const p = pending.get(d.id); if (!p) return; if (d.progress != null) { p.kick(); return; } pending.delete(d.id); p.done(d); };
    b.failAll = (msg) => { for (const p of pending.values()) p.done({ ok: false, error: msg }); pending.clear(); };
    if (kind === "worker") {
      const src = "const h=(" + core.toString() + ")((d,t)=>self.postMessage(d,t||[]),(u)=>importScripts(u),true);self.onmessage=(e)=>h(e.data);";
      const url = URL.createObjectURL(new Blob([src], { type: "text/javascript" }));
      const w = new Worker(url); URL.revokeObjectURL && setTimeout(() => URL.revokeObjectURL(url), 30000);
      w.onmessage = (e) => onMsg(e.data);
      w.onerror = (e) => { e.preventDefault && e.preventDefault(); b.failAll("worker error: " + (e.message || "blocked?")); };
      b.send = (m, tr) => w.postMessage(m, tr || []); b.kill = () => { b.dead = true; try { w.terminate(); } catch (e) {} b.failAll("disposed"); };
    } else {
      const loadScript = (u) => new Promise((res, rej) => { const s = document.createElement("script"); s.src = u; s.async = true; s.onload = res; s.onerror = () => rej(new Error("script blocked/failed: " + u)); document.head.appendChild(s); });
      const h = core((d) => setTimeout(() => onMsg(d), 0), loadScript, false);
      b.send = (m) => { h(m); }; b.kill = () => { b.dead = true; b.failAll("disposed"); try { h({ id: -1, type: "release" }); } catch (e) {} };
    }
    // send with a hard timeout and an optional stall timeout reset by progress messages
    b.call = (msg, timeout, stall) => new Promise((res, rej) => {
      const id = ++seq; msg.id = id; let t = 0;
      const arm = (ms) => { clearTimeout(t); t = setTimeout(() => { pending.delete(id); rej(new Error(msg.type + " timeout " + ms + "ms")); }, ms); };
      arm(stall || timeout);
      pending.set(id, { kick: () => stall && arm(stall), done: (d) => { clearTimeout(t); d.ok ? res(d) : rej(new Error(d.error)); } });
      try { b.send(msg, msg.transfer); } catch (e) { pending.delete(id); clearTimeout(t); rej(e); }
    });
    return b;
  }
  const status = (p) => { try { cfg.onStatus && cfg.onStatus(p); } catch (e) {} };
  function drop() { try { be && be.kill(); } catch (e) {} be = null; }
  function kill() { clearTimeout(idleT); drop(); ready = null; }

  async function init() {
    const t0 = performance.now(), base = new URL(cfg.base || "ml/", docBase()).href, abs = (u) => new URL(u, docBase()).href;
    const models = (Array.isArray(cfg.model) ? cfg.model : [cfg.model]).map(f => new URL(f, base).href);
    const sources = (cfg.ortSources || [[CDN + "ort.wasm.min.js", CDN + "ort-wasm-simd-threaded.mjs", "cdn"], [base + "ort.wasm.min.js", base + "ort-wasm-simd-threaded.mjs", "local"]]);
    const kinds = [], tried = [];
    if (cfg.workers && root.Worker && root.Blob && root.URL) kinds.push("worker");
    if (cfg.mainThread && root.document) kinds.push("main");
    for (const kind of kinds) for (const [js, glue, label] of sources) {
      const path = kind + "+" + (label || "src");
      try {
        be = makeBackend(kind);
        await be.call({ type: "boot", ortJs: abs(js) }, cfg.bootTimeoutMs);
        const tb = performance.now();
        await be.call({ type: "fetch", urls: [base + "ort-wasm-simd-threaded.wasm", ...models] }, 600000, cfg.stallTimeoutMs);
        const tf = performance.now();
        const r = await be.call({ type: "create", glue: abs(glue) }, cfg.createTimeoutMs);
        api.stats.path = path; api.stats.tried = tried;
        api.stats.init = { ms: Math.round(performance.now() - t0), bootMs: Math.round(tb - t0), fetchMs: Math.round(tf - tb), createMs: Math.round(performance.now() - tf), wasmHeapMB: r.memMB };
        return true;
      } catch (e) {
        const msg = String(e && e.message || e); tried.push(path + ": " + msg); drop();
        if (/wasm blocked/.test(msg)) { api.stats.tried = tried; throw new Error(msg); }   // nothing else can work
        if (/^HTTP 4/.test(msg)) { api.stats.tried = tried; throw new Error(msg); }      // our own files are missing
      }
    }
    api.stats.tried = tried;
    throw new Error(tried.length ? tried[tried.length - 1] : "no Worker / document");
  }

  function preprocess(canvas) {
    const S = cfg.size, c = document.createElement("canvas"); c.width = S; c.height = S;
    const x = c.getContext("2d", { willReadFrequently: true }); x.imageSmoothingEnabled = true; x.imageSmoothingQuality = "high";
    x.drawImage(canvas, 0, 0, S, S);
    const d = x.getImageData(0, 0, S, S).data, n = S * S;
    let mx = 1; for (let i = 0; i < n * 4; i += 4) { if (d[i] > mx) mx = d[i]; if (d[i + 1] > mx) mx = d[i + 1]; if (d[i + 2] > mx) mx = d[i + 2]; }
    const u2 = cfg.norm === "u2net", mean = u2 ? [0.485, 0.456, 0.406] : [0.5, 0.5, 0.5], std = u2 ? [0.229, 0.224, 0.225] : [1, 1, 1], sc = u2 ? 1 / mx : 1 / 255;
    const mk = (flip) => {
      const t = new Float32Array(3 * n);
      for (let y = 0; y < S; y++) for (let X = 0; X < S; X++) { const j = (y * S + (flip ? S - 1 - X : X)) * 4, o = y * S + X; for (let k = 0; k < 3; k++) t[k * n + o] = (d[j + k] * sc - mean[k]) / std[k]; }
      return t.buffer;
    };
    return cfg.tta ? [mk(false), mk(true)] : [mk(false)];
  }
  function start() { if (!ready) { ready = init(); ready.catch((e) => { failed = e; api.stats.error = String(e && e.message || e); kill(); }); } return ready; }

  async function mlSubjectMask(canvas) {
    if (failed) return null;
    clearTimeout(idleT);
    try {
      if (!root.WebAssembly) throw new Error("no WebAssembly");
      if (!ready) status("load");
      start(); await ready;
      status("run");
      const inputs = preprocess(canvas), t0 = performance.now();
      const r = await be.call({ type: "run", size: cfg.size, inputs, transfer: be.kind === "worker" ? inputs : null }, cfg.runTimeoutMs);
      api.stats.run = { ms: Math.round(performance.now() - t0), inferMs: Math.round(r.ms), wasmHeapMB: r.memMB, passes: inputs.length };
      if (cfg.idleDisposeMs > 0) idleT = setTimeout(kill, cfg.idleDisposeMs);
      status("idle");
      return { mask: r.mask, w: cfg.size, h: cfg.size, ms: r.ms };
    } catch (e) {
      api.stats.error = String(e && e.message || e);
      if (root.console) console.warn("[kidart-ml] off, using the colour method:", api.stats.error);
      failed = e; kill(); status("idle"); return null;
    }
  }
  Object.assign(api, {
    config(o) { Object.assign(cfg, o || {}); return cfg; },
    preload() { if (failed || !root.WebAssembly) return null; clearTimeout(idleT); if (!ready) { start(); ready.then(() => { if (cfg.idleDisposeMs > 0) idleT = setTimeout(kill, cfg.idleDisposeMs); }, () => {}); } return ready; },
    dispose() { kill(); },
    reset() { kill(); failed = null; api.stats = {}; mlSubjectMask.stats = api.stats; },  // allow another try after a failure
  });
  root.mlSubjectMask = Object.assign(mlSubjectMask, api);
  Object.defineProperty(root.mlSubjectMask, "loaded", { get: () => !!(be && api.stats.path && !failed) });
  Object.defineProperty(root.mlSubjectMask, "failed", { get: () => !!failed });
  root.mlPreload = api.preload; root.mlDispose = api.dispose;
})(typeof self !== "undefined" ? self : this);
