# Code Examples

## Component with shadcn/ui

```typescript
import { cn } from '@/lib/utils';
import { Button } from '@/components/ui/button';
import { Card, CardHeader, CardTitle, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Play, RotateCcw } from 'lucide-react';

interface StepCardProps {
  title: string;
  status: 'not_run' | 'running' | 'complete' | 'error';
  onRun: () => void;
  children: React.ReactNode;
}

export function StepCard({ title, status, onRun, children }: StepCardProps) {
  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between">
        <div className="flex items-center gap-2">
          <CardTitle className="text-base">{title}</CardTitle>
          <Badge variant={status === 'complete' ? 'default' : status === 'error' ? 'destructive' : 'secondary'}>
            {status}
          </Badge>
        </div>
        <Button size="sm" onClick={onRun} disabled={status === 'running'}>
          {status === 'complete' ? <RotateCcw className="mr-1 size-3" /> : <Play className="mr-1 size-3" />}
          {status === 'complete' ? 'Re-run' : 'Run'}
        </Button>
      </CardHeader>
      <CardContent>{children}</CardContent>
    </Card>
  );
}
```

## Data Fetching with TanStack Query

```typescript
import { queryOptions, useSuspenseQuery } from '@tanstack/react-query';
import { createServerFn } from '@tanstack/react-start';

const getSession = createServerFn({ method: 'GET' })
  .inputValidator((data: { id: string }) => data)
  .handler(async ({ data }) => {
    // Server-side data fetching
    return db.query.sessions.findFirst({ where: eq(sessions.id, data.id) });
  });

export const sessionQueryOptions = (id: string) =>
  queryOptions({
    queryKey: ['session', id],
    queryFn: () => getSession({ data: { id } }),
  });

// In component
function SessionView({ sessionId }: { sessionId: string }) {
  const { data: session } = useSuspenseQuery(sessionQueryOptions(sessionId));
  return <div>{session.name}</div>;
}
```

## Form with shadcn/ui

```typescript
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';

function PromptEditor({ prompt, onSave }: { prompt: string; onSave: (text: string) => void }) {
  const [text, setText] = useState(prompt);

  return (
    <div className="space-y-3">
      <Label htmlFor="prompt">Prompt</Label>
      <Textarea
        id="prompt"
        value={text}
        onChange={(e) => setText(e.target.value)}
        rows={8}
        className="font-mono text-sm"
      />
      <div className="flex justify-end gap-2">
        <Button variant="outline" onClick={() => setText(prompt)}>Reset</Button>
        <Button onClick={() => onSave(text)}>Save</Button>
      </div>
    </div>
  );
}
```
