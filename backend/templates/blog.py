"""Blog template: post list + featured post + author bio."""

TEMPLATE_ID = "blog"
DESCRIPTION = "Content blog: featured post hero, post list grid, author bio, subscribe."
SPEC_SCHEMA_HINT = """
{
  "blog_name": "string",
  "tagline": "string",
  "featured_title": "string",
  "featured_excerpt": "string",
  "featured_author": "string",
  "featured_date": "string",
  "featured_read_time": "string",
  "posts": [{"title": "string", "excerpt": "string", "author": "string", "date": "string", "category": "string"}, ...5],
  "about_headline": "string",
  "about_bio": "string",
  "subscribe_headline": "string",
  "theme": "dark|indigo|emerald|rose|amber|sky"
}
"""


def render(spec: dict) -> dict[str, str]:
    """Render a blog landing page."""

    blog_name = spec.get("blog_name") or "The Dispatch"
    tagline = spec.get("tagline") or "Insights, ideas, and inspiration"

    featured_title = spec.get("featured_title") or "Building in public: lessons from the first 1000 users"
    featured_excerpt = (
        spec.get("featured_excerpt")
        or "We launched our product publicly 3 months ago. Here's what we learned."
    )
    featured_author = spec.get("featured_author") or "Alex Johnson"
    featured_date = spec.get("featured_date") or "March 15, 2024"
    featured_read_time = spec.get("featured_read_time") or "8 min read"

    posts = spec.get("posts") or [
        {
            "title": "The art of product feedback",
            "excerpt": "How to ask the right questions and listen like a designer.",
            "author": "Jordan Lee",
            "date": "March 10, 2024",
            "category": "Design",
        },
        {
            "title": "Scaling to 10k users without breaking",
            "excerpt": "Infrastructure lessons from 30 days of exponential growth.",
            "author": "Sam Chen",
            "date": "March 5, 2024",
            "category": "Engineering",
        },
        {
            "title": "Why we open-sourced our core library",
            "excerpt": "Building in the open accelerated our development by 5x.",
            "author": "Casey Williams",
            "date": "February 28, 2024",
            "category": "Open Source",
        },
        {
            "title": "The founder's guide to fundraising",
            "excerpt": "Everything we wish we knew before pitching to VCs.",
            "author": "Alex Johnson",
            "date": "February 20, 2024",
            "category": "Startup",
        },
        {
            "title": "Remote-first company culture",
            "excerpt": "How we built a tight-knit team across 6 time zones.",
            "author": "Morgan Paul",
            "date": "February 12, 2024",
            "category": "Culture",
        },
    ]

    about_headline = spec.get("about_headline") or "About this blog"
    about_bio = (
        spec.get("about_bio")
        or "We share weekly posts on product, design, engineering, and building in the open. "
        "This is where we document our journey and the lessons we learn along the way."
    )

    subscribe_headline = spec.get("subscribe_headline") or "Subscribe for weekly updates"

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

    # Build posts list
    posts_html = ""
    for post in posts[:5]:
        posts_html += f"""
    <article className="rounded-lg border border-neutral-800 hover:border-neutral-700 transition-colors p-6 bg-neutral-900 bg-opacity-20 group cursor-pointer">
      <div className="flex items-start justify-between mb-4">
        <h3 className="text-xl font-bold text-neutral-50 group-hover:text-{accent_light} transition-colors flex-1 leading-tight">{post.get('title', 'Post')}</h3>
      </div>
      <p className="text-neutral-400 mb-4 leading-relaxed">{post.get('excerpt', '')}</p>
      <div className="flex items-center justify-between text-sm text-neutral-500">
        <div className="flex gap-4">
          <span>{post.get('author', 'Author')}</span>
          <span>•</span>
          <span>{post.get('date', 'Date')}</span>
        </div>
        <span className="px-3 py-1 rounded-full bg-neutral-800 text-neutral-300 text-xs font-medium">{post.get('category', 'Category')}</span>
      </div>
    </article>"""

    app_jsx = f'''function Header() {{
  return (
    <header className="sticky top-0 bg-neutral-950 bg-opacity-95 border-b border-neutral-800 px-6 py-4 z-50">
      <div className="max-w-4xl mx-auto">
        <h1 className="text-2xl font-bold text-neutral-50">{blog_name}</h1>
      </div>
    </header>
  );
}}

function FeaturedPost() {{
  return (
    <section className="bg-neutral-950 px-6 py-32">
      <div className="max-w-4xl mx-auto">
        <div className="mb-4">
          <span className="text-{accent_light} text-sm font-semibold uppercase tracking-widest">Featured</span>
        </div>
        <h1 className="text-5xl md:text-6xl font-bold tracking-tight text-neutral-50 mb-6">{featured_title}</h1>
        <p className="text-xl text-neutral-400 mb-8 leading-relaxed max-w-2xl">{featured_excerpt}</p>
        <div className="flex items-center gap-4">
          <div className="w-10 h-10 rounded-full bg-{accent_light} bg-opacity-20"></div>
          <div>
            <p className="font-semibold text-neutral-50">{featured_author}</p>
            <p className="text-sm text-neutral-400">{featured_date} · {featured_read_time}</p>
          </div>
        </div>
        <div className="mt-12 rounded-2xl overflow-hidden border border-neutral-800">
          <img src="https://images.unsplash.com/photo-1552664730-d307ca884978?w=1200&h=600&fit=crop&auto=format&q=80" alt="Featured post" className="w-full h-auto" />
        </div>
      </div>
    </section>
  );
}}

function PostsList() {{
  return (
    <section className="py-24 bg-neutral-950 px-6">
      <div className="max-w-4xl mx-auto">
        <h2 className="text-4xl md:text-5xl font-bold tracking-tight text-neutral-50 mb-12">Latest posts</h2>
        <div className="space-y-6">{posts_html}
        </div>
      </div>
    </section>
  );
}}

function About() {{
  return (
    <section className="py-24 bg-neutral-900 px-6">
      <div className="max-w-4xl mx-auto">
        <h2 className="text-3xl font-bold text-neutral-50 mb-6">{about_headline}</h2>
        <p className="text-lg text-neutral-400 leading-relaxed">{about_bio}</p>
      </div>
    </section>
  );
}}

function Subscribe() {{
  const [email, setEmail] = React.useState('');
  const [submitted, setSubmitted] = React.useState(false);

  const handleSubmit = (e) => {{
    e.preventDefault();
    setSubmitted(true);
    setTimeout(() => {{ setSubmitted(false); }}, 3000);
  }};

  return (
    <section className="py-24 bg-neutral-950 px-6 border-t border-neutral-800">
      <div className="max-w-2xl mx-auto text-center">
        <h2 className="text-4xl font-bold text-neutral-50 mb-6">{subscribe_headline}</h2>
        <form onSubmit={{handleSubmit}} className="flex flex-col sm:flex-row gap-3">
          <input
            type="email"
            placeholder="you@email.com"
            value={{email}}
            onChange={{(e) => setEmail(e.target.value)}}
            required
            className="flex-1 bg-neutral-900 border border-neutral-800 rounded-lg px-6 py-3 text-neutral-50 placeholder-neutral-500 focus:outline-none focus:border-{accent_light}"
          />
          <button type="submit" className="bg-{accent_light} hover:bg-{accent_dark} text-neutral-950 font-semibold px-8 py-3 rounded-lg transition-colors">
            Subscribe
          </button>
        </form>
        {{submitted && (
          <p className="text-{accent_light} text-sm mt-4">✓ Thanks for subscribing!</p>
        )}}
      </div>
    </section>
  );
}}

function App() {{
  return (
    <div className="bg-neutral-950">
      <Header />
      <FeaturedPost />
      <PostsList />
      <About />
      <Subscribe />
    </div>
  );
}}
'''

    return {
        "package.json": """{
  "name": "blog",
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
  <title>Blog</title>
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
        "README.md": f"""# {blog_name}

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
