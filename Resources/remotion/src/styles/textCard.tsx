import { AbsoluteFill, interpolate, useCurrentFrame, useVideoConfig } from "remotion";

export const TextCard: React.FC<{ text: string }> = ({ text }) => {
  const frame = useCurrentFrame();
  const { width, height } = useVideoConfig();
  const rise = interpolate(frame, [0, 12], [24, 0], { extrapolateRight: "clamp" });
  const opacity = interpolate(frame, [0, 10], [0, 1], { extrapolateRight: "clamp" });
  const size = Math.round(Math.min(width, height) * (text.length > 60 ? 0.05 : 0.08));
  return (
    <AbsoluteFill style={{ backgroundColor: "#111214", justifyContent: "center", alignItems: "center", padding: width * 0.1 }}>
      <div
        style={{
          color: "#f4f2ee",
          fontFamily: "Inter, 'Helvetica Neue', Arial, sans-serif",
          fontWeight: 600,
          fontSize: size,
          lineHeight: 1.2,
          textAlign: "center",
          opacity,
          transform: `translateY(${rise}px)`,
        }}
      >
        {text}
      </div>
    </AbsoluteFill>
  );
};
