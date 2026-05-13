/**
 * {{ComponentName}}
 *
 * {{Description}}
 */

import { cn } from '@/utils/utils';

interface {{ComponentName}}Props {
  className?: string;
  // Add your props here
}

export function {{ComponentName}}({ className, ...props }: {{ComponentName}}Props) {
  return (
    <div className={cn('', className)}>
      {/* Component content */}
    </div>
  );
}

// Default export (optional)
export default {{ComponentName}};
