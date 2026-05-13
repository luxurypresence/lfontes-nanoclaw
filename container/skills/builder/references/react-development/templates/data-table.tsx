/**
 * {{TableName}}
 *
 * DataTable component using design-system-ui with filtering, sorting, and pagination.
 */

import {
  DataTable,
  columns
} from '@luxury-presence/design-system-ui/components/composite/data-table';
import { Button } from '@luxury-presence/design-system-ui/components/ui/button';
import { Badge } from '@luxury-presence/design-system-ui/components/ui/badge';

// Define your data type
interface {{DataType}} {
  id: string;
  name: string;
  email: string;
  status: 'active' | 'inactive';
  // Add your fields here
}

interface {{TableName}}Props {
  data: {{DataType}}[];
  isLoading?: boolean;
  onRowClick?: (row: {{DataType}}) => void;
}

export function {{TableName}}({ data, isLoading, onRowClick }: {{TableName}}Props) {
  // Define columns using the column builder API
  const tableColumns = [
    columns.text('name', {
      header: 'Name',
      cell: (row) => (
        <div className="font-medium text-on-surface">
          {row.name}
        </div>
      )
    }),
    columns.text('email', {
      header: 'Email',
      cell: (row) => (
        <span className="text-on-surface-variant">
          {row.email}
        </span>
      )
    }),
    columns.select('status', {
      header: 'Status',
      cell: (row) => (
        <Badge variant={row.status === 'active' ? 'default' : 'secondary'}>
          {row.status}
        </Badge>
      ),
      options: [
        { value: 'active', label: 'Active' },
        { value: 'inactive', label: 'Inactive' }
      ]
    }),
    columns.actions('actions', {
      header: 'Actions',
      cell: (row) => (
        <Button
          size="sm"
          variant="ghost"
          onClick={() => onRowClick?.(row)}
        >
          View
        </Button>
      )
    })
  ];

  return (
    <DataTable
      columns={tableColumns}
      data={data}
      enableFiltering
      enableSorting
      enablePagination
      isLoading={isLoading}
      onRowClick={onRowClick}
    />
  );
}

export default {{TableName}};
