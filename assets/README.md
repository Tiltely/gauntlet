# assets

`banner.gif` — the README header. Same shape as lens's: **640×200, animated, `width="100%"`**
in the markup so it renders full-width on GitHub.

The current one is Kurapika's Judgement Chain — a condition set in the target's heart
that closes if the condition is broken, which is this plugin's whole argument in one
image. Source: a 640×358 gif, cropped with the second recipe below; 376 KB, 29 frames.

To replace it, drop the source clip or gif here and crop it to the banner shape:

```sh
# from a video clip
ffmpeg -i source.mp4 -ss 00:00:03 -t 3 \
  -vf "fps=15,scale=640:-1:flags=lanczos,crop=640:200:0:ih/2-100,split[a][b];[a]palettegen[p];[b][p]paletteuse" \
  -loop 0 banner.gif

# from an existing gif
ffmpeg -i source.gif \
  -vf "scale=640:-1:flags=lanczos,crop=640:200:0:ih/2-100,split[a][b];[a]palettegen[p];[b][p]paletteuse" \
  -loop 0 banner.gif
```

Keep it under ~1.5 MB — lens's is 1.3 MB and GitHub renders it fine, but a heavier one makes
the README slow to load on mobile.
