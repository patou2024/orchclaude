# orchclaude template: REST API

Build a complete REST API server in this directory.

## Project Goal

Create a production-quality REST API with full CRUD operations, input validation,
error handling, and documentation. Use the language/framework already present in
this directory. If no preference is detected, default to Node.js + Express.

## Endpoints to implement

| Method | Path              | Description                                      |
|--------|-------------------|--------------------------------------------------|
| GET    | /health           | Health check: returns `{ status: "ok", uptime }` |
| GET    | /api/items        | List all items (supports ?search= and ?limit=)   |
| GET    | /api/items/:id    | Get one item by ID (404 if not found)            |
| POST   | /api/items        | Create a new item                                |
| PUT    | /api/items/:id    | Update an existing item (404 if not found)       |
| DELETE | /api/items/:id    | Delete an item (404 if not found)                |

## Item schema

```json
{
  "id": "uuid-v4",
  "name": "string (required, 1-100 chars)",
  "description": "string (optional, max 500 chars)",
  "createdAt": "ISO 8601 timestamp",
  "updatedAt": "ISO 8601 timestamp"
}
```

## Requirements

- **Storage**: in-memory only (no database); data resets on restart
- **Validation**: return 400 with a clear `{ error: "..." }` body for bad input
- **Errors**: 400 bad request, 404 not found, 500 internal — all return JSON
- **CORS**: enabled for all origins
- **Logging**: log method + path + status code + response time on every request
- **Content-Type**: always respond with `application/json`

## Deliverables

1. Working server file(s) with all endpoints implemented
2. Dependency manifest (`package.json` / `requirements.txt` / `go.mod` etc.)
3. `README.md` with:
   - Install and start instructions
   - Full endpoint reference
   - Example curl commands for every endpoint

## Acceptance

Run the server and verify:
- All 6 endpoints respond correctly
- POST /api/items with missing `name` returns 400
- GET /api/items/:id with unknown ID returns 404
- README is accurate and complete

When done, output: ORCHESTRATION_COMPLETE
