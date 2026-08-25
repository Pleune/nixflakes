# Context7

Search for libraries and query their documentation via the Context7 API.

## Search Libraries

```bash
./search.js "library name" "what you need help with"
```

Example:

```bash
./search.js "react" "hooks for state management"
```

Returns matching libraries with Context7-compatible IDs for use with the docs tool.

## Query Documentation

```bash
./docs.js "/org/project" "your question"
```

Example:

```bash
./docs.js "/websites/react_dev" "useEffect cleanup"
```

Use the library ID from search results. Returns relevant documentation and code examples.
