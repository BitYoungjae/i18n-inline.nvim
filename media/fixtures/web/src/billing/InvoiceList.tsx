import { useTranslation } from 'react-i18next'
import { EmptyState, Table } from '@/ui'
import type { Invoice } from './types'

export function InvoiceList({ invoices }: { invoices: Invoice[] }) {
  const { t } = useTranslation('billing')

  if (invoices.length === 0) {
    return <EmptyState title={t('invoices.empty', 'No invoices yet')} />
  }

  return (
    <Table
      caption={t('invoices.title', 'Invoices')}
      columns={[
        { key: 'date', label: t('invoices.date', 'Date') },
        { key: 'amount', label: t('invoices.amount', 'Amount') },
        { key: 'status', label: t('invoices.status', 'Status') },
      ]}
      rows={invoices}
    />
  )
}
