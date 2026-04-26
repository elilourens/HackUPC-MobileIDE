import Foundation

/// Hardcoded Iron Man tribute page used by the "daddy's home" easter egg.
/// Self-contained: Tailwind via CDN, Iron-Man imagery from Wikimedia/TMDB
/// (hot-link-friendly hosts), inline SVG arc reactor for accents. No build
/// step, no JS dependencies — drops straight into the preview WebView and
/// renders as a polished black/hot-rod-red Stark Industries landing page.
enum StarkTributePage {
    static let html: String = #"""
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>STARK INDUSTRIES — The OG Vibe Coder</title>
      <script src="https://cdn.tailwindcss.com"></script>
      <link rel="preconnect" href="https://fonts.googleapis.com" />
      <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
      <link href="https://fonts.googleapis.com/css2?family=Orbitron:wght@500;700;900&family=Inter:wght@400;500;700&display=swap" rel="stylesheet" />
      <style>
        :root {
          --hot-rod: #c8102e;
          --hot-rod-glow: #ff2a44;
          --gold: #f4c430;
          --gold-soft: #ffd866;
          --void: #060608;
          --panel: #0d0d12;
          --grid: rgba(196, 22, 28, 0.18);
        }
        html, body { background: var(--void); color: #ededf2; font-family: 'Inter', sans-serif; }
        .display { font-family: 'Orbitron', sans-serif; letter-spacing: 0.04em; }
        .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }

        /* Background grid + scanlines for that Tony-Stark HUD feel. */
        .hud-bg {
          background-image:
            linear-gradient(var(--grid) 1px, transparent 1px),
            linear-gradient(90deg, var(--grid) 1px, transparent 1px),
            radial-gradient(circle at 50% 30%, rgba(255, 42, 68, 0.18), transparent 60%);
          background-size: 56px 56px, 56px 56px, 100% 100%;
        }

        /* Pulsing arc reactor at the hero. */
        .reactor { animation: pulse 2.4s ease-in-out infinite; }
        @keyframes pulse {
          0%, 100% { filter: drop-shadow(0 0 28px rgba(120, 220, 255, 0.55)); transform: scale(1); }
          50%      { filter: drop-shadow(0 0 56px rgba(120, 220, 255, 0.95)); transform: scale(1.04); }
        }

        /* HUD-style scanline sweep on hero card. */
        .scan {
          position: relative; overflow: hidden;
        }
        .scan::after {
          content: ""; position: absolute; inset: 0;
          background: linear-gradient(180deg, transparent 0%, rgba(255, 42, 68, 0.08) 50%, transparent 100%);
          transform: translateY(-100%);
          animation: sweep 3.2s ease-in-out infinite;
          pointer-events: none;
        }
        @keyframes sweep {
          0% { transform: translateY(-100%); }
          100% { transform: translateY(100%); }
        }

        .glow-text { text-shadow: 0 0 24px rgba(255, 42, 68, 0.45); }

        /* Stark-red corner brackets on cards. */
        .bracket { position: relative; }
        .bracket::before, .bracket::after {
          content: ""; position: absolute; width: 14px; height: 14px;
          border-color: var(--hot-rod-glow); border-style: solid;
        }
        .bracket::before { top: 0; left: 0; border-width: 1px 0 0 1px; }
        .bracket::after  { bottom: 0; right: 0; border-width: 0 1px 1px 0; }

        .photo-card { transition: transform .35s ease, box-shadow .35s ease; }
        .photo-card:hover { transform: translateY(-4px); box-shadow: 0 22px 48px rgba(200, 16, 46, 0.32); }
        .photo-card img { object-fit: cover; }
      </style>
    </head>
    <body class="min-h-screen">

      <!-- TOP NAV -->
      <header class="border-b border-red-900/40 bg-black/70 backdrop-blur sticky top-0 z-30">
        <div class="max-w-6xl mx-auto px-6 py-4 flex items-center justify-between">
          <div class="flex items-center gap-3">
            <svg viewBox="0 0 32 32" class="w-7 h-7 reactor">
              <defs>
                <radialGradient id="core" cx="50%" cy="50%" r="50%">
                  <stop offset="0%"  stop-color="#dffaff" />
                  <stop offset="40%" stop-color="#7ddcff" />
                  <stop offset="100%" stop-color="#1c5b8c" />
                </radialGradient>
              </defs>
              <circle cx="16" cy="16" r="14" fill="none" stroke="#7ddcff" stroke-width="0.6" opacity="0.4"/>
              <circle cx="16" cy="16" r="11" fill="none" stroke="#7ddcff" stroke-width="0.8" opacity="0.7"/>
              <circle cx="16" cy="16" r="7"  fill="url(#core)" />
              <g stroke="#bfeaff" stroke-width="0.8" opacity="0.85">
                <line x1="16" y1="3"  x2="16" y2="8" />
                <line x1="16" y1="29" x2="16" y2="24"/>
                <line x1="3"  y1="16" x2="8"  y2="16"/>
                <line x1="29" y1="16" x2="24" y2="16"/>
              </g>
            </svg>
            <span class="display text-white font-bold tracking-widest text-sm">STARK INDUSTRIES</span>
          </div>
          <nav class="hidden md:flex items-center gap-7 text-xs uppercase tracking-[0.2em] text-zinc-400">
            <a href="#suits" class="hover:text-red-400">Suits</a>
            <a href="#vibes" class="hover:text-red-400">Vibes</a>
            <a href="#timeline" class="hover:text-red-400">Timeline</a>
            <a href="#contact" class="hover:text-red-400">Contact</a>
          </nav>
          <div class="flex items-center gap-2 text-[11px] text-emerald-400 mono">
            <span class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse"></span>
            JARVIS · ONLINE
          </div>
        </div>
      </header>

      <!-- HERO -->
      <section class="hud-bg relative">
        <div class="max-w-6xl mx-auto px-6 pt-20 pb-24 grid md:grid-cols-2 gap-12 items-center">
          <div class="space-y-8">
            <div class="inline-flex items-center gap-2 text-[10px] uppercase tracking-[0.35em] text-red-400 mono">
              <span class="w-2 h-px bg-red-500"></span>
              EST. 1939 · CALIFORNIA
            </div>
            <h1 class="display text-5xl md:text-7xl font-black leading-[0.95] text-white glow-text">
              THE ORIGINAL<br/>
              <span class="text-red-500">VIBE CODER</span>
            </h1>
            <p class="text-lg text-zinc-300 max-w-md leading-relaxed">
              Forty years before the world ever heard the words <span class="text-amber-300">"prompt engineer"</span>,
              Anthony E. Stark was sketching repulsor schematics in a cave with a box of scraps and a JARVIS instance
              running on hand-built silicon. We've been vibe coding since you were watching cartoons.
            </p>
            <div class="flex flex-wrap gap-4 pt-2">
              <a href="#suits" class="inline-flex items-center gap-2 px-6 py-3 bg-red-600 text-white font-semibold tracking-wide uppercase text-xs hover:bg-red-500 transition">
                Browse the Suits
                <span aria-hidden>→</span>
              </a>
              <a href="#vibes" class="inline-flex items-center gap-2 px-6 py-3 border border-amber-400/60 text-amber-300 font-semibold tracking-wide uppercase text-xs hover:bg-amber-400/10 transition">
                Read the Code
              </a>
            </div>
            <div class="grid grid-cols-3 gap-6 pt-8 border-t border-red-900/40">
              <div>
                <div class="display text-3xl text-white">85+</div>
                <div class="text-[10px] uppercase tracking-[0.25em] text-zinc-500 mt-1">Mark Variants</div>
              </div>
              <div>
                <div class="display text-3xl text-white">3.2 GW</div>
                <div class="text-[10px] uppercase tracking-[0.25em] text-zinc-500 mt-1">Reactor Output</div>
              </div>
              <div>
                <div class="display text-3xl text-white">∞</div>
                <div class="text-[10px] uppercase tracking-[0.25em] text-zinc-500 mt-1">Loves You 3000</div>
              </div>
            </div>
          </div>

          <!-- HERO IMAGE -->
          <div class="scan bracket relative bg-black/50 p-3">
            <img
              src="https://upload.wikimedia.org/wikipedia/en/4/47/Iron_Man_bleeding_edge.jpg"
              alt="Iron Man — Bleeding Edge armor"
              loading="eager"
              class="w-full h-[520px] object-cover grayscale-[0.05] contrast-110"
              onerror="this.onerror=null; this.src='https://image.tmdb.org/t/p/original/78lPtwv72eTNqFW9COBYI0dWDJa.jpg';"
            />
            <div class="absolute top-5 left-5 text-[10px] mono text-red-400 tracking-widest">// LIVE FEED · BAY 04</div>
            <div class="absolute bottom-5 right-5 text-[10px] mono text-zinc-300 tracking-widest">MK · LXXXV</div>
          </div>
        </div>
      </section>

      <!-- SUITS GALLERY -->
      <section id="suits" class="border-y border-red-900/30 bg-[var(--panel)]/60">
        <div class="max-w-6xl mx-auto px-6 py-20">
          <div class="flex items-end justify-between mb-12">
            <div>
              <div class="text-[10px] uppercase tracking-[0.35em] text-red-400 mono mb-3">// HALL OF ARMOR</div>
              <h2 class="display text-4xl md:text-5xl font-bold text-white">SELECTED SUITS</h2>
            </div>
            <div class="hidden md:block text-xs text-zinc-500 mono">RENDERED FROM SCHEMATICS · STARK ARCHIVE</div>
          </div>

          <div class="grid md:grid-cols-3 gap-6">
            <!-- Mark III -->
            <article class="photo-card bracket bg-black/60 border border-red-900/30">
              <div class="aspect-[4/5] overflow-hidden">
                <img
                  src="https://upload.wikimedia.org/wikipedia/commons/thumb/4/40/Iron_Man_face.jpg/640px-Iron_Man_face.jpg"
                  alt="Mark III — Hot Rod Red"
                  loading="lazy"
                  class="w-full h-full"
                  onerror="this.onerror=null; this.src='https://image.tmdb.org/t/p/original/ny8EM7B4iiMv2cisuUkBM72M8eu.jpg';"
                />
              </div>
              <div class="p-5">
                <div class="text-[10px] mono text-red-400 tracking-widest mb-2">MK · III</div>
                <h3 class="display text-xl text-white mb-2">HOT ROD RED</h3>
                <p class="text-sm text-zinc-400 leading-relaxed">First flight-capable suit painted in racecar colors after Tony decided gunmetal silver was, and we quote, <em>"a little ostentatious."</em></p>
              </div>
            </article>

            <!-- Mark XLII -->
            <article class="photo-card bracket bg-black/60 border border-red-900/30">
              <div class="aspect-[4/5] overflow-hidden">
                <img
                  src="https://upload.wikimedia.org/wikipedia/commons/thumb/8/8a/Iron_Man_Mark_VII_3D_print.jpg/640px-Iron_Man_Mark_VII_3D_print.jpg"
                  alt="Mark XLII — Prodigal Son"
                  loading="lazy"
                  class="w-full h-full"
                  onerror="this.onerror=null; this.src='https://image.tmdb.org/t/p/original/cezWGskPY5x7GaglTTRN4Fugfb8.jpg';"
                />
              </div>
              <div class="p-5">
                <div class="text-[10px] mono text-red-400 tracking-widest mb-2">MK · XLII</div>
                <h3 class="display text-xl text-white mb-2">PRODIGAL SON</h3>
                <p class="text-sm text-zinc-400 leading-relaxed">Modular self-assembling armor controlled via subdermal nanite implants. The first suit a coder could literally summon.</p>
              </div>
            </article>

            <!-- Mark L -->
            <article class="photo-card bracket bg-black/60 border border-red-900/30">
              <div class="aspect-[4/5] overflow-hidden">
                <img
                  src="https://upload.wikimedia.org/wikipedia/commons/thumb/f/f9/Avengers_Iron_Man.jpg/640px-Avengers_Iron_Man.jpg"
                  alt="Mark L — Bleeding Edge"
                  loading="lazy"
                  class="w-full h-full"
                  onerror="this.onerror=null; this.src='https://image.tmdb.org/t/p/original/zoeGtv6BMbwRRRCwtcVdrwzjlBs.jpg';"
                />
              </div>
              <div class="p-5">
                <div class="text-[10px] mono text-red-400 tracking-widest mb-2">MK · L</div>
                <h3 class="display text-xl text-white mb-2">BLEEDING EDGE</h3>
                <p class="text-sm text-zinc-400 leading-relaxed">Nano-armor worn into Titan. 90% of its source-of-truth lived in a JARVIS branch with the commit message <span class="mono text-amber-300">"trust me bro"</span>.</p>
              </div>
            </article>
          </div>
        </div>
      </section>

      <!-- VIBES / QUOTES -->
      <section id="vibes" class="hud-bg">
        <div class="max-w-5xl mx-auto px-6 py-24 text-center space-y-10">
          <div class="text-[10px] uppercase tracking-[0.35em] text-red-400 mono">// PHILOSOPHY</div>
          <blockquote class="display text-3xl md:text-5xl font-bold text-white leading-tight glow-text max-w-3xl mx-auto">
            "Sometimes you gotta run<br class="hidden md:block"/> before you can walk."
          </blockquote>
          <div class="text-xs uppercase tracking-[0.4em] text-zinc-500 mono">— TONY STARK · 2008</div>

          <div class="grid md:grid-cols-3 gap-6 pt-12 text-left">
            <div class="bracket bg-black/50 p-6 border border-red-900/30">
              <div class="text-amber-300 display text-2xl mb-2">01</div>
              <h4 class="text-white font-semibold mb-2 tracking-wide">SHIP IT</h4>
              <p class="text-sm text-zinc-400 leading-relaxed">"I had a moment." Built a flight-capable suit out of cave parts in 8 weeks. PRs welcome, but the suit flies tonight.</p>
            </div>
            <div class="bracket bg-black/50 p-6 border border-red-900/30">
              <div class="text-amber-300 display text-2xl mb-2">02</div>
              <h4 class="text-white font-semibold mb-2 tracking-wide">PAIR WITH AI</h4>
              <p class="text-sm text-zinc-400 leading-relaxed">JARVIS handled the boilerplate. Tony handled the vibes. The original Cursor + Claude combo, just with more explosions.</p>
            </div>
            <div class="bracket bg-black/50 p-6 border border-red-900/30">
              <div class="text-amber-300 display text-2xl mb-2">03</div>
              <h4 class="text-white font-semibold mb-2 tracking-wide">BE THE BENCHMARK</h4>
              <p class="text-sm text-zinc-400 leading-relaxed">"I am Iron Man." Don't ship features. Ship identity. The product is the engineer wearing the suit.</p>
            </div>
          </div>
        </div>
      </section>

      <!-- TIMELINE -->
      <section id="timeline" class="border-t border-red-900/30 bg-[var(--panel)]/60">
        <div class="max-w-5xl mx-auto px-6 py-24">
          <div class="text-[10px] uppercase tracking-[0.35em] text-red-400 mono mb-3 text-center">// COMMIT LOG</div>
          <h2 class="display text-4xl text-white text-center mb-14">A FEW MAJOR COMMITS</h2>
          <ol class="relative border-l-2 border-red-700/50 ml-4 space-y-10">
            <li class="ml-8">
              <span class="absolute -left-[11px] w-5 h-5 rounded-full bg-red-600 ring-4 ring-black"></span>
              <div class="text-xs mono text-red-400">2008 · MK I</div>
              <div class="display text-xl text-white mt-1">First flight from a cave</div>
              <div class="text-sm text-zinc-400 mt-1">Built suit-of-armor v0 with Yinsen. <span class="mono text-amber-300">git init</span>, basically.</div>
            </li>
            <li class="ml-8">
              <span class="absolute -left-[11px] w-5 h-5 rounded-full bg-red-600 ring-4 ring-black"></span>
              <div class="text-xs mono text-red-400">2010 · MK VI</div>
              <div class="display text-xl text-white mt-1">Discovered a new element</div>
              <div class="text-sm text-zinc-400 mt-1">Synthesized vibranium-adjacent core to fix the palladium poisoning bug. Hot patch, no downtime.</div>
            </li>
            <li class="ml-8">
              <span class="absolute -left-[11px] w-5 h-5 rounded-full bg-red-600 ring-4 ring-black"></span>
              <div class="text-xs mono text-red-400">2012 · MK VII</div>
              <div class="display text-xl text-white mt-1">"Hello, Mr. Stark."</div>
              <div class="text-sm text-zinc-400 mt-1">Saved Manhattan from a portal. JARVIS shipped voice-driven dispatch in production.</div>
            </li>
            <li class="ml-8">
              <span class="absolute -left-[11px] w-5 h-5 rounded-full bg-red-600 ring-4 ring-black"></span>
              <div class="text-xs mono text-red-400">2018 · MK L</div>
              <div class="display text-xl text-white mt-1">Bleeding-Edge nano armor</div>
              <div class="text-sm text-zinc-400 mt-1">Pure on-device inference for suit transformation. Ahead of its time. Still is.</div>
            </li>
            <li class="ml-8">
              <span class="absolute -left-[11px] w-5 h-5 rounded-full bg-amber-400 ring-4 ring-black"></span>
              <div class="text-xs mono text-amber-300">2019 · FINAL DEPLOY</div>
              <div class="display text-xl text-white mt-1">"And… I… am… Iron Man."</div>
              <div class="text-sm text-zinc-400 mt-1">Snapped the universe back into a green build. Highest-impact commit in MCU history.</div>
            </li>
          </ol>
        </div>
      </section>

      <!-- CTA / FOOTER -->
      <section id="contact" class="hud-bg">
        <div class="max-w-4xl mx-auto px-6 py-24 text-center">
          <svg viewBox="0 0 32 32" class="w-16 h-16 mx-auto reactor">
            <defs>
              <radialGradient id="core2" cx="50%" cy="50%" r="50%">
                <stop offset="0%"  stop-color="#dffaff" />
                <stop offset="40%" stop-color="#7ddcff" />
                <stop offset="100%" stop-color="#1c5b8c" />
              </radialGradient>
            </defs>
            <circle cx="16" cy="16" r="14" fill="none" stroke="#7ddcff" stroke-width="0.4" opacity="0.4"/>
            <circle cx="16" cy="16" r="11" fill="none" stroke="#7ddcff" stroke-width="0.6" opacity="0.7"/>
            <circle cx="16" cy="16" r="7"  fill="url(#core2)" />
          </svg>
          <h3 class="display text-3xl md:text-4xl text-white mt-8">DADDY'S HOME.</h3>
          <p class="text-zinc-400 max-w-xl mx-auto mt-4 leading-relaxed">
            This page is a tribute. ArcReact is the spiritual successor — vibe coding in AR with JARVIS at your side.
            Wave a palm. Say "build me a landing page." Stark would've approved.
          </p>
          <div class="mt-10 inline-flex items-center gap-3 text-xs text-zinc-500 mono uppercase tracking-[0.3em]">
            <span class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse"></span>
            ArcReact · Powered by JARVIS · 2026
          </div>
        </div>
      </section>

      <footer class="border-t border-red-900/40 bg-black">
        <div class="max-w-6xl mx-auto px-6 py-6 flex flex-wrap items-center justify-between gap-4">
          <div class="text-[10px] uppercase tracking-[0.3em] text-zinc-500 mono">
            STARK INDUSTRIES · 10880 MALIBU PT · 90265
          </div>
          <div class="text-[10px] uppercase tracking-[0.3em] text-red-500 mono">
            "I AM IRON MAN."
          </div>
        </div>
      </footer>

    </body>
    </html>
    """#
}
