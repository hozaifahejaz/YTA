// Colour looks, applied to the picture only. A LUT file is not used in the browser renderer, so looks are CSS filters.
export const looks: Record<string, string> = {
  neutral: "none",
  warm: "sepia(0.18) saturate(1.08) contrast(1.04)",
  cool: "saturate(0.92) hue-rotate(-6deg) contrast(1.05)",
  archive: "sepia(0.35) contrast(1.08) brightness(0.96)",
  mono: "grayscale(1) contrast(1.1)",
};

export const colourFilter = (look?: string | null): string => looks[look ?? "neutral"] ?? "none";
