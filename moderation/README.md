# Moderation list

Every copy of Carrel fetches `blocklist.json` from this repo's `main` branch on launch and hides
anything listed, everywhere in the app (iPhone and Apple TV). This is how reports are acted on,
as App Store Guideline 1.2 requires, ideally within 24 hours of the report.

To act on a report (it arrives by email with the claim ID):

1. Add the video's claim ID to `claims`, or the channel's claim ID to `channels` (removes all its
   videos too). `tags` hides any video carrying that tag.
2. Update `updated`, commit and push to `main`.

Apps pick it up on their next launch (GitHub's raw CDN can take a few minutes).
