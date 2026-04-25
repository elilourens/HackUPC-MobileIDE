"""SaaS landing page template: hero + features + metrics + testimonial + pricing + CTA."""

TEMPLATE_ID = "saas_landing"
DESCRIPTION = "Generic SaaS landing: hero, features grid, metrics, testimonial, pricing table, CTA."
SPEC_SCHEMA_HINT = """
{
  "product_name": "string",
  "tagline": "string (short, catchy)",
  "hero_headline": "string",
  "hero_subheadline": "string",
  "primary_cta": "string (button label)",
  "secondary_cta": "string (button label)",
  "features": [{"title": "string", "description": "string", "icon": "zap|users|grid|rocket|shield|settings"}, ...6],
  "metrics": [{"value": "string", "label": "string"}, ...3],
  "testimonial": {"quote": "string", "author": "string", "role": "string", "company": "string"},
  "pricing_plans": [{"name": "string", "price": "string", "description": "string", "features": ["item", ...3], "cta": "string"}, ...3],
  "footer_tagline": "string",
  "theme": "dark|indigo|emerald|rose|amber|sky"
}
"""


def render(spec: dict) -> dict[str, str]:
    """Render a SaaS landing page with the given spec."""

    # Defaults
    product_name = spec.get("product_name") or "Linear"
    tagline = spec.get("tagline") or "Issues you'll actually want to track"
    hero_headline = spec.get("hero_headline") or "Softwaredesigned to spec"
    hero_subheadline = (
        spec.get("hero_subheadline")
        or "Linear is a purpose-built tool for planning and building products. Streamline issues, sprints, and projects with the speed and craft of an artisan."
    )
    primary_cta = spec.get("primary_cta") or "Start building"
    secondary_cta = spec.get("secondary_cta") or "Watch demo"

    features = spec.get("features") or [
        {"title": "Built for speed", "description": "Designed for high-performance teams that move fast.", "icon": "zap"},
        {"title": "Real-time sync", "description": "Instant updates across all team members.", "icon": "users"},
        {"title": "Powerful insights", "description": "Track progress with rich analytics and dashboards.", "icon": "grid"},
        {"title": "Integrations galore", "description": "Connect with your favorite tools seamlessly.", "icon": "rocket"},
        {"title": "Bank-grade security", "description": "Enterprise-level security and compliance built-in.", "icon": "shield"},
        {"title": "Fully customizable", "description": "Adapt the tool to your exact workflow.", "icon": "settings"},
    ]

    metrics = spec.get("metrics") or [
        {"value": "10,000+", "label": "Teams"},
        {"value": "500M+", "label": "Tasks tracked"},
        {"value": "99.9%", "label": "Uptime"},
    ]

    testimonial = spec.get("testimonial") or {
        "quote": "Linear is hands down the best tool we've found for managing our product roadmap. It's fast, beautiful, and just works.",
        "author": "Karri Saarinen",
        "role": "Co-founder",
        "company": "Linear",
    }

    pricing_plans = spec.get("pricing_plans") or [
        {
            "name": "Starter",
            "price": "$29",
            "period": "/month",
            "description": "Perfect for small teams",
            "features": ["Up to 10 users", "Unlimited issues", "Basic reports"],
            "cta": "Get started",
        },
        {
            "name": "Pro",
            "price": "$79",
            "period": "/month",
            "description": "For growing teams",
            "features": ["Up to 50 users", "Advanced analytics", "Priority support", "Custom fields"],
            "cta": "Get started",
            "highlighted": True,
        },
        {
            "name": "Enterprise",
            "price": "Custom",
            "period": "",
            "description": "For large orgs",
            "features": ["Unlimited users", "Dedicated support", "SSO & SAML", "SLA guarantee"],
            "cta": "Contact sales",
        },
    ]

    footer_tagline = spec.get("footer_tagline") or "Built for makers, by makers."

    # Theme colors
    theme = spec.get("theme", "indigo").lower()
    theme_map = {
        "indigo": ("indigo-500", "indigo-600", "indigo-950"),
        "emerald": ("emerald-500", "emerald-600", "emerald-950"),
        "rose": ("rose-500", "rose-600", "rose-950"),
        "amber": ("amber-500", "amber-600", "amber-950"),
        "sky": ("sky-500", "sky-600", "sky-950"),
        "dark": ("blue-500", "blue-600", "neutral-950"),
    }
    accent_light, accent_dark, body_accent = theme_map.get(theme, theme_map["indigo"])

    # Icon map for features
    icon_svg = {
        "zap": '<svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"/></svg>',
        "users": '<svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 20h5v-2a3 3 0 00-5.856-1.487M15 10a3 3 0 11-6 0 3 3 0 016 0zM12.93 12a7 7 0 00-6.86 0"/></svg>',
        "grid": '<svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 5a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1H5a1 1 0 01-1-1V5zM14 5a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1h-4a1 1 0 01-1-1V5zM4 15a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1H5a1 1 0 01-1-1v-4zM14 15a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1h-4a1 1 0 01-1-1v-4z"/></svg>',
        "rocket": '<svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"/></svg>',
        "shield": '<svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>',
        "settings": '<svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"/></svg>',
    }

    # Build features HTML
    features_html = ""
    for feat in features[:6]:
        icon = icon_svg.get(feat.get("icon", "zap"), icon_svg["zap"])
        features_html += f"""
    <div className="rounded-2xl border border-neutral-800 p-8 hover:border-neutral-700 transition-colors">
      <div className="mb-4 text-{accent_light}">{icon}</div>
      <h3 className="text-lg font-semibold text-neutral-50 mb-2">{feat.get('title', 'Feature')}</h3>
      <p className="text-neutral-400">{feat.get('description', '')}</p>
    </div>"""

    # Build metrics HTML
    metrics_html = ""
    for metric in metrics[:3]:
        metrics_html += f"""
    <div className="text-center">
      <div className="text-4xl font-bold text-{accent_light} mb-2">{metric.get('value', '0')}</div>
      <p className="text-neutral-400">{metric.get('label', '')}</p>
    </div>"""

    # Build pricing HTML
    pricing_html = ""
    for plan in pricing_plans[:3]:
        is_highlighted = plan.get("highlighted", False)
        pricing_html += f"""
    <div className="{'ring-2 ring-' + accent_light + ' scale-105' if is_highlighted else 'border border-neutral-800'} rounded-2xl p-8 {'bg-neutral-800 bg-opacity-40' if is_highlighted else ''}">
      <h3 className="text-2xl font-bold text-neutral-50 mb-2">{plan.get('name', 'Plan')}</h3>
      <p className="text-neutral-400 mb-4">{plan.get('description', '')}</p>
      <div className="mb-6">
        <span className="text-4xl font-bold text-neutral-50">{plan.get('price', 'Custom')}</span>
        <span className="text-neutral-400 ml-2">{plan.get('period', '')}</span>
      </div>
      <ul className="space-y-3 mb-8">"""
        for feature in plan.get("features", [])[:3]:
            pricing_html += f'<li className="text-neutral-300 flex items-center"><span className="mr-3 text-{accent_light}">✓</span>{feature}</li>'
        pricing_html += f"""
      </ul>
      <button className="w-full bg-{accent_light} hover:bg-{accent_dark} text-neutral-950 font-semibold py-3 rounded-lg transition-colors">{plan.get('cta', 'Get started')}</button>
    </div>"""

    app_jsx = f'''function Hero() {{
  return (
    <section className="min-h-screen bg-neutral-950 flex items-center justify-center px-6 py-32">
      <div className="max-w-6xl mx-auto">
        <div className="text-center mb-12">
          <p className="text-{accent_light} text-sm font-semibold uppercase tracking-widest mb-4">{product_name}</p>
          <h1 className="text-6xl md:text-7xl font-bold tracking-tight text-neutral-50 mb-6">{hero_headline}</h1>
          <p className="text-xl text-neutral-400 max-w-3xl mx-auto leading-relaxed mb-8">{hero_subheadline}</p>
          <div className="flex flex-col sm:flex-row gap-4 justify-center">
            <button className="bg-{accent_light} hover:bg-{accent_dark} text-neutral-950 font-semibold px-8 py-3 rounded-lg transition-colors">{primary_cta}</button>
            <button className="border border-neutral-700 hover:border-neutral-600 text-neutral-50 font-semibold px-8 py-3 rounded-lg transition-colors">{secondary_cta}</button>
          </div>
        </div>
        <div className="rounded-2xl overflow-hidden border border-neutral-800">
          <img src="https://images.unsplash.com/photo-1552664730-d307ca884978?w=1600&q=80&auto=format&fit=crop" alt="Product demo" className="w-full h-auto" />
        </div>
      </div>
    </section>
  );
}}

function Features() {{
  return (
    <section className="py-24 bg-neutral-950 px-6">
      <div className="max-w-6xl mx-auto">
        <div className="text-center mb-16">
          <h2 className="text-4xl md:text-5xl font-bold tracking-tight text-neutral-50 mb-4">Powerful features</h2>
          <p className="text-lg text-neutral-400">Everything you need to build faster and smarter</p>
        </div>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-8">{features_html}
        </div>
      </div>
    </section>
  );
}}

function Metrics() {{
  return (
    <section className="py-24 bg-neutral-900 px-6">
      <div className="max-w-6xl mx-auto">
        <div className="grid grid-cols-1 md:grid-cols-3 gap-12">{metrics_html}
        </div>
      </div>
    </section>
  );
}}

function Testimonial() {{
  return (
    <section className="py-24 bg-neutral-950 px-6">
      <div className="max-w-4xl mx-auto text-center">
        <p className="text-2xl md:text-3xl font-light text-neutral-100 mb-8 leading-relaxed">"{testimonial['quote']}"</p>
        <div className="flex items-center justify-center gap-4">
          <div className="w-12 h-12 rounded-full bg-{accent_light} opacity-20"></div>
          <div>
            <p className="font-semibold text-neutral-50">{testimonial['author']}</p>
            <p className="text-sm text-neutral-400">{testimonial['role']} at {testimonial['company']}</p>
          </div>
        </div>
      </div>
    </section>
  );
}}

function Pricing() {{
  return (
    <section className="py-24 bg-neutral-950 px-6">
      <div className="max-w-6xl mx-auto">
        <div className="text-center mb-16">
          <h2 className="text-4xl md:text-5xl font-bold tracking-tight text-neutral-50 mb-4">Simple, transparent pricing</h2>
          <p className="text-lg text-neutral-400">Choose the plan that fits your needs</p>
        </div>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-8">{pricing_html}
        </div>
      </div>
    </section>
  );
}}

function Footer() {{
  return (
    <section className="py-16 bg-neutral-900 border-t border-neutral-800 px-6">
      <div className="max-w-6xl mx-auto flex flex-col sm:flex-row justify-between items-center">
        <p className="text-neutral-400">{footer_tagline}</p>
        <div className="flex gap-6 mt-4 sm:mt-0">
          <a href="#" className="text-neutral-400 hover:text-{accent_light} transition-colors">Privacy</a>
          <a href="#" className="text-neutral-400 hover:text-{accent_light} transition-colors">Terms</a>
          <a href="#" className="text-neutral-400 hover:text-{accent_light} transition-colors">Contact</a>
        </div>
      </div>
    </section>
  );
}}

function App() {{
  return (
    <div className="bg-neutral-950">
      <Hero />
      <Features />
      <Metrics />
      <Testimonial />
      <Pricing />
      <Footer />
    </div>
  );
}}
'''

    return {
        "package.json": '''{
  "name": "saas-landing",
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
}''',
        "vite.config.js": """import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
  },
});
""",
        "index.html": """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Landing</title>
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
        "src/index.css": """/* Tailwind is loaded via CDN. Add custom styles here if needed. */
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&display=swap');

:root {
  --accent: rgb(var(--color-accent));
}
""",
        "README.md": f"""# {product_name}

{hero_subheadline}

## Development

Install dependencies:
```bash
npm install
```

Start the dev server:
```bash
npm run dev
```

Open http://localhost:5173 in your browser.

## Build

```bash
npm run build
```

The built site is in `dist/`.
""",
    }
