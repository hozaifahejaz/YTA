import { Video } from "@remotion/media";
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { motionCurve } from "./styles/motion";
import { TextCard } from "./styles/textCard";
import { Clip } from "./types";

export const ClipView: React.FC<{ clip: Clip; fadeFrames: number; motionStyle: string }> = ({ clip, fadeFrames, motionStyle }) => {
  const frame = useCurrentFrame();
  const { durationInFrames } = useVideoConfig();
  const opacity = fadeFrames > 0 ? interpolate(frame, [0, fadeFrames], [0, 1], { extrapolateRight: "clamp" }) : 1;

  if (clip.kind === "textCard" || !clip.file) {
    return (
      <AbsoluteFill style={{ opacity }}>
        <TextCard text={clip.text ?? ""} />
      </AbsoluteFill>
    );
  }

  if (clip.kind === "video") {
    return (
      <AbsoluteFill style={{ opacity }}>
        <Video src={staticFile(clip.file)} muted style={{ width: "100%", height: "100%", objectFit: "cover" }} />
      </AbsoluteFill>
    );
  }

  // Still images get slow movement (section 8.4).
  const progress = motionCurve(motionStyle, frame / Math.max(1, durationInFrames - 1));
  const m = clip.motion ?? { fromScale: 1.05, toScale: 1.12, fromX: 0, toX: 0, fromY: 0, toY: 0 };
  const scale = m.fromScale + (m.toScale - m.fromScale) * progress;
  const x = m.fromX + (m.toX - m.fromX) * progress;
  const y = m.fromY + (m.toY - m.fromY) * progress;

  return (
    <AbsoluteFill style={{ opacity, overflow: "hidden" }}>
      {/* A blurred copy fills the frame behind images that are not 16:9. */}
      <Img src={staticFile(clip.file)} style={{ position: "absolute", width: "100%", height: "100%", objectFit: "cover", filter: "blur(40px) brightness(0.5)", transform: "scale(1.2)" }} />
      <Img
        src={staticFile(clip.file)}
        style={{
          position: "absolute",
          width: "100%",
          height: "100%",
          objectFit: "contain",
          transform: `scale(${scale}) translate(${x}%, ${y}%)`,
        }}
      />
    </AbsoluteFill>
  );
};
