import Foundation

/// JetBrains-style splash page used as the default content for `index.html`.
/// Rendered in the WKWebView preview the moment the app opens — gives the
/// demo a real, polished landing instead of an empty editor.
///
/// The layout deliberately mirrors jetbrains.com: black bg with a teal radial
/// spotlight in the hero, JetBrains nav bar, huge Inter-Display headline,
/// and a "Featured" product card showcasing ArcReact alongside IntelliJ /
/// PyCharm / WebStorm / DataGrip / Rider.
enum StarterPage {
    static let html: String = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<title>ArcReact — JetBrains</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&display=swap" rel="stylesheet">
<style>
  :root {
    --bg: #000000;
    --bg-card: #19193e;
    --bg-card-inner: #2a2a5a;
    --teal: #1cc4b8;
    --teal-2: #0e8a87;
    --text: #ffffff;
    --text-dim: rgba(255,255,255,0.72);
    --text-faint: rgba(255,255,255,0.45);
    --violet: #7c5cff;
    --jb-orange: #ff7937;
    --jb-pink: #f64ea2;
    --jb-red: #ee2746;
    --jb-yellow: #fcf84a;
  }

  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; }
  body {
    background: var(--bg);
    color: var(--text);
    font-family: 'Inter', -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
    font-feature-settings: "ss01", "cv01";
    -webkit-font-smoothing: antialiased;
    overflow-x: hidden;
  }

  a { color: inherit; text-decoration: none; }

  /* ─────────────── NAV ─────────────── */
  .nav {
    position: sticky;
    top: 0;
    z-index: 50;
    display: flex;
    align-items: center;
    gap: 28px;
    padding: 16px 28px;
    background: rgba(0,0,0,0.85);
    backdrop-filter: blur(8px);
    border-bottom: 1px solid rgba(255,255,255,0.04);
  }
  .nav-brand {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-right: 12px;
  }
  .jb-cube {
    width: 28px; height: 28px;
    position: relative;
    flex-shrink: 0;
  }
  .jb-cube::before, .jb-cube::after {
    content: '';
    position: absolute;
    width: 18px; height: 18px;
    border-radius: 4px;
  }
  .jb-cube::before {
    top: 0; left: 0;
    background: linear-gradient(135deg, var(--jb-pink) 0%, var(--jb-red) 60%, var(--jb-orange) 100%);
  }
  .jb-cube::after {
    bottom: 0; right: 0;
    background: linear-gradient(135deg, var(--jb-orange) 0%, var(--jb-yellow) 100%);
    mix-blend-mode: screen;
  }
  .nav-brand-text {
    font-weight: 800;
    letter-spacing: 1.5px;
    font-size: 15px;
  }
  .nav-links {
    display: flex;
    gap: 28px;
    font-size: 14px;
    color: var(--text);
    flex: 1;
  }
  .nav-links span { cursor: default; opacity: 0.92; }
  .nav-icons {
    display: flex;
    gap: 16px;
    color: var(--text-dim);
    font-size: 14px;
  }
  .nav-icons span { cursor: default; }

  /* ─────────────── HERO ─────────────── */
  .hero {
    position: relative;
    padding: 96px 24px 64px;
    text-align: center;
    overflow: hidden;
    isolation: isolate;
  }
  .hero::before {
    /* Teal radial spotlight from the top — this is the signature jetbrains.com look */
    content: '';
    position: absolute;
    inset: -10%;
    background: radial-gradient(60% 70% at 50% 18%, rgba(28,196,184,0.55) 0%, rgba(14,138,135,0.18) 35%, transparent 70%);
    z-index: -1;
  }
  .hero-eyebrow {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 6px 12px;
    border: 1px solid rgba(255,255,255,0.18);
    border-radius: 999px;
    font-size: 12px;
    font-weight: 600;
    letter-spacing: 0.6px;
    color: var(--text-dim);
    margin-bottom: 26px;
  }
  .hero-eyebrow .new-pill {
    padding: 2px 8px;
    border-radius: 999px;
    background: var(--teal);
    color: #001a18;
    font-weight: 800;
    font-size: 10px;
    letter-spacing: 0.8px;
  }
  .hero h1 {
    font-size: clamp(40px, 7vw, 84px);
    line-height: 0.98;
    font-weight: 800;
    letter-spacing: -0.02em;
    margin: 0 auto;
    max-width: 14ch;
  }
  .hero-sub {
    margin-top: 22px;
    font-size: clamp(14px, 1.2vw, 18px);
    color: var(--text-dim);
    font-weight: 400;
  }
  .hero-cta {
    margin-top: 36px;
    display: inline-flex;
    align-items: center;
    gap: 10px;
    padding: 14px 22px;
    background: var(--text);
    color: #000;
    border-radius: 8px;
    font-weight: 700;
    font-size: 14px;
  }

  /* ─────────────── PRODUCT MOCK CARD ─────────────── */
  .ide-mock {
    margin: 56px auto 0;
    max-width: 880px;
    aspect-ratio: 16 / 9;
    border-radius: 14px;
    background: #0e0f12;
    border: 1px solid rgba(255,255,255,0.08);
    box-shadow: 0 20px 60px rgba(0,0,0,0.6);
    overflow: hidden;
    position: relative;
  }
  .ide-titlebar {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 10px 14px;
    background: #18191c;
    border-bottom: 1px solid rgba(255,255,255,0.06);
    font-size: 11px;
    color: var(--text-dim);
  }
  .ide-titlebar .sticker {
    width: 16px; height: 16px;
    border-radius: 4px;
    background: linear-gradient(135deg, var(--teal) 0%, #4f7cff 100%);
  }
  .ide-body {
    display: grid;
    grid-template-columns: 220px 1fr;
    height: calc(100% - 36px);
  }
  .ide-side {
    background: #131418;
    padding: 12px 10px;
    font-size: 11px;
    color: var(--text-faint);
    line-height: 1.7;
    border-right: 1px solid rgba(255,255,255,0.04);
  }
  .ide-side div { padding: 2px 8px; }
  .ide-side .file-active { background: rgba(28,196,184,0.12); color: var(--teal); border-radius: 4px; }
  .ide-code {
    padding: 16px 18px;
    font-family: "JetBrains Mono", "SF Mono", Menlo, monospace;
    font-size: 12px;
    line-height: 1.6;
    color: #bcbec4;
    white-space: pre;
    overflow: hidden;
  }
  .kw  { color: #cc7832; }
  .str { color: #6a8759; }
  .fn  { color: #ffc66d; }
  .com { color: #808080; }
  .num { color: #6897bb; }

  /* ─────────────── FEATURED ─────────────── */
  .section { padding: 72px 24px; }
  .section-inner { max-width: 1080px; margin: 0 auto; }
  .featured-eyebrow {
    color: var(--violet);
    font-weight: 700;
    font-size: 14px;
    letter-spacing: -0.005em;
    margin-bottom: 8px;
  }
  .featured-eyebrow .braces { color: var(--violet); }
  .featured-h2 {
    font-size: clamp(32px, 5vw, 56px);
    font-weight: 800;
    letter-spacing: -0.02em;
    line-height: 1.05;
    margin: 0 0 36px;
  }
  .featured-card {
    background: var(--bg-card);
    border-radius: 18px;
    padding: 32px 28px;
    position: relative;
  }
  .featured-tab {
    position: absolute;
    top: 28px; left: -10px;
    background: rgba(124,92,255,0.5);
    color: rgba(255,255,255,0.85);
    padding: 4px 7px 4px 9px;
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.5px;
    writing-mode: vertical-rl;
    transform: rotate(180deg);
    border-radius: 3px;
  }
  .featured-card h3 {
    font-size: clamp(20px, 2.4vw, 28px);
    font-weight: 700;
    margin: 0 0 22px;
    color: var(--text);
    line-height: 1.2;
  }
  .product-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
    gap: 14px;
  }
  .product-card {
    background: var(--bg-card-inner);
    border-radius: 12px;
    padding: 22px 20px;
    position: relative;
    min-height: 130px;
    display: flex;
    flex-direction: column;
    justify-content: flex-end;
  }
  .product-card .pill {
    position: absolute;
    top: 14px; right: 14px;
    background: rgba(124,92,255,0.4);
    color: rgba(255,255,255,0.85);
    font-size: 10px;
    font-weight: 600;
    padding: 4px 8px;
    border-radius: 999px;
  }
  .sticker {
    width: 52px; height: 52px;
    border-radius: 8px;
    margin-bottom: 14px;
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    color: #fff;
    font-weight: 800;
    font-size: 14px;
    letter-spacing: -0.01em;
    overflow: hidden;
  }
  .sticker::after {
    content: '';
    position: absolute; inset: auto 0 0 0;
    height: 6px;
    background: linear-gradient(90deg, currentColor, transparent);
    opacity: 0.6;
  }
  /* Per-product gradients matching jetbrains.com palette */
  .stk-arc  { background: linear-gradient(135deg, #1cc4b8 0%, #4f7cff 60%, #7c5cff 100%); }
  .stk-ij   { background: linear-gradient(135deg, #ff7937 0%, #f64ea2 50%, #ee2746 100%); }
  .stk-pc   { background: linear-gradient(135deg, #21d789 0%, #fcf84a 50%, #07c3f2 100%); }
  .stk-ws   { background: linear-gradient(135deg, #fcf84a 0%, #21d789 50%, #07c3f2 100%); }
  .stk-dg   { background: linear-gradient(135deg, #21d789 0%, #ff318c 100%); }
  .stk-rd   { background: linear-gradient(135deg, #c91f37 0%, #ff318c 50%, #fcf84a 100%); }

  .product-card .name {
    font-size: 15px;
    font-weight: 700;
    color: var(--text);
    margin-bottom: 4px;
  }
  .product-card .desc {
    font-size: 12px;
    color: var(--text-dim);
    line-height: 1.4;
  }

  .explore {
    margin-top: 22px;
    color: var(--text-dim);
    font-size: 13px;
  }
  .explore::after { content: ' →'; color: var(--text); }

  /* ─────────────── FOOTER ─────────────── */
  .footer {
    padding: 48px 24px 64px;
    text-align: center;
    color: var(--text-faint);
    font-size: 12px;
    letter-spacing: 0.4px;
    border-top: 1px solid rgba(255,255,255,0.04);
  }
  .footer .pill-jb {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 6px 12px;
    border: 1px solid rgba(255,255,255,0.14);
    border-radius: 999px;
    color: var(--text-dim);
    margin-bottom: 14px;
  }
  .footer .pill-jb .dot {
    width: 8px; height: 8px;
    border-radius: 2px;
    background: linear-gradient(135deg, var(--jb-pink), var(--jb-orange));
  }

  @media (max-width: 720px) {
    .nav-links { display: none; }
    .ide-body { grid-template-columns: 140px 1fr; }
  }
</style>
</head>
<body>

<!-- ─── NAV ─── -->
<nav class="nav">
  <div class="nav-brand">
    <div class="jb-cube"></div>
    <span class="nav-brand-text">JETBRAINS</span>
  </div>
  <div class="nav-links">
    <span>Products</span>
    <span>For Business</span>
    <span>Education</span>
    <span>Solutions</span>
    <span>Support</span>
    <span>Store</span>
  </div>
  <div class="nav-icons">
    <span>⌕</span>
    <span>◐</span>
    <span>⌗</span>
    <span>文A</span>
  </div>
</nav>

<!-- ─── HERO ─── -->
<section class="hero">
  <div class="hero-eyebrow">
    <span class="new-pill">NEW</span>
    <span>Introducing ArcReact</span>
  </div>
  <h1>Code anywhere.<br>Even on your desk.</h1>
  <p class="hero-sub">The first AR-native IDE from JetBrains. Your workspace becomes the canvas.</p>
  <a class="hero-cta">Open ArcReact ↗</a>

  <!-- IDE mock screenshot (faux) -->
  <div class="ide-mock">
    <div class="ide-titlebar">
      <div class="sticker"></div>
      <span>ArcReact &middot; index.html</span>
    </div>
    <div class="ide-body">
      <div class="ide-side">
        <div>my-app</div>
        <div class="file-active">⬢ index.html</div>
        <div>⬢ styles.css</div>
        <div>⬢ app.js</div>
      </div>
      <div class="ide-code"><span class="com">// shake your phone to enter AR</span>
<span class="kw">import</span> { <span class="fn">createApp</span> } <span class="kw">from</span> <span class="str">'arcreact'</span>

<span class="kw">const</span> app = <span class="fn">createApp</span>({
  surface: <span class="str">'desk'</span>,
  panels:  [<span class="str">'editor'</span>, <span class="str">'preview'</span>, <span class="str">'agent'</span>],
  ai:      <span class="str">'junie'</span>
})

app.<span class="fn">run</span>()
</div>
    </div>
  </div>
</section>

<!-- ─── FEATURED ─── -->
<section class="section">
  <div class="section-inner">
    <div class="featured-eyebrow">For <span class="braces">{developers}</span></div>
    <h2 class="featured-h2">Enjoy building software<br>in space and on screen.</h2>

    <div class="featured-card">
      <div class="featured-tab">Featured</div>
      <h3>A rich suite of tools that provide an exceptional developer experience</h3>

      <div class="product-grid">

        <div class="product-card">
          <span class="pill">NEW</span>
          <div class="sticker stk-arc">AR</div>
          <div class="name">ArcReact</div>
          <div class="desc">AR-native IDE for spatial coding</div>
        </div>

        <div class="product-card">
          <div class="sticker stk-ij">IJ</div>
          <div class="name">IntelliJ IDEA</div>
          <div class="desc">IDE for Java and Kotlin</div>
        </div>

        <div class="product-card">
          <div class="sticker stk-pc">PC</div>
          <div class="name">PyCharm</div>
          <div class="desc">IDE for Python</div>
        </div>

        <div class="product-card">
          <span class="pill">Free for non-commercial use</span>
          <div class="sticker stk-ws">WS</div>
          <div class="name">WebStorm</div>
          <div class="desc">IDE for JavaScript</div>
        </div>

        <div class="product-card">
          <div class="sticker stk-dg">DG</div>
          <div class="name">DataGrip</div>
          <div class="desc">Tool for multiple databases</div>
        </div>

        <div class="product-card">
          <span class="pill">Free for non-commercial use</span>
          <div class="sticker stk-rd">RD</div>
          <div class="name">Rider</div>
          <div class="desc">IDE for .NET and game dev</div>
        </div>

      </div>

      <div class="explore">Explore JetBrains IDEs and code authoring tools</div>
    </div>
  </div>
</section>

<!-- ─── FOOTER ─── -->
<footer class="footer">
  <div class="pill-jb"><span class="dot"></span><span>A JetBrains Product</span></div>
  <div>ArcReact &copy; JetBrains s.r.o. — Built with Junie AI</div>
</footer>

</body>
</html>
"""#
}
