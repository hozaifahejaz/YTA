// Mirrors Sources/Workflow/Timeline.swift. Times are in seconds; files are relative to the video's Working files.

export type Motion = {
  fromScale: number;
  toScale: number;
  fromX: number;
  toX: number;
  fromY: number;
  toY: number;
};

export type Clip = {
  shot: string;
  start: number;
  end: number;
  kind: "image" | "video" | "textCard";
  file?: string;
  text?: string;
  motion?: Motion;
  transition: "cut" | "fade";
};

export type Caption = { start: number; end: number; text: string };

export type MusicCue = { file: string; start: number; end: number; gainDb: number };

export type EditStyle = {
  name: string;
  captions: boolean;
  captionStyle: string;
  motion: string;
  transitions: string;
  colourLook?: string | null;
};

export type Timeline = {
  schemaVersion: number;
  fps: number;
  width: number;
  height: number;
  duration: number;
  narration?: string;
  music: MusicCue[];
  clips: Clip[];
  captions: Caption[];
  style: EditStyle;
};

export type Props = { timeline: Timeline };
