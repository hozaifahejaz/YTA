import { CalculateMetadataFunction, Composition } from "remotion";
import { Edit } from "./Edit";
import { Props, Timeline } from "./types";

const empty: Timeline = {
  schemaVersion: 1,
  fps: 30,
  width: 1920,
  height: 1080,
  duration: 5,
  music: [],
  clips: [{ shot: "s001", start: 0, end: 5, kind: "textCard", text: "No timeline loaded", transition: "cut" }],
  captions: [],
  style: { name: "documentary", captions: true, captionStyle: "clean", motion: "documentary", transitions: "cut" },
};

// The timeline decides size, length and frame rate; the composition only picks the aspect.
const fromTimeline: CalculateMetadataFunction<Props> = ({ props }) => {
  const t = props.timeline;
  return {
    fps: t.fps,
    width: t.width,
    height: t.height,
    durationInFrames: Math.max(1, Math.ceil(t.duration * t.fps)),
  };
};

export const Root: React.FC = () => {
  return (
    <>
      <Composition
        id="Long"
        component={Edit}
        durationInFrames={150}
        fps={30}
        width={1920}
        height={1080}
        defaultProps={{ timeline: empty }}
        calculateMetadata={fromTimeline}
      />
      <Composition
        id="Short"
        component={Edit}
        durationInFrames={150}
        fps={30}
        width={1080}
        height={1920}
        defaultProps={{ timeline: { ...empty, width: 1080, height: 1920 } }}
        calculateMetadata={fromTimeline}
      />
    </>
  );
};
