import Link from "next/link";
import { LogoMark } from "./icons";

/** The purple vortex mark and the two tone wordmark: "vortex" in purple, "vids" in the text color. */
export function Logo({ onClick }: { onClick?: () => void }) {
  return (
    <Link
      href="/"
      onClick={onClick}
      aria-label="vortexvids home"
      className="flex h-14 items-center gap-1 pl-4 pr-3 group"
    >
      <LogoMark className="h-7 w-7 transition-all group-hover:drop-shadow-[0_0_8px_rgba(139,92,246,0.6)]" />
      <span className="text-[20px] font-bold leading-none tracking-[-0.9px] text-text">
        <span className="text-[var(--logo-word)] transition-all group-hover:drop-shadow-[0_0_4px_rgba(109,40,217,0.5)]">vortex</span>vids
      </span>
    </Link>
  );
}
