# Security policy

Thataway reads other apps' accessibility trees and, with the optional vision fallback, images of
their windows. A bug that exposes that content is a security bug, and I want to hear about it.

## Report a problem privately

Email **jalen.edusei@gmail.com** with "Thataway security" in the subject. Please do not open a
public issue for a security problem.

Include:

- what you found and what an attacker could do with it;
- steps to reproduce, and the macOS version and Mac model;
- whether you built with a Developer ID, Apple Development or ad hoc signature.

Leave real personal content out of the report. A fictional window or a test account shows the
problem just as well.

I will confirm that I received the report, keep you updated while I work on a fix, and credit you
in the changelog if you want the credit.

## What counts

- Thataway reading or capturing an app or window that matches an exclusion rule.
- Screen content, accessibility text or audio leaving the Mac.
- The vision sidecar's temp file being readable by another user, or surviving after the reply.
- The sidecar, or a file it reads, being replaceable by another process to run code as you.
- The hotkey event tap swallowing keystrokes other than Option Space, or keeping any keystroke it sees.
- Watch me recordings or `exclusions.conf` written somewhere other users can read.

Bugs in the resolver's accuracy, or a pointer landing on the wrong control, are ordinary bugs.
Please file those as issues.

## Supported versions

There are no releases yet. Fixes go to the `main` branch, and only the latest `main` is
supported.
