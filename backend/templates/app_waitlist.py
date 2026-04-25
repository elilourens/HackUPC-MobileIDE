"""App waitlist template: phone mockup + feature list + email signup."""

TEMPLATE_ID = "app_waitlist"
DESCRIPTION = "App launch waitlist: phone mockup, feature highlights, email signup form."
SPEC_SCHEMA_HINT = """
{
  "app_name": "string",
  "tagline": "string",
  "hero_headline": "string",
  "features": [{"emoji": "string", "title": "string", "description": "string"}, ...4],
  "signup_headline": "string",
  "signup_subheadline": "string",
  "signup_button": "string",
  "early_access_message": "string",
  "theme": "dark|indigo|emerald|rose|amber|sky"
}
"""


def render(spec: dict) -> dict[str, str]:
    """Render an app waitlist landing page."""

    app_name = spec.get("app_name") or "MindFlow"
    tagline = spec.get("tagline") or "Your personal AI assistant, always in your pocket"
    hero_headline = spec.get("hero_headline") or "AI that fits in your pocket"

    features = spec.get("features") or [
        {"emoji": "✨", "title": "Smart Assistant", "description": "AI-powered companion that learns your preferences."},
        {"emoji": "⚡", "title": "Lightning Fast", "description": "Instant responses, zero lag, always responsive."},
        {"emoji": "🔒", "title": "Privacy First", "description": "End-to-end encryption, your data is yours alone."},
        {"emoji": "🌍", "title": "Works Offline", "description": "Full functionality without internet connection."},
    ]

    signup_headline = spec.get("signup_headline") or "Join the waitlist"
    signup_subheadline = (
        spec.get("signup_subheadline")
        or "Be among the first to experience the future of mobile AI. Limited beta spots available."
    )
    signup_button = spec.get("signup_button") or "Get early access"
    early_access_message = spec.get("early_access_message") or "We'll notify you as soon as it's available for your platform."

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

    # Build features
    features_html = ""
    for feat in features[:4]:
        features_html += f"""
    <div className="rounded-xl border border-neutral-800 bg-neutral-900 bg-opacity-30 p-8 hover:border-{accent_light} transition-colors">
      <div className="text-4xl mb-4">{feat.get('emoji', '✨')}</div>
      <h3 className="text-lg font-semibold text-neutral-50 mb-3">{feat.get('title', 'Feature')}</h3>
      <p className="text-neutral-400">{feat.get('description', '')}</p>
    </div>"""

    app_jsx = f'''function Hero() {{
  return (
    <section className="min-h-screen bg-neutral-950 flex items-center justify-center px-6 py-32">
      <div className="max-w-6xl mx-auto grid grid-cols-1 md:grid-cols-2 gap-12 items-center">
        <div>
          <p className="text-{accent_light} text-sm font-semibold uppercase tracking-widest mb-4">{app_name}</p>
          <h1 className="text-6xl md:text-7xl font-bold tracking-tight text-neutral-50 mb-6">{hero_headline}</h1>
          <p className="text-xl text-neutral-400 leading-relaxed mb-8">{tagline}</p>
          <div className="flex gap-3 flex-wrap">
            <span className="px-4 py-2 rounded-full bg-neutral-900 text-neutral-300 text-sm border border-neutral-800">iOS</span>
            <span className="px-4 py-2 rounded-full bg-neutral-900 text-neutral-300 text-sm border border-neutral-800">Android</span>
            <span className="px-4 py-2 rounded-full bg-neutral-900 text-neutral-300 text-sm border border-neutral-800">Web</span>
          </div>
        </div>
        <div className="flex justify-center">
          <div className="relative">
            <div className="absolute inset-0 bg-{accent_light} opacity-5 blur-3xl rounded-3xl"></div>
            <div className="relative bg-gradient-to-b from-neutral-800 to-neutral-900 rounded-3xl border-8 border-neutral-700 w-64 h-96 flex items-center justify-center shadow-2xl">
              <div className="w-full h-full rounded-2xl bg-{accent_light} bg-opacity-10 flex items-center justify-center">
                <div className="text-center">
                  <div className="text-6xl mb-4">📱</div>
                  <p className="text-neutral-400 text-sm">Coming soon</p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}}

function Features() {{
  return (
    <section className="py-24 bg-neutral-950 px-6">
      <div className="max-w-6xl mx-auto">
        <h2 className="text-4xl md:text-5xl font-bold tracking-tight text-neutral-50 mb-16 text-center">What makes it special</h2>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-8">{features_html}
        </div>
      </div>
    </section>
  );
}}

function Signup() {{
  const [email, setEmail] = React.useState('');
  const [submitted, setSubmitted] = React.useState(false);

  const handleSubmit = (e) => {{
    e.preventDefault();
    setSubmitted(true);
    setTimeout(() => {{ setSubmitted(false); }}, 3000);
  }};

  return (
    <section className="py-24 bg-neutral-900 px-6">
      <div className="max-w-2xl mx-auto text-center">
        <h2 className="text-4xl md:text-5xl font-bold tracking-tight text-neutral-50 mb-4">{signup_headline}</h2>
        <p className="text-lg text-neutral-400 mb-12">{signup_subheadline}</p>
        <form onSubmit={{handleSubmit}} className="flex flex-col sm:flex-row gap-3 mb-6">
          <input
            type="email"
            placeholder="you@email.com"
            value={{email}}
            onChange={{(e) => setEmail(e.target.value)}}
            required
            className="flex-1 bg-neutral-800 border border-neutral-700 rounded-lg px-6 py-3 text-neutral-50 placeholder-neutral-500 focus:outline-none focus:border-{accent_light}"
          />
          <button type="submit" className="bg-{accent_light} hover:bg-{accent_dark} text-neutral-950 font-semibold px-8 py-3 rounded-lg transition-colors whitespace-nowrap">
            {signup_button}
          </button>
        </form>
        {{submitted && (
          <div className="bg-{accent_light} bg-opacity-10 border border-{accent_light} rounded-lg p-4 text-{accent_light} text-sm">
            ✓ {early_access_message}
          </div>
        )}}
      </div>
    </section>
  );
}}

function Footer() {{
  return (
    <footer className="py-12 bg-neutral-950 border-t border-neutral-800 px-6">
      <div className="max-w-6xl mx-auto text-center">
        <p className="text-neutral-500 text-sm">No spam. We'll only email you when we launch.</p>
      </div>
    </footer>
  );
}}

function App() {{
  return (
    <div className="bg-neutral-950">
      <Hero />
      <Features />
      <Signup />
      <Footer />
    </div>
  );
}}
'''

    return {
        "package.json": """{
  "name": "app-waitlist",
  "type": "module",
  "version": "1.0.0",
  "scripts": {
    "dev": "vite",
    "build": "vite build"
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
  <title>App Waitlist</title>
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
        "README.md": f"""# {app_name} Waitlist

{tagline}

## Development

```bash
npm install
npm run dev
```

## Build

```bash
npm run build
```
""",
    }
