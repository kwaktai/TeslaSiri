---
name: prepare-trip
description: Get the user's car or Tesla ready to leave, by checking range and tire pressure, warming or cooling the cabin, and sending the destination to the car's navigation. Use when the user asks to get my car ready, prep the car for a commute or road trip, warm up or cool down my car before leaving, or asks if my car is ready to drive somewhere. Not for a single command like only setting the temperature or only sending an address, and not for securing a parked car overnight.
---

# Prepare a Trip

## 1. Check readiness

Use the Get Tesla Vehicle Info tool with the battery, range, charging, tire pressure, and climate topics.

- Tires: flag any tire under 38 PSI. Most Teslas recommend about 42 PSI cold.
- Range: if the user named a destination or a distance, compare it with the range. If less than about 20% of range would be left at arrival, say so.
  - If the car is plugged in, offer to raise the charge limit with the Set Tesla Charge Limit tool (90% for a long trip, 100% only if the user asks), and start charging with the Start Tesla Charging tool. The user confirms the limit change.
  - If it's unplugged, tell the user they'll need to charge before or during the trip.

## 2. Condition the cabin in one step

Use the Configure Tesla Cabin Climate tool once, rather than separate climate tools. Choose the settings from the weather and what the user said:

- Freezing outside, or the user mentions ice, frost, or snow: about 22 °C, max defrost on, driver seat heat 3, steering wheel heater on.
- Hot cabin (above about 29 °C or 85 °F): about 20 °C. Driver seat cooling only if the user asks.
- Otherwise: 21 °C, or the temperature the user asked for.
- Smoke or poor air quality: turn on Bioweapon Defense Mode.

The user may say Fahrenheit. Convert to Celsius (°C = (°F − 32) × 5 ⁄ 9) and keep it between 15 and 28 °C.

## 3. Send the destination

If the user gave a destination, use the Send Destination to Tesla tool with the most complete address or place name you have. If they gave only a business name, include the city if you know it.

## 4. Report

Summarize in a few lines: battery and range, cabin settings that were applied, any low tire, and the destination that was sent.

## Don't

- Don't unlock the car or open the trunk or frunk unless the user asked.
- Don't turn Dog Mode off.
