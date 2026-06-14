---
name: s3-presigned-upload-fails-nonexistent-bucket
description: |
  Diagnose browser/server S3 uploads that fail even though presigned-URL generation
  "works". Use when: (1) browser direct PUT to a presigned S3 URL fails with
  "Failed to fetch", (2) a same-origin/server fallback upload returns 500 / generic
  "Upload failed", (3) the configured bucket name looks plausible but uploads never
  land. Key insight: generating a presigned URL requires NO S3 permission and does
  NOT verify the bucket exists, so a wrong/missing bucket name passes presign and
  only fails at PUT time. Covers HeadBucket 404-vs-403 interpretation, using the
  CloudFront origin to find the REAL bucket name, and the "repo renamed but infra
  kept old names" drift pattern.
author: Claude Code
version: 1.0.0
date: 2026-06-14
source: https://github.com/voitta-ai/skillz
source_file: skills/s3-presigned-upload-fails-nonexistent-bucket/SKILL.md
---

> **Canonical source.** This skill lives in the repo at
> `skills/s3-presigned-upload-fails-nonexistent-bucket/SKILL.md`.

# S3 presigned upload fails: the bucket is wrong/missing, not the code

## Problem
Media/file upload fails. The browser shows `Failed to fetch` on the direct
presigned `PUT`; a server-side fallback returns 500 "Upload failed". The app code
and env look correct, so it's tempting to blame CORS or the code — but the real
cause is often that the **configured bucket name doesn't exist**.

## Context / Trigger conditions
- App generates a presigned `PutObject` URL server-side and the browser PUTs to it.
- Direct PUT: `Failed to fetch` (browser can't distinguish nonexistent-host/404/CORS).
- Server fallback `PutObject`: `NoSuchBucket: The specified bucket does not exist`.
- The IAM creds are valid (`aws sts get-caller-identity` works).

## Why presign hides it
`getSignedUrl(s3, new PutObjectCommand(...))` only **signs** a request locally — it
makes no AWS call, needs no `s3:PutObject` permission, and never checks that the
bucket exists. So a misconfigured `*_BUCKET` env sails through presign and only
blows up when something actually talks to S3.

## Solution / diagnostic steps
Use an admin AWS profile (`aws --profile <admin>`):
1. **HeadBucket — 404 vs 403 is the tell:**
   ```
   aws s3api head-bucket --bucket <configured-name>
   ```
   - `404 Not Found` -> you HAVE permission for that name but the bucket does not
     exist (name is wrong / never created / deleted).
   - `403` -> bucket exists but creds lack access (different problem).
2. **Find the REAL bucket via CloudFront origin** (the public base URL usually fronts
   it): `aws cloudfront list-distributions` and read
   `Origins.Items[0].DomainName` -> e.g. `the-real-bucket.s3.<region>.amazonaws.com`.
3. **Check the IAM policy resource ARN too** — `aws iam get-user-policy ...`. The
   uploader policy often references the SAME wrong name; fix the `Resource` ARN.
4. **Fix all three to the real name:** the env var(s), the IAM policy resource, and
   (if browser PUT is used) the bucket CORS `AllowedOrigins`.

## Verification
- `aws s3api put-object --bucket <real> --key uploads/_diag/x --body f` returns an
  `ETag` using the APP's (uploader) creds, not just admin.
- Re-run the upload in the app; the object appears under the real bucket.

## Notes
- **Naming drift is the usual culprit.** After a repo/project rename, infra
  frequently keeps old or differently-suffixed names (e.g. bucket `<name>-prod` vs
  `<name>-prod-<accountid>`, a database project still under the pre-rename name).
  Never assume infra names match the repo; confirm each.
- `s3:ListAllMyBuckets` is often denied for scoped app users — don't rely on
  `list-buckets`; use `head-bucket` on candidate names and the CloudFront origin.
- A server-side upload fallback is a fine resilience layer, but it ALSO needs the
  correct bucket + `s3:PutObject` on it — it won't paper over a missing bucket.
