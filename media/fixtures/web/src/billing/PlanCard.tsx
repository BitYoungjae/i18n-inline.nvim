import { useTranslation } from 'react-i18next'
import { Button, Card, Price } from '@/ui'
import type { Plan } from './types'

export function PlanCard({ plan }: { plan: Plan }) {
  const { t } = useTranslation('billing')

  return (
    <Card>
      <h2>{t('plan.title', 'Choose your plan')}</h2>
      <p>{t('plan.subtitle', 'Cancel any time.')}</p>
      <Price unit={t('plan.perSeat', 'per seat / month')} />
      <p>{t('plan.seats', '{{n}} seats', { n: plan.seats })}</p>
      <Button>{t('cta.upgrade', 'Start free trial')}</Button>
      <small>{t('cta.noCard', 'No credit card required')}</small>
    </Card>
  )
}
