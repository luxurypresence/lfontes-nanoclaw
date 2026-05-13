import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildClientSchema, getIntrospectionQuery, printSchema } from 'graphql';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REFERENCES_DIR = join(__dirname, '..', 'references');

// =============================================================================
// BEARER TOKENS - Update these when they expire
// Environment variables take precedence if set
// =============================================================================

const X_LP_API_KEY = '2r4kPE1dqCA6adxVf7RPspQ3dV4nzEEomkIuHN7bRlpLcTvaMM7pCCrkkwxjYGy8';

// =============================================================================
// ENDPOINTS CONFIGURATION
// =============================================================================
const ENDPOINTS = {
  current: {
    url: 'https://graphql.luxurycoders.com/graphql',
    outputFile: 'schema.graphql',
    name: 'Current (graphql.luxurycoders.com)',
  },
  legacy: {
    url: 'https://gw.luxurycoders.com/graphql',
    outputFile: 'schema-legacy.graphql',
    name: 'Legacy (gw.luxurycoders.com)',
  },
};

async function fetchSchema(endpoint: (typeof ENDPOINTS)[keyof typeof ENDPOINTS]) {
  console.log(`\nFetching ${endpoint.name} schema from:`, endpoint.url);

  const introspectionQuery = getIntrospectionQuery();

  const response = await fetch(endpoint.url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-lp-api-key': X_LP_API_KEY,
    },
    body: JSON.stringify({
      query: introspectionQuery,
    }),
  });

  if (!response.ok) {
    throw new Error(`HTTP error! status: ${response.status} ${response.statusText}`);
  }

  const result = await response.json();

  if (result.errors) {
    throw new Error(`GraphQL errors: ${JSON.stringify(result.errors, null, 2)}`);
  }

  if (!result.data) {
    throw new Error('No data returned from introspection query');
  }

  const schema = buildClientSchema(result.data);
  const sdl = printSchema(schema);

  const outputPath = join(REFERENCES_DIR, endpoint.outputFile);
  writeFileSync(outputPath, sdl, 'utf-8');

  console.log(`✅ ${endpoint.name} schema saved to:`, outputPath);
  console.log(`   Total size: ${(sdl.length / 1024).toFixed(2)} KB`);
}

async function fetchAllSchemas() {
  console.log('Fetching GraphQL schemas...');

  const results: { name: string; success: boolean; error?: string }[] = [];

  for (const endpoint of Object.values(ENDPOINTS)) {
    try {
      await fetchSchema(endpoint);
      results.push({ name: endpoint.name, success: true });
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      console.error(`❌ Failed to fetch ${endpoint.name} schema:`, errorMessage);
      results.push({
        name: endpoint.name,
        success: false,
        error: errorMessage,
      });
    }
  }

  console.log('\n--- Summary ---');
  for (const result of results) {
    if (result.success) {
      console.log(`✅ ${result.name}: Success`);
    } else {
      console.log(`❌ ${result.name}: Failed - ${result.error}`);
    }
  }

  const hasFailures = results.some((r) => !r.success);
  if (hasFailures) {
    process.exit(1);
  }
}

void fetchAllSchemas();
