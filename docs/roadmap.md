# Pulse implementation roadmap

The checkboxes track implemented behavior across the supplied P0, P1 and P2 roadmap. Each section describes its verification coverage and any remaining device or distribution work.

[Two-minute sprint](../Previews/Sprint.mp4) · [Week planning walkthrough](../Previews/Week-planning.mp4) · [Simulator walkthrough](../Previews/Navigation.mp4) · [Check-in recording](../Previews/Check-in.mp4) · [Private sync design](private-sync.md)


## 1. Today & Home

Tap the date or greeting for the day overview. Tap the task duration for a smaller start, feedback, and completion. Quick add is available from the landscape.

- [x] Atmospheric home screen (P0)
- [x] Live time-of-day themes (P0)
- [x] Animated original illustrations (P0)
- [x] Personalized greeting (P0)
- [x] One recommended next action (P0)
- [x] Start / complete / defer action (P0)
- [x] Expandable day overview (P0)
- [x] Daily progress summary (P1)
- [x] Quick-add task (P0)
- [x] Manual recovery mode (P0)

## 2. Smart Day Planner

Flexible work fits around commitments, transition buffers, rest and the daily budget. Future previews assume earlier work is completed. Calendar arithmetic and 160 mixed schedules are covered by planner tests.

- [x] Automatic daily scheduling (P0)
- [x] Task priority and urgency (P0)
- [x] Duration estimates (P0)
- [x] Fixed commitments (P0)
- [x] Recurring tasks and routines (P0)
- [x] Task dependencies (P1)
- [x] Auto-reschedule missed tasks (P0)
- [x] Time-block editing (P0)
- [x] Drag-and-drop timeline (P1)
- [x] Break and buffer allocation (P0)
- [x] Schedule conflict resolution (P0)
- [x] One-tap regenerate day (P0)
- [x] Minimum viable day mode (P0)
- [x] Tomorrow preview (P1)
- [x] Weekly planning view (P1)

## 3. Task Management

Find Inbox, Projects, Routines and Archive in the Plan view menu. A simulator check saved a project and milestone, completed a weekly template, and verified its next occurrence had a fresh three-step checklist. Tasks support editable steps, notes, reminders and saved templates.

- [x] Task inbox (P0)
- [x] Natural-language quick capture (P1)
- [x] Projects and subtasks (P0)
- [x] Deadlines and reminders (P0)
- [x] Estimated effort and energy cost (P0)
- [x] Task splitting into smaller steps (P0)
- [x] Postpone and skip without penalty (P0)
- [x] Task templates (P1)
- [x] Snooze and defer (P0)
- [x] Task search and filtering (P1)
- [x] Task history and archive (P1)
- [x] Task notes (P1)

## 4. Energy & Mood

Physical energy, mental clarity and interest drive the illustration while dragging. Sleep, workload, stress, fatigue notes and recovery feedback are optional. The three-slider save flow took 7.31 seconds in the recorded simulator walkthrough and 7.75 seconds in a repeat on iOS 27.

- [x] Three-slider daily check-in (P0)
- [x] Physical energy tracking (P0)
- [x] Interest / motivation tracking (P0)
- [x] Mental clarity tracking (P0)
- [x] Optional sleep quality (P0)
- [x] Optional stress and fatigue notes (P1)
- [x] Multiple check-ins per day (P1)
- [x] Subjective recovery feedback (P0)
- [x] Energy history (P0)
- [x] Daily capacity estimate (P0)
- [x] User-controlled workload budget (P0)
- [x] Manual override of predictions (P0)
- [x] Optional symptom trend export (P1)

## 5. Adaptive Intelligence

Scheduling uses reported energy, time of day, personal history, task friction and feedback. Explanations and uncertainty depend on available observations. Longer-term comparisons require observations in both periods.

- [x] Personal baseline estimation (P0)
- [x] Dynamic task ranking (P0)
- [x] Task duration adaptation (P0)
- [x] Activation friction scoring (P1)
- [x] Energy prediction (P1)
- [x] Prediction uncertainty (P1)
- [x] Unexplained deviation detection (P1)
- [x] Long-term change detection (P2)
- [x] Time-of-day energy patterns (P1)
- [x] Recovery-aware planning (P0)
- [x] Gradual preference learning (P1)
- [x] User feedback on suggestions (P0)
- [x] Explainable recommendations (P1)
- [x] Safe cold-start defaults (P0)

## 6. Focus & Activation

Start opens the countdown over Today’s landscape. Finish can complete a step, complete a task or save partial progress. Use Capture distraction below the countdown to save a thought. The foreground rain loop is optional.

- [x] Native focus timer (P0)
- [x] Pause / resume / finish (P0)
- [x] Adjustable focus duration (P0)
- [x] Tiny first-step mode (P0)
- [x] Stuck / activation rescue (P0)
- [x] Gentle focus completion feedback (P0)
- [x] Focus session history (P1)
- [x] Distraction capture inbox (P1)
- [x] Automatic task continuation (P1)
- [x] Optional ambient sounds (P2)
- [x] Live Activity timer (P1)

## 7. AI Assistant

The assistant previews edits before applying them. The offline path was exercised with real task creation, rescheduling, clarification and step generation. The optional Apple Intelligence path requires a supported device with models installed.

- [x] Conversational task entry (P1)
- [x] AI day planning from free text (P1)
- [x] Break down overwhelming tasks (P1)
- [x] Natural-language rescheduling (P1)
- [x] Daily plan explanations (P1)
- [x] Task clarification (P1)
- [x] Preference-aware suggestions (P2)
- [x] Weekly reflection generation (P2)
- [x] AI tool-call validation (P1)
- [x] Offline deterministic fallback (P0)
- [x] AI privacy controls (P0)

## 8. Insights & Analytics

The date control opens earlier days and weeks. The comparison shows selected energy and clarity together. A 14-day simulator fixture verified calendar selection, missing days and review totals for prior weeks. Weekly review shows completion patterns, first saved plan versus recorded focus, and descriptive associations when sufficient data exists.

- [x] Daily energy chart (P0)
- [x] Weekly energy trends (P1)
- [x] Physical vs mental energy comparison (P1)
- [x] Time-to-first-action metric (P1)
- [x] Task completion patterns (P1)
- [x] Personal energy rhythm (P1)
- [x] Sleep-energy relationships (P2)
- [x] Activity and fatigue patterns (P1)
- [x] Plan accuracy metrics (P1)
- [x] Meaningful activity tracking (P1)
- [x] Missing-data indicators (P0)
- [x] Weekly review (P1)
- [x] Data export (P1)

## 9. Calendar & Integrations

Simulator checks exercised native permissions, Calendar and Reminders imports, duplicate prevention and Calendar write-back. The Health screen paired six hours of synthetic HealthKit sleep and 420 steps with a 7/10 check-in and recovery feedback. Switching days verified the empty state. Real-device HealthKit readings, spoken Siri invocation and the OneRep handoff remain unverified. The OneRep connection opens Workouts.

- [x] Apple Calendar integration (P1)
- [x] Calendar permission controls (P1)
- [x] Import fixed events (P1)
- [x] Calendar conflict detection (P1)
- [x] Optional write-back (P2)
- [x] Reminders import (P2). Choose individual lists for ongoing, one-way import. Pulse checks when it opens and when EventKit changes while it is active. Undated reminders stay in Inbox. Source changes preserve local edits, and users can stop a list even after revoking permission.
- [x] HealthKit sleep data (P2)
- [x] HealthKit activity data (P2)
- [x] Siri / App Intents (P1)
- [x] Shortcuts integration (P1)
- [x] Optional OneRep integration (P2)

## 10. Notifications & Widgets

The Home Screen widget and Dynamic Island timer were exercised on a simulator. A delivered Lock Screen notification was snoozed and its task updated. Showing titles, widget content and reminders is optional.

- [x] Local task reminders (P0)
- [x] Reminder preferences (P0)
- [x] Quiet hours (P0)
- [x] Notification action buttons (P1)
- [x] Home Screen widget (P1)
- [x] Lock Screen widget (P1)
- [x] Live Activities (P1)
- [x] Smart reminder throttling (P1)
- [x] Missed-plan recovery prompt (P1)
- [x] Morning check-in reminder (P1)
- [x] Notification-free mode (P0)

## 11. Native Design & Motion

Tab changes, Focus, timeline edits and preview changes support Reduce Motion. The Focus and Check-in flow passed with the simulator’s system Reduce Motion setting both on and off. Maximum Dynamic Type navigation was exercised on an iPhone simulator. Apple’s automated accessibility audit covered Welcome, Today, Tomorrow, Week, Insights, Health, Check-in and Focus. Spoken VoiceOver on physical hardware is unverified.

- [x] Five atmospheric themes (P0)
- [x] Smooth theme interpolation (P1)
- [x] Original landscape illustration system (P0)
- [x] Energy-reactive atmosphere (P1)
- [x] Beautiful light-first palette (P0)
- [x] Manual appearance overrides (P1)
- [x] Native haptics (P0)
- [x] Focus transition animation (P1)
- [x] Timeline microinteractions (P1)
- [x] Reduce Motion support (P0)
- [x] Dynamic Type support (P0)
- [x] VoiceOver accessibility (P0)
- [x] Performance profiling (P0)
- [x] Offline visual consistency (P0)

## 12. Routines & Consistency

Routine instances keep their weekday and step list through deferrals. Repeat can use selected weekdays. For example, a Tuesday/Thursday routine appears on those two days. Moving one occurrence preserves subsequent dates. Weekly practices continue to support a flexible number of days without choosing fixed weekdays. Timing estimates adapt after three measured completions. Routine templates include morning and weekly planning.

- [x] Recurring daily anchors (P1)
- [x] Flexible routines (P1)
- [x] Routine templates (P1)
- [x] Adaptive routine duration (P1)
- [x] Consistency without streak punishment (P1)
- [x] Rest-day recognition (P1)
- [x] Weekly planning ritual (P2)
- [x] Personal goals and milestones (P1)
- [x] Return-after-absence experience (P0)

## 13. Privacy & Data

SwiftData stores the journal in the app’s private container. File export and sync require an explicit choice. Sync encrypts before writing. Revision divergence, wrong keys, corruption and conflict resolution were exercised with isolated copies. Propagation between signed-in iCloud devices is unverified.

- [x] Local-first data storage (P0)
- [x] Reliable database migrations (P0)
- [x] Offline-first operation (P0)
- [x] Data backup and recovery (P1)
- [x] Optional cloud sync (P2)
- [x] End-to-end encryption design for sync (P2)
- [x] Export data to JSON / CSV (P1)
- [x] Delete all personal data (P0)
- [x] Privacy onboarding (P0)
- [x] AI consent and disclosure (P0)
- [x] Sensitive data minimization (P0)
- [x] Private-by-default analytics (P0)
- [x] Appropriate teen protections (P0)
- [x] No medical diagnosis or dose advice (P0)

## 14. Reliability & Launch

The signed local archive and exported IPA contain Pulse, its widget and Control Center extension, its share extension, and three privacy manifests. Apple’s seven native XCTest accessibility checks found no issues on Welcome, Today, Tomorrow, Week, Insights, Health, Check-in or Focus. A deliberately inaccessible control produced seven findings. Direct checks also covered touch targets, maximum text size and Reduce Motion. Physical battery measurement remains open. TestFlight distribution is on hold at the owner’s request.

- [x] First-launch onboarding (P0)
- [x] Working demo mode (P0)
- [x] Empty / loading / error states (P0)
- [x] Automated unit tests (P0)
- [x] Planner simulation tests (P0)
- [x] UI regression tests (P1)
- [x] Accessibility audit (P0). Eight representative screens were audited in the iPhone simulator.
- [x] Crash reporting with privacy controls (P0)
- [ ] Performance and battery testing (P0). Simulator sampling only.
- [x] Graceful AI/network failure (P0)
- [x] App lifecycle restoration (P0)
- [ ] App Store privacy compliance (P0). Public privacy policy URL and owner disclosures pending.
- [ ] TestFlight distribution (P0). On hold.
- [x] In-app feedback (P1)
- [x] Feature flags (P1)

## Short sessions and end-of-day planning

- **Start small.** Start a two-minute first step from Today, the app icon, Shortcuts or Control Center. With an open minute and no task ready, Open sprint starts a timer and logs the work without creating a task. Existing commitments, daily limits and planned tasks keep their time. An active session reopens at its current time. Finish step completes just that checklist item. An empty journal offers Add a task and Open sprint. A saved return cue appears when the task comes up again.
- **Capture a distraction.** Save from the countdown, the sprint’s Lock Screen activity, or the Capture a distraction shortcut. Untimed thoughts stay in Inbox until the user schedules them. Durations alone keep that behavior. A saved draft interprets relative dates from its last text edit, including after midnight or a time-zone change. Each line of a to-do dump keeps its own time reference. Explicit dates, availability windows and clock times feed the planner. In Plan’s Inbox, filter to Inbox only or use a thought’s calendar button to choose when it goes on the schedule. Assigning a project keeps an unscheduled thought in Inbox. A running or paused timer keeps its state. Today and Insights can reopen the thoughts saved during a particular sprint, including an unfinished local draft. When a two-minute step ends, Keep going offers up to five more minutes within the remaining task time and planning limits. Time spent deciding after the bell is excluded.
- **Something easier.** Under Not now, try an available task with lower energy demand. Undo returns to the original suggestion. Neither choice postpones the original task.
- **Weekly practices.** In Plan’s Routines view, choose a number of days per week. Log a day directly or add a flexible session to the plan. Completing a linked task counts the day.

- **Spare moment.** Open the day overview or choose “Find a shorter task” under Today’s “Not now” button. Choose 5, 10 or 15 minutes to see whole tasks that fit. Tapping a task starts its Focus timer.
- **Resume notes.** Open the task title during Focus to edit a cue, or choose “Leave a note and finish” to save it with the session. The cue appears next time that task starts. Fresh routine occurrences and templates start with an empty cue.
- **Close out today.** Open the day overview or the Plan view menu. Select unfinished tasks and confirm the move to tomorrow. The reviewed occurrence carries its steps and progress forward. Deadlines and future routine cadence stay in place.

## Getting started and working from the task list

A personal journal starts empty. Welcome offers an optional interactive walkthrough of capture, scheduling, repeating blocks, Focus, and energy. Reopen it from Settings, from an empty Today, or at the Schedule lesson from Planning options in Plan. Practice entries live only while the walkthrough is open. Existing journals retire the former default intention only when it has no edits, progress, history, or references.

Tap the play button beside an Inbox or All items task to start its Focus session when time is available. Starting a held Inbox item for a session keeps its unfinished remainder in Inbox. Swipe left on a task’s title or hold it and choose Delete task. The confirmation names the task and notes affected dependencies or future repeats. Deletion preserves its photos and recorded sessions. Task icons can use a symbol, an emoji, or an initial. Tap the icon beside the task name in its editor, or hold a task and choose Change icon. Templates and new routine occurrences carry the custom icon forward.

Plan’s Routines view offers New repeating task. The Repeat control includes daily, weekly, weekdays, weekends, and custom day selections. Repeating focus and protected blocks support a first date and optional last date. Overnight reservations finish the next morning, including the last scheduled opening.

## Pictures, to-do capture and Health

- **Picture log.** Attach a photo in a task editor, or choose “Finish with a photo” in Focus. Open the log from Plan’s view menu to add a photo to an existing or new task, filter plan and completion pictures, or zoom in. Add or edit an optional caption. Search by caption, original or current task title, or project. Photos keep the task title and date, including after task deletion. Deleting a photo removes it from local recovery too. Photos are resized and re-encoded before being stored. The journal allows up to 300 photos within a total of 24 MiB. JSON backups include them. Private sync and CSV exclude them.
- **Share to Pulse.** Use the iOS share sheet for text, a web link or one photo. Choose Save as distraction to keep the item in Inbox and associate it with its local sprint. The optional timing field uses the time zone at sharing. Dates in shared articles and photo captions are kept as content. Pulse imports the task on its next foreground visit. A picture waiting for space stays on this device until a slot is available.
- **To-do dump.** Enter one task per line from Plan’s view menu or Add to plan. Review the titles, durations and usual energy demands before saving. Unsent text and reviewed rows survive relaunch. Saving or cancelling clears that draft. Each task’s estimated cost changes with daily capacity. The scheduler uses the relationship between demand and available energy when ranking work.
- **Health.** Browse up to 28 days of available heart readings, a rolling 14-day energy chart, individual hours and six future days. Forecasts need observations on three distinct days. In a simulator left open across midnight, new synthetic HealthKit readings automatically changed both the Health estimate and Plan capacity from 2/10 to 8/10. Physiological estimates use comparable prior resting pulse, HRV or sleep measurements available when the check-ins were entered. Earlier days each contribute one rating from their closest recorded set of measurements, with each logged hour weighted equally. Tap the source beneath a modeled score to see the actual days and ratings behind it. A recovery estimate also shows the matched measurements. Open a contributing day to see its history. An hour can be corrected or reset. Turn on Automatic plan adjustments below the energy graph for recurring use, or choose Use for today’s plan in Health planning. While active, Pulse refreshes Health data on launch, at day changes and at approximately 15-minute intervals. The scheduler uses hour-specific estimates and, for later days with sparse hourly history, the supported daily forecast. The forecast pencil sets expected energy for a whole future day or a single upcoming hour. A whole-day adjustment follows the local date during travel. An hourly adjustment keeps its selected instant. Plan uses those values directly. Check-ins and corrections supply the recorded history. Health’s Past forecasts compares the first modeled forecast saved the previous day with completed days of self-reported energy. Manual capacity and recovery limits still apply.

## Forecast timeline and appearance

- Plan opens on Today’s plan, with one full-day overview and a chronological agenda. Tap the overview to open a particular hour or use its heading to show the hourly ruler. The hourly energy trace shares its time axis with task blocks and commitments. Drag a task onto an hour, or tap it to compare demand and forecast, choose a valid start, or let Pulse pick. A move pins this occurrence and preserves existing fixed time, buffers, prerequisites and workload limits. A blocked hour offers a nearby opening. If a whole day is booked, Pulse compares the remaining feasible times and offers a different slot to accept. Missing forecast hours remain blank. The full-day overview shows busy intervals and the visible time window. Tapping it jumps to an hour. It also accepts a task drop.
- **Still to schedule.** At the end of the Week agenda, review real tasks with time still outside this projection. The review shows planned and remaining minutes, explains known constraints, and opens the timing picker. Completed tasks and Inbox-only thoughts are excluded.
- Tomorrow shows one dated agenda. Week lists all seven agendas with start times and empty days. Tap a date to jump there or Show hours to open its forecast. Drag a task’s grip to another day to use an available hour, or drop on an expanded ruler to choose an hour directly. Seven day targets appear during a grip drag, including when the destination is offscreen. Week timing compares feasible day/hour combinations across today and the next six local days. Let Pulse pick considers energy, commitments and completion of the whole task before its deadline. What changes previews the effect on other tasks without saving a move. Undo restores the previous timing. After relaunch, Unpin time returns a task to automatic planning. Use usual schedule removes a single routine exception. Day-level estimates can support a suggestion when hourly evidence is sparse. A projected routine can move between neighboring occurrences. Pulse saves the chosen time locally and applies it when the previous occurrence is completed.
- Optional task hours restrict work to the selected local weekdays and times. Overnight windows begin on the chosen weekdays. For example, “Call the repair shop only on weekdays from 9am to 5pm” sets these constraints during capture. The timing picker, a manual drop, a new sprint and resuming Focus honor them.
- **Appointment preparation.** Open an upcoming commitment, or hold its row, to add a 10-minute prep task. You can also link an existing task from either the commitment or task editor, or link a sprint capture directly from its review. The task keeps its photos, checklist and notes. It follows the selected occurrence and must finish before its transition buffer. If Calendar becomes unavailable, Pulse retains the last known time. A real EventKit update moved a simulated appointment into a running prep session. The countdown shortened, stopped at the new boundary and recorded the time worked.
- Apple Calendar’s optional Keep in Plan connection follows busy times and changes to recurring appointments while Pulse is open. Wrap up by protects the user’s chosen end of day.
- Evening and Night use native iOS dark controls, editors and sheets. Dawn, Daylight and Golden hour use light controls.

## Local verification

- An earlier release passed 121 engine tests and 55 native app tests on iOS 26.2 and 27 simulators. They cover scheduling, persistence, imports, habits, reminders and Focus. Its 13 native UI scenarios passed together, including a long-press drag from Tomorrow, a cross-day recommendation, Undo, and resuming a Focus session after relaunch.
- iPhone 16e, iPhone 17 Pro and iPad Air simulator checks covered native dragging and week timing. A fresh release build carried a saved task time across Berlin, Los Angeles and Kolkata. Its expected energy stayed on the selected local date in all three. Real timed sessions covered pause, resumption, process termination, background expiry and a local midnight rollover.
- A 32-photo journal with 7.7 MB of image data used a 7.1 kB journal record after migration. Twenty note edits took 0.03 seconds in a release-mode SwiftData test on the development Mac, compared with 0.77 seconds when each snapshot embedded the JPEGs.
- A Release benchmark with 5,000 saved tasks, 40 open tasks and 365 check-ins measured median weekly placement at 0.34 seconds, or 0.50 seconds with a deadline. A randomized old/new comparison matched 8,640 energy values and 542 weekly placements.
- A planner replay checked 6,712 candidate starts across 1,006 synthetic journals. Every offered slot passed its scheduling checks. A 40-minute simulator run with 180 tasks, 365 check-ins and 32 photos included 13 idle minutes each on Today and Week. Neither foreground interval wrote to disk. A separate 28-minute run covered 123 circuits of the four tabs, 20 check-ins and 15 relaunches while Focus stayed paused. Its final session excluded all paused time. Hardware battery drain has not been measured.


## Energy activities, time blocks and nonprescription stimulants

In Plan’s Timeline, Tomorrow and Week views, tap New block on the intended day, select Focus or Protected and adjust the start and end times. You can also draw the range on the hourly ruler and drag either handle to resize it. The Add to plan sheet offers New time block for the selected date, with an optional name or weekly repeat. Review and save to add a block for that date. Resizing a weekly block updates its repeating hours.

Drag an Inbox task’s grip onto a date to let Pulse find an available time, or onto a named focus block to schedule work inside that occurrence. Hover over a different day to see its focus blocks. Tapping the grip offers the same choices. Tomorrow and Week also have a From Inbox shelf for tasks without a saved time. Undo restores the previous schedule, including Inbox-only status.

When creating a focus block, Choose a task is available next to the start and end times and in the review. The block and assignment save together once Pulse finds room. A task keeps its original category, and a repeating block assigns the task to the selected occurrence. A focus block can accommodate part of a longer task. Assignment supports planning up to 366 days ahead.

Before a future focus block, Pulse suggests the activity with the strongest typical energy gain in your own before-and-after ratings that fits the available time. Pulse looks for a positive median change across at least three logged days and gives each day equal weight. Accept the suggestion to put it immediately before focus, or pick another activity.

Plan also supports single-date and repeating time blocks from its time block editor. The Health page has dedicated sections for HRV, energy activities, stimulants, OneRep and Screen Time. Jump links below the landscape scroll to the charts and logs in place. Log a boost, a drain, stimulant intake or a lab result from its section. Connected data appears only with the appropriate permissions.

The stimulant log covers labeled caffeine sources, cocoa/theobromine and nicotine products. Products can be named and reused, including custom nonprescription products without a built-in kinetic model. It accepts unknown amounts and patch wear intervals. Lab entries distinguish caffeine, nicotine, theobromine, paraxanthine and cotinine. A post-absorption projection requires an explicitly marked lab result. Dose-based dietary curves are separate from measured blood concentrations. Vape liquid strength and volume and 16- or 24-hour patch labeling retain their units. A user can review a supported personal response estimate before applying it to a future Plan hour. Comparable before-and-after ratings support personal energy estimates and a response trend. Co-use history and perceived-effect ratings cannot establish individual interaction safety or receptor desensitization.

Kinetic assumptions are documented in the app, with links to the [EFSA caffeine summary](https://www.efsa.europa.eu/sites/default/files/corporate_publications/files/efsaexplainscaffeine150527.pdf), [human methylxanthine study](https://pmc.ncbi.nlm.nih.gov/articles/PMC1401099/), [theobromine study](https://pubmed.ncbi.nlm.nih.gov/627135/) and [nicotine formulation study](https://doi.org/10.1007/s40262-020-00960-5).

The integrated feature build passed 184 engine tests, 117 native app tests and 17 UI scenarios. Simulator checks exercised a protected morning, a focus window with a five-minute boost, a retained HRV percentile, and an explicit stimulant response estimate saved into Plan. Screen Time authorization and the empty report were verified. Populated device usage requires a device with usage history. OneRep handoff reached sign-in and source-specific HealthKit tests used synthetic samples. Local development signing grants Family Controls to the app and report extension. App Store distribution requires the corresponding distribution approval for each.
