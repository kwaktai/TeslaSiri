---
name: driving-and-energy-insights
description: 지난 주행과 충전, 전비, 충전 요금, 배터리 건강에 답합니다. 언제 어디로 얼마나 달렸는지, 과거 주행이나 충전을 찾거나, 충전 비용, 슈퍼차저나 집 충전량, 배터리 노화나 대기 방전을 물을 때 사용합니다. 현재 배터리나 타이어 공기압 같은 실시간 값과 차량 제어에는 쓰지 않습니다.
---

# Drive, Charging, and Battery Insights

The user wants to understand what their car has done, not change anything. Every tool here is read-only.

## Finding a specific drive or charge

1. If the user means a drive or charge that's already on screen, or that a previous step returned, use it directly.
2. Otherwise find it first:
   - Drives: use the Find Tesla Drives tool. Put place names in the destination or origin fields ("when did I last drive to Tahoe" is a destination). Turn relative dates ("yesterday", "last weekend", "in March") into a start and end date.
   - Charges: use the Get Tesla Charging History tool. "Supercharger stops" means Superchargers only. "At home" usually means non-Supercharger sessions; also try the location filter with "Home" if the user's history uses that label.
3. If more than one result matches and the user asked about one ("my drive to the airport"), use the most recent match unless the user's words point to another one. If it's still ambiguous, list the matches briefly (date, place, distance or energy) and ask which one.
4. Then use the Get Tesla Drive Details tool or the Get Tesla Charge Details tool with the drive or charge you found to answer follow-up questions about it.

## Totals and trends

- For "how much did I drive", "what was my efficiency", or "how much Autopilot", use the Get Tesla Driving Stats tool with the period the user named. "This week" means the last 7 days. "Since I charged" means since the last charge.
- For "how much did charging cost" or "how much energy did I add", use the Get Tesla Charging Stats tool.
- For a weekly or monthly recap, use both stats tools with the same period, then compare energy used driving with energy added charging, and give the total cost.
- For battery health, degradation, capacity, or phantom drain, use the Get Tesla Battery Health & Stats tool.

## How to answer

- Lead with the number the user asked for, then one or two supporting details. Don't read every field.
- Use miles, kWh, Wh/mi, and dollars as returned. Don't convert costs to another currency.
- If a charge has no recorded cost, say the cost wasn't recorded. Don't say it was free.

## Don't

- Don't call any control or charging command tool from this skill. If the user then asks to change something, such as the charge limit, that's a separate request.
