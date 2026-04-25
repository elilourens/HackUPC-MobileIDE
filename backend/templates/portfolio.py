"""Portfolio template: hero + projects grid + about + contact."""

TEMPLATE_ID = "portfolio"
DESCRIPTION = "Personal portfolio: hero, projects showcase, about section, contact CTA."
SPEC_SCHEMA_HINT = """
{
  "name": "string",
  "title": "string (e.g. 'Designer & Developer')",
  "hero_tagline": "string",
  "bio": "string",
  "projects": [{"title": "string", "description": "string", "role": "string", "image_keyword": "string"}, ...4],
  "about_headline": "string",
  "about_body": "string",
  "skills": ["skill", ...8],
  "contact_headline": "string",
  "contact_subheadline": "string",
  "contact_cta": "string",
  "theme": "dark|indigo|emerald|rose|amber|sky"
}
"""


def render(spec: dict) -> dict[str, str]:
    """Render a personal portfolio."""

    name = spec.get("name") or "Sarah Chen"
    title = spec.get("title") or "Designer & Developer"
    hero_tagline = spec.get("hero_tagline") or "I design and build beautiful digital experiences"
    bio = spec.get("bio") or "Passionate about creating products that solve real problems. Always learning, always shipping."

    projects = spec.get("projects") or [
        {
            "title": "Mobile Banking App",
            "description": "Redesigned the entire payment flow, reducing steps by 40%.",
            "role": "Lead Designer",
        },
        {
            "title": "E-commerce Platform",
            "description": "Built a full-featured marketplace from zero to 10k MAU.",
            "role": "Full Stack Developer",
        },
        {
            "title": "Analytics Dashboard",
            "description": "Real-time data visualization for 500+ customers.",
            "role": "Frontend Engineer",
        },
        {
            "title": "AI Chatbot",
            "description": "Conversational AI with NLP integration and custom training.",
            "role": "ML Engineer",
        },
    ]

    about_headline = spec.get("about_headline") or "About me"
    about_body = (
        spec.get("about_body")
        or "I've been designing and building digital products for 8 years. Started as a designer, learned to code, "
        "and now I'm obsessed with the intersection of design and engineering. I love working with small, focused teams "
        "to ship products that matter."
    )

    skills = spec.get("skills") or ["Product Design", "React", "UI/UX", "JavaScript", "Figma", "Web Design", "Prototyping", "Strategy"]

    contact_headline = spec.get("contact_headline") or "Let's work together"
    contact_subheadline = spec.get("contact_subheadline") or "Have a project in mind? I'd love to hear about it."
    contact_cta = spec.get("contact_cta") or "Get in touch"

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

    # Build projects HTML
    projects_html = ""
    project_images = [
        "photo-1561070791-2526d30994b5",  # design
        "photo-1460925895917-adf4078cae81",  # analytics
        "photo-1552664730-d307ca884978",  # code
        "photo-1517694712202-14dd9538aa97",  # tech
    ]
    for idx, proj in enumerate(projects[:4]):
        img_id = project_images[idx] if idx < len(project_images) else project_images[0]
        projects_html += f"""
    <div class="group rounded-2xl overflow-hidden border border-neutral-800 hover:border-{accent_light} transition-colors bg-neutral-900 bg-opacity-30">
      <div class="relative overflow-hidden h-64">
        <img src="https://images.unsplash.com/photo-{img_id}?w=800&h=600&fit=crop&auto=format&q=80" alt="{proj.get('title', 'Project')}" class="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300" />
      </div>
      <div class="p-6">
        <p class="text-{accent_light} text-sm font-semibold uppercase tracking-widest mb-2">{proj.get('role', 'Project')}</p>
        <h3 class="text-xl font-bold text-neutral-50 mb-2">{proj.get('title', 'Project')}</h3>
        <p class="text-neutral-400 leading-relaxed">{proj.get('description', '')}</p>
      </div>
    </div>"""

    # Build skills HTML
    skills_html = ""
    for skill in skills[:8]:
        skills_html += f'<div class="px-4 py-2 rounded-full border border-neutral-700 text-neutral-300 text-sm">{skill}</div>'

    app_jsx = f'''function Header() {{
  return (
    <header class="sticky top-0 bg-neutral-950 bg-opacity-95 border-b border-neutral-800 px-6 py-4 z-50">
      <div class="max-w-6xl mx-auto flex justify-between items-center">
        <h1 class="text-2xl font-bold text-neutral-50">{name}</h1>
        <nav class="flex gap-8 hidden sm:flex">
          <a href="#work" class="text-neutral-400 hover:text-{accent_light} transition-colors">Work</a>
          <a href="#about" class="text-neutral-400 hover:text-{accent_light} transition-colors">About</a>
          <a href="#contact" class="text-neutral-400 hover:text-{accent_light} transition-colors">Contact</a>
        </nav>
      </div>
    </header>
  );
}}

function Hero() {{
  return (
    <section class="min-h-screen bg-neutral-950 flex items-center justify-center px-6 py-32">
      <div class="max-w-4xl mx-auto text-center">
        <p class="text-{accent_light} text-sm font-semibold uppercase tracking-widest mb-4">{title}</p>
        <h1 class="text-6xl md:text-7xl font-bold tracking-tight text-neutral-50 mb-6">{hero_tagline}</h1>
        <p class="text-xl text-neutral-400 max-w-2xl mx-auto leading-relaxed">{bio}</p>
      </div>
    </section>
  );
}}

function Work() {{
  return (
    <section id="work" class="py-24 bg-neutral-950 px-6">
      <div class="max-w-6xl mx-auto">
        <h2 class="text-4xl md:text-5xl font-bold tracking-tight text-neutral-50 mb-16">Recent work</h2>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-8">{projects_html}
        </div>
      </div>
    </section>
  );
}}

function About() {{
  return (
    <section id="about" class="py-24 bg-neutral-950 px-6">
      <div class="max-w-4xl mx-auto">
        <h2 class="text-4xl md:text-5xl font-bold tracking-tight text-neutral-50 mb-8">{about_headline}</h2>
        <p class="text-lg text-neutral-400 leading-relaxed mb-12">{about_body}</p>
        <div>
          <h3 class="text-lg font-semibold text-neutral-50 mb-6">Skills</h3>
          <div class="flex flex-wrap gap-3">{skills_html}
          </div>
        </div>
      </div>
    </section>
  );
}}

function Contact() {{
  return (
    <section id="contact" class="py-24 bg-neutral-900 px-6">
      <div class="max-w-4xl mx-auto text-center">
        <h2 class="text-4xl md:text-5xl font-bold tracking-tight text-neutral-50 mb-4">{contact_headline}</h2>
        <p class="text-lg text-neutral-400 mb-8">{contact_subheadline}</p>
        <button class="bg-{accent_light} hover:bg-{accent_dark} text-neutral-950 font-semibold px-8 py-3 rounded-lg transition-colors">{contact_cta}</button>
      </div>
    </section>
  );
}}

function App() {{
  return (
    <div class="bg-neutral-950">
      <Header />
      <Hero />
      <Work />
      <About />
      <Contact />
    </div>
  );
}}
'''

    return {
        "package.json": """{
  "name": "portfolio",
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
  <title>Portfolio</title>
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
        "README.md": f"""# {name}'s Portfolio

{hero_tagline}

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
