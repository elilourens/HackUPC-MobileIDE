"""E-commerce template: product hero + features + gallery + reviews + buy CTA."""

TEMPLATE_ID = "ecommerce"
DESCRIPTION = "E-commerce product page: hero image, product details, features, gallery, reviews, add to cart."
SPEC_SCHEMA_HINT = """
{
  "product_name": "string",
  "price": "string (e.g. '$99.99')",
  "description": "string",
  "headline": "string",
  "features": [{"name": "string", "description": "string"}, ...4],
  "reviews": [{"rating": 5, "text": "string", "author": "string"}, ...3],
  "gallery_keywords": ["keyword", ...4],
  "primary_cta": "string",
  "theme": "dark|indigo|emerald|rose|amber|sky"
}
"""


def render(spec: dict) -> dict[str, str]:
    """Render an e-commerce product page."""

    product_name = spec.get("product_name") or "Premium Wireless Headphones"
    price = spec.get("price") or "$299"
    description = (
        spec.get("description")
        or "Professional-grade audio with active noise cancellation. Crystal-clear sound for work, play, and everything in between."
    )
    headline = spec.get("headline") or "Studio-quality sound in your pocket"

    features = spec.get("features") or [
        {"name": "Active Noise Cancellation", "description": "Block out the world with industry-leading ANC technology."},
        {"name": "48-hour Battery", "description": "Listen for days without charging."},
        {"name": "Premium Materials", "description": "Crafted with aluminum and premium leather."},
        {"name": "Seamless Pairing", "description": "Connect to all your devices instantly."},
    ]

    reviews = spec.get("reviews") or [
        {"rating": 5, "text": "Best headphones I've ever owned. The sound quality is incredible.", "author": "Alex M."},
        {"rating": 5, "text": "Worth every penny. Comfort, quality, and amazing battery life.", "author": "Jordan L."},
        {"rating": 5, "text": "Professional sound at a reasonable price. Highly recommended.", "author": "Sam P."},
    ]

    gallery_images = [
        "photo-1505740420928-5e560c06d30e",  # headphones
        "photo-1487215078519-e21cc028cb29",  # audio
        "photo-1484704849700-f032a568e944",  # tech
        "photo-1514306688659-f097612a5f1f",  # gear
    ]

    primary_cta = spec.get("primary_cta") or "Add to cart"

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

    # Build features HTML
    features_html = ""
    for feat in features[:4]:
        features_html += f"""
    <div className="flex gap-4">
      <div className="w-12 h-12 rounded-lg bg-{accent_light} bg-opacity-10 flex items-center justify-center flex-shrink-0">
        <span className="text-{accent_light} font-bold">✓</span>
      </div>
      <div>
        <h3 className="text-lg font-semibold text-neutral-50 mb-1">{feat.get('name', 'Feature')}</h3>
        <p className="text-neutral-400">{feat.get('description', '')}</p>
      </div>
    </div>"""

    # Build gallery HTML
    gallery_html = ""
    for idx, img_id in enumerate(gallery_images):
        gallery_html += f"""
    <div className="rounded-xl overflow-hidden border border-neutral-800">
      <img src="https://images.unsplash.com/photo-{img_id}?w=600&h=500&fit=crop&auto=format&q=80" alt="Product view {idx + 1}" className="w-full h-auto object-cover" />
    </div>"""

    # Build reviews HTML
    reviews_html = ""
    for review in reviews[:3]:
        rating = "★" * review.get("rating", 5)
        reviews_html += f"""
    <div className="rounded-lg border border-neutral-800 p-6 bg-neutral-900 bg-opacity-30">
      <div className="text-{accent_light} font-bold mb-3">{rating}</div>
      <p className="text-neutral-300 mb-4">"{review.get('text', '')}"</p>
      <p className="text-neutral-500 text-sm">— {review.get('author', 'Customer')}</p>
    </div>"""

    app_jsx = f'''function Header() {{
  return (
    <header className="sticky top-0 bg-neutral-950 bg-opacity-95 border-b border-neutral-800 px-6 py-4 z-50">
      <div className="max-w-6xl mx-auto flex justify-between items-center">
        <h1 className="text-xl font-bold text-neutral-50">{product_name}</h1>
        <button className="border border-neutral-700 hover:border-{accent_light} text-neutral-50 px-6 py-2 rounded-lg transition-colors">Cart</button>
      </div>
    </header>
  );
}}

function Hero() {{
  return (
    <section className="min-h-screen bg-neutral-950 flex items-center justify-center px-6 py-32">
      <div className="max-w-6xl mx-auto grid grid-cols-1 md:grid-cols-2 gap-12 items-center">
        <div className="rounded-2xl overflow-hidden border border-neutral-800">
          <img src="https://images.unsplash.com/photo-1505740420928-5e560c06d30e?w=800&h=800&fit=crop&auto=format&q=80" alt="{product_name}" className="w-full h-auto" />
        </div>
        <div>
          <h1 className="text-5xl md:text-6xl font-bold tracking-tight text-neutral-50 mb-4">{headline}</h1>
          <p className="text-xl text-neutral-400 leading-relaxed mb-8">{description}</p>
          <div className="mb-8">
            <span className="text-4xl font-bold text-neutral-50">{price}</span>
          </div>
          <button className="w-full bg-{accent_light} hover:bg-{accent_dark} text-neutral-950 font-semibold py-4 rounded-lg transition-colors mb-4 text-lg">{primary_cta}</button>
          <button className="w-full border border-neutral-700 hover:border-{accent_light} text-neutral-50 font-semibold py-4 rounded-lg transition-colors">View details</button>
        </div>
      </div>
    </section>
  );
}}

function Features() {{
  return (
    <section className="py-24 bg-neutral-950 px-6">
      <div className="max-w-4xl mx-auto">
        <h2 className="text-4xl md:text-5xl font-bold tracking-tight text-neutral-50 mb-16">Why you'll love it</h2>
        <div className="space-y-8">{features_html}
        </div>
      </div>
    </section>
  );
}}

function Gallery() {{
  return (
    <section className="py-24 bg-neutral-950 px-6">
      <div className="max-w-6xl mx-auto">
        <h2 className="text-4xl md:text-5xl font-bold tracking-tight text-neutral-50 mb-12">Product gallery</h2>
        <div className="grid grid-cols-2 md:grid-cols-4 gap-6">{gallery_html}
        </div>
      </div>
    </section>
  );
}}

function Reviews() {{
  return (
    <section className="py-24 bg-neutral-950 px-6">
      <div className="max-w-4xl mx-auto">
        <h2 className="text-4xl md:text-5xl font-bold tracking-tight text-neutral-50 mb-12">Loved by customers</h2>
        <div className="space-y-6">{reviews_html}
        </div>
      </div>
    </section>
  );
}}

function CTA() {{
  return (
    <section className="py-24 bg-neutral-900 px-6">
      <div className="max-w-4xl mx-auto text-center">
        <h2 className="text-4xl md:text-5xl font-bold tracking-tight text-neutral-50 mb-8">Ready to upgrade?</h2>
        <button className="bg-{accent_light} hover:bg-{accent_dark} text-neutral-950 font-semibold px-8 py-4 rounded-lg transition-colors text-lg">{primary_cta}</button>
      </div>
    </section>
  );
}}

function App() {{
  return (
    <div className="bg-neutral-950">
      <Header />
      <Hero />
      <Features />
      <Gallery />
      <Reviews />
      <CTA />
    </div>
  );
}}
'''

    return {
        "package.json": """{
  "name": "ecommerce",
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
  <title>Product</title>
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
        "README.md": f"""# {product_name}

{description}

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
