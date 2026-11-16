---
name: overnight-security-check
description: 주차된 차를 밤이나 외출 중에 확인합니다. 잠금, 감시 모드, 창문, 충전구, 켜 둔 공조, 충전 여부를 다룹니다. 차가 잠겼는지, 취침 전 점검, 잠그기, 밤에 꽂혀 있는지를 물을 때 사용합니다. 출발 준비는 prepare-trip 스킬이 담당합니다.
---

# Overnight Security Check

## 1. Read the car's state once

Use the Get Tesla Vehicle Info tool with the security, charging, battery, and climate topics. Use the returned values for every decision below. Don't call it again after each step.

## 2. Secure the car

- If the car isn't locked, lock it with the Lock Tesla tool. Locking doesn't need the user's permission, because it's what they asked for.
- Sentry Mode: turn it on with the Set Tesla Sentry Mode tool only if the user asked for full security, or said the car is parked away from home. Tesla won't run Sentry Mode at 20% battery or below; if the battery is that low, tell the user instead.
- If the user asked about windows, use the Close Tesla Windows tool. The user is asked to confirm.
- If the charge port door is open and the car isn't plugged in, close it with the Control Tesla Charge Port tool.

## 3. Climate

- If climate is on and the user didn't ask to keep it on, turn it off with the Turn Off Tesla Climate tool.
- If Dog Mode is on, leave climate running and mention that Dog Mode is keeping the cabin conditioned. Never turn Dog Mode off unless the user asks.

## 4. Charging

- If the car is unplugged and the battery is under 50%, say so clearly. You can't plug it in.
- If it's plugged in but not charging, and the user wants it charged by morning, use the Start Tesla Charging tool.
- Only change the charge limit if the user names a limit.

## 5. Report

Give a short checklist: locked or not, Sentry Mode, anything you closed or turned off, battery percent and range, and whether the car is charging, plugged in, or unplugged.

## Don't

- Don't unlock the car, open the trunk or frunk, or turn Sentry Mode off as part of this check.
