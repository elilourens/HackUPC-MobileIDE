"""AI tool template: hero + live demo block + before/after + integrations grid."""

TEMPLATE_ID = "ai_tool"
DESCRIPTION = "AI tool showcase: hero, interactive demo mockup, before/after comparison, integrations grid."
SPEC_SCHEMA_HINT = """
{
  "tool_name": "string",
  "tagline": "string",
  "hero_headline": "string",
  "hero_subheadline": "string",
  "demo_input_placeholder": "string",
  "demo_output_sample": "string",
  "before_title": "string",
  "before_description": "string",
  "after_title": "string",
  "after_description": "string",
  "integrations": ["string", ...6],
  "primary_cta": "string",
  "secondary_cta": "string",
  "theme": "dark|indigo|emerald|rose|amber|sky"
}
"""


def render(spec: dict) -> dict[str, str]:
    """Render an AI tool landing page."""

    tool_name = spec.get("tool_name") or "DataMind"
    tagline = spec.get("tagline") or "AI that understands your data"
    hero_headline = spec.get("hero_headline") or "Understand data like never before"
    hero_subheadline = (
        spec.get("hero_subheadline")
        or "Upload a CSV, ask a question in plain English, and get insights instantly. No coding required."
    )
    demo_input_placeholder = spec.get("demo_input_placeholder") or "What's the revenue trend this year?"
    demo_output_sample = spec.get("demo_output_sample") or "Revenue up 24% YoY, with peak in Q3 at $2.4M"

    before_title = spec.get("before_title") or "Before"
    before_description = (
        spec.get("before_description")
        or "Hours spent wrangling spreadsheets, writing SQL queries, waiting for dashboards to load."
    )
    after_title = spec.get("after_title") or "After"
    after_description = (
        spec.get("after_description")
        or "Ask a question. Get an answer in seconds. Find insights you didn't even know to ask for."
    )

    integrations = spec.get("integrations") or [
        "Slack",
        "Google Sheets",
        "Salesforce",
        "HubSpot",
        "Stripe",
        "PostgreSQL",
    ]

    primary_cta = spec.get("primary_cta") or "Start free"
    secondary_cta = spec.get("secondary_cta") or "See demo"

    # Theme colors
    theme = spec.get("theme", "indigo").lower()
    theme_map = {
        "indigo": ("indigo-500", "indigo-600"),
        "emerald": ("emerald-500", "emerald-600"),
        "rose": ("rose-500", "rose-600"),
        "amber": ("amber-500", "amber-600"),
        "sky": ("sky-500", "sky-600"),
        "dark": ("blue-500", "blue-600"),
    }
    accent_light, accent_dark = theme_map.get(theme, theme_map["indigo"])

    # Build integrations HTML
    integrations_html = ""
    for integration in integrations[:6]:
        integrations_html += f"""
    <div class="flex items-center justify-center p-6 rounded-lg border border-neutral-800 hover:border-neutral-700 transition-colors bg-neutral-900 bg-opacity-30">
      <p class="text-neutral-300 font-medium">{integration}</p>
    </div>"""

    app_jsx = f'''function Hero() {{
  return (
    <section class="min-h-screen bg-neutral-950 flex items-center justify-center px-6 py-32">
      <div class="max-w-6xl mx-auto">
        <div class="text-center mb-12">
          <p class="text-{accent_light} text-sm font-semibold uppercase tracking-widest mb-4">{tool_name}</p>
          <h1 class="text-6xl md:text-7xl font-bold tracking-tight text-neutral-50 mb-6">{hero_headline}</h1>
          <p class="text-xl text-neutral-400 max-w-3xl mx-auto leading-relaxed mb-8">{hero_subheadline}</p>
          <div class="flex flex-col sm:flex-row gap-4 justify-center">
            <button class="bg-{accent_light} hover:bg-{accent_dark} text-neutral-950 font-semibold px-8 py-3 rounded-lg transition-colors">{primary_cta}</button>
            <button class="border border-neutral-700 hover:border-neutral-600 text-neutral-50 font-semibold px-8 py-3 rounded-lg transition-colors">{secondary_cta}</button>
          </div>
        </div>
      </div>
    </section>
  );
}}

function DemoBlock() {{
  return (
    <section class="py-24 bg-neutral-950 px-6">
      <div class="max-w-4xl mx-auto">
        <div class="rounded-2xl border border-neutral-800 bg-neutral-900 overflow-hidden shadow-2xl">
          <div class="bg-neutral-800 border-b border-neutral-700 px-6 py-4 flex gap-2">
            <div class="w-3 h-3 rounded-full bg-neutral-600"></div>
            <div class="w-3 h-3 rounded-full bg-neutral-600"></div>
            <div class="w-3 h-3 rounded-full bg-neutral-600"></div>
          </div>
          <div class="p-8">
            <p class="text-sm text-neutral-500 mb-4">Ask anything about your data</p>
            <div class="bg-neutral-800 rounded-lg p-4 mb-6">
              <p class="text-neutral-50 font-mono text-sm">> {demo_input_placeholder}</p>
            </div>
            <div class="bg-{accent_light} bg-opacity-10 border border-{accent_light} border-opacity-30 rounded-lg p-4">
              <p class="text-{accent_light} font-mono text-sm font-semibold">{demo_output_sample}</p>
            </div>
            <p class="text-neutral-500 text-xs mt-4">Response generated in 0.8s</p>
          </div>
        </div>
      </div>
    </section>
  );
}}

function BeforeAfter() {{
  return (
    <section class="py-24 bg-neutral-950 px-6">
      <div class="max-w-6xl mx-auto">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-8">
          <div class="rounded-2xl border border-neutral-800 bg-neutral-900 bg-opacity-50 p-12 text-center">
            <div class="w-16 h-16 rounded-full bg-neutral-800 flex items-center justify-center mx-auto mb-6">
              <span class="text-2xl">⏱️</span>
            </div>
            <h3 class="text-2xl font-bold text-neutral-50 mb-4">{before_title}</h3>
            <p class="text-neutral-400 leading-relaxed">{before_description}</p>
          </div>
          <div class="rounded-2xl border border-{accent_light} border-opacity-50 bg-{accent_light} bg-opacity-5 p-12 text-center">
            <div class="w-16 h-16 rounded-full bg-{accent_light} bg-opacity-20 flex items-center justify-center mx-auto mb-6">
              <span class="text-2xl">⚡</span>
            </div>
            <h3 class="text-2xl font-bold text-neutral-50 mb-4">{after_title}</h3>
            <p class="text-neutral-400 leading-relaxed">{after_description}</p>
          </div>
        </div>
      </div>
    </section>
  );
}}

function Integrations() {{
  return (
    <section class="py-24 bg-neutral-950 px-6">
      <div class="max-w-6xl mx-auto">
        <div class="text-center mb-16">
          <h2 class="text-4xl md:text-5xl font-bold tracking-tight text-neutral-50 mb-4">Works with your tools</h2>
          <p class="text-lg text-neutral-400">Integrates seamlessly with platforms you already use</p>
        </div>
        <div class="grid grid-cols-2 md:grid-cols-3 gap-6">{integrations_html}
        </div>
      </div>
    </section>
  );
}}

function CTA() {{
  return (
    <section class="py-24 bg-neutral-900 px-6">
      <div class="max-w-4xl mx-auto text-center">
        <h2 class="text-4xl md:text-5xl font-bold tracking-tight text-neutral-50 mb-6">Ready to transform your data?</h2>
        <button class="bg-{accent_light} hover:bg-{accent_dark} text-neutral-950 font-semibold px-8 py-4 rounded-lg transition-colors text-lg">{primary_cta}</button>
      </div>
    </section>
  );
}}

function App() {{
  return (
    <div class="bg-neutral-950">
      <Hero />
      <DemoBlock />
      <BeforeAfter />
      <Integrations />
      <CTA />
    </div>
  );
}}
'''

    return {
        "package.json": """{
  "name": "ai-tool",
  "type": "module",
  "version": "1.0.0",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.2.0",
    "react-dom": "^18.2.0"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^4.2.0",
    "vite": "^5.0.0"
  }
}""",
        "vite.config.js": """import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [react()],
  server: { port: 5173 },
});
""",
        "index.html": """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>AI Tool</title>
  <script src="https://cdn.tailwindcss.com"></script>
</head>
<body>
  <div id="root"></div>
  <script type="module" src="/src/main.jsx"></script>
</body>
</html>
""",
        "src/main.jsx": """import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
""",
        "src/App.jsx": app_jsx,
        "src/index.css": "@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');",
        "README.md": f"""# {tool_name}

{hero_subheadline}

## Start

```bash
npm install
npm run dev
```

Open http://localhost:5173.

## Build

```bash
npm run build
```
""",
    }
