// Shipped motion styles, selected by name from styles/editing.json.
export const motionStyles = ["documentary", "calm", "punchy"] as const;

const ease = (t: number) => t * t * (3 - 2 * t);

/** Maps a clip's progress (0 to 1) to how far its movement has gone. */
export const motionCurve = (style: string, t: number): number => {
  const clamped = Math.min(1, Math.max(0, t));
  switch (style) {
    case "calm":
      return ease(clamped) * 0.6;
    case "punchy":
      return Math.min(1, ease(clamped) * 1.4);
    default:
      return ease(clamped);
  }
};
