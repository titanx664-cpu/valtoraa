export const FIRST_PURCHASE_BONUS_RATE = 7.5;

// Presentation only: the authoritative calculation is performed with
// PostgreSQL numeric values in the approval transaction.
export function firstPurchaseBonusAmount(planPrice: number): number {
  const priceInMinorUnits = Math.round(Number(planPrice) * 100);
  return (priceInMinorUnits * FIRST_PURCHASE_BONUS_RATE) / 10000;
}
