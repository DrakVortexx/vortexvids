import { ImageResponse } from "next/og";
import { siteConfig } from "@/site.config";

export const alt = siteConfig.siteName;
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default function Image() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          background: "#faf5ff",
          position: "relative",
          overflow: "hidden",
        }}
      >
        <div style={{ position: "absolute", left: -140, top: -180, width: 480, height: 480, borderRadius: 240, background: "#ede9fe", opacity: 0.9 }} />
        <div style={{ position: "absolute", right: -120, bottom: -220, width: 520, height: 520, borderRadius: 260, background: "#ddd6fe", opacity: 0.8 }} />
        <div style={{ display: "flex", alignItems: "center", gap: 28 }}>
          <div
            style={{
              display: "flex",
              width: 150,
              height: 150,
              borderRadius: 75,
              background: "#7c3aed",
              alignItems: "center",
              justifyContent: "center",
            }}
          >
            <div style={{ display: "flex", width: 86, height: 86, borderRadius: 43, border: "12px solid #fff" }} />
          </div>
          <div style={{ display: "flex", flexDirection: "column" }}>
            <div style={{ display: "flex", fontSize: 104, fontWeight: 700, letterSpacing: -5, color: "#6d28d9" }}>
              {siteConfig.siteName}
            </div>
            <div style={{ display: "flex", marginTop: 16, fontSize: 34, color: "#4c1d95" }}>
              {siteConfig.description}
            </div>
          </div>
        </div>
      </div>
    ),
    size,
  );
}
