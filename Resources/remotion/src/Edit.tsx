import { Audio } from "@remotion/media";
import { AbsoluteFill, interpolate, Sequence, staticFile, useVideoConfig } from "remotion";
import { ClipView } from "./ClipView";
import { CaptionTrack } from "./styles/captions";
import { colourFilter } from "./styles/looks";
import { Props } from "./types";

const gain = (db: number) => Math.pow(10, db / 20);

export const Edit: React.FC<Props> = ({ timeline }) => {
  const { fps } = useVideoConfig();
  const frames = (seconds: number) => Math.round(seconds * fps);

  return (
    <AbsoluteFill style={{ backgroundColor: "#0b0b0c" }}>
      <AbsoluteFill style={{ filter: colourFilter(timeline.style.colourLook) }}>
        {timeline.clips.map((clip, index) => {
          const from = frames(clip.start);
          const length = Math.max(1, frames(clip.end) - from);
          // A fading clip starts a little early and fades in over the one before.
          const overlap = clip.transition === "fade" && index > 0 ? Math.min(12, from) : 0;
          return (
            <Sequence key={clip.shot} from={from - overlap} durationInFrames={length + overlap} premountFor={fps}>
              <ClipView clip={clip} fadeFrames={overlap} motionStyle={timeline.style.motion} />
            </Sequence>
          );
        })}
      </AbsoluteFill>

      {timeline.style.captions ? <CaptionTrack captions={timeline.captions} variant={timeline.style.captionStyle} /> : null}

      {timeline.narration ? <Audio src={staticFile(timeline.narration)} /> : null}

      {timeline.music.map((cue) => {
        const from = frames(cue.start);
        const length = Math.max(1, frames(cue.end) - from);
        const level = gain(cue.gainDb);
        return (
          <Sequence key={cue.file + cue.start} from={from} durationInFrames={length}>
            <Audio
              src={staticFile(cue.file)}
              loop
              volume={(f) =>
                level *
                interpolate(f, [0, fps * 2, length - fps * 3, length], [0, 1, 1, 0], {
                  extrapolateLeft: "clamp",
                  extrapolateRight: "clamp",
                })
              }
            />
          </Sequence>
        );
      })}
    </AbsoluteFill>
  );
};
