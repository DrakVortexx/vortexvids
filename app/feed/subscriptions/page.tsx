import { Suspense } from "react";
import { SubscriptionsSkeleton, SubscriptionsView } from "@/components/subscriptions/SubscriptionsView";

export const metadata = { title: "Subscriptions | vortexvids" };

export default function SubscriptionsFeed() {
  return (
    <Suspense fallback={<SubscriptionsSkeleton />}>
      <SubscriptionsView />
    </Suspense>
  );
}
