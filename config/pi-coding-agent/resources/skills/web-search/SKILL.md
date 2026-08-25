---
name: web-search
description: Plans and guides web search across local SearXNG and public search engines, then fetches source pages for cited answers. Use when user asks to search the web, find current information, compare external sources, look beyond the codebase, or explicitly mentions Google, Bing, DuckDuckGo, SearXNG, latest, current, or web research.
---

# Web Search

Use this skill when local files are not enough and the agent needs external web results.

## Quick start

1. Shape the query mentally before fetching:
   - `general`: use the user query as-is.
   - `recent`: prefer fresher results; retry with the current year if needed.
   - `docs`: prefer official docs; retry with `documentation`, `site:`, or `filetype:pdf` if needed.
2. Try local SearXNG first.
3. If SearXNG is unavailable or weak, fetch DuckDuckGo Lite and Bing in parallel.
4. Only add Google if DDG/Bing are weak, blocked, or low quality.
5. Open 2-5 promising source pages and answer with citations.

## Workflow

### 1) Plan
- Infer the query mode from the request: `general`, `recent`, or `docs`.
- Use the available fetch/index tool for search pages and source pages.
- In this repo that will usually be a context-mode fetch/index tool such as `ctx_fetch_and_index`.
- Construct search URLs directly; no helper script is required.

### 2) Search
- Try local SearXNG first at `http://localhost:8081/search?q=<encoded query>&format=json`.
- If SearXNG errors, times out, or returns weak results, switch to:
  - `https://lite.duckduckgo.com/lite/?q=<encoded query>`
  - `https://www.bing.com/search?q=<encoded query>`
- Extract candidate result URLs from engine result pages.
- Do not treat search snippets as evidence; use them only to triage which pages to open.
- If an engine returns anti-bot, CAPTCHA, or unusable markup, skip it and continue.

### 3) Fetch sources
- Open 2-5 candidate pages.
- Prefer primary sources: official docs, vendor pages, specs, repositories, maintainers, or the original announcement.
- Use secondary summaries only when primary sources are missing or insufficient.

### 4) Retry once if results are weak
- Retry once with one operator-heavy reformulation.
- Good retry patterns:
  - `site:example.com <query>` when an authoritative domain is known.
  - `"<query>"` for exact phrases.
  - `<query> <current year>` for recent topics.
  - `<query> documentation` for docs lookups.
  - `filetype:pdf <query>` for reports, papers, or manuals.
- If SearXNG is unavailable and DDG/Bing are weak, add Google at this stage.

### 5) Answer
- Answer the user's request directly.
- Cite every non-trivial factual claim with source links.
- If sources conflict, say so and summarize the disagreement.
- For time-sensitive topics, prefer fresher or primary sources.

## Guardrails
- Default output contract: concise synthesis with citations.
- Do not claim certainty from one weak secondary source.
- If search quality remains poor after retry, say what was tried and what is still missing.

## Notes
- Local SearXNG endpoint assumption: `http://localhost:8081/search?q=<query>&format=json`
- Default fallback policy without SearXNG: DuckDuckGo Lite + Bing first, Google only if needed.
