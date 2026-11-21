import { EmptyState } from "@/components/EmptyState";

export const metadata = { title: "Library | vortexvids", robots: { index: false } };

export default function Library() {
  return (
    <EmptyState
      title="Your library is empty."
      hint="Videos you watch show up in History, and the channels you follow in Subscriptions."
      action={{ href: "/", label: "Browse videos" }}
    />
  );
}
