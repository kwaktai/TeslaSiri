---
name: software-update-advisor
description: Explain the user's car or Tesla software update status and what's new, read the release notes aloud, and install or cancel an update when the user asks. Use when the user asks if my car has an update, what's new in the car update or the current version, to read the release notes, whether now is a good time to update my car, or to install or cancel a car software update.
---

# Software Update Advisor

## 1. Find out where the update stands

Use the Check Tesla Software Update tool. It tells you the installed version, the available version, and whether the update is downloading, ready to install, scheduled, or installing.

## 2. Read what's new

- Use the Read Tesla Release Notes tool. Leave the version empty to get the notes for the pending update, or for the installed version when there's no update.
- If the user asked about a topic ("anything for FSD?"), pass it as the feature filter.
- Summarize the most interesting features in a sentence each. Read the full notes only if the user asks for everything.

## 3. Installing

Only install when the user asks to. Before using the Install Tesla Software Update tool:

- If the update is still downloading, say so with the download progress, and don't try to install yet.
- Remind the user that the car can't be driven during the install, which usually takes 20–40 minutes.
- If the battery is under 20%, use the Get Tesla Vehicle Info tool with the battery topic, and recommend charging first.

The tool asks the user to confirm before it starts.

## 4. Canceling

If an install is scheduled and the user wants to drive, or asks to cancel, use the Cancel Tesla Software Update tool. It can't stop an install that has already started.

## Don't

- Don't install an update just because one is available. The user has to ask.
