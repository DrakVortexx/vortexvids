import { Suspense } from "react";
import { ShortsSkeleton, ShortsView } from "@/components/shorts/ShortsView";

export const metadata = { title: "Snips | vortexvids" };

export default function Snips() {
  return (
    <Suspense fallback={<ShortsSkeleton />}>
      <ShortsView />
    </Suspense>
  );
}
