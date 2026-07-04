# Exercise Image Attribution

ForgeFit bundles optimized exercise thumbnails derived from the open-source `free-exercise-db` image dataset:

https://github.com/yuhonas/free-exercise-db

The source image path from `ForgeFit/Resources/exercises.json` is preserved as `mediaSlug`, and the bundled thumbnail filename is a sanitized form of that path. Rebuild thumbnails with:

```sh
node ForgeFit/scripts/build_exercise_thumbnails.js
```
