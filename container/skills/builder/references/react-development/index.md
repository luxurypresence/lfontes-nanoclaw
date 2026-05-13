---
name: react-development
description: React and frontend development using shadcn/ui components, Tailwind CSS v4, and modern React patterns. Use when creating or modifying React components, working with UI components, or styling.
---

# React Development

## Overview

This Skill guides React and frontend development using shadcn/ui components, Tailwind CSS v4, and lucide-react icons.

**Supporting Files:**

- [reference.md](reference.md) - shadcn/ui component API documentation
- [examples.md](examples.md) - Component patterns and code examples
- [templates/](templates/) - Component templates and boilerplate code

## UI Components: shadcn/ui

This project uses **shadcn/ui** components directly (not the LP design system). Components are installed into `src/components/ui/`.

### Available Components

Install components as needed with:

```bash
pnpm dlx shadcn@latest add <component>
```

Common components: button, input, textarea, checkbox, label, badge, avatar, card, separator, skeleton, collapsible, dialog, sheet, popover, tooltip, select, tabs, dropdown-menu, command, table, scroll-area.

### Import Pattern

```typescript
// shadcn/ui components from local ui directory
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Card, CardHeader, CardTitle, CardContent } from '@/components/ui/card';
```

### Icons - Always Use lucide-react

```typescript
// ✅ Correct - import from lucide-react
import { Search, Filter, Tag, User, ChevronDown, Play, RotateCcw } from 'lucide-react';

// Usage
<Search className="size-4" />
<Filter className="size-5 text-muted-foreground" />
```

## Tailwind CSS v4 + shadcn Color Tokens

This project uses shadcn's oklch-based CSS custom properties. **Never use default Tailwind colors.**

### Color Token Patterns

| Use Case       | Token Class                                  | Description          |
| -------------- | -------------------------------------------- | -------------------- |
| Primary text   | `text-foreground`                            | Default text color   |
| Secondary text | `text-muted-foreground`                      | Muted/secondary text |
| Background     | `bg-background`                              | Default background   |
| Card           | `bg-card text-card-foreground`               | Card surfaces        |
| Primary action | `bg-primary text-primary-foreground`         | Primary buttons      |
| Secondary      | `bg-secondary text-secondary-foreground`     | Secondary buttons    |
| Muted          | `bg-muted text-muted-foreground`             | Muted backgrounds    |
| Accent         | `bg-accent text-accent-foreground`           | Hover/accent states  |
| Destructive    | `bg-destructive text-destructive-foreground` | Error/destructive    |
| Border         | `border-border`                              | Default borders      |
| Input          | `border-input`                               | Input borders        |
| Ring           | `ring-ring`                                  | Focus rings          |

### Bad vs Good

```typescript
// ❌ Bad - Default Tailwind colors
className = 'text-black bg-white text-gray-500 border-gray-200';

// ✅ Good - shadcn tokens
className = 'text-foreground bg-background text-muted-foreground border-border';
```

## Code Style Guidelines

### TypeScript

- **Strict mode enabled** - All code must pass strict TypeScript checks
- **Explicit typing** - Avoid `any` types
- **PascalCase** for interfaces and types
- **No file extensions** in imports

### File Naming

- **Component files**: kebab-case (e.g., `step-card.tsx`, `prompt-editor.tsx`)
- **Component names**: PascalCase (e.g., `StepCard`, `PromptEditor`)
- **Hook files**: kebab-case with `use-` prefix (e.g., `use-step-state.ts`)
- **Utility files**: kebab-case (e.g., `format-date.ts`)

### React

- Functional components only with hooks
- All props typed with interfaces
- Use `React.memo` for expensive components when appropriate

### Styling

- TailwindCSS preferred over inline styles
- `cn()` utility from `@/lib/utils` for class composition
- `class-variance-authority` (cva) for components with variants
- Use shadcn tokens, never raw colors

### Styling Example

```typescript
import { cn } from '@/lib/utils';

export function MyComponent({ variant }: Props) {
  return (
    <div className={cn(
      'flex items-center gap-4',
      'bg-card text-card-foreground',
      variant === 'primary' && 'bg-primary text-primary-foreground'
    )}>
      Content
    </div>
  );
}
```

## React Hooks Best Practices

Before using `useEffect`, ask: [You Might Not Need an Effect](https://react.dev/learn/you-might-not-need-an-effect)

- Calculate derived state during render, not in effects
- Use event handlers instead of effect chains
- Use `useState` initializer for localStorage/initial data
- Only use effects for external system sync (WebSocket, browser APIs, analytics)
- For data fetching, use TanStack Query (this project's standard)

## Data Fetching

This project uses **TanStack Query** with **TanStack Start server functions**:

```typescript
import { createServerFn } from '@tanstack/react-start';
import { queryOptions } from '@tanstack/react-query';

// Server function
const getData = createServerFn({ method: 'GET' })
  .inputValidator((data: { id: string }) => data)
  .handler(async ({ data }) => {
    // runs on server
    return fetchFromAPI(data.id);
  });

// Query options factory
export const dataQueryOptions = (id: string) =>
  queryOptions({
    queryKey: ['data', id],
    queryFn: () => getData({ data: { id } }),
  });
```

## Questions to Ask Before Making Changes

1. Is there a shadcn/ui component I can use? (`pnpm dlx shadcn@latest add <name>`)
2. Am I using lucide-react for icons?
3. Am I using shadcn color tokens (not raw Tailwind colors)?
4. Am I using `cn()` for conditional classes?
5. For data fetching, am I using TanStack Query + server functions?
