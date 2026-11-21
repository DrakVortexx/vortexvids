import Link from "next/link";
import { EmptyState } from "@/components/EmptyState";
import { FeedGrid } from "@/components/feed/FeedGrid";
import { AccountCircleIcon, SubscriptionsIcon } from "@/components/icons";
import { SkeletonRow, videoGridClass } from "@/components/VideoCard";
import { subscriptionsFeed } from "@/lib/subscriptions/server";

const frame = "mx-auto max-w-[2200px] px-0 py-6 sm:px-6";

/** A calm, centred notice for states where there is nothing to show. */
function Notice({ state, title, text, children }: { state: string; title: string; text: string; children?: React.ReactNode }) {
  return (
    <div data-subs-state={state} className="mx-auto flex max-w-md justify-center px-6 py-12 text-center sm:py-20">
      <div className="w-full rounded-2xl border border-divider bg-surface px-6 py-10 shadow-[0_8px_32px_rgba(124,58,237,0.08)]">
        <div className="mx-auto mb-5 grid h-14 w-14 place-items-center rounded-full bg-hover">
          <SubscriptionsIcon className="h-8 w-8 text-[var(--mark)]" />
        </div>
        <h1 className="text-[20px] font-medium leading-7 text-text">{title}</h1>
        <p className="mt-2 text-[14px] leading-6 text-text-2">{text}</p>
        {children}
      </div>
    </div>
  );
}

export function SubscriptionsSkeleton() {
  return (
    <div className={frame} data-subs-state="loading">
      <div className="mb-4 h-5 w-24 bg-skeleton" />
      <div className={videoGridClass}>
        <SkeletonRow />
        <SkeletonRow />
      </div>
    </div>
  );
}

/**
 * /feed/subscriptions: uploads from the channels the person subscribes to,
 * under Today, This week and Older. Reads the request, so it is rendered
 * inside <Suspense>.
 */
export async function SubscriptionsView() {
  const state = await subscriptionsFeed();
  switch (state.kind) {
    case "off":
    case "no-db":
      return (
        <div data-subs-state={state.kind}>
          <EmptyState
            title="No subscriptions yet."
            hint="Subscriptions aren't switched on yet."
            action={{ href: "/trending", label: "Browse videos" }}
          />
        </div>
      );
    case "signed-out":
      return (
        <Notice
          state="signed-out"
          title="Don't miss new videos"
          text="Sign in to see updates from channels you subscribe to."
        >
          <Link
            href="/login?next=%2Ffeed%2Fsubscriptions"
            className="mt-6 inline-flex h-9 items-center gap-2 rounded-[2px] border border-[var(--link)] px-[11px] text-[14px] font-medium uppercase text-[var(--link)]"
          >
            <AccountCircleIcon className="h-6 w-6" />
            Sign in
          </Link>
        </Notice>
      );
    case "not-set-up":
      return (
        <div data-subs-state="not-set-up">
          <EmptyState
            title="Subscriptions aren't set up yet."
            hint="The site owner still needs to finish the database setup."
          />
        </div>
      );
    case "ready":
      if (state.page.cards.length === 0) {
        return (
          <Notice
            state="empty"
            title="No new videos"
            text="Subscribe to channels and their new uploads show up here."
          >
            <Link href="/trending" className="btn-blue mt-6">
              Browse videos
            </Link>
          </Notice>
        );
      }
      return (
        <div className={frame} data-subs-state="ready">
          <FeedGrid kind="subscriptions" initial={state.page} now={state.now} />
        </div>
      );
  }
}
