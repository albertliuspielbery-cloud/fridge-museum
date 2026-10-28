# 勞作模式 ML 去背：整合說明（web 原型專用）

> **狀態（已整合）**：`segment.js` + `fuse.js` 已內嵌進 `kidart.html`（主 `<script>` 中 `buildCraft` 之後）。
> `ml/` 只放執行期檔案：`u2netp.onnx`、`ort-wasm-simd-threaded.wasm`、`ort-wasm-simd-threaded.mjs`、`ort.wasm.min.js` 與授權檔。
> 改了 `ml/segment.js` / `ml/fuse.js` 之後，要同步更新 kidart.html 裡的內嵌版本（兩者目前逐字相同）。
> 執行路徑依序嘗試：worker+cdn → worker+local → main+cdn → main+local；wasm 被 CSP 擋（缺 `'wasm-unsafe-eval'`）時立刻放棄，
> 用顏色法。實際走的路徑記錄在 `S.mlDebug = {path, ms, error, used, why, tried, init}`；網址加 `?mldebug`
> （或 `localStorage.kidart.mldebug = "1"`）時，提示列會附上一行簡短說明。第一張照片最多等 20 秒模型下載，超過就先給顏色法的結果，
> 模型到了以後，若使用者還沒塗抹，會自動換成 AI 結果。閒置 2 分鐘或 `pagehide` 時釋放 runtime。

> **2026-10-28 更新（v0.9.0「勞作去背：減少黏在作品旁的雜物」）**：
> - 細長部件補回多一個條件：部件外圍 3 px 的環至少 60 % 要像桌面。延伸進別的東西（資料夾邊、杯子後面的筆）的條狀物不再補回；腳、天線、旗桿這類躺在桌面上的仍會補回。
> - 邊緣帶加入局部兩色模型：用附近有把握的主體平均色 F 和背景平均色 B（半徑約長邊的 2 %），只在 F、B 有差異且像素顏色靠近 F–B 線時才採用，跟 guided filter 的結果混合。這修好了亮金屬杯緣被切掉的問題。
> - `craftMaskML` 現在也回傳 `core`（ML 主體）。`craftParts()` 會把從顏色法補回、位於 ML 主體外的細長部件分成獨立的 part，點一下就能移除或保留。

這個資料夾提供一個完全在裝置上執行的主體分割器（U²-Netp + onnxruntime-web wasm），用來改善
`craftMask/craftAlpha`：目前的方法靠邊框顏色模型，桌面是淺色紋路大理石時會失敗。
**`kidart.html` 沒有被修改**；以下是要整合時的確切步驟。

## 1. 要發佈的檔案（放在頁面旁邊的 `ml/` 資料夾，同源、用相對網址）

| 檔案 | 大小 | 用途 | 授權 |
|---|---|---|---|
| `ml/ort-wasm-simd-threaded.wasm` | 14,848,852 B（gzip 3.8 MB） | ORT wasm 二進位檔，由我們自己 fetch 後傳給 `env.wasm.wasmBinary` | MIT（onnxruntime-web 1.31.1） |
| `ml/u2netp.onnx` | 4,574,327 B | U²-Netp 模型 | Apache-2.0 |
| `ml/ort.wasm.min.js` | 53,796 B | 備援：jsdelivr 載不到時用的本地 ORT JS | MIT |
| `ml/ort-wasm-simd-threaded.mjs` | 24,738 B | 備援：本地 ORT 膠水程式 | MIT |
| `ml/LICENSE-onnxruntime-MIT.txt`, `ml/LICENSE-u2netp-Apache-2.0.txt` | | 授權文字（Apache-2.0 §4 要求隨附） | |
| `ml/segment.js`, `ml/fuse.js` | 約 9 KB + 9 KB | 程式碼：內嵌到 kidart.html 裡（見第 2 步） | 我們自己的 |

每個檔案都 ≤ 15 MB，合計約 19.5 MB（gzip 後約 8 MB）。`ml/INTEGRATION.md` 不需要發佈，發佈了也無妨。

模型來源：`u2netp.onnx` 是 rembg 的 `u2netp.onnx`（md5 `8e83ca70e441ab06c318d82300c84806`；npm 上的
`@rmbg/model-u2netp@0.0.1` 和 `@planby-tech/rmbg-webgpu@0.2.1` 內含同一個檔案，後者的
THIRD_PARTY_NOTICES 註明它來自 rembg 的 GitHub release，模型授權為 U-2-Net 的 Apache-2.0）。
我做了兩處只改計算圖、不動權重的修改：輸入的 H/W 改成動態，並移除 6 個沒用到的側輸出
（修改後 md5 `e859721e511feaa998a51f31f763304d`；在 320 px 時輸出與原始模型逐位元相同）。
Apache-2.0 要求註明修改，上面這段就是註明。

執行期的載入順序：worker 先用 `importScripts` 從 jsdelivr 載入 `ort.wasm.min.js@1.31.1`（CSP 允許），
ORT 再 `import()` jsdelivr 上的 `ort-wasm-simd-threaded.mjs`；`.wasm` 和 `.onnx` 一律 `fetch('ml/…')`
從同源取得。jsdelivr 載不到時，會改用 `ml/` 裡的本地 JS 重試一次。執行時不需要 SharedArrayBuffer，
也不需要 cross-origin isolation（numThreads=1）。我在 `crossOriginIsolated === false` 的 Chromium 上驗證過。

## 2. 載入程式碼

CSP 只允許 CDN 的 script 來源，同源的 `<script src="ml/segment.js">` 可能會被擋。所以請把
`ml/segment.js`，再接著 `ml/fuse.js`，**原封不動貼進** kidart.html 的主 `<script>`，位置放在 `craftAlpha`
定義之後的任何地方（`fuse.js` 會用到 `craftMask`、`craftAlpha`、`maskCheck`、`components`、`morph`、
`boxBlur`、`smooth`、`clamp`、`ctx2d`、`makeCanvas`、`feat`、`bgDist`；這些都是在呼叫時才查找，所以檔案內的定義順序
無所謂）。

`segment.js` 會建立 `mlSubjectMask(canvas)`、`mlPreload()` 和 `mlDispose()`，另外還有
`mlSubjectMask.config({...})`、`mlSubjectMask.reset()` 和 `mlSubjectMask.stats`。
`fuse.js` 會建立 `craftMaskML(src, sens, ml)` 和 `craftAlphaML(src, m)`。

如果頁面不在網站根目錄，或者 `ml/` 放在別的地方：`mlSubjectMask.config({ base: "相對或絕對路徑/ml/" })`。

## 3. 修改 kidart.html 的程式碼（降級順序：ML → 顏色法 → plainCraft）

```js
// ---- ML 遮罩快取（每張照片只算一次；拉「靈敏度」滑桿時不重算） ----
S.ml = null; S.mlFor = null;
async function ensureML() {
  if (S.mode !== "craft" || !S.src || S.mlFor === S.src) return;
  const src = S.src; setBusy(true);
  let r = null; try { r = await mlSubjectMask(src); } catch (e) { r = null; }
  if (S.src === src) { S.ml = r; S.mlFor = src; }   // 等待期間使用者可能已經換了照片
  setBusy(false);
}

// 取代第 1365 行原本的 buildCraft（仍然是同步函式，所以 later()/滑桿的呼叫端都不用改）
function buildCraft() {
  const ml = S.mlFor === S.src ? S.ml : null;
  let m = null;
  if (ml) { try { m = craftMaskML(S.src, S.params.sens, ml); } catch (e) { m = null; } }
  if (!m) m = craftMask(S.src, S.params.sens);          // 顏色法（不變）
  const alphaBase = m.ml ? craftAlphaML(S.src, m) : craftAlpha(S.src, m);
  S.craft = { m, alphaBase, fallback: m.fallback, edge: m.edge, info: m.info, ml: !!m.ml };
}
```

- `craftMaskML` 會自己決定要不要相信 ML：遮罩太小或太大（< 1 % 或 > 92 %）、結果模稜兩可（平均 |2P−1| < 0.55），
  或者 ML 只抓到顏色法找到的物體的一部分時，它會原封不動地回傳 `craftMask()` 的結果（`m.ml === false`）。
  顏色法失敗時（`m.fallback`），`composeCraft()` 照舊呼叫 `plainCraft()`。這樣降級順序就是
  **ML 融合 → 顏色法 → 原照片**，而且 `mlSubjectMask` 失敗時一律回傳 `null`，不會丟出例外。
- 在 `loadSource()`（第 1361 行）和 `setMode()`（第 1673 行）裡，在 `await later(...)` 之前加上
  `if (S.mode === "craft") await ensureML();`（setMode 裡要用新模式 `m`：
  `if (m === "craft") await ensureML();`）。
- 第 1708 行的靈敏度滑桿不用改：`buildCraft()` 會重用快取的 ML 遮罩，`sens` 只影響顏色法那部分（細長部件）。
- 預先載入：使用者切到勞作模式或按下快門／相簿按鈕時，呼叫 `mlPreload()`
  （例如在 `setPick("craft")` 裡和 `$("shutter").onclick` 裡）。這會先下載並初始化（約 19.5 MB，之後走 HTTP 快取），
  不會阻塞 UI。
- 釋放記憶體：在 `showHome()` 裡，以及 `window.addEventListener("pagehide", mlDispose)` 時呼叫 `mlDispose()`。
  這會釋放 worker（RSS 約 −170 MB）。下次使用會重新初始化（約 1 秒，檔案已在快取裡）。
- 提示文字（選用）：在 `processNote()` 裡，`S.craft.ml` 為 true 時可以加上「AI 去背」之類的說明。
  ML 沒採用的原因可以從 `S.craft.m.mlInfo`（`trust` / `partial` / `dec`）看到。
- 建議預設值（已寫在 `segment.js`）：`size: 224`，`tta: false`。
- 已驗證：把上面的修改套到 kidart.html 的一份副本上（scratchpad `ml/site/integrated.html`，產生方式見 `ml/inttest.js`），
  走 `loadSource()` 勞作模式處理 LEGO 照片：`S.craft.ml === true`，沒有 page error，總時間 2.9 s（含冷啟動）。

### 融合邏輯（`fuse.js` 檔頭也有完整說明）
在 craftMask 的約 256 px 網格上：
1. `P` = ML 機率，雙線性重取樣（ML 遮罩是整張照片被壓成 224×224）。`core = P > 0.5`，做半徑 1 的開運算，
   去掉小於最大塊 15 % 的碎塊。
2. 信任檢查：`1 % ≤ 面積 ≤ 92 %` 且平均 `|2P−1| ≥ 0.55`。不通過就用顏色法。
3. 「ML 只抓到一部分」：顏色結果正常、包含 core 的 85 % 以上，而且面積是 core 的 2.5 倍以上時，用顏色法。
4. 細長部件補回：`A = (顏色軟遮罩 > 0.15) \ core`。A 的某一塊若同時符合「距 core 2 px 內」、
   「至少 30 % 的像素離 core 超過 3 px（排除陰影光暈）」、「做 5×5 侵蝕後剩下的不超過 25 %（是線不是塊）」，
   就併入。這能補回腳、天線、吸管、毛根，但不會把桌面花紋或另一張紙這類大塊黏進來。
5. `F = blur1(把 core 中小於 0.3 % 的洞補起來)`；拱門、圓環這類大洞保留。add 區域則提高到 `min(1, 1.5·顏色遮罩)`。
6. 全解析度 alpha：`v ≥ .98 → 255`、`v ≤ .02 → 0`。中間的過渡帶：
   - 從顏色法補回的部件，沿用原本的顏色距離邊緣（`ad·0.65 + v·0.35`），在純色桌面上很銳利；
   - 其他像素用彩色 guided filter（He et al.）：在 ≤768 px 的縮圖上計算，半徑約為長邊的 0.6 %，eps 1e-3，
     放大後用 `smoothstep(0.3, 0.7)` 收邊。這樣 224 px 的 ML 輪廓會貼齊照片中真正的邊緣，而且完全不依賴
     （在大理石上不可靠的）桌面顏色模型。

## 4. 實測結果（headless Chromium，Xeon 2.8 GHz，wasm 單執行緒 SIMD）

IoU 是以 alpha > 128 和 GT 在全解析度計算。真實照片沒有 GT，改用 IS-Net 1024 px 的輸出當參考答案
（只能當參考，IS-Net 本身也漏掉了白色旗桿）。

| 案例 | (a) 顏色法 | (b) ML 單獨 | (c) 融合 |
|---|---|---|---|
| LEGO／大理石（真實，相對 IS-Net） | 0.707（米色、粉紅、白、淡紫積木被挖掉） | 0.963 | **0.969** |
| 旗子／大理石（真實，相對 IS-Net） | 0.966（上緣珠子被削掉） | 0.964（邊緣較軟） | 0.964（邊緣銳利） |
| touchEdge（合成） | 0.953 | 0.993 | **0.998** |
| whiteClay | 0.868 | 0.912 | **0.917** |
| texture | 0.772 | 0.986 | **0.995** |
| thin（細腳召回率） | 0.920（1.00） | 0.750（0.00） | 0.894（**1.00**） |
| busy（花桌布） | 0.079（退回原照片） | 0.968 | **0.976** |

輸入尺寸的影響：在 320 px（模型原本的訓練尺寸）時，touchEdge 只有 0.17（只抓到頭）、texture 只有 0.75；
224 px 時是 0.99 和 0.99，速度約快 2 倍，峰值 wasm heap 從 175 MB 降到 111 MB。所以預設用 224。
在 320 px 時，融合的「ML 只抓到一部分」規則能把 touchEdge 救回 0.953（顏色法）。

時間：冷啟動初始化（本機 HTTP 抓檔 + 建立 session）約 0.9–1.0 s，加上第一次推論約 1.3 s。
熱推論 1.25–1.35 s（224 px）。融合（遮罩 + alpha，2400×1800）約 0.3–0.7 s，顏色法本身 0.1–0.25 s。
iPhone 上估計推論 1–3 s（未實機測過）；第一次需要下載約 19.5 MB（gzip 後約 8 MB）。
記憶體：wasm heap 峰值 111 MB。renderer RSS 增量：只跑顏色法時 +96 MB；加上 ML 和融合後再 +220 MB（峰值）；
呼叫 `mlDispose()` 後回到只跑顏色法的水準。

測試程式在 scratchpad 的 `ml/`：`eval.js`（三種方法比較 + 計時）、`memtest.js`、`failtest.js`、
`export_cases.js`。它們需要 `ml/site/` 的 http server（`python3 -m http.server 8765`）。

## 5. 已知限制
- U²-Netp 是「顯著物體」模型：照片裡有兩個以上同樣顯眼的東西（手機、杯子、手）時，它可能把它們也當成主體，
  或者只挑其中一個。細長部件（< 約 1 % 畫面寬）它看不到，靠顏色法補回，但只限顏色法本身能正常運作的桌面。
- 旗子底下的白色塑膠旗桿（白色、碰到照片邊緣、在白色大理石上）三種方法都丟掉了。
- 沒有在 iOS Safari 上實機測過。ORT 1.31 的 threaded wasm 在 numThreads=1、不需要 SAB 的情況下可以執行
  （Chromium 已驗證）；Safari 18 應該一樣，但請在實機上確認。
- 更大的模型：silueta（u2net 的 int8 版，44 MB，Apache-2.0 衍生，但作者沒有明確標示授權）
  和 IS-Net（npm `@wepkg/isnet*`，176 MB fp32、44 MB quint8，來源看起來是 IMG.LY 的轉檔，授權不明）。
  它們在合成案例上更好（IS-Net 的細腳也抓得到），但都超過 25 MB，在手機上也慢 2–5 倍，所以沒有採用。

## 6. 對應到原生 iOS app
原生 app 用 Vision 的 `VNGenerateForegroundInstanceMaskRequest`（iOS 17+），web 的 ML 模型只給原型用。對應關係如下：

| web 原型 | iOS 原生 |
|---|---|
| `mlSubjectMask(canvas)` → 224² 機率圖 | `VNImageRequestHandler(cgImage:orientation:)` + `VNGenerateForegroundInstanceMaskRequest`；`observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)` → 全解析度軟遮罩 `CVPixelBuffer`（Float32/OneComponent8） |
| 信任檢查（面積 1–92 %、果斷度） | `results` 為空或沒有 instance → 走顏色法；面積同樣檢查 |
| `craftMaskML` 的細部補回 | 可選：Vision 的遮罩通常已經包含細部，先不做；如果實測發現細腳掉了，再移植第 4 步（同一套形態學規則） |
| `craftAlphaML`（guided filter 修邊） | 不需要：Vision 輸出就是全解析度、貼合邊緣的遮罩。直接當 alpha（`CIBlendWithMask` 或 `CIFilter.blendWithMask()`） |
| `craftMask/craftAlpha`（顏色法） | 移植成 Swift／Accelerate 版，當 Vision 沒結果時的備援 |
| `plainCraft()` | 同樣保留原照片（略微提亮） |
| 多個物體 | `allInstances` 合併（勞作常是多件組合，例如 LEGO 場景）；之後可以讓使用者點選 instance（`instanceMask` 的 label） |

注意：Vision 這個 request 在模擬器上可能沒有結果或很慢，請用實機測試。它在 Neural Engine 上執行，一般不到 0.3 s。
