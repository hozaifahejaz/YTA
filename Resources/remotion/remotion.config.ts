import { Config } from "@remotion/cli/config";

// Kept low for a fanless MacBook Air (section 8.4, Rendering).
Config.setConcurrency(2);
Config.setVideoImageFormat("jpeg");
Config.setOverwriteOutput(true);
