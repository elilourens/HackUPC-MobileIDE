"""Dashboard template: sidebar + topbar + stat cards + chart + table."""

TEMPLATE_ID = "dashboard"
DESCRIPTION = "Internal tool dashboard: sidebar navigation, topbar, stat cards, chart placeholder, data table."
SPEC_SCHEMA_HINT = """
{
  "app_name": "string",
  "page_title": "string",
  "stats": [{"label": "string", "value": "string", "icon": "users|trending|clock|chart"}, ...4],
  "chart_title": "string",
  "table_headers": ["string", ...4],
  "table_rows": [["value", ...4], ...3],
  "sidebar_items": ["string", ...6],
  "theme": "dark|indigo|emerald|rose|amber|sky"
}
"""


def render(spec: dict) -> dict[str, str]:
    """Render a dashboard interface."""

    app_name = spec.get("app_name") or "Dashboard"
    page_title = spec.get("page_title") or "Analytics"

    stats = spec.get("stats") or [
        {"label": "Total Users", "value": "12,453", "icon": "users"},
        {"label": "Revenue", "value": "$48.3k", "icon": "trending"},
        {"label": "Conversion", "value": "3.2%", "icon": "chart"},
        {"label": "Avg. Session", "value": "4m 23s", "icon": "clock"},
    ]

    chart_title = spec.get("chart_title") or "Revenue over time"

    table_headers = spec.get("table_headers") or ["Name", "Status", "Revenue", "Date"]
    table_rows = spec.get("table_rows") or [
        ["Acme Corp", "Active", "$2,400", "Jan 15"],
        ["TechStart Inc", "Active", "$1,800", "Jan 14"],
        ["Growth Labs", "Pending", "$1,200", "Jan 13"],
    ]

    sidebar_items = spec.get("sidebar_items") or [
        "Dashboard",
        "Analytics",
        "Reports",
        "Users",
        "Settings",
        "Documentation",
    ]

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

    icon_svg = {
        "users": '<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 20h5v-2a3 3 0 00-5.856-1.487M15 10a3 3 0 11-6 0 3 3 0 016 0zM12.93 12a7 7 0 00-6.86 0"/></svg>',
        "trending": '<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 7h8m0 0v8m0-8l-8 8-4-4-6 6"/></svg>',
        "chart": '<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"/></svg>',
        "clock": '<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 2m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>',
    }

    # Build sidebar
    sidebar_html = ""
    for idx, item in enumerate(sidebar_items[:6]):
        active = "bg-neutral-800 border-l-2 border-" + accent_light if idx == 0 else ""
        sidebar_html += f'<a href="#" class="block px-6 py-3 text-neutral-400 hover:text-neutral-50 hover:bg-neutral-800 transition-colors {active}">{item}</a>'

    # Build stats
    stats_html = ""
    for stat in stats[:4]:
        icon = icon_svg.get(stat.get("icon", "users"), icon_svg["users"])
        stats_html += f"""
    <div class="rounded-lg border border-neutral-700 bg-neutral-800 bg-opacity-50 p-6">
      <div class="flex items-start justify-between mb-4">
        <p class="text-neutral-400 text-sm font-medium">{stat.get('label', 'Stat')}</p>
        <div class="text-{accent_light}">{icon}</div>
      </div>
      <p class="text-3xl font-bold text-neutral-50">{stat.get('value', '0')}</p>
    </div>"""

    # Build table
    table_html = ""
    table_html += f"""
    <table class="w-full">
      <thead>
        <tr class="border-b border-neutral-700">"""
    for header in table_headers[:4]:
        table_html += f'<th class="text-left py-3 px-4 text-neutral-400 text-sm font-medium">{header}</th>'
    table_html += """
        </tr>
      </thead>
      <tbody>"""
    for row in table_rows[:3]:
        table_html += "<tr class='border-b border-neutral-700 hover:bg-neutral-800 transition-colors'>"
        for cell in row[:4]:
            table_html += f'<td class="py-3 px-4 text-neutral-300 text-sm">{cell}</td>'
        table_html += "</tr>"
    table_html += """
      </tbody>
    </table>"""

    app_jsx = f'''function Sidebar() {{
  return (
    <aside class="hidden md:block w-64 bg-neutral-900 border-r border-neutral-700 h-screen sticky top-0 overflow-y-auto">
      <div class="px-6 py-8">
        <h1 class="text-2xl font-bold text-neutral-50">{app_name}</h1>
      </div>
      <nav class="space-y-1">{sidebar_html}
      </nav>
    </aside>
  );
}}

function Topbar() {{
  return (
    <header class="bg-neutral-900 border-b border-neutral-700 px-6 py-4 flex justify-between items-center sticky top-0 z-10">
      <h2 class="text-2xl font-bold text-neutral-50">{page_title}</h2>
      <div class="flex gap-4 items-center">
        <input type="text" placeholder="Search..." class="bg-neutral-800 border border-neutral-700 rounded-lg px-4 py-2 text-neutral-50 placeholder-neutral-500 focus:outline-none focus:border-{accent_light} hidden md:block" />
        <div class="w-10 h-10 rounded-full bg-{accent_light} bg-opacity-20"></div>
      </div>
    </header>
  );
}}

function StatsGrid() {{
  return (
    <section class="p-6 grid grid-cols-1 md:grid-cols-4 gap-4">{stats_html}
    </section>
  );
}}

function ChartSection() {{
  return (
    <section class="px-6 pb-6">
      <div class="rounded-lg border border-neutral-700 bg-neutral-800 bg-opacity-30 p-6">
        <h3 class="text-lg font-semibold text-neutral-50 mb-6">{chart_title}</h3>
        <div class="h-64 flex items-end justify-center gap-4 px-8">
          <div class="w-12 bg-{accent_light} h-1/2 rounded-t-lg"></div>
          <div class="w-12 bg-{accent_light} h-2/3 rounded-t-lg"></div>
          <div class="w-12 bg-{accent_light} h-3/4 rounded-t-lg"></div>
          <div class="w-12 bg-{accent_light} h-1/3 rounded-t-lg"></div>
          <div class="w-12 bg-{accent_light} h-4/5 rounded-t-lg"></div>
          <div class="w-12 bg-{accent_light} h-1/2 rounded-t-lg"></div>
        </div>
      </div>
    </section>
  );
}}

function DataTable() {{
  return (
    <section class="px-6 pb-6">
      <div class="rounded-lg border border-neutral-700 bg-neutral-800 bg-opacity-30 p-6 overflow-x-auto">
        <h3 class="text-lg font-semibold text-neutral-50 mb-4">Recent activity</h3>
        {table_html}
      </div>
    </section>
  );
}}

function App() {{
  return (
    <div class="flex h-screen bg-neutral-950">
      <Sidebar />
      <div class="flex-1 flex flex-col overflow-hidden">
        <Topbar />
        <div class="flex-1 overflow-y-auto">
          <StatsGrid />
          <ChartSection />
          <DataTable />
        </div>
      </div>
    </div>
  );
}}
'''

    return {
        "package.json": """{
  "name": "dashboard",
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
  <title>Dashboard</title>
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
        "README.md": f"""# {app_name}

Admin dashboard and internal tool.

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
