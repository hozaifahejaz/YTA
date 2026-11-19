import { AbsoluteFill, useCurrentFrame, useVideoConfig } from "remotion";
import { Caption } from "../types";

// Shipped caption styles: "clean" (small, low), "bold" (large, centred, heavy) and "minimal" (lower third, no box).
export const captionStyles = ["clean", "bold", "minimal"] as const;

export const CaptionTrack: React.FC<{ captions: Caption[]; variant: string }> = ({ captions, variant }) => {
  const frame = useCurrentFrame();
  const { fps, width, height } = useVideoConfig();
  const now = frame / fps;
  const current = captions.find((c) => now >= c.start && now < c.end);
  if (!current) return null;

  const base = Math.min(width, height);
  const vertical = height > width;
  const common: React.CSSProperties = {
    fontFamily: "Inter, 'Helvetica Neue', Arial, sans-serif",
    color: "#ffffff",
    textAlign: "center",
    maxWidth: width * 0.8,
  };

  if (variant === "bold") {
    return (
      <AbsoluteFill style={{ justifyContent: vertical ? "center" : "flex-end", alignItems: "center", paddingBottom: height * 0.14 }}>
        <div style={{ ...common, fontWeight: 800, fontSize: base * 0.065, textTransform: "uppercase", WebkitTextStroke: `${base * 0.004}px #000`, textShadow: "0 4px 18px rgba(0,0,0,0.6)" }}>
          {current.text}
        </div>
      </AbsoluteFill>
    );
  }

  if (variant === "minimal") {
    return (
      <AbsoluteFill style={{ justifyContent: "flex-end", alignItems: "center", paddingBottom: height * 0.08 }}>
        <div style={{ ...common, fontWeight: 500, fontSize: base * 0.038, textShadow: "0 2px 10px rgba(0,0,0,0.85)" }}>{current.text}</div>
      </AbsoluteFill>
    );
  }

  return (
    <AbsoluteFill style={{ justifyContent: "flex-end", alignItems: "center", paddingBottom: height * (vertical ? 0.22 : 0.07) }}>
      <div style={{ ...common, fontWeight: 600, fontSize: base * 0.042, backgroundColor: "rgba(10,10,12,0.62)", padding: `${base * 0.008}px ${base * 0.02}px`, borderRadius: base * 0.008 }}>
        {current.text}
      </div>
    </AbsoluteFill>
  );
};
