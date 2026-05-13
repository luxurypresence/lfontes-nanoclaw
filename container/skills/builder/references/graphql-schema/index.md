---
name: graphql-schema
description: Fetch and reference GraphQL schemas from Luxury Presence endpoints. This skill should be used when working with GraphQL queries, mutations, or types for the current (graphql.luxurycoders.com) or legacy (gw.luxurycoders.com) APIs. Use it to look up type definitions, available queries/mutations, field types, or when building new GraphQL operations.
---

# GraphQL Schema Reference

This skill provides access to GraphQL schemas for Luxury Presence APIs through introspection.

## IMPORTANT: Always Fetch First

**Before reading or searching the schema files, ALWAYS run the fetch script to ensure you have the latest schema:**

```bash
npx tsx scripts/fetch-schema.ts
```

This ensures the schema is always up-to-date with the production API. The schema files in `references/` may be stale, so fetching fresh data is mandatory before any schema lookup.

## Available Schemas

Two schemas are maintained in `references/`:

- `schema.graphql` - Current API (graphql.luxurycoders.com)
- `schema-legacy.graphql` - Legacy API (gw.luxurycoders.com)

## Usage Workflow

### Step 1: Fetch Latest Schema (Required)

Always start by fetching the latest schema:

```bash
npx tsx scripts/fetch-schema.ts
```

**Note:** This requires a valid API key. If the fetch fails with authentication errors, update the `X_LP_API_KEY` constant in `scripts/fetch-schema.ts`.

### Step 2: Look Up Types and Queries

After fetching, read or grep the schema files in `references/`:

```bash
# Find a type definition
grep -A 20 "^type User " references/schema.graphql

# Find all queries
grep -A 2 "^type Query" references/schema.graphql

# Find fields containing a keyword
grep -i "listing" references/schema.graphql
```

### When Fetch Fails

If the fetch script fails with authentication errors:

1. Verify the API key in `scripts/fetch-schema.ts` is valid
2. Ask the user to provide a valid API key

## Common Tasks

| Task                   | Action                                                     |
| ---------------------- | ---------------------------------------------------------- |
| Find a type definition | `grep -A 30 "^type TypeName " references/schema.graphql`   |
| Find an input type     | `grep -A 20 "^input InputName " references/schema.graphql` |
| Find an enum           | `grep -A 10 "^enum EnumName " references/schema.graphql`   |
| List all queries       | `grep -A 100 "^type Query" references/schema.graphql`      |
| List all mutations     | `grep -A 100 "^type Mutation" references/schema.graphql`   |
| Search for a field     | `grep "fieldName" references/schema.graphql`               |
