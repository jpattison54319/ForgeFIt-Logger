#!/usr/bin/env node
const { execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const repoRoot = path.resolve(__dirname, "..");
const exerciseJSON = path.join(repoRoot, "ForgeFit", "Resources", "exercises.json");
const outputDir = path.join(repoRoot, "ForgeFit", "ExerciseThumbnails");
const baseURL = "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/";

function resourceName(mediaPath) {
  return mediaPath.replace(/\.jpg$/i, "").replace(/[^A-Za-z0-9-]/g, "_");
}

function run(command, args) {
  execFileSync(command, args, { stdio: "ignore" });
}

fs.mkdirSync(outputDir, { recursive: true });

const exercises = JSON.parse(fs.readFileSync(exerciseJSON, "utf8"));
const frameZeroPaths = [...new Set(exercises.map((exercise) => exercise.image).filter(Boolean))];
const frameOnePaths = [...new Set(frameZeroPaths.map((mediaPath) => mediaPath.replace(/\/0\.jpg$/i, "/1.jpg")))];
let downloaded = 0;
let skipped = 0;
let failedRequired = 0;
let failedOptional = 0;

function downloadFrame(mediaPath, required) {
  const name = `${resourceName(mediaPath)}.jpg`;
  const out = path.join(outputDir, name);
  if (fs.existsSync(out) && fs.statSync(out).size > 0) {
    skipped += 1;
    return;
  }

  const tmp = path.join(os.tmpdir(), `forgefit-thumb-${process.pid}-${downloaded}-${path.basename(name)}`);
  try {
    run("curl", ["-L", "--fail", "--silent", "--show-error", `${baseURL}${encodeURI(mediaPath)}`, "-o", tmp]);
    try {
      run("sips", ["-s", "format", "jpeg", "-Z", "220", tmp, "--out", out]);
    } catch {
      fs.copyFileSync(tmp, out);
    }
    downloaded += 1;
    if (downloaded % 50 === 0) {
      console.log(`Downloaded ${downloaded} thumbnails...`);
    }
  } catch (error) {
    if (required) {
      failedRequired += 1;
      console.warn(`Failed required ${mediaPath}: ${error.message}`);
    } else {
      failedOptional += 1;
      console.warn(`Missing optional ${mediaPath}: ${error.message}`);
    }
  } finally {
    fs.rmSync(tmp, { force: true });
  }
}

for (const mediaPath of frameZeroPaths) downloadFrame(mediaPath, true);
for (const mediaPath of frameOnePaths) downloadFrame(mediaPath, false);

console.log(
  `Exercise thumbnails complete: ${downloaded} downloaded, ${skipped} skipped, ` +
  `${failedRequired} required failed, ${failedOptional} optional missing, ` +
  `${frameZeroPaths.length + frameOnePaths.length} total.`
);
if (failedRequired > 0) process.exitCode = 1;
