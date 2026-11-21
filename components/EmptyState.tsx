import Link from "next/link";
import { LogoMark } from "./icons";

/**
 * A real empty state: one clear message and one next step. Grey card grids are
 * for loading only, so an empty or unavailable feature never looks half loaded.
 */
export function EmptyState({
  title = "Nothing here yet",
  hint = "Check back soon.",
  action,
}: {
  title?: string;
  hint?: string;
  action?: { href: string; label: string };
}) {
  return (
    <div className="mx-auto flex max-w-[2200px] justify-center px-4 py-12 sm:px-6 sm:py-20" data-empty-state>
      <div className="w-full max-w-md rounded-2xl border border-divider bg-surface px-6 py-10 text-center shadow-[0_8px_32px_rgba(124,58,237,0.08)] sm:px-10">
        <div className="mx-auto mb-5 grid h-14 w-14 place-items-center rounded-full bg-hover">
          <LogoMark className="h-8 w-8" />
        </div>
        <h1 className="text-[20px] font-medium leading-7 text-text">{title}</h1>
        <p className="mx-auto mt-2 max-w-sm text-[14px] leading-6 text-text-2">{hint}</p>
        {action && (
          <Link
            href={action.href}
            className="btn-blue mt-6 normal-case"
          >
            {action.label}
          </Link>
        )}
      </div>
    </div>
  );
}
