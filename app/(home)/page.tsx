import { Suspense } from "react";
import { FeedSkeleton, FeedView } from "@/components/feed/FeedView";

export default function Home() {
  return (
    <Suspense fallback={<FeedSkeleton title="Recommended" />}>
      <FeedView
        kind="newest"
        title="Recommended"
        placeholder={{
          title: "Welcome to vortexvids",
          hint: "This site is ready for videos. Once a channel uploads one, it will show up here.",
        }}
      />
    </Suspense>
  );
}
