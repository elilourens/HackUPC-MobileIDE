"""Restaurant template: hero food image + menu sections + hours/location + reservation CTA."""

TEMPLATE_ID = "restaurant"
DESCRIPTION = "Restaurant website: hero image, menu sections, hours/location, reservation form."
SPEC_SCHEMA_HINT = """
{
  "restaurant_name": "string",
  "cuisine": "string (e.g. 'Modern Italian')",
  "tagline": "string",
  "menu_sections": [{"name": "string", "items": [{"name": "string", "description": "string", "price": "string"}, ...3]}, ...3],
  "hours": "string (e.g. 'Tue-Thu 5-10pm, Fri-Sat 5-11pm')",
  "address": "string",
  "phone": "string",
  "reservation_headline": "string",
  "theme": "dark|indigo|emerald|rose|amber|sky"
}
"""


def render(spec: dict) -> dict[str, str]:
    """Render a restaurant website."""

    restaurant_name = spec.get("restaurant_name") or "The Harvest"
    cuisine = spec.get("cuisine") or "Modern Italian"
    tagline = spec.get("tagline") or "Farm-to-table dining experience"

    menu_sections = spec.get("menu_sections") or [
        {
            "name": "Appetizers",
            "items": [
                {"name": "Burrata & Heirloom", "description": "Fresh burrata with seasonal heirloom tomatoes", "price": "$14"},
                {"name": "Grilled Octopus", "description": "Charred octopus with lemon and olive oil", "price": "$18"},
                {"name": "Wild Mushroom Toast", "description": "Crispy bread with foraged mushrooms", "price": "$12"},
            ],
        },
        {
            "name": "Mains",
            "items": [
                {"name": "Handmade Pappardelle", "description": "Fresh pasta with wild boar ragù", "price": "$24"},
                {"name": "Branzino al Forno", "description": "Whole roasted Mediterranean branzino", "price": "$32"},
                {"name": "Heritage Pork Chop", "description": "Thick-cut chop with seasonal vegetables", "price": "$28"},
            ],
        },
        {
            "name": "Desserts",
            "items": [
                {"name": "Panna Cotta", "description": "Silky vanilla panna cotta with berries", "price": "$8"},
                {"name": "Tiramisu", "description": "Classic tiramisu made fresh daily", "price": "$9"},
                {"name": "Olive Oil Cake", "description": "Rustic olive oil cake with citrus", "price": "$7"},
            ],
        },
    ]

    hours = spec.get("hours") or "Tuesday - Thursday 5pm-10pm, Friday - Saturday 5pm-11pm, Sunday 5pm-9pm"
    address = spec.get("address") or "142 Oak Street, San Francisco, CA 94107"
    phone = spec.get("phone") or "(415) 555-0123"
    reservation_headline = spec.get("reservation_headline") or "Reserve your table"

    theme = spec.get("theme", "amber").lower()
    theme_map = {
        "indigo": ("indigo-500", "indigo-600"),
        "emerald": ("emerald-500", "emerald-600"),
        "rose": ("rose-500", "rose-600"),
        "amber": ("amber-500", "amber-600"),
        "sky": ("sky-500", "sky-600"),
        "dark": ("blue-500", "blue-600"),
    }
    accent_light, accent_dark = theme_map.get(theme, theme_map["amber"])

    # Build menu HTML
    menu_html = ""
    for section in menu_sections[:3]:
        menu_html += f"""
    <div class="mb-12">
      <h3 class="text-3xl font-bold text-neutral-50 mb-8 pb-4 border-b border-neutral-800">{section.get('name', 'Section')}</h3>
      <div class="space-y-8">"""
        for item in section.get("items", [])[:3]:
            menu_html += f"""
        <div>
          <div class="flex justify-between items-start mb-2">
            <h4 class="text-xl font-semibold text-neutral-50">{item.get('name', 'Dish')}</h4>
            <span class="text-{accent_light} font-semibold">{item.get('price', '')}</span>
          </div>
          <p class="text-neutral-400">{item.get('description', '')}</p>
        </div>"""
        menu_html += """
      </div>
    </div>"""

    app_jsx = f'''function Header() {{
  return (
    <header class="sticky top-0 bg-neutral-950 bg-opacity-95 border-b border-neutral-800 px-6 py-4 z-50">
      <div class="max-w-6xl mx-auto flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-bold text-neutral-50">{restaurant_name}</h1>
          <p class="text-{accent_light} text-sm">{cuisine}</p>
        </div>
        <a href="#reserve" class="border border-{accent_light} text-{accent_light} px-6 py-2 rounded-lg hover:bg-{accent_light} hover:text-neutral-950 transition-colors font-semibold">Reserve</a>
      </div>
    </header>
  );
}}

function Hero() {{
  return (
    <section class="relative min-h-screen flex items-center justify-center overflow-hidden">
      <img src="https://images.unsplash.com/photo-1546069901-ba9599a7e63c?w=1600&h=900&fit=crop&auto=format&q=80" alt="Restaurant" class="absolute inset-0 w-full h-full object-cover" />
      <div class="absolute inset-0 bg-neutral-950 bg-opacity-60"></div>
      <div class="relative z-10 text-center px-6">
        <h2 class="text-6xl md:text-7xl font-bold tracking-tight text-neutral-50 mb-4">{restaurant_name}</h2>
        <p class="text-2xl text-neutral-300 mb-8">{tagline}</p>
        <a href="#menu" class="inline-block bg-{accent_light} hover:bg-{accent_dark} text-neutral-950 font-semibold px-8 py-3 rounded-lg transition-colors">Explore menu</a>
      </div>
    </section>
  );
}}

function Menu() {{
  return (
    <section id="menu" class="py-32 bg-neutral-950 px-6">
      <div class="max-w-4xl mx-auto">
        <h2 class="text-5xl font-bold text-neutral-50 mb-6 text-center">Menu</h2>
        <p class="text-center text-neutral-400 mb-16">Seasonally inspired dishes made with the finest local ingredients</p>
        {menu_html}
      </div>
    </section>
  );
}}

function Info() {{
  return (
    <section class="py-24 bg-neutral-900 px-6">
      <div class="max-w-4xl mx-auto grid grid-cols-1 md:grid-cols-2 gap-12">
        <div>
          <h3 class="text-2xl font-bold text-neutral-50 mb-6">Hours</h3>
          <p class="text-neutral-400 leading-relaxed whitespace-pre-line">{hours}</p>
        </div>
        <div>
          <h3 class="text-2xl font-bold text-neutral-50 mb-6">Location</h3>
          <p class="text-neutral-300 mb-3">{address}</p>
          <p class="text-{accent_light} font-semibold">{phone}</p>
        </div>
      </div>
    </section>
  );
}}

function Reservation() {{
  const [email, setEmail] = React.useState('');
  const [submitted, setSubmitted] = React.useState(false);

  const handleSubmit = (e) => {{
    e.preventDefault();
    setSubmitted(true);
    setTimeout(() => {{ setSubmitted(false); }}, 3000);
  }};

  return (
    <section id="reserve" class="py-24 bg-neutral-950 px-6">
      <div class="max-w-2xl mx-auto text-center">
        <h2 class="text-4xl md:text-5xl font-bold tracking-tight text-neutral-50 mb-6">{reservation_headline}</h2>
        <form onSubmit={{handleSubmit}} class="space-y-4">
          <input
            type="text"
            placeholder="Your name"
            required
            class="w-full bg-neutral-900 border border-neutral-800 rounded-lg px-6 py-3 text-neutral-50 placeholder-neutral-500 focus:outline-none focus:border-{accent_light}"
          />
          <input
            type="email"
            placeholder="Email"
            value={{email}}
            onChange={{(e) => setEmail(e.target.value)}}
            required
            class="w-full bg-neutral-900 border border-neutral-800 rounded-lg px-6 py-3 text-neutral-50 placeholder-neutral-500 focus:outline-none focus:border-{accent_light}"
          />
          <input
            type="date"
            required
            class="w-full bg-neutral-900 border border-neutral-800 rounded-lg px-6 py-3 text-neutral-50 focus:outline-none focus:border-{accent_light}"
          />
          <select required class="w-full bg-neutral-900 border border-neutral-800 rounded-lg px-6 py-3 text-neutral-50 focus:outline-none focus:border-{accent_light}">
            <option value="">Select party size</option>
            <option value="1">1 guest</option>
            <option value="2">2 guests</option>
            <option value="3">3 guests</option>
            <option value="4">4 guests</option>
            <option value="5">5+ guests</option>
          </select>
          <button type="submit" class="w-full bg-{accent_light} hover:bg-{accent_dark} text-neutral-950 font-semibold py-3 rounded-lg transition-colors">
            Request reservation
          </button>
        </form>
        {{submitted && (
          <div class="mt-6 bg-{accent_light} bg-opacity-10 border border-{accent_light} rounded-lg p-4 text-{accent_light}">
            ✓ Thank you! We'll confirm your reservation shortly.
          </div>
        )}}
      </div>
    </section>
  );
}}

function Footer() {{
  return (
    <footer class="py-12 bg-neutral-900 border-t border-neutral-800 px-6">
      <div class="max-w-6xl mx-auto text-center">
        <p class="text-neutral-500">Follow us on Instagram @{restaurant_name.lower().replace(' ', '')}</p>
      </div>
    </footer>
  );
}}

function App() {{
  return (
    <div class="bg-neutral-950">
      <Header />
      <Hero />
      <Menu />
      <Info />
      <Reservation />
      <Footer />
    </div>
  );
}}
'''

    return {
        "package.json": """{
  "name": "restaurant",
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
  <title>Restaurant</title>
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
        "README.md": f"""# {restaurant_name}

{cuisine} cuisine. {tagline}

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
