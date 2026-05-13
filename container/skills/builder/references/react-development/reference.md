# shadcn/ui Component Reference

## Button

```typescript
import { Button } from '@/components/ui/button';

// Variants: default, destructive, outline, secondary, ghost, link
// Sizes: default, sm, lg, icon
<Button variant="default" size="default">Click me</Button>
<Button variant="outline" size="sm">Small</Button>
<Button variant="ghost" size="icon"><Icon className="size-4" /></Button>
```

## Input

```typescript
import { Input } from '@/components/ui/input';

<Input type="email" placeholder="Enter email" className="max-w-sm" />
```

## Card

```typescript
import { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter } from '@/components/ui/card';

<Card>
  <CardHeader>
    <CardTitle>Title</CardTitle>
    <CardDescription>Description</CardDescription>
  </CardHeader>
  <CardContent>Content</CardContent>
  <CardFooter><Button>Action</Button></CardFooter>
</Card>
```

## Dialog

```typescript
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter, DialogTrigger } from '@/components/ui/dialog';

<Dialog open={open} onOpenChange={setOpen}>
  <DialogTrigger asChild><Button>Open</Button></DialogTrigger>
  <DialogContent>
    <DialogHeader>
      <DialogTitle>Title</DialogTitle>
      <DialogDescription>Description</DialogDescription>
    </DialogHeader>
    <div>Content</div>
    <DialogFooter>
      <Button variant="outline" onClick={() => setOpen(false)}>Cancel</Button>
      <Button onClick={handleSubmit}>Submit</Button>
    </DialogFooter>
  </DialogContent>
</Dialog>
```

## Badge

```typescript
import { Badge } from '@/components/ui/badge';

// Variants: default, secondary, destructive, outline
<Badge>Default</Badge>
<Badge variant="secondary">Secondary</Badge>
```

## Select

```typescript
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

<Select value={value} onValueChange={setValue}>
  <SelectTrigger className="w-[180px]">
    <SelectValue placeholder="Select" />
  </SelectTrigger>
  <SelectContent>
    <SelectItem value="a">Option A</SelectItem>
    <SelectItem value="b">Option B</SelectItem>
  </SelectContent>
</Select>
```

## Tabs

```typescript
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';

<Tabs defaultValue="tab1">
  <TabsList>
    <TabsTrigger value="tab1">Tab 1</TabsTrigger>
    <TabsTrigger value="tab2">Tab 2</TabsTrigger>
  </TabsList>
  <TabsContent value="tab1">Content 1</TabsContent>
  <TabsContent value="tab2">Content 2</TabsContent>
</Tabs>
```

## Textarea

```typescript
import { Textarea } from '@/components/ui/textarea';

<Textarea placeholder="Type here..." rows={6} />
```

## Label

```typescript
import { Label } from '@/components/ui/label';

<Label htmlFor="email">Email</Label>
```

## Scroll Area

```typescript
import { ScrollArea } from '@/components/ui/scroll-area';

<ScrollArea className="h-[400px]">
  {/* Long content */}
</ScrollArea>
```

## Color Tokens (shadcn oklch)

| Token                     | CSS Variable           | Use               |
| ------------------------- | ---------------------- | ----------------- |
| `bg-background`           | `--background`         | Page background   |
| `text-foreground`         | `--foreground`         | Primary text      |
| `bg-card`                 | `--card`               | Card backgrounds  |
| `text-card-foreground`    | `--card-foreground`    | Card text         |
| `bg-primary`              | `--primary`            | Primary actions   |
| `text-primary-foreground` | `--primary-foreground` | Text on primary   |
| `bg-secondary`            | `--secondary`          | Secondary actions |
| `bg-muted`                | `--muted`              | Muted backgrounds |
| `text-muted-foreground`   | `--muted-foreground`   | Secondary text    |
| `bg-accent`               | `--accent`             | Hover/accent      |
| `bg-destructive`          | `--destructive`        | Error/destructive |
| `border-border`           | `--border`             | Borders           |
| `border-input`            | `--input`              | Input borders     |
| `ring-ring`               | `--ring`               | Focus rings       |
