import { Suspense } from "react";
import { GuideButton } from "./GuideButton";
import { Logo } from "./Logo";
import { SearchBox, SearchBoxFromUrl } from "./SearchBox";
import { TopBarEnd } from "./TopBarEnd";

/** The 56 px top bar: hamburger and logo, centered search, actions on the right. */
export function TopBar() {
  return (
    <header className="fixed inset-x-0 top-0 z-40 flex h-14 items-center border-b border-divider bg-surface px-4 shadow-[0_2px_12px_rgba(76,29,149,0.06)]">
      <div className="flex shrink-0 items-center">
        <GuideButton />
        <Logo />
      </div>
      <Suspense fallback={<SearchBox />}>
        <SearchBoxFromUrl />
      </Suspense>
      <div className="flex shrink-0 items-center gap-2">
        <Suspense fallback={<div className="flex items-center gap-2"><span className="h-8 w-8 rounded-full bg-skeleton" /><span className="h-8 w-20 rounded-full bg-skeleton" /></div>}>
          <TopBarEnd />
        </Suspense>
      </div>
    </header>
  );
}
